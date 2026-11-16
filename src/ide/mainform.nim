## The IDE's main window: menu, toolbars, component palette and a docking
## layout (Object TreeView and Object Inspector on the left, the unit editors
## in the middle, the Project Manager on the right, Messages at the bottom).
##
## Everything the user can do is a proc on `IdeForm` (`openProject`,
## `openUnit`, `compile`, `run`, ...), so the scripted session and the tests
## drive the same code as the menu. The few modal dialogs (save changes,
## errors, text input, file choice) are hooks (`askSave`, `showError`,
## `askText`, `pickFile`) that tests replace.
##
## Where things live:
##
## * commands: `actions.nim` (one `ActionList`); this module sets their
##   `onExecute` and keeps their state current in `refreshActions`;
## * `refreshTree`, `refreshActions`, ... are called from an idle hook after
##   every batch of events (`sync`), and by hand in headless scripts.

import std/[os, strutils, tables, times, sequtils]
import nimvcl
import nimvcl/controls/inspector
import nimvcl/dsl/[props, props_std]
import ./[project, builder, messages, ideconfig, icons, actions, palette,
          projecttree, messagespanel, uniteditor]

const
  AppName* = "nimvcl IDE"
  AppVersion* = "0.0.1"

type
  SaveChoice* = enum scSave, scDiscard, scCancel

  IdeForm* = ref object of Form
    settings*: Settings
    settingsFile*: string
    project*: Project
    acts*: IdeActions
    ideIcons*: ImageList
    palIcons: ImageList
    palIndex: Table[string, int]
    menu: MainMenu
    recentMenu: MenuItem
    palette*: ComponentPalette
    site*: DockSite
    pnlTree*, pnlInspector*, pnlProject*, pnlMessages*, pnlEditors*: DockPanel
    objTree*: TreeView
    inspector*: ObjectInspector
    projectTree*: ProjectTree
    messages*: MessagesPanel
    pages*: PageControl
    status*: StatusBar
    editors*: seq[UnitEditor]
    sheets: seq[TabSheet]
    bound: UnitEditor
    defaultLayout*: string
    treeSig: string
    treeComps: seq[Component]
    treeNodes: seq[TreeNode]
    syncingTree: bool
    pendingRun: bool
    buildStart: float
    runUnits: int
    lastBuildOk*: bool
    lastBuildInfo*: string
    buildCount*: int
    # modal dialogs (replaced by tests)
    askSave*: proc(unitName: string): SaveChoice
    showError*: proc(text: string)
    askText*: proc(caption, prompt: string, value: var string): bool
    pickFile*: proc(title: string, filters: seq[(string, string)]): string

  StatusPart = enum spState, spBuild, spCaret, spModified, spMessage

# ------------------------------------------------------------------ dialogs

proc askSaveDefault(unitName: string): SaveChoice =
  let d = newForm(nil, 440, 150)
  d.caption = "Save changes"
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  newLabel(d, "Save changes to " & unitName & "?", 24, 28, 390)
  let save = newButton(d, "&Save", 96, 90, 96, 32)
  save.modalResult = mrYes
  save.isDefault = true
  let discardBtn = newButton(d, "Do&n't Save", 200, 90, 112, 32)
  discardBtn.modalResult = mrNo
  let cancel = newButton(d, "Cancel", 320, 90, 96, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  let r = d.showModal()
  d.freeWindow()
  case r
  of mrYes: scSave
  of mrNo: scDiscard
  else: scCancel

proc defaultProjectsDir*(): string = getHomeDir() / "nimvcl-projects"

# ------------------------------------------------------------------ helpers

proc say*(ide: IdeForm, text: string) =
  ide.status.panels[ord spMessage].text = text

proc setPart(ide: IdeForm, part: StatusPart, text: string) =
  ide.status.panels[ord part].text = text

proc fail(ide: IdeForm, text: string) =
  ide.say text
  if ide.showError != nil: ide.showError text

proc activeIndex(ide: IdeForm): int =
  if ide.editors.len == 0: -1 else: ide.pages.activePageIndex

proc activeEditor*(ide: IdeForm): UnitEditor =
  let i = ide.activeIndex
  if i >= 0 and i < ide.editors.len: ide.editors[i] else: nil

proc editorIndex*(ide: IdeForm, unitName: string): int =
  for i, e in ide.editors:
    if e.unitName == unitName: return i
  -1

proc editorOf*(ide: IdeForm, unitName: string): UnitEditor =
  let i = ide.editorIndex(unitName)
  if i >= 0: ide.editors[i] else: nil

proc busy*(ide: IdeForm): bool = buildState() != bsIdle

proc saveSettings*(ide: IdeForm) =
  discard ideconfig.saveSettings(ide.settings, ide.settingsFile)

proc isDark*(ide: IdeForm): bool = ide.settings.theme == "dark"

proc editorFont(ide: IdeForm): FontSpec =
  result = currentTheme().monoFont
  result.size = ide.settings.editorFontSize.float32

proc applyEditorFont*(ide: IdeForm) =
  for e in ide.editors: e.code.font = ide.editorFont
  ide.messages.output.font = ide.editorFont

proc updateCaption(ide: IdeForm) =
  ide.caption = AppName & (if ide.project != nil: " - " & ide.project.name else: "")

proc modifiedUnits*(ide: IdeForm): seq[string] =
  for e in ide.editors:
    if e.modified: result.add e.unitName

proc updateTabs(ide: IdeForm) =
  for i, e in ide.editors:
    let cap = e.unitName & (if e.modified: "*" else: "")
    if ide.sheets[i].caption != cap: ide.sheets[i].caption = cap

# --------------------------------------------------------------- object tree

proc classNameOfComp(c: Component): string =
  let ci = classOf(Obj(c))
  if ci != nil: ci.name else: "?"

proc refreshTree*(ide: IdeForm) =
  ## Rebuilds the Object TreeView when the form's components changed, and
  ## selects the node of the selected component.
  let ed = ide.activeEditor
  var flat: seq[(Component, int)]
  if ed != nil and ed.isForm: flat = ed.componentTree
  var sig = ""
  for (c, d) in flat: sig.add $d & ":" & c.name & ":" & classNameOfComp(c) & ";"
  if sig != ide.treeSig:
    ide.treeSig = sig
    ide.syncingTree = true
    ide.objTree.beginUpdate()
    ide.objTree.items.clear()
    ide.treeComps.setLen 0
    ide.treeNodes.setLen 0
    var stack: seq[TreeNode]
    for (c, depth) in flat:
      let cls = classNameOfComp(c)
      let text = c.name & ": " & cls
      var n: TreeNode
      if depth <= 0 or stack.len == 0:
        n = ide.objTree.items.addChild(nil, text)
        stack = @[n]
      else:
        while stack.len > depth: stack.setLen stack.len - 1
        n = stack[^1].addChild(text)
        stack.add n
      n.tag = ide.treeComps.len
      n.imageIndex = ide.palIndex.iconOf(cls)
      n.selectedIndex = n.imageIndex
      ide.treeComps.add c
      ide.treeNodes.add n
    ide.objTree.expandAll()
    ide.objTree.endUpdate()
    ide.syncingTree = false
  # selection
  if ed != nil and ed.isForm:
    let sel = ed.selection
    if sel.len > 0:
      let i = ide.treeComps.find(sel[0])
      if i >= 0 and i < ide.treeNodes.len and ide.objTree.selected != ide.treeNodes[i]:
        ide.syncingTree = true
        ide.objTree.selected = ide.treeNodes[i]
        ide.syncingTree = false

# ------------------------------------------------------------------ editing

proc routeToDesigner(ide: IdeForm): bool =
  let ed = ide.activeEditor
  ed != nil and ed.isForm and ed.designerVisible

proc editUndo*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed == nil: return
  if ide.routeToDesigner: discard ed.designer.undo() else: ed.code.undo()

proc editRedo*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed == nil: return
  if ide.routeToDesigner: discard ed.designer.redo() else: ed.code.redo()

proc editCut*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed == nil: return
  if ide.routeToDesigner: ed.cutSelection() else: ed.code.cutToClipboard()

proc editCopy*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed == nil: return
  if ide.routeToDesigner: ed.copySelection() else: ed.code.copyToClipboard()

proc editPaste*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed == nil: return
  if ide.routeToDesigner: ed.paste() else: ed.code.pasteFromClipboard()

proc editDelete*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed == nil: return
  if ide.routeToDesigner: ed.deleteSelection()
  elif ed.code.hasSelection:
    let keep = Application.clipboard      # cut would overwrite the clipboard
    ed.code.cutToClipboard()
    Application.clipboard = keep

proc editSelectAll*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed == nil: return
  if ide.routeToDesigner:
    var all: seq[Control]
    for c in ed.designedForm.children: all.add c
    if all.len > 0: ed.designer.select(all)
  else: ed.code.selectAll()

proc toggleView*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed != nil and ed.isForm: ed.toggleView()

# -------------------------------------------------------------------- search

proc codeOfActive(ide: IdeForm): CodeEdit =
  let ed = ide.activeEditor
  if ed == nil: return nil
  if ed.isForm and ed.designerVisible: ed.showCode()
  ed.code

proc findText*(ide: IdeForm, replace = false) =
  let c = ide.codeOfActive
  if c != nil:
    c.showFindBar(replace)

proc findNext*(ide: IdeForm) =
  let c = ide.codeOfActive
  if c != nil: discard c.findNext()

proc gotoLineDialog*(ide: IdeForm) =
  let c = ide.codeOfActive
  if c == nil: return
  var v = $(c.caretPos.line + 1)
  let ok =
    if ide.askText != nil: ide.askText("Go to Line Number", "Enter new line number:", v)
    else: inputQuery("Go to Line Number", "Enter new line number:", v)
  if ok:
    try:
      let n = parseInt(v.strip)
      c.gotoLine(max(n - 1, 0))
    except ValueError:
      ide.say "Not a line number: " & v

# --------------------------------------------------------------------- panels

proc panelShown(p: DockPanel): bool = p.state != dpHidden

proc toggleDockPanel*(ide: IdeForm, p: DockPanel) =
  if p.state == dpHidden: p.show() else: p.hide()

proc showPanel*(ide: IdeForm, p: DockPanel) =
  if p.state == dpHidden: p.show() else: p.activate()

proc resetLayout*(ide: IdeForm) =
  discard ide.site.loadLayout(ide.defaultLayout)
  for p in ide.site.panels:
    if p.state == dpHidden: p.show()

proc saveLayout*(ide: IdeForm) =
  ## Stores the docking layout in the settings (and writes them).
  ide.settings.layout = ide.site.saveLayout()
  ide.saveSettings()

# ----------------------------------------------------------------- selection

proc selectionChanged(ide: IdeForm) =
  ide.refreshTree()
  let ed = ide.activeEditor
  if ed != nil and ed.isForm and ide.palette.picked.len > 0 and ed.designer.creating.len == 0:
    ide.palette.reset()      # the component was placed (or the placement was cancelled)
  if ed != nil and ed.isForm:
    let sel = ed.selection
    if sel.len == 1: ide.say sel[0].name & ": " & classNameOfComp(sel[0])
    elif sel.len > 1: ide.say $sel.len & " components selected"

proc bindActive*(ide: IdeForm) =
  ## Makes the active editor the one the Object Inspector and TreeView show.
  let ed = ide.activeEditor
  if ide.bound != nil and ide.bound != ed:
    if ide.bound.isForm: ide.bound.designer.cancelCreate()
    ide.bound.unbindInspector()
  ide.palette.reset()
  if ed != nil and ide.bound != ed:
    ed.bindInspector(ide.inspector)
    let prev = ide.inspector.onPropertyChanged
    ide.inspector.onPropertyChanged = proc(s: Control, t: Obj, prop: string) =
      if prev != nil: prev(s, t, prop)
      ide.refreshTree()
      ide.updateTabs()
  elif ed == nil:
    ide.inspector.inspect(newSeq[Obj]())
  ide.bound = ed
  ide.treeSig = "\0"
  ide.refreshTree()
  if ed != nil: ide.projectTree.selectUnit(ed.unitName)

# ---------------------------------------------------------------- actions state

proc refreshActions*(ide: IdeForm) =
  let a = ide.acts
  let ed = ide.activeEditor
  let busy = ide.busy
  let hasProject = ide.project != nil
  let designer = ide.routeToDesigner
  let hasSel = designer and ed.designer.selection.len > 0
  a[aNewForm].enabled = hasProject
  a[aSave].enabled = ed != nil
  a[aSaveAll].enabled = hasProject
  a[aClose].enabled = ed != nil
  a[aUndo].enabled = ed != nil and (not designer or ed.designer.canUndo)
  a[aRedo].enabled = ed != nil
  a[aCut].enabled = ed != nil and (not designer or hasSel)
  a[aCopy].enabled = ed != nil and (not designer or hasSel)
  a[aPaste].enabled = ed != nil
  a[aDelete].enabled = ed != nil and (not designer or hasSel)
  a[aSelectAll].enabled = ed != nil
  for id in [aFind, aReplace, aFindNext, aGotoLine]: a[id].enabled = ed != nil
  a[aToggleView].enabled = ed != nil and ed.isForm
  a[aAddToProject].enabled = hasProject
  a[aRemoveFromProject].enabled = ed != nil
  a[aProjectOptions].enabled = hasProject
  a[aCompile].enabled = hasProject and not busy
  a[aRun].enabled = hasProject and not busy
  a[aReset].enabled = busy
  a[aPointer].enabled = designer
  for id in [aBringToFront, aSendToBack, aAlignLefts, aAlignTops, aCenterH, aCenterV]:
    a[id].enabled = hasSel
  a[aViewProjectMgr].checked = ide.pnlProject.state != dpHidden
  a[aViewInspector].checked = ide.pnlInspector.state != dpHidden
  a[aViewTree].checked = ide.pnlTree.state != dpHidden
  a[aViewMessages].checked = ide.pnlMessages.state != dpHidden
  a[aTheme].checked = ide.isDark

proc updateStatus(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed != nil and not (ed.isForm and ed.designerVisible):
    let p = ed.code.caretPos
    ide.setPart(spCaret, $(p.line + 1) & ": " & $(p.col + 1))
  else:
    ide.setPart(spCaret, "")
  ide.setPart(spModified, if ed != nil and ed.modified: "Modified" else: "")

proc sync*(ide: IdeForm) =
  ## Brings the derived UI state up to date (also runs after every batch of
  ## events). Cheap when nothing changed.
  ide.refreshTree()
  ide.refreshActions()
  ide.updateStatus()
  ide.updateTabs()
  let ed = ide.activeEditor
  if ed != nil and ed.isForm and ide.palette.picked.len > 0 and ed.designer.creating.len == 0:
    ide.palette.reset()

# ------------------------------------------------------------------- units

proc hookEditor(ide: IdeForm, ed: UnitEditor) =
  ed.onSelectionChanged = proc(e: UnitEditor) = ide.selectionChanged()
  ed.onModifiedChanged = proc(e: UnitEditor) =
    ide.updateTabs()
    ide.updateStatus()
  ed.onMessage = proc(e: UnitEditor, msg: string) = ide.say msg
  ed.code.onCaretMove = proc(s: Control, line, col: int) = ide.updateStatus()

proc openUnit*(ide: IdeForm, unitName: string): UnitEditor =
  ## Opens (or activates) the editor tab of a unit; nil when there is no such unit.
  if ide.project == nil: return nil
  let i = ide.editorIndex(unitName)
  if i >= 0:
    ide.pages.activePageIndex = i
    ide.bindActive()
    return ide.editors[i]
  if ide.project.findUnit(unitName) < 0: return nil
  let sheet = newTabSheet(ide.pages, unitName)
  var ed: UnitEditor
  try:
    ed = newUnitEditor(ide.project, unitName, sheet)
  except CatchableError as e:
    sheet.free()
    ide.fail "Cannot open " & unitName & ": " & e.msg
    return nil
  ed.view.align = alClient
  ide.editors.add ed
  ide.sheets.add sheet
  ide.hookEditor ed
  ed.code.font = ide.editorFont
  ide.pages.activePage = sheet
  ide.bindActive()
  ide.say "Opened " & unitName
  ed

proc closeEditor*(ide: IdeForm, ed: UnitEditor): bool =
  ## Closes a unit's tab; asks what to do with unsaved changes (false = the
  ## user cancelled).
  let i = ide.editors.find(ed)
  if i < 0: return true
  if ed.modified:
    let choice = if ide.askSave != nil: ide.askSave(ed.unitName) else: scSave
    case choice
    of scCancel: return false
    of scSave: ed.save()
    of scDiscard: discard
  if ide.bound == ed:
    if ed.isForm: ed.designer.cancelCreate()
    ed.unbindInspector()
    ide.bound = nil
  let sheet = ide.sheets[i]
  ide.editors.delete i
  ide.sheets.delete i
  sheet.free()
  if ide.editors.len > 0:
    ide.pages.activePageIndex = min(i, ide.editors.len - 1)
  ide.bindActive()
  true

proc closeAllEditors*(ide: IdeForm): bool =
  ## Closes every unit (prompting for the modified ones); false on cancel.
  while ide.editors.len > 0:
    if not ide.closeEditor(ide.editors[^1]): return false
  true

proc saveActive*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed == nil: return
  ed.save()
  ide.updateTabs()
  ide.say "Saved " & ed.unitName

proc saveAll*(ide: IdeForm) =
  for e in ide.editors: e.save()
  if ide.project != nil: ide.project.save()
  ide.updateTabs()
  ide.say "All saved"

# ----------------------------------------------------------------- projects

proc refreshProject(ide: IdeForm) =
  ide.projectTree.refresh(ide.project)
  ide.updateCaption()
  let ed = ide.activeEditor
  if ed != nil: ide.projectTree.selectUnit(ed.unitName)

proc closeProject*(ide: IdeForm): bool =
  ## Closes the project and its editors (false: cancelled at the save prompt).
  if not ide.closeAllEditors(): return false
  if ide.project != nil: ide.project.save()
  ide.project = nil
  ide.messages.clear()
  ide.refreshProject()
  true

proc rememberProject(ide: IdeForm) =
  ide.settings.addRecent(ide.project.filePath)
  ide.saveSettings()

proc openProject*(ide: IdeForm, path: string): bool

proc openHandler(ide: IdeForm, path: string): MenuItemEvent =
  result = proc(s: MenuItem) = discard ide.openProject(path)

proc rebuildRecentMenu(ide: IdeForm) =
  ide.recentMenu.clear()
  if ide.settings.recentProjects.len == 0:
    let none = ide.recentMenu.addItem("(none)")
    none.enabled = false
    return
  for path in ide.settings.recentProjects:
    ide.recentMenu.addItem(path.extractFilename.changeFileExt("") & "   " & path.parentDir,
                           openHandler(ide, path))

proc openProject*(ide: IdeForm, path: string): bool =
  ## Opens a `.nimproj` (the current project is closed first).
  var p: Project
  try:
    p = loadProject(path)
  except CatchableError as e:
    ide.settings.removeRecent(path)
    ide.saveSettings()
    ide.rebuildRecentMenu()
    ide.fail "Cannot open " & path & ": " & e.msg
    return false
  if not ide.closeProject(): return false
  ide.project = p
  ide.messages.clear()
  ide.refreshProject()
  ide.rememberProject()
  ide.rebuildRecentMenu()
  if p.units.len > 0: discard ide.openUnit(p.units[0].name)
  ide.say "Opened project " & p.name
  true

proc nextProjectName(dir: string): string =
  var n = 1
  while dirExists(dir / ("Project" & $n)) or fileExists(dir / ("Project" & $n & ProjectExt)): inc n
  "Project" & $n

proc newApplication*(ide: IdeForm, dir = "", name = ""): bool =
  ## File > New Application: a project with one form. Without `dir` it goes to
  ## `~/nimvcl-projects/ProjectN`.
  if not ide.closeProject(): return false
  var d = dir
  var n = name
  if d.len == 0:
    n = nextProjectName(defaultProjectsDir())
    d = defaultProjectsDir() / n
  elif n.len == 0:
    n = d.extractFilename
  try:
    ide.project = newApplicationProject(d, n)
  except CatchableError as e:
    ide.fail "Cannot create the project: " & e.msg
    return false
  ide.messages.clear()
  ide.refreshProject()
  ide.rememberProject()
  ide.rebuildRecentMenu()
  if ide.project.units.len > 0: discard ide.openUnit(ide.project.units[0].name)
  ide.say "Created project " & ide.project.name & " in " & ide.project.dir
  true

proc newForm*(ide: IdeForm): UnitEditor =
  ## File > New Form: adds a form unit to the project and opens it.
  if ide.project == nil: return nil
  try:
    let u = ide.project.newFormUnit()
    ide.project.save()
    ide.refreshProject()
    result = ide.openUnit(u.name)
  except CatchableError as e:
    ide.fail "Cannot create the form: " & e.msg

proc formTypeOfNfm(path: string): string =
  ## `object Form1: Form` -> "Form1".
  try:
    for l in lines(path):
      let t = l.strip
      if t.startsWith("object "):
        let r = t[7 .. ^1]
        let c = r.find(':')
        return (if c > 0: r[0 ..< c] else: r).strip
  except CatchableError: discard

proc addToProject*(ide: IdeForm, path: string): bool =
  ## Adds an existing `.nim` unit (a form unit when a `.nfm` of the same name
  ## sits next to it).
  if ide.project == nil: return false
  let name = path.splitFile.name
  let nfm = path.changeFileExt(".nfm")
  try:
    if not validName(name): raise newException(ProjectError, "bad unit name " & name)
    if fileExists(nfm):
      discard ide.project.addUnit(name, path, nfm, true, formTypeOfNfm(nfm))
    else:
      discard ide.project.addUnit(name, path)
    ide.project.save()
    ide.refreshProject()
    discard ide.openUnit(name)
    result = true
  except CatchableError as e:
    ide.fail "Cannot add " & path & ": " & e.msg

proc removeFromProject*(ide: IdeForm, unitName: string): bool =
  ## Takes a unit out of the project (its files stay on disk). The unit that
  ## makes the main form cannot be removed.
  if ide.project == nil: return false
  let i = ide.project.findUnit(unitName)
  if i < 0: return false
  let u = ide.project.units[i]
  let mainSrc = try: readFile(ide.project.mainPath) except CatchableError: ""
  if u.isForm and ("new" & u.formType & "(") in mainSrc:
    ide.fail "The main form (" & u.formType & ") cannot be removed from the project."
    return false
  let ed = ide.editorOf(unitName)
  if ed != nil and not ide.closeEditor(ed): return false
  ide.project.removeUnit(unitName)
  ide.project.save()
  # drop the import line from the main file
  var kept: seq[string]
  var changed = false
  for l in mainSrc.splitLines:
    if l.strip == "import " & unitName: changed = true
    else: kept.add l
  if changed: writeFile(ide.project.mainPath, kept.join("\n"))
  ide.refreshProject()
  true

proc showProjectOptions*(ide: IdeForm) =
  ## Project > Options: output folder, extra compiler flags, run arguments.
  if ide.project == nil: return
  let p = ide.project
  let d = newForm(nil, 480, 250)
  d.caption = "Project Options"
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  newLabel(d, "Output folder:", 20, 20, 120)
  let outDir = newEdit(d, p.outputDir, 150, 16, 310)
  newLabel(d, "Compiler flags:", 20, 62, 120)
  let flags = newEdit(d, p.nimFlags.join(" "), 150, 58, 310)
  newLabel(d, "Run arguments:", 20, 104, 120)
  let args = newEdit(d, p.runArgs.join(" "), 150, 100, 310)
  let hint = newLabel(d, "Flags are passed to `nim c`, e.g.  -d:release --threads:on", 20, 142, 440)
  hint.muted = true
  let ok = newButton(d, "OK", 284, 190, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 376, 190, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  if d.showModal() == mrOk:
    p.outputDir = if outDir.text.strip.len > 0: outDir.text.strip else: "build"
    p.nimFlags = flags.text.splitWhitespace
    p.runArgs = args.text.splitWhitespace
    p.save()
    ide.say "Project options saved"
  d.freeWindow()

# ------------------------------------------------------------------- jumping

proc unitOfFile*(ide: IdeForm, file: string): string =
  ## The unit whose `.nim` is `file` ("" when it is not a unit of the project).
  if ide.project == nil: return ""
  let f = normalizedPath(file)
  for u in ide.project.units:
    if normalizedPath(ide.project.nimPathOf(u)) == f: return u.name

proc jumpTo*(ide: IdeForm, file: string, line, col: int): bool =
  ## Opens the unit of `file` in its code view with the caret at `line`,
  ## `col` (1-based, as the compiler prints them).
  let name = ide.unitOfFile(file)
  if name.len == 0:
    ide.say "Not a unit of this project: " & file.extractFilename
    return false
  let ed = ide.openUnit(name)
  if ed == nil: return false
  ed.gotoLine(line, col)
  ide.activeControl = ed.code
  true

# ---------------------------------------------------------------- build / run

proc buildOptions(ide: IdeForm): BuildOptions =
  result = defaultBuildOptions()
  result.nimExe = ide.settings.nimPath

proc countLines(ide: IdeForm): int =
  if ide.project == nil: return 0
  var files = @[ide.project.mainPath]
  for u in ide.project.units: files.add ide.project.nimPathOf(u)
  for f in files:
    try: result += readFile(f).countLines
    except CatchableError: discard

proc secs(t: float): string = formatFloat(t, ffDecimal, 1) & " s"

proc clearErrorMarkers(ide: IdeForm) =
  for e in ide.editors: e.code.clearMarkers(MarkerKind.mkError)

proc markErrors(ide: IdeForm) =
  for m in ide.messages.msgs:
    if m.kind == MessageKind.mkError and m.hasLocation:
      let ed = ide.editorOf(ide.unitOfFile(m.file))
      if ed != nil: ed.code.addMarker(max(m.line - 1, 0), MarkerKind.mkError)

proc startProgram(ide: IdeForm) =
  let p = ide.project
  ide.messages.addOutput "--- running " & p.exePath.extractFilename & " ---"
  let onLine = proc(line: string) = ide.messages.addOutput(line)
  let onExit = proc(code: int) =
    ide.messages.addOutput("--- program ended with exit code " & $code & " ---")
    ide.setPart(spState, "Ready")
    ide.say "Program ended (exit code " & $code & ")"
    ide.refreshActions()
  let started = runProject(p, onLine, onExit)
  if started:
    ide.setPart(spState, "Running")
    ide.say "Running " & p.name
  else:
    ide.fail "Cannot start " & p.exePath
  ide.refreshActions()

proc compileDone(ide: IdeForm, ok: bool) =
  let dt = epochTime() - ide.buildStart
  ide.messages.finish()
  ide.lastBuildOk = ok
  inc ide.buildCount
  let lines = ide.countLines
  ide.lastBuildInfo = $lines & " lines, " & secs(dt)
  ide.setPart(spBuild, ide.lastBuildInfo)
  ide.setPart(spState, "Ready")
  if ok:
    ide.messages.addNote("Build succeeded: " & ide.project.name & " (" & $ide.messages.warningCount &
                         " warnings, " & secs(dt) & ")", icSuccess)
    ide.say "Build succeeded"
    if ide.pendingRun:
      ide.pendingRun = false
      ide.startProgram()
  else:
    ide.pendingRun = false
    ide.messages.addNote("Build failed: " & $ide.messages.errorCount & " errors, " &
                         $ide.messages.warningCount & " warnings (" & secs(dt) & ")", icError)
    ide.say "Build failed"
    ide.markErrors()
    let first = ide.messages.firstError()
    if first >= 0: ide.messages.jump first
  ide.refreshActions()

proc compile*(ide: IdeForm): bool =
  ## Project > Compile: saves everything, then runs the compiler in the
  ## background. Returns false when busy or without a project.
  if ide.project == nil or ide.busy: return false
  ide.saveAll()
  ide.messages.clear()
  ide.clearErrorMarkers()
  ide.messages.showMessages()
  ide.setPart(spState, "Compiling...")
  ide.say "Compiling " & ide.project.name
  ide.buildStart = epochTime()
  let onLine = proc(line: string) = ide.messages.feed(line)
  let onDone = proc(ok: bool, exe: string) = ide.compileDone(ok)
  let started = compileProject(ide.project, onLine, onDone, ide.buildOptions)
  if not started:
    ide.setPart(spState, "Ready")
    return false
  ide.refreshActions()
  true

proc needsBuild(ide: IdeForm): bool =
  let p = ide.project
  if not fileExists(p.exePath): return true
  if ide.modifiedUnits.len > 0: return true
  let t = getLastModificationTime(p.exePath)
  var files = @[p.mainPath, p.dir / "nim.cfg"]
  for u in p.units:
    files.add p.nimPathOf(u)
    if u.nfmPath.len > 0: files.add p.nfmPathOf(u)
  for f in files:
    if fileExists(f) and getLastModificationTime(f) > t: return true
  false

proc run*(ide: IdeForm): bool =
  ## Run > Run: compiles when something changed, then starts the program.
  if ide.project == nil or ide.busy: return false
  ide.saveAll()
  if ide.needsBuild:
    ide.pendingRun = true
    result = ide.compile()
    if not result: ide.pendingRun = false
  else:
    ide.startProgram()
    result = true

proc programReset*(ide: IdeForm) =
  ## Run > Program Reset: stops the running program (or the compiler).
  ide.pendingRun = false
  case buildState()
  of bsRunning: stopProject()
  of bsCompiling: cancelCompile()
  of bsIdle: discard

proc waitIdle*(ide: IdeForm, seconds = 120.0): bool =
  ## Runs the event loop until no build or program is active (scripts, tests).
  let t0 = epochTime()
  while ide.busy:
    if epochTime() - t0 > seconds: return false
    Application.processMessages(20)
  Application.processMessages(0)
  true

# --------------------------------------------------------------------- theme

proc setDark*(ide: IdeForm, dark: bool) =
  ide.settings.theme = if dark: "dark" else: "light"
  Application.theme = if dark: themeDark() else: themeLight()
  ide.applyEditorFont()
  ide.refreshActions()

proc editorOptions*(ide: IdeForm) =
  var v = $ide.settings.editorFontSize
  let ok =
    if ide.askText != nil: ide.askText("Editor Options", "Font size:", v)
    else: inputQuery("Editor Options", "Font size (6 - 40):", v)
  if not ok: return
  try:
    let n = parseInt(v.strip)
    if n notin 6 .. 40: raise newException(ValueError, "range")
    ide.settings.editorFontSize = n
    ide.applyEditorFont()
    ide.saveSettings()
  except ValueError:
    ide.say "Font size must be a number from 6 to 40"

# ----------------------------------------------------------------- building

proc connectActions(ide: IdeForm) =
  let a = ide.acts
  template on(id: ActId, body: untyped) =
    a[id].onExecute = proc(x: Action) =
      body
  on aNewApp: discard ide.newApplication()
  on aNewForm: discard ide.newForm()
  on aOpenProject:
    let f =
      if ide.pickFile != nil: ide.pickFile("Open Project", @[("nimvcl projects", "nimproj")])
      else:
        let dlg = newOpenDialog(ide)
        dlg.title = "Open Project"
        dlg.initialDir = defaultProjectsDir()
        dlg.filters = @[("nimvcl projects", "nimproj"), ("All files", "*")]
        if dlg.executeModal(): dlg.fileName else: ""
    if f.len > 0: discard ide.openProject(f)
  on aSave: ide.saveActive()
  on aSaveAll: ide.saveAll()
  on aClose:
    let ed = ide.activeEditor
    if ed != nil: discard ide.closeEditor(ed)
  on aExit: ide.close()
  on aUndo: ide.editUndo()
  on aRedo: ide.editRedo()
  on aCut: ide.editCut()
  on aCopy: ide.editCopy()
  on aPaste: ide.editPaste()
  on aDelete: ide.editDelete()
  on aSelectAll: ide.editSelectAll()
  on aFind: ide.findText(false)
  on aReplace: ide.findText(true)
  on aFindNext: ide.findNext()
  on aGotoLine: ide.gotoLineDialog()
  on aViewProjectMgr: ide.toggleDockPanel(ide.pnlProject)
  on aViewInspector: ide.toggleDockPanel(ide.pnlInspector)
  on aViewTree: ide.toggleDockPanel(ide.pnlTree)
  on aViewMessages: ide.toggleDockPanel(ide.pnlMessages)
  on aToggleView: ide.toggleView()
  on aTheme:
    ide.setDark(not ide.isDark)
    ide.saveSettings()
  on aAddToProject:
    let f =
      if ide.pickFile != nil: ide.pickFile("Add to Project", @[("Nim units", "nim")])
      else:
        let dlg = newOpenDialog(ide)
        dlg.title = "Add to Project"
        if ide.project != nil: dlg.initialDir = ide.project.dir
        dlg.filters = @[("Nim units", "nim"), ("All files", "*")]
        if dlg.executeModal(): dlg.fileName else: ""
    if f.len > 0: discard ide.addToProject(f)
  on aRemoveFromProject:
    let ed = ide.activeEditor
    if ed != nil: discard ide.removeFromProject(ed.unitName)
  on aProjectOptions: ide.showProjectOptions()
  on aCompile: discard ide.compile()
  on aRun: discard ide.run()
  on aReset: ide.programReset()
  on aPointer:
    ide.palette.pick("")
  on aBringToFront:
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.designer.bringToFront()
  on aSendToBack:
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.designer.sendToBack()
  on aAlignLefts:
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.designer.alignSelection(aeLefts)
  on aAlignTops:
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.designer.alignSelection(aeTops)
  on aCenterH:
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.designer.centerInParent(true, false)
  on aCenterV:
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.designer.centerInParent(false, true)
  on aEditorOptions: ide.editorOptions()
  on aAbout:
    messageDlg(AppName & " " & AppVersion & "\n\nA Delphi-style IDE for building windowed\n" &
               "applications with nimvcl.", mtInformation, {mbOK}, mbOK, "About")

proc addAct(m: MenuItem, a: Action): MenuItem {.discardable.} =
  result = m.addItem(a.caption)
  result.action = a

proc buildMenu(ide: IdeForm) =
  let a = ide.acts
  let m = newMainMenu(ide)
  m.images = ide.ideIcons
  ide.menu = m
  let file = m.addItem("&File")
  file.addAct a[aNewApp]
  file.addAct a[aNewForm]
  file.addAct a[aOpenProject]
  ide.recentMenu = file.addItem("Recent &Projects")
  file.addSeparator()
  file.addAct a[aSave]
  file.addAct a[aSaveAll]
  file.addAct a[aClose]
  file.addSeparator()
  file.addAct a[aExit]
  let edit = m.addItem("&Edit")
  for id in [aUndo, aRedo]: edit.addAct a[id]
  edit.addSeparator()
  for id in [aCut, aCopy, aPaste, aDelete]: edit.addAct a[id]
  edit.addSeparator()
  edit.addAct a[aSelectAll]
  let search = m.addItem("&Search")
  for id in [aFind, aReplace, aFindNext]: search.addAct a[id]
  search.addSeparator()
  search.addAct a[aGotoLine]
  let view = m.addItem("&View")
  for id in [aViewProjectMgr, aViewInspector, aViewTree, aViewMessages]: view.addAct a[id]
  view.addSeparator()
  view.addAct a[aToggleView]
  view.addSeparator()
  view.addAct a[aTheme]
  view.addItem("Reset &Layout", proc(s: MenuItem) = ide.resetLayout())
  let proj = m.addItem("&Project")
  for id in [aAddToProject, aRemoveFromProject]: proj.addAct a[id]
  proj.addSeparator()
  proj.addAct a[aProjectOptions]
  let run = m.addItem("&Run")
  for id in [aCompile, aRun, aReset]: run.addAct a[id]
  let comp = m.addItem("&Component")
  comp.addAct a[aPointer]
  comp.addSeparator()
  for id in [aBringToFront, aSendToBack]: comp.addAct a[id]
  comp.addSeparator()
  for id in [aAlignLefts, aAlignTops, aCenterH, aCenterV]: comp.addAct a[id]
  let tools = m.addItem("&Tools")
  tools.addAct a[aEditorOptions]
  let help = m.addItem("&Help")
  help.addAct a[aAbout]
  ide.rebuildRecentMenu()

proc buildToolbars(ide: IdeForm, parent: Container) =
  let a = ide.acts
  proc fill(bar: ToolBar, ids: openArray[ActId]) =
    bar.images = ide.ideIcons
    for id in ids:
      if id == aExit:          # a separator marker
        newToolButton(bar, kind = tbsSeparator)
      else:
        let b = newToolButton(bar, "", tbsButton)
        b.action = a[id]
        b.showCaption = false
  let bar1 = newToolBar(parent)
  bar1.fill [aNewApp, aOpenProject, aSave, aSaveAll, aExit, aNewForm, aAddToProject,
             aRemoveFromProject, aExit, aUndo, aRedo]
  let bar2 = newToolBar(parent)
  bar2.fill [aCompile, aRun, aReset, aExit, aToggleView, aExit, aViewProjectMgr,
             aViewInspector, aViewTree, aViewMessages]

proc buildDocking(ide: IdeForm) =
  let site = newDockSite(ide)
  site.align = alClient
  ide.site = site
  proc mk(name, caption: string, content: Control, icon: int, closable = true): DockPanel =
    result = newDockPanel(site, name, caption, content, closable)
    result.images = ide.ideIcons
    result.imageIndex = icon

  ide.objTree = newTreeView(nil)
  ide.objTree.images = ide.palIcons
  ide.objTree.readOnly = true
  ide.objTree.onChange = proc(sender: Control, node: TreeNode) =
    if ide.syncingTree or node == nil: return
    let ed = ide.activeEditor
    if ed != nil and node.tag >= 0 and node.tag < ide.treeComps.len:
      ed.selectComponent(ide.treeComps[node.tag])
  ide.inspector = newObjectInspector(nil)
  ide.pages = newPageControl(nil)
  ide.pages.onChange = proc(sender: Control) =
    ide.bindActive()
    ide.sync()
  ide.projectTree = newProjectTree(nil, ide.ideIcons)
  ide.projectTree.onOpenUnit = proc(name: string) = discard ide.openUnit(name)
  ide.messages = newMessagesPanel(nil, ide.ideIcons)
  ide.messages.onJump = proc(file: string, line, col: int) = discard ide.jumpTo(file, line, col)

  ide.pnlTree = mk("tree", "Object TreeView", ide.objTree, icTreeIc)
  ide.pnlInspector = mk("inspector", "Object Inspector", ide.inspector, icInspectorIc)
  ide.pnlEditors = mk("editors", "Editor", ide.pages, icUnit, closable = false)
  ide.pnlProject = mk("project", "Project Manager", ide.projectTree.tree, icProjectMgr)
  ide.pnlMessages = mk("messages", "Messages", ide.messages.root, icMessagesIc)
  site.dock(ide.pnlEditors)
  site.dock(ide.pnlTree, nil, dsLeft, 0.23)
  site.dock(ide.pnlInspector, ide.pnlTree, dsBottom, 0.62)
  site.dock(ide.pnlProject, nil, dsRight, 0.17)
  site.dock(ide.pnlMessages, ide.pnlEditors, dsBottom, 0.21)
  ide.pnlEditors.activate()
  ide.defaultLayout = site.saveLayout()

proc newIdeForm*(settingsFile = settingsPath(), width = 1360, height = 860): IdeForm =
  ## Builds the window (no project yet; see `startup`). `Application.init()`
  ## must have run. The settings are read from (and saved to) `settingsFile`.
  let ide = IdeForm()
  ide.initForm()
  ide.settingsFile = settingsFile
  ide.settings = loadSettings(settingsFile)
  ide.setBounds(0, 0, width.float32, height.float32)
  ide.position = poScreenCenter
  ide.askSave = askSaveDefault
  ide.showError = proc(text: string) = messageDlg(text, mtError)
  Application.theme = if ide.isDark: themeDark() else: themeLight()

  ide.ideIcons = makeIdeIcons(16)
  let pal = makePaletteIcons(20)
  ide.palIcons = pal.images
  ide.palIndex = pal.index
  ide.acts = newIdeActions(ide, ide.ideIcons)

  ide.buildMenu()

  # top: toolbars at the left, the component palette filling the rest
  let top = newPanel(ide)
  top.align = alTop
  top.borderStyle = pbNone
  top.height = 72
  let bars = newPanel(top)
  bars.align = alLeft
  bars.borderStyle = pbNone
  bars.width = 380
  ide.buildToolbars(bars)
  ide.palette = newComponentPalette(top, ide.ideIcons, ide.palIcons, ide.palIndex)
  ide.palette.root.align = alClient
  ide.palette.onPick = proc(cls: string) =
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.beginCreate(cls)
    else:
      ide.palette.reset()
      ide.say "Open a form to place components"
  ide.palette.onCancel = proc() =
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.designer.cancelCreate()

  ide.status = newStatusBar(ide)
  discard ide.status.addPanel("Ready", 130)
  discard ide.status.addPanel("", 190)
  discard ide.status.addPanel("", 96, taCenter)
  discard ide.status.addPanel("", 80, taCenter)
  discard ide.status.addPanel("", 100)
  ide.status.sizeGrip = true

  ide.buildDocking()
  ide.connectActions()
  ide.refreshActions()
  ide.updateCaption()

  if ide.settings.layout.len > 0:
    discard ide.site.loadLayout(ide.settings.layout)

  ide.onCloseQuery = proc(sender: Form, canClose: var bool) =
    for e in ide.editors:
      if e.modified:
        let choice = if ide.askSave != nil: ide.askSave(e.unitName) else: scSave
        case choice
        of scCancel:
          canClose = false
          return
        of scSave: e.save()
        of scDiscard: discard
    if ide.project != nil: ide.project.save()
    ide.programReset()
    ide.saveLayout()
  Application.addIdleHook("ide-sync", proc() = ide.sync())
  ide

proc startup*(ide: IdeForm, defaultDir = "") =
  ## Opens the last project, else a fresh `Project1` in `defaultDir`
  ## (`~/nimvcl-projects/Project1`; an existing one is reopened).
  for path in ide.settings.recentProjects:
    if fileExists(path) and ide.openProject(path): return
  let dir = if defaultDir.len > 0: defaultDir else: defaultProjectsDir() / "Project1"
  let existing = dir / "Project1" & ProjectExt
  if fileExists(existing) and ide.openProject(existing): return
  discard ide.newApplication(dir, "Project1")
