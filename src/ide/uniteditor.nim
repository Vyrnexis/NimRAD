## `UnitEditor`: the editor of one project unit. A form unit has two views,
## the form designer (the form built from its `.nfm` through the property
## registry, with a `FormDesigner` on top) and the code (`CodeEdit` on the
## `.nim`); a plain unit only has the code. F12 (see `toggleView`) switches.
##
## The designed form is a hidden `Form` object (the model: it carries the
## form's own properties, its handler names and its name) whose children are
## moved into a "design form" panel (a window look-alike with a title bar) so
## that they can be shown, selected and edited inside the IDE window. Saving
## writes the model's properties and the panel's children back to the `.nfm`.
##
## Everything here is single threaded UI code; build the editor after
## `Application.init()`.

import std/[os, strutils, tables, sets, sequtils]
import nimvcl
import nimvcl/dsl/[props, props_std, nfm]
import nimvcl/controls/[inspector, propeditors]
import ./[project, codegen, fileio, nimsource, unitimports]

type
  UnitEditor* = ref object of RootObj
    project*: Project
    unitName*: string
    onSelectionChanged*: proc(e: UnitEditor)
    onModifiedChanged*: proc(e: UnitEditor)
    onDesignChanged*: proc(e: UnitEditor)
      ## The form was edited (any change, also when it was modified before).
    onStructureChanged*: proc(e: UnitEditor)
      ## The set or the names of the components changed (the Object TreeView follows).
    onMessage*: proc(e: UnitEditor, msg: string)
      ## A problem or hint for the status line (a refused rename, ...).
    loadError*: string
      ## Why the form could not be loaded ("" when fine); the unit then only
      ## has its code view and `save` leaves the `.nfm` alone.
    fUnit: ProjectUnit
    fView: Panel
    fScroll: ScrollBox
    fFrame, fBody: Panel
    fTitle: Panel
    fForm: Form                    ## the model of the designed form
    fDesigner: FormDesigner
    fCode: CodeEdit
    fInsp: ObjectInspector
    fHost: PropEditorHost          ## where the "..." editors find pictures (see `propHost`)
    fNfmEol: string
    fDesignDirty: bool
    fLastModified: bool
    fNames: Table[Component, string]
    fExtra: Component              ## selected through the tree, outside the designer
    fPasteCount: int
    fBusy: bool                    ## ignore designer callbacks while rebuilding

  DesignTitle = ref object of Panel
  DesignBody = ref object of Panel

const
  TitleH = 28'f32
  FramePad = 1'f32
  ClipMark = "object nvclipboard: Panel"

var gClipboard = ""   ## fallback when the system clipboard cannot hold the text

# ------------------------------------------------------------------ painting

method paint(p: DesignTitle, c: Canvas) =
  let t = p.theme
  let r = p.clientRect
  c.fillRect(r, t.accent)
  c.drawMnemonic(p.caption, font(t.font.family, t.font.size, {fsBold}),
                 r.inflate(-t.spacing), t.accentText, false, taLeft, vaCenter)
  # window buttons: minimise, maximise, close
  let cy = r.y + r.h / 2
  var x = r.right - 20
  for i in 0 .. 2:
    case 2 - i
    of 0: c.line(x - 5, cy + 3, x + 5, cy + 3, t.accentText, 1.4)
    of 1: c.strokeRoundRect(rectF(x - 5, cy - 5, 10, 9), 0, t.accentText, 1.4)
    else:
      c.line(x - 5, cy - 5, x + 5, cy + 5, t.accentText, 1.4)
      c.line(x - 5, cy + 5, x + 5, cy - 5, t.accentText, 1.4)
    x -= 26
  procCall paint(Control(p), c)

method paint(p: DesignBody, c: Canvas) =
  c.fillRect(p.clientRect, if p.parentColor: p.theme.window else: p.color)
  procCall paint(Control(p), c)

# ------------------------------------------------------------------- helpers

proc styleKey(s: string): string =
  ## Nim identifier equality: the first letter counts, the rest ignores case
  ## and underscores.
  if s.len == 0: return ""
  result = $s[0]
  for ch in s[1 .. ^1]:
    if ch != '_': result.add ch.toLowerAscii

proc isControlClass(ci: ClassInfo): bool =
  var c = ci
  while c != nil:
    if c.name == "Control": return true
    c = c.parent
  false

proc isNonVisualClass(ci: ClassInfo): bool =
  ci != nil and not ci.abstract and not ci.isControlClass and ci.name != "Form" and
    (ci.name in ["Timer", "ImageList", "ActionList", "PopupMenu", "MainMenu"] or
     ci.parent != nil and ci.parent.name == "Component")

func codeOf(e: UnitEditor): string = e.fCode.text

proc say(e: UnitEditor, msg: string) =
  if e.onMessage != nil: e.onMessage(e, msg)

# --------------------------------------------------------------- accessors

proc view*(e: UnitEditor): Control = e.fView
proc isForm*(e: UnitEditor): bool = e.fUnit.isForm
proc code*(e: UnitEditor): CodeEdit = e.fCode
proc designer*(e: UnitEditor): FormDesigner = e.fDesigner
proc designedForm*(e: UnitEditor): Container =
  ## The design root: the panel that holds the controls of the form.
  if e.fBody == nil: nil else: Container(e.fBody)
proc designerVisible*(e: UnitEditor): bool =
  e.fScroll != nil and e.fScroll.visible

proc modified*(e: UnitEditor): bool = e.fDesignDirty or e.fCode.modified

proc checkModified(e: UnitEditor) =
  let m = e.modified
  if m != e.fLastModified:
    e.fLastModified = m
    if e.onModifiedChanged != nil: e.onModifiedChanged(e)

proc touchDesign(e: UnitEditor) =
  if e.fBusy: return
  e.fDesignDirty = true
  e.checkModified()
  if e.onDesignChanged != nil: e.onDesignChanged(e)

# ------------------------------------------------------------------ the tree

proc tiles(e: UnitEditor): seq[NonVisualTile] =
  if e.fDesigner == nil: @[] else: e.fDesigner.nonVisuals

proc tileOf(e: UnitEditor, c: Component): NonVisualTile =
  for t in e.tiles:
    if t.component == c: return t

proc componentOf(e: UnitEditor, c: Control): Component =
  ## The component a design control stands for: the form model for the design
  ## root, the component of a tile, else the control itself.
  if c == nil: nil
  elif c == Control(e.fBody): Component(e.fForm)
  elif c of NonVisualTile: NonVisualTile(c).component
  else: Component(c)

proc walkNames(e: UnitEditor, f: proc(c: Component)) =
  ## Every named thing of the form: the form, its controls (any depth), tiles.
  if e.fForm == nil: return
  f(Component(e.fForm))
  proc rec(o: Obj) =
    for k in kidsOf(o):
      if k of Component:
        f(Component(k))
        rec(k)
  rec(Obj(e.fBody))
  for t in e.tiles:
    f(t.component)
    rec(Obj(t.component))

proc syncNames(e: UnitEditor) =
  e.fNames.clear()
  e.walkNames(proc(c: Component) = e.fNames[c] = c.name)
  if e.onStructureChanged != nil: e.onStructureChanged(e)

proc nameTaken(e: UnitEditor, name: string, skip: Component = nil): bool =
  let key = name.styleKey
  var hit = false
  e.walkNames(proc(c: Component) =
    if c != skip and c.name.styleKey == key: hit = true)
  if hit: return true
  if e.fUnit.formType.styleKey == key: return true
  let fc = classByName("Form")
  fc != nil and fc.findProp(name) != nil       # `caption`, `width`...: a Form field

proc freshName(e: UnitEditor, className: string, extra: HashSet[string] = initHashSet[string]()): string =
  var base = className
  if base.len == 0: base = "Control"
  var n = 1
  while e.nameTaken(base & $n) or (base & $n).styleKey in extra: inc n
  base & $n

proc treeRec(o: Obj, depth: int, res: var seq[(Component, int)]) =
  for k in kidsOf(o):
    if k of Component:
      res.add (Component(k), depth)
      treeRec(k, depth + 1, res)

proc componentTree*(e: UnitEditor): seq[(Component, int)] =
  ## (component, depth) in tree order, for the Object TreeView: the form,
  ## then its controls and tiles with their own children.
  if e.fForm == nil: return
  result.add (Component(e.fForm), 0)
  treeRec(Obj(e.fBody), 1, result)
  for t in e.tiles:
    result.add (t.component, 1)
    treeRec(Obj(t.component), 2, result)

proc selection*(e: UnitEditor): seq[Component] =
  if e.fExtra != nil: return @[e.fExtra]
  if e.fDesigner == nil: return
  for c in e.fDesigner.selection:
    let x = e.componentOf(c)
    if x != nil and x notin result: result.add x

# ------------------------------------------------------------------- code edits

proc posOf(s: string, off: int): CodePos =
  var line = 0
  var last = -1
  for i in 0 ..< off:
    if s[i] == '\n':
      inc line
      last = i
  (line, off - last - 1)

proc isCont(s: string, i: int): bool = i in 0 ..< s.len and (ord(s[i]) and 0xC0) == 0x80

proc setCodeText(e: UnitEditor, newText: string) =
  ## Makes the editor hold `newText` by replacing only the span that differs
  ## (one undo step, the line ending of the file is kept).
  let old = e.fCode.text
  if old == newText: return
  let m = min(old.len, newText.len)
  var a = 0
  while a < m and old[a] == newText[a]: inc a
  while a > 0 and (old.isCont(a) or newText.isCont(a)): dec a
  var b = 0
  while b < m - a and old[old.len - 1 - b] == newText[newText.len - 1 - b]: inc b
  while b > 0 and newText.isCont(newText.len - b): dec b
  # one undo step; the caret and selection stay where they were
  e.fCode.replaceRange(posOf(old, a), posOf(old, old.len - b),
                       newText[a ..< newText.len - b], keepSelection = true)
  e.checkModified()

proc editCode*(e: UnitEditor, change: proc(src: string): string): bool {.discardable.} =
  ## Applies `change` to the text of the code view (one undo step); true when
  ## the text changed. The editor is modified afterwards; save it to keep it.
  let old = e.fCode.text
  let res = change(old)
  if res == old: return false
  e.setCodeText res
  true

proc showCode*(e: UnitEditor) =
  if e.fScroll != nil: e.fScroll.visible = false
  e.fCode.visible = true
  e.fCode.setFocus()

proc showDesigner*(e: UnitEditor) =
  if e.fDesigner == nil: return
  e.fCode.visible = false
  e.fScroll.visible = true

proc toggleView*(e: UnitEditor) =
  if e.designerVisible: e.showCode() else: e.showDesigner()

proc gotoLine*(e: UnitEditor, line, col: int) =
  ## Shows the code and puts the caret at (`line`, `col`), both 1-based as the
  ## compiler prints them (0 or less counts as 1).
  e.showCode()
  e.fCode.gotoLine(max(line, 1) - 1, max(col, 1) - 1)

# ---------------------------------------------------------------- handlers

const PreferredEvents = ["onClick", "onChange", "onTimer", "onExecute", "onShow"]

proc defaultEvent(c: Component): string =
  ## The event a double click creates a handler for.
  let ci = classOf(Obj(c))
  if ci == nil: return ""
  for ev in PreferredEvents:
    let p = ci.findProp(ev)
    if p != nil and p.kind == pkEvent: return ev
  for p in ci.propsOf:
    if p.kind == pkEvent: return p.name

proc handlerNameFor(e: UnitEditor, c: Component, event: string): string =
  let tail = if event.startsWith("on") and event.len > 2: event[2 .. ^1] else: event
  ## Delphi style: component name plus the event, e.g. `Button1Click`, `FormShow`.
  (if c == Component(e.fForm): "Form" else: c.name) & tail

proc createHandler(e: UnitEditor, target: Component, event, handler: string,
                   inheritedBinding = false): StubResult =
  ## Makes sure the handler exists in the code (the stub is inserted when it
  ## does not) and returns where its body starts.
  let ci = classOf(Obj(target))
  var ancType = ""
  if inheritedBinding and target.inherited and e.fUnit.ancestor.len > 0:
    let ancIdx = e.project.findUnit(e.fUnit.ancestor)
    if ancIdx >= 0: ancType = e.project.units[ancIdx].formType
  result = ensureHandlerFor(e.codeOf, e.fUnit.formType,
                            if ci != nil: ci.name else: "", event, handler, ancType)
  if result.inserted: e.setCodeText(result.text)

proc refreshInspector(e: UnitEditor)

proc openHandler(e: UnitEditor, target: Component, event: string) =
  ## Names a handler for `event` of `target` when it has none, creates its stub
  ## and shows the code at it.
  if event.len == 0: return
  var h = handlerNameOf(Obj(target), event)
  let hadName = h.len > 0
  if h.len == 0:
    h = e.handlerNameFor(target, event)
    setProp(Obj(target), event, pvEvent(h))
    e.touchDesign()
  let r = e.createHandler(target, event, h, hadName)
  e.refreshInspector()
  e.showCode()
  e.fCode.gotoLine(r.line, r.col)

# ------------------------------------------------------------------- geometry

proc syncGeometry(e: UnitEditor) =
  ## The frame, title and design root follow the form's size, caption, colour.
  let w = max(e.fForm.width, 16)
  let h = max(e.fForm.height, 16)
  e.fTitle.caption = e.fForm.caption
  e.fBody.setBounds(FramePad, FramePad + TitleH, w, h)
  e.fTitle.setBounds(FramePad, FramePad, w, TitleH)
  e.fFrame.setBounds(e.fFrame.left, e.fFrame.top, w + 2 * FramePad, h + TitleH + 2 * FramePad)
  if not e.fForm.parentColor: e.fBody.color = e.fForm.color
  e.fTitle.invalidate()
  e.fBody.invalidate()

# ------------------------------------------------------------------- loading

proc nfmDir(e: UnitEditor): string =
  ## Image paths of the form are relative to the folder of its `.nfm`.
  e.project.nfmPathOf(e.fUnit).parentDir

proc readNfm(e: UnitEditor): string =
  let path = e.project.nfmPathOf(e.fUnit)
  result = readFile(path)
  e.fNfmEol = if "\r\n" in result: "\r\n" else: "\n"

proc addTile(e: UnitEditor, comp: Component, className: string) =
  ## The tile goes where the component's `designLeft`/`designTop` say.
  e.fDesigner.addNonVisual(comp, className)

proc collectNonVisual(c: Component, seen: HashSet[Obj], res: var seq[Component]) =
  for x in c.components:
    if x of Control:
      collectNonVisual(x, seen, res)
    elif Obj(x) notin seen and classOf(Obj(x)) != nil and classOf(Obj(x)).isNonVisualClass:
      res.add x

proc collectKids(o: Obj, seen: var HashSet[Obj]) =
  for k in kidsOf(o):
    seen.incl k
    collectKids(k, seen)

proc className(c: Component): string =
  let ci = classOf(Obj(c))
  if ci == nil: "" else: ci.name

proc selectionChanged(e: UnitEditor) =
  if e.fBusy: return
  e.fExtra = nil
  e.refreshInspector()
  if e.onSelectionChanged != nil: e.onSelectionChanged(e)

proc defaultCaption(e: UnitEditor, c: Control) =
  ## Delphi gives a new Button the caption "Button1".
  let ci = classOf(Obj(c))
  if ci == nil: return
  for pn in ["caption", "text"]:
    let p = ci.findProp(pn)
    if p != nil and p.kind == pkString and p.get(Obj(c)).s.len == 0 and
       (pn == "caption" or ci.name == "Edit"):
      p.set(Obj(c), pvString(c.name))
      return

proc installDesigner(e: UnitEditor) =
  let d = newFormDesigner(e.fBody, attachNow = false)
  e.fDesigner = d
  d.componentOwner = e.fForm
  d.createControl = proc(className: string): Control =
    let ci = classByName(className)
    if ci == nil or ci.abstract or not ci.isControlClass: return nil
    try:
      let o = ci.createObject(nil, nil)
      if o != nil and o of Control: Control(o) else: nil
    except CatchableError: nil
  d.nameControl = proc(f: FormDesigner, c: Control, className: string): string =
    e.freshName(className)
  d.onSelectionChanged = proc(f: FormDesigner, sel: seq[Control]) = e.selectionChanged()
  d.onModified = proc(f: FormDesigner) =
    e.touchDesign()
    e.syncNames()
    e.refreshInspector()
  d.onCreated = proc(f: FormDesigner, c: Control) =
    e.defaultCaption(c)
    e.touchDesign()
    e.syncNames()
  d.onDeleted = proc(f: FormDesigner, cs: seq[Control]) =
    e.touchDesign()
    e.syncNames()
  d.onDoubleClick = proc(f: FormDesigner, c: Control) =
    let comp = e.componentOf(c)
    if comp != nil: e.openHandler(comp, defaultEvent(comp))
  d.attach()

proc buildDesign(e: UnitEditor, text: string) =
  ## Builds the model form from `text` and the design surface for it. Raises
  ## `NfmError` (nothing is changed then).
  let opt = newNfmOptions(strict = true)
  let form = loadNfm(text, nil, opt, e.project.nfmPathOf(e.fUnit))
  for w in opt.warnings: e.say w          # e.g. a picture that is not there
  e.fBusy = true
  defer: e.fBusy = false
  let frame = newPanel(e.fScroll, "", 16, 16, 100, 100)
  frame.borderStyle = pbSingle
  let title = DesignTitle()
  title.initPanel(frame)
  frame.insertControl title
  let body = DesignBody()
  body.initPanel(frame)
  frame.insertControl body
  body.borderStyle = pbNone
  e.fFrame = frame
  e.fTitle = title
  e.fBody = body
  e.fForm = form
  e.syncGeometry()
  # the designer resizes the design root: the form and the frame follow
  body.onResize = proc(s: Control) =
    if e.fForm == nil or e.fBody == nil: return
    let w = int(e.fBody.width)
    let h = int(e.fBody.height)
    if w != int(e.fForm.width) or h != int(e.fForm.height):
      e.fForm.width = float32(w)
      e.fForm.height = float32(h)
      e.syncGeometry()
      e.touchDesign()
  # tiles: menus and the components that are not controls
  var seen: HashSet[Obj]
  collectKids(Obj(form), seen)
  var comps: seq[Component]
  collectNonVisual(Component(form), seen, comps)
  var kids = form.children
  var menus: seq[Component]
  for c in kids:
    if c of MainMenu:
      menus.add c
      form.removeControl c
    else:
      form.removeControl c
      body.insertControl c
  e.installDesigner()
  for m in menus: e.addTile(m, "MainMenu")
  for c in comps: e.addTile(c, c.className)
  title.onMouseDown = proc(s: Control, b: MouseButton, sh: ShiftState, x, y: float32) =
    if b == mbLeft and e.fDesigner != nil: e.fDesigner.select(Control(e.fBody))
  e.syncNames()

proc teardownDesign(e: UnitEditor) =
  if e.fDesigner != nil:
    e.fDesigner.detach()
    for t in e.tiles:
      if t.component of Timer: Timer(t.component).enabled = false
  if e.fFrame != nil: e.fFrame.free()
  e.fDesigner = nil
  e.fFrame = nil
  e.fBody = nil
  e.fTitle = nil
  e.fForm = nil
  e.fExtra = nil

proc dispose*(e: UnitEditor) =
  ## Call when the editor is closed: the form's timers stop (they would keep
  ## firing, and keep the form alive, in the program-wide timer list).
  e.teardownDesign()

# ---------------------------------------------------------------- inspector

proc objsOf(e: UnitEditor): seq[Obj] =
  for c in e.selection: result.add Obj(c)

proc refreshInspector(e: UnitEditor) =
  if e.fInsp == nil or e.fBusy: return
  e.fInsp.inspect(e.objsOf)

proc descendantProblem(e: UnitEditor, name: string): string =
  ## Why the component `name` cannot change or go: forms that inherit from this
  ## one use it ("" when none does).
  let users = e.project.descendantsUsing(e.unitName, name)
  if users.len > 0:
    "`" & name & "` is used by " & users.join(", ") & ", which inherit from this form"
  else: ""

proc nameProblem(e: UnitEditor, c: Component, nw: string): string =
  ## Why `c` cannot be called `nw` ("" when it can).
  if c == Component(e.fForm): "rename the form from the project, not here"
  elif c.inherited: "`" & c.name & "` comes from the ancestor form and cannot be renamed here"
  elif not isValidIdent(nw): "`" & nw & "` is not a valid identifier"
  elif e.nameTaken(nw, c): "the name `" & nw & "` is already used"
  else: e.descendantProblem(c.name)

proc applyRename(e: UnitEditor, c: Component) =
  let old = e.fNames.getOrDefault(c, "")
  let nw = c.name
  if old == nw: return
  if old.len > 0:
    e.setCodeText(renameComponentRefs(e.codeOf, old, nw, e.fUnit.formType))
  e.fNames[c] = nw
  if e.onStructureChanged != nil: e.onStructureChanged(e)
  let t = e.tileOf(c)
  if t != nil: t.name = nw
  if c of Control: Control(c).invalidate()

proc propertyChanged(e: UnitEditor, target: Obj, prop: string) =
  if not (target of Component): return
  let c = Component(target)
  if prop == "name":
    e.applyRename(c)
  elif prop.startsWith("on"):
    # a handler named by hand: make sure it exists in the code
    let h = handlerNameOf(target, prop)
    if h.len > 0 and not hasProc(e.codeOf, h):
      discard e.createHandler(c, prop, h)
  if c == Component(e.fForm): e.syncGeometry()
  e.touchDesign()
  if e.fDesigner != nil: e.fDesigner.refresh()
  if e.fInsp != nil: e.fInsp.refresh()
  if c of Control and not (c of Form): Control(c).invalidate()

proc itemAdded(e: UnitEditor, parent, item: Obj) =
  ## A collection editor made `item` (a menu item, a page, a column...): it
  ## gets a name (when it is a component) and a caption.
  let ci = classOf(item)
  if item of Component:
    let c = Component(item)
    c.name = e.freshName(if ci != nil: ci.name else: "Item")
    if ci != nil and ci.name in ["MenuItem", "TabSheet", "Action"]:
      let p = ci.findProp("caption")
      if p != nil: p.set(item, pvString(c.name))
  elif ci != nil and ci.name == "ListColumn":
    let p = ci.findProp("caption")
    if p != nil: p.set(item, pvString("Column" & $(kidsOf(parent).len)))
  e.syncNames()

proc propHost*(e: UnitEditor): PropEditorHost =
  ## What the Object Inspector's "..." editors work with: pictures are stored
  ## relative to the `.nfm` and copied into the project's `images/` folder when
  ## they come from elsewhere. (Tests replace `runModal` to drive the dialogs.)
  if e.fHost == nil:
    let h = newPropEditorHost()
    h.onChanged = proc(t: Obj, prop: string) = e.propertyChanged(t, prop)
    h.onItemAdded = proc(parent, item: Obj) = e.itemAdded(parent, item)
    h.onItemRemoved = proc(parent, item: Obj) =
      if item of Component and e.fDesigner != nil:
        e.fDesigner.refresh()
    e.fHost = h
  e.fHost.baseDir = e.nfmDir
  e.fHost.imagesDir = e.project.filePath.parentDir / "images"
  e.fHost

proc bindInspector*(e: UnitEditor, insp: ObjectInspector) =
  ## While bound, `insp` shows the selection of this editor and its edits
  ## apply to the designed form.
  if insp == nil: return
  e.fInsp = insp
  insp.onPropertyChanging = proc(s: Control, t: Obj, prop: string, v: PropValue,
                                 accept: var bool, message: var string) =
    if prop == "name" and t of Component and v.kind == pkString:
      message = e.nameProblem(Component(t), v.s)
      accept = message.len == 0
  insp.onPropertyChanged = proc(s: Control, t: Obj, prop: string) =
    e.propertyChanged(t, prop)
  insp.onCreateHandler = proc(s: Control, t: Obj, event: string): string =
    if not (t of Component): return ""
    let c = Component(t)
    let h = e.handlerNameFor(c, event)
    let r = e.createHandler(c, event, h)
    e.touchDesign()
    e.showCode()
    e.fCode.gotoLine(r.line, r.col)
    h
  insp.onGetHandlers = proc(s: Control, t: Obj, event: string): seq[string] =
    handlerNames(e.codeOf, e.fUnit.formType)
  insp.knownHandlers = @[]
  attachEditors(insp, e.propHost)
  insp.onGetChoices = proc(s: Control, t: Obj, prop: string): seq[Obj] =
    ## the components of the designed form (the design surface sits inside the
    ## IDE window, so walking up from the target would find the IDE's own)
    var all: seq[Obj]
    for (c, _) in e.componentTree:
      if c != Component(e.fForm): all.add Obj(c)
    all
  e.refreshInspector()

proc unbindInspector*(e: UnitEditor) =
  let insp = e.fInsp
  if insp == nil: return
  e.fInsp = nil
  insp.onPropertyChanging = nil
  insp.onPropertyChanged = nil
  insp.onCreateHandler = nil
  insp.onGetHandlers = nil
  insp.onEditExtra = nil
  insp.onGetChoices = nil
  insp.inspect(newSeq[Obj]())

proc inBody(e: UnitEditor, c: Control): bool =
  var p = c.parent
  while p != nil and p != Container(e.fBody): p = p.parent
  p != nil

proc selectComponent*(e: UnitEditor, c: Component) =
  if e.fDesigner == nil or c == nil: return
  e.fExtra = nil
  if c == Component(e.fForm):
    e.fDesigner.select(Control(e.fBody))
  elif e.tileOf(c) != nil:
    e.fDesigner.select(Control(e.tileOf(c)))
  elif c of Control and e.inBody(Control(c)):
    e.fDesigner.select(Control(c))
  else:
    # something the designer does not show (a menu item, a column): inspect it
    e.fDesigner.clearSelection()
    e.fExtra = c
    e.refreshInspector()
    if e.onSelectionChanged != nil: e.onSelectionChanged(e)

# ------------------------------------------------------------- creating things

proc beginCreate*(e: UnitEditor, className: string) =
  ## The next click or drag on the form creates a `className` (a control).
  ## A non-visual class (`Timer`, `ImageList`, ...) is added at once as a tile.
  if e.fDesigner == nil: return
  let ci = classByName(className)
  if ci == nil: return
  if ci.isControlClass and ci.name != "MainMenu":
    e.showDesigner()
    e.fDesigner.beginCreate(className)
  elif ci.isNonVisualClass or ci.name == "MainMenu":     # a main menu is a tile too
    e.showDesigner()
    var o: Obj
    try: o = ci.createObject(Component(e.fForm), nil)
    except CatchableError as ex:
      e.say ex.msg
      return
    if o == nil or not (o of Component): return
    let c = Component(o)
    if c.owner == nil: Component(e.fForm).insertComponent(c)
    c.name = e.freshName(className)
    e.addTile(c, className)
    e.fDesigner.select(Control(e.tileOf(c)))
    e.syncNames()
    e.touchDesign()

# ------------------------------------------------------------------ clipboard

proc topSelected(e: UnitEditor): seq[Control] =
  for c in e.fDesigner.selection:
    if c != Control(e.fBody) and not (c of NonVisualTile): result.add c

proc copySelection*(e: UnitEditor): bool {.discardable.} =
  ## Puts the selected controls (with their children) on the clipboard as
  ## `.nfm` text. Tiles and the form itself are not copied.
  if e.fDesigner == nil: return false
  let sel = e.topSelected
  if sel.len == 0: return false
  let root = newNfmNode("nvclipboard", "Panel")
  for c in sel:
    let n = objectToNfmNode(Obj(c))
    if n != nil: root.children.add n
  if root.children.len == 0: return false
  gClipboard = writeNfm(root)
  Application.clipboard = gClipboard
  e.fPasteCount = 0
  true

proc deleteSelection*(e: UnitEditor): bool {.discardable.} =
  ## Deletes the selection; the handlers stay in the code. Components that come
  ## from the ancestor of an inherited form are never deleted.
  if e.fDesigner == nil: return false
  for c in e.fDesigner.selection:
    if c.inherited or (c of NonVisualTile and NonVisualTile(c).component != nil and
                       NonVisualTile(c).component.inherited):
      e.say "`" & c.name & "` comes from the ancestor form and cannot be deleted"
      return false
  for c in e.fDesigner.selection:
    let problem = e.descendantProblem(c.name)
    if problem.len > 0:
      e.say problem
      return false
  e.fDesigner.deleteSelection()

proc cutSelection*(e: UnitEditor): bool {.discardable.} =
  if e.copySelection(): e.deleteSelection() else: false

proc pasteTarget(e: UnitEditor): Container =
  var c: Container = Container(e.fBody)
  let p = e.fDesigner.primary
  if p != nil and p != Control(e.fBody) and not (p of NonVisualTile):
    var x: Control = p
    while x != nil and x != Control(e.fBody):
      if x of Container and e.fDesigner.acceptsChildren(Container(x)):
        return Container(x)
      x = x.parent
  c

proc paste*(e: UnitEditor): bool {.discardable.} =
  ## Pastes the clipboard's controls into the selected container (else the
  ## form): names that are taken get a new one, the copies move by the grid.
  if e.fDesigner == nil: return false
  var text = Application.clipboard
  if not text.startsWith(ClipMark): text = gClipboard
  if not text.startsWith(ClipMark): return false
  var root: NfmNode
  try: root = parseNfm(text)
  except CatchableError: return false
  # new names for everything that collides, references follow
  var renamed = initTable[string, string]()
  var taken = initHashSet[string]()
  for top in root.children:
    for n in walk(top):
      if n.name.len > 0 and (e.nameTaken(n.name) or n.name.styleKey in taken):
        renamed[n.name] = e.freshName(n.className, taken)
        n.name = renamed[n.name]
      if n.name.len > 0: taken.incl n.name.styleKey
  for top in root.children:
    for n in walk(top):
      for p in n.props.mitems:
        if p.value.kind == nvIdent and not p.name.startsWith("on") and
           p.value.text in renamed:
          p.value.text = renamed[p.value.text]
  var tmp: Obj
  let popt = newNfmOptions(strict = true)
  popt.baseDir = e.nfmDir
  try: tmp = buildNfm(root, Component(e.fForm), popt)
  except CatchableError as ex:
    e.say "cannot paste: " & ex.msg
    return false
  if tmp == nil or not (tmp of Container): return false
  let target = e.pasteTarget
  inc e.fPasteCount
  let off = max(e.fDesigner.grid, 8) * float32(e.fPasteCount)
  var added: seq[Control]
  for c in Container(tmp).children:
    if c.align == alNone: c.setBounds(c.left + off, c.top + off, c.width, c.height)
    Component(e.fForm).insertComponent(c)
    var cn = classOf(Obj(c))
    e.fDesigner.insertNew(target, c, if cn != nil: cn.name else: "")
    added.add c
  Component(e.fForm).removeComponent(Component(tmp))
  if added.len > 0: e.fDesigner.select(added)
  e.syncNames()
  e.touchDesign()
  true

proc undo*(e: UnitEditor): bool {.discardable.} =
  e.fDesigner != nil and e.fDesigner.undo()
proc redo*(e: UnitEditor): bool {.discardable.} =
  e.fDesigner != nil and e.fDesigner.redo()

# ---------------------------------------------------------------- save / load

proc designNfm(e: UnitEditor): string =
  ## The `.nfm` text of the designed form. An inherited form is written as the
  ## difference from its ancestor's file (read afresh).
  var root: NfmNode
  if e.fForm.ancestorPath.len > 0:
    var kids: seq[Obj]
    for c in e.fBody.children: kids.add Obj(c)
    for t in e.tiles: kids.add Obj(t.component)
    root = formToNfmNode(e.fForm, kids)
  else:
    root = objectToNfmNode(Obj(e.fForm))
    root.children = @[]
    for c in e.fBody.children:
      let n = objectToNfmNode(Obj(c))
      if n != nil: root.children.add n
    for t in e.tiles:
      let n = objectToNfmNode(Obj(t.component))
      if n != nil: root.children.add n
  result = writeNfm(root)
  if e.fNfmEol == "\r\n": result = result.replace("\n", "\r\n")

proc save*(e: UnitEditor) =
  ## Writes the `.nfm` (when the form changed) and the `.nim` (when the code
  ## changed); both are clean afterwards. The control imports between the
  ## `nimrad: imports` markers of the `.nim` follow the classes of the form
  ## (see `unitimports`).
  if e.fDesigner != nil and e.fDesignDirty:
    let nfm = e.designNfm
    writeFileAtomic(e.project.nfmPathOf(e.fUnit), nfm)
    e.fDesignDirty = false
    if e.fUnit.isForm:
      e.setCodeText(syncFromNfm(e.codeOf, nfm, e.nfmDir, e.project.importAll))
  if e.fCode.modified or not fileExists(e.project.nimPathOf(e.fUnit)):
    e.fCode.saveToFile(e.project.nimPathOf(e.fUnit))
  e.checkModified()

proc loadCode(e: UnitEditor) =
  let path = e.project.nimPathOf(e.fUnit)
  if fileExists(path):
    e.fCode.loadFromFile(path)
  e.fCode.highlighter = newNimHighlighter()
  e.fCode.fileName = path

proc syncLoadedImports(e: UnitEditor) =
  ## The imports of the unit follow the classes of the `.nfm` as it is on disk
  ## (it may have been edited outside the designer).
  if e.fUnit.isForm and e.fDesigner != nil and fileExists(e.project.nfmPathOf(e.fUnit)):
    e.setCodeText(syncFromNfm(e.codeOf, readFile(e.project.nfmPathOf(e.fUnit)), e.nfmDir,
                              e.project.importAll))

proc reloadFromDisk*(e: UnitEditor) =
  ## Re-reads the `.nim` and the `.nfm`, dropping every unsaved change.
  e.loadCode()
  if e.fUnit.isForm and fileExists(e.project.nfmPathOf(e.fUnit)):
    let sel = e.selection
    var selName = ""
    if sel.len == 1: selName = sel[0].name
    let wasDesigner = e.designerVisible
    e.teardownDesign()
    try:
      e.buildDesign(e.readNfm())
      e.loadError = ""
    except CatchableError as ex:
      e.loadError = ex.msg
      e.say "cannot load " & e.fUnit.nfmPath & ": " & ex.msg
    if e.fDesigner != nil:
      e.fDesigner.select(Control(e.fBody))
      e.fScroll.visible = wasDesigner
      e.fCode.visible = not wasDesigner
    else:
      e.fCode.visible = true
  e.syncLoadedImports()
  e.fDesignDirty = false
  e.fExtra = nil
  e.refreshInspector()
  e.checkModified()
  if e.onSelectionChanged != nil: e.onSelectionChanged(e)

# ------------------------------------------------------------------ creation

proc newUnitEditor*(project: Project, unitName: string, parent: Container): UnitEditor =
  ## Builds a Panel (alClient in `parent`) holding the form designer (form
  ## units only) and the code editor of unit `unitName`.
  let idx = project.findUnit(unitName)
  if idx < 0: raise newException(ProjectError, "no unit " & unitName)
  new result
  let e = result
  e.project = project
  e.unitName = unitName
  e.fUnit = project.units[idx]
  e.fNfmEol = "\n"
  let view = newPanel(parent)
  view.align = alClient
  view.borderStyle = pbNone
  e.fView = view
  # the code
  let ed = newCodeEdit(view)
  ed.align = alClient
  ed.tabWidth = 2
  e.fCode = ed
  e.loadCode()
  ed.onModifiedChanged = proc(s: Control) = e.checkModified()
  # the designer
  if e.fUnit.isForm and e.fUnit.nfmPath.len > 0 and
     fileExists(project.nfmPathOf(e.fUnit)):
    let sb = newScrollBox(view)
    sb.align = alClient
    sb.autoContentSize = true
    sb.padding = spacing(0)
    e.fScroll = sb
    try:
      e.buildDesign(e.readNfm())
    except CatchableError as ex:
      e.loadError = ex.msg
      sb.visible = false
      e.fScroll = nil
      sb.free()
    if e.fDesigner != nil:
      ed.visible = false
      e.fDesigner.select(Control(e.fBody))
    e.syncLoadedImports()
  e.fLastModified = false
