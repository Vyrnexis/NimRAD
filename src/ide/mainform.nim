## The IDE's main window: menu, toolbars, component palette and a docking
## layout (Object TreeView and Object Inspector on the left, the unit editors
## in the middle, the Project Manager on the right, Messages at the bottom).
##
## Everything the user can do is a proc on `IdeForm` (`openProject`,
## `openUnit`, `compile`, `run`, ...), so the scripted session and the tests
## drive the same code as the menu. The few modal dialogs (save changes,
## errors, text input, file choice) are hooks (`askSave`, `showError`,
## `askText`, `pickFile`, `pickItem`) that tests replace.
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
import ./[nimvclpath, project, builder, messages, ideconfig, icons, actions, palette,
          projecttree, messagespanel, uniteditor, editortabs, mainfile, unitimports,
          symbols, quickfix]

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
    recentMenu*: MenuItem
    palette*: ComponentPalette
    site*: DockSite
    pnlTree*, pnlInspector*, pnlProject*, pnlMessages*, pnlEditors*: DockPanel
    objTree*: TreeView
    inspector*: ObjectInspector
    projectTree*: ProjectTree
    messages*: MessagesPanel
    pages*: EditorPages
    status*: StatusBar
    editors*: seq[UnitEditor]
    sheets: seq[TabSheet]
    bound: UnitEditor
    defaultLayout*: string
    treeSig: string
    treeDirty: bool            ## the components of the bound form changed
    actionsDirty: bool         ## something the action states depend on changed
    watched: tuple[msgs, panels, units: int, state: BuildState]
      ## what changes without an event of ours (messages, dock panels, project)
    treeComps: seq[Component]
    treeNodes: seq[TreeNode]
    syncingTree: bool
    pendingRun: bool
    failedWasRun: bool         ## the build that failed was started by Run
    autoRetried: bool          ## the automatic import fix has rebuilt once already
    running: bool
    buildStart: float
    runUnits: int
    lastExitCode*: int          ## exit code of the program that ran last
    lastBuildOk*: bool
    lastBuildInfo*: string
    buildCount*: int
    # modal dialogs (replaced by tests)
    askSave*: proc(unitName: string): SaveChoice
    showError*: proc(text: string)
    askText*: proc(caption, prompt: string, value: var string): bool
    pickFile*: proc(title: string, filters: seq[(string, string)]): string
    pickItem*: proc(title: string, items: seq[string], selected: int): int
      ## A list to choose from; the index, or -1 when cancelled.

  ProjectOptions* = object
    ## The fields of the Project Options dialog (text as typed).
    outputDir*, flags*, defines*, title*, version*: string
    autoImports*, importAll*: bool

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

proc pickItemDefault(title: string, items: seq[string], selected: int): int =
  let d = newForm(nil, 380, 380)
  d.caption = title
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  let lb = newListBox(d, 16, 16, 348, 270)
  for it in items: lb.items.add it
  lb.itemIndex = clamp(selected, 0, max(items.len - 1, 0))
  lb.onDblClick = proc(sender: Control) = d.modalResult = mrOk
  let ok = newButton(d, "OK", 188, 306, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 280, 306, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  d.activeControl = lb
  result = if d.showModal() == mrOk: lb.itemIndex else: -1
  d.freeWindow()

proc defaultProjectsDir*(): string = getHomeDir() / "nimvcl-projects"

# ------------------------------------------------------------------ helpers

proc say*(ide: IdeForm, text: string) =
  ide.status.panels[ord spMessage].text = text

proc setPart(ide: IdeForm, part: StatusPart, text: string) =
  if ide.status.panels[ord part].text != text: ide.status.panels[ord part].text = text

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
  ide.caption = AppName & (if ide.project != nil: " - " & ide.project.name else: "") &
                (if ide.running: " [Running]" else: "")

proc isMainEditor*(ide: IdeForm, ed: UnitEditor): bool =
  ## The editor of the program file (it is not a unit of the project).
  ide.project != nil and ed != nil and ed.unitName == ide.project.name and
    ide.project.findUnit(ed.unitName) < 0

proc tabCaption(ide: IdeForm, ed: UnitEditor): string =
  (if ide.isMainEditor(ed): ed.unitName & ".nim" else: ed.unitName) &
    (if ed.modified: "*" else: "")

proc modifiedUnits*(ide: IdeForm): seq[string] =
  for e in ide.editors:
    if e.modified: result.add e.unitName

proc updateTabs(ide: IdeForm) =
  for i, e in ide.editors:
    let cap = ide.tabCaption(e)
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
  ide.actionsDirty = true
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
  ide.actionsDirty = true
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
  a[aNewInheritedForm].enabled = hasProject and ide.project.formUnits.len > 0
  a[aSave].enabled = ed != nil
  a[aSaveAs].enabled = ed != nil
  a[aSaveProjectAs].enabled = hasProject
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
  a[aFindUnit].enabled = ed != nil
  a[aQuickFix].enabled = hasProject and ide.messages.firstWithFix() >= 0
  a[aToggleView].enabled = ed != nil and ed.isForm
  a[aAddToProject].enabled = hasProject
  a[aAddFont].enabled = hasProject
  a[aRemoveFromProject].enabled = ed != nil and not ide.isMainEditor(ed)
  a[aViewSource].enabled = hasProject
  a[aViewUnits].enabled = hasProject
  a[aViewForms].enabled = hasProject
  a[aRunParameters].enabled = hasProject
  a[aShowHints].checked = ide.settings.showHints
  for id in [aNextMessage, aNextMessageAlt]:
    a[id].enabled = ide.messages.nextJumpable() >= 0
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
  ## Brings all the derived UI state up to date at once (scripts and tests;
  ## the idle hook only does what changed, see `flush`).
  ide.refreshTree()
  ide.refreshActions()
  ide.updateStatus()
  ide.updateTabs()
  ide.treeDirty = false
  ide.actionsDirty = false
  let ed = ide.activeEditor
  if ed != nil and ed.isForm and ide.palette.picked.len > 0 and ed.designer.creating.len == 0:
    ide.palette.reset()

proc watchedState(ide: IdeForm): tuple[msgs, panels, units: int, state: BuildState] =
  ## The few things the action states depend on that nobody tells us about.
  for p in [ide.pnlProject, ide.pnlInspector, ide.pnlTree, ide.pnlMessages]:
    result.panels = result.panels * 2 + (if p.state != dpHidden: 1 else: 0)
  result.msgs = ide.messages.msgs.len
  result.units = if ide.project == nil: -1 else: ide.project.units.len
  result.state = buildState()

proc flush(ide: IdeForm) =
  ## The idle hook: refreshes the Object TreeView and the actions only when
  ## something they show changed (the editors tell us, see `hookEditor`).
  let w = ide.watchedState
  if w != ide.watched:
    ide.watched = w
    ide.actionsDirty = true
  ide.updateStatus()
  if ide.treeDirty:
    ide.treeDirty = false
    ide.refreshTree()
  if ide.actionsDirty:
    ide.actionsDirty = false
    ide.refreshActions()

proc dropComponent*(ide: IdeForm, className: string): bool {.discardable.} =
  ## Puts a `className` on the current form without the mouse: into the
  ## selected container (else the form), at a default spot that steps down and
  ## right with every control already there. Non-visual classes become tiles.
  let ed = ide.activeEditor
  if ed == nil or not ed.isForm:
    ide.say "Open a form to place components"
    return false
  let ci = classByName(className)
  if ci == nil: return false
  ed.showDesigner()
  let d = ed.designer
  if d.createControl == nil: return false
  let c = if ci.name == "MainMenu": nil else: d.createControl(className)
  if c == nil:                           # not a control: a tile, added at once
    ed.beginCreate(className)
    return true
  var target = Container(ed.designedForm)
  var x = d.primary
  while x != nil and x != Control(ed.designedForm):
    if x of Container and (d.acceptsChildren == nil or d.acceptsChildren(Container(x))):
      target = Container(x)
      break
    x = x.parent
  let step = max(d.grid, 8'f32)
  let off = 2 * step + step * float32(target.controlCount mod 10)
  c.setBounds(off, off, c.width, c.height)
  d.insertNew(target, c, className)
  true

# ------------------------------------------------------------------- units

proc hookEditor(ide: IdeForm, ed: UnitEditor) =
  ed.onSelectionChanged = proc(e: UnitEditor) = ide.selectionChanged()
  ed.onModifiedChanged = proc(e: UnitEditor) =
    ide.actionsDirty = true
    ide.updateTabs()
    ide.updateStatus()
  ed.onDesignChanged = proc(e: UnitEditor) = ide.actionsDirty = true
  ed.onStructureChanged = proc(e: UnitEditor) = ide.treeDirty = true
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
  let isMain = unitName == ide.project.name and ide.project.findUnit(unitName) < 0
  if ide.project.findUnit(unitName) < 0 and not isMain: return nil
  let sheet = newTabSheet(ide.pages, unitName)
  var ed: UnitEditor
  try:
    if isMain:
      # the program file is not a unit: the editor gets a one-unit project of its own
      let p = ide.project
      let shadow = Project(filePath: p.filePath, name: p.name, mainFile: p.mainFile,
                           units: @[ProjectUnit(name: p.name, nimPath: p.mainFile)])
      ed = newUnitEditor(shadow, unitName, sheet)
    else:
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

proc openMain*(ide: IdeForm): UnitEditor =
  ## Project > View Source: the program file in the editor.
  if ide.project == nil: return nil
  ide.openUnit(ide.project.name)

proc mainEditor*(ide: IdeForm): UnitEditor =
  if ide.project == nil: nil else: ide.editorOf(ide.project.name)

proc beforeMainEdit(ide: IdeForm): UnitEditor =
  ## Call before the project edits the main file on disk: an open editor of it
  ## is saved first, so no change of the user is lost, and returned for `afterMainEdit`.
  result = ide.mainEditor
  if result != nil: result.save()

proc afterMainEdit(ide: IdeForm, ed: UnitEditor) =
  if ed != nil: ed.reloadFromDisk()

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
  ed.dispose()
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
  ide.updateTabs()
  ide.actionsDirty = true
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

proc rebuildRecentMenu*(ide: IdeForm) =
  ## File > Reopen: the recent projects (at most `MaxRecent`), newest first.
  ide.recentMenu.clear()
  if ide.settings.recentProjects.len == 0:
    let none = ide.recentMenu.addItem("(none)")
    none.enabled = false
    return
  for i, path in ide.settings.recentProjects:
    let num = if i < 9: "&" & $(i + 1) else: "1&0"
    ide.recentMenu.addItem(num & "  " & path.extractFilename.changeFileExt("") & "   " & path.parentDir,
                           openHandler(ide, path))

proc openProject*(ide: IdeForm, path: string): bool =
  ## Opens a `.nimproj` (the current project is closed first).
  var p: Project
  try:
    p = loadProject(path)
  except CatchableError as e:
    let gone = not fileExists(path)
    ide.settings.removeRecent(path)
    ide.saveSettings()
    ide.rebuildRecentMenu()
    ide.fail(if gone: "The project " & path & " no longer exists; it was removed from the Reopen list."
             else: "Cannot open " & path & ": " & e.msg)
    return false
  if not ide.closeProject(): return false
  ide.project = p
  p.registerFonts()
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
  let mainEd = ide.beforeMainEdit()
  try:
    let u = ide.project.newFormUnit()       # also imports and creates it in the main file
    ide.project.save()
    ide.afterMainEdit(mainEd)
    ide.refreshProject()
    result = ide.openUnit(u.name)
  except CatchableError as e:
    ide.fail "Cannot create the form: " & e.msg

proc formTypeOfNfm(path: string): string =
  ## `object Form1: Form` -> "Form1" (`inherited Form2: Form2` -> "Form2").
  try:
    for l in lines(path):
      let t = l.strip
      if t.startsWith("object ") or t.startsWith("inherited "):
        let r = t[t.find(' ') + 1 .. ^1]
        let c = r.find(':')
        return (if c > 0: r[0 ..< c] else: r).strip
  except CatchableError: discard

proc addToProject*(ide: IdeForm, path: string): bool =
  ## Adds an existing `.nim` unit (a form unit when a `.nfm` of the same name
  ## sits next to it).
  if ide.project == nil: return false
  let name = path.splitFile.name
  let nfm = path.changeFileExt(".nfm")
  let mainEd = ide.beforeMainEdit()
  try:
    if not validName(name): raise newException(ProjectError, "bad unit name " & name)
    if name == ide.project.name: raise newException(ProjectError, name & " is the program file")
    var u: ProjectUnit
    if fileExists(nfm):
      u = ide.project.addUnit(name, path, nfm, true, formTypeOfNfm(nfm),
                              ide.project.ancestorUnitOf(nfm))
    else:
      u = ide.project.addUnit(name, path)
    ide.project.save()
    if not ide.project.addToMain(u) and fileExists(ide.project.mainPath) and
       not readFile(ide.project.mainPath).hasBlock(ImportsBlock):
      ide.say "The main file has no nimvcl-ide markers: import " & name & " there yourself"
    ide.afterMainEdit(mainEd)
    ide.refreshProject()
    discard ide.openUnit(name)
    result = true
  except CatchableError as e:
    ide.fail "Cannot add " & path & ": " & e.msg

proc addFontFile*(ide: IdeForm, path: string): bool =
  ## Project > Add Font File: copies the font into `<project>/fonts/`, records it
  ## in the project and makes the main file register it at startup.
  if ide.project == nil: return false
  let mainEd = ide.beforeMainEdit()
  try:
    let f = ide.project.addFontFile(path)
    ide.project.save()
    ide.project.registerFonts()
    if not ide.project.syncFontsBlock() and fileExists(ide.project.mainPath) and
       not readFile(ide.project.mainPath).hasBlock(ImportsBlock):
      ide.say "The main file has no nimvcl-ide markers: register " & f.file & " there yourself"
    ide.afterMainEdit(mainEd)
    ide.say "Added font " & f.family & " (" & f.style & ")"
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
  if ide.project.isMainForm(u):
    ide.fail "The main form (" & u.formType & ") cannot be removed from the project."
    return false
  let ed = ide.editorOf(unitName)
  if ed != nil and not ide.closeEditor(ed): return false
  let mainEd = ide.beforeMainEdit()
  ide.project.removeUnit(unitName)         # also drops its import and create line from the main file
  ide.project.save()
  ide.afterMainEdit(mainEd)
  ide.refreshProject()
  true

proc cleanDefine(d: string): string =
  ## `-d:foo`, `--define:foo` and `foo` all name the define `foo`.
  result = d.strip
  for pre in ["--define:", "-d:", "--define=", "-d="]:
    if result.startsWith(pre):
      result = result[pre.len .. ^1]
      break

proc splitDefines*(text: string): seq[string] =
  ## "a b,c=1 -d:d" -> `@["a", "b", "c=1", "d"]`.
  for w in text.replace(',', ' ').splitWhitespace:
    let d = w.cleanDefine
    if d.len > 0 and d notin result: result.add d

proc currentOptions*(ide: IdeForm): ProjectOptions =
  let p = ide.project
  ProjectOptions(outputDir: p.outputDir, flags: p.nimFlags.join(" "),
                 defines: p.defines.join(" "), title: p.title, version: p.version,
                 autoImports: p.autoImports, importAll: p.importAll)

proc applyOptions*(ide: IdeForm, o: ProjectOptions) =
  ## Project > Options, after OK: stores the options and saves the project.
  if ide.project == nil: return
  let p = ide.project
  p.outputDir = if o.outputDir.strip.len > 0: o.outputDir.strip else: "build"
  p.nimFlags = o.flags.splitWhitespace
  p.defines = splitDefines(o.defines)
  p.title = o.title.strip
  p.version = o.version.strip
  p.autoImports = o.autoImports
  let modeChanged = p.importAll != o.importAll
  if modeChanged:
    ide.saveAll()                      # unsaved edits go to disk before the files are rewritten
    p.importAll = o.importAll
    let changed = p.rewriteImports()
    for e in ide.editors: e.reloadFromDisk()
    ide.say(if p.importAll: "All units import nimvcl (" & $changed.len & " files changed)"
            else: "Units import the prelude and their controls (" & $changed.len & " files changed)")
  p.save()
  if not modeChanged: ide.say "Project options saved"

proc showProjectOptions*(ide: IdeForm) =
  ## Project > Options: output folder, compiler flags, conditional defines,
  ## application title and version.
  if ide.project == nil: return
  let o = ide.currentOptions
  let d = newForm(nil, 520, 420)
  d.caption = "Project Options"
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  newLabel(d, "Output folder:", 20, 24, 130)
  let outDir = newEdit(d, o.outputDir, 160, 20, 340)
  newLabel(d, "Compiler flags:", 20, 66, 130)
  let flags = newEdit(d, o.flags, 160, 62, 340)
  newLabel(d, "Conditional defines:", 20, 108, 130)
  let defs = newEdit(d, o.defines, 160, 104, 340)
  let hint = newLabel(d, "Flags go to `nim c`, e.g.  --threads:on.  Defines are -d: names, e.g.  release  level=2", 20, 142, 480)
  hint.muted = true
  newLabel(d, "Application title:", 20, 186, 130)
  let title = newEdit(d, o.title, 160, 182, 340)
  newLabel(d, "Version:", 20, 228, 130)
  let version = newEdit(d, o.version, 160, 224, 340)
  let autoImp = newCheckBox(d, "Add missing nimvcl imports automatically", o.autoImports, 20, 270, 480)
  let impAll = newCheckBox(d, "Import all of nimvcl (units import `nimvcl`; builds are slower)", o.importAll, 20, 302, 480)
  let ok = newButton(d, "OK", 324, 366, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 416, 366, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  if d.showModal() == mrOk:
    ide.applyOptions ProjectOptions(outputDir: outDir.text, flags: flags.text,
                                    defines: defs.text, title: title.text, version: version.text,
                                    autoImports: autoImp.checked, importAll: impAll.checked)
  d.freeWindow()

proc quoteArg(a: string): string =
  if a.len == 0 or a.anyIt(it in {' ', '\t', '"'}): "\"" & a.replace("\"", "\\\"") & "\"" else: a

proc runParameters*(ide: IdeForm): string =
  ## The program arguments as one line (as shown by Run > Parameters).
  if ide.project != nil: ide.project.runArgs.map(quoteArg).join(" ") else: ""

proc setRunParameters*(ide: IdeForm, text: string) =
  if ide.project == nil: return
  ide.project.runArgs = parseCmdLine(text)
  ide.project.save()
  ide.say "Run parameters saved"

proc showRunParameters*(ide: IdeForm) =
  ## Run > Parameters: the command line arguments of the program.
  if ide.project == nil: return
  var v = ide.runParameters
  let ok =
    if ide.askText != nil: ide.askText("Run Parameters", "Parameters:", v)
    else: inputQuery("Run Parameters", "Parameters:", v)
  if ok: ide.setRunParameters v

# ----------------------------------------------------------- units and forms

proc chooseUnit(ide: IdeForm, title: string, formsOnly: bool): string =
  ## Asks which unit to open from the list; "" when cancelled. The program
  ## file comes first in the Units list and is returned as the project name.
  var names, labels: seq[string]
  if not formsOnly:
    names.add ide.project.name
    labels.add ide.project.name & " (program)"
  for u in ide.project.units:
    if formsOnly and not u.isForm: continue
    names.add u.name
    labels.add(if u.isForm: u.name & " (" & u.formType & ")" else: u.name)
  if names.len == 0: return ""
  var cur = 0
  let ed = ide.activeEditor
  if ed != nil: cur = max(names.find(ed.unitName), 0)
  let i =
    if ide.pickItem != nil: ide.pickItem(title, labels, cur)
    else: pickItemDefault(title, labels, cur)
  if i >= 0 and i < names.len: names[i] else: ""

proc viewUnits*(ide: IdeForm, formsOnly = false): UnitEditor =
  ## View > Units... (Ctrl+F12) and View > Forms... (Shift+F12): choose, open.
  if ide.project == nil: return nil
  let n = ide.chooseUnit(if formsOnly: "View Form" else: "View Unit", formsOnly)
  if n.len > 0: result = ide.openUnit(n)

proc newInheritedForm*(ide: IdeForm, ancestor = ""): UnitEditor =
  ## File > New Inherited Form...: asks which form of the project to inherit
  ## from (`ancestor`, a unit name, skips the question), adds the descendant
  ## unit and opens it.
  if ide.project == nil: return nil
  var anc = ancestor
  if anc.len == 0:
    var names, labels: seq[string]
    for u in ide.project.formUnits:
      names.add u.name
      labels.add u.name & " (" & u.formType & ")"
    if names.len == 0:
      ide.fail "The project has no form to inherit from."
      return nil
    let ed = ide.activeEditor
    let cur = if ed != nil: max(names.find(ed.unitName), 0) else: 0
    let i =
      if ide.pickItem != nil: ide.pickItem("New Inherited Form", labels, cur)
      else: pickItemDefault("New Inherited Form", labels, cur)
    if i < 0 or i >= names.len: return nil
    anc = names[i]
  let mainEd = ide.beforeMainEdit()
  try:
    let u = ide.project.newInheritedFormUnit(anc)
    ide.project.save()
    ide.afterMainEdit(mainEd)
    ide.refreshProject()
    result = ide.openUnit(u.name)
  except CatchableError as e:
    ide.fail "Cannot create the form: " & e.msg

# ------------------------------------------------------------------- jumping

proc unitOfFile*(ide: IdeForm, file: string): string =
  ## The unit whose `.nim` is `file` ("" when it is not a unit of the project);
  ## the program file gives the project's name (what `openUnit` accepts for it).
  if ide.project == nil: "" else: ide.project.unitOfFile(file)

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
  result.hints = ide.settings.showHints

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
  # the program's stdout and stderr arrive line by line while it runs
  let onLines = proc(lines: seq[string]) = ide.messages.addOutputLines(lines)
  let onExit = proc(code: int) =
    ide.running = false
    ide.lastExitCode = code
    let stopped = wasCancelled()
    let how = if stopped: "stopped" else: "ended"
    ide.messages.addNote("Program " & how & " with exit code " & $code,
                         if code == 0: icSuccess elif stopped: icInfo else: icError)
    ide.setPart(spState, "Ready")
    ide.say "Program " & how & " (exit code " & $code & ")"
    ide.updateCaption()
    ide.refreshActions()
  let started = runProject(p, onLines, onExit)
  if started:
    ide.running = true
    ide.messages.showOutput()
    ide.setPart(spState, "Running")
    ide.say "Running " & p.name
    ide.updateCaption()
  else:
    ide.fail "Cannot start " & p.exePath
  ide.refreshActions()

proc compileWith(ide: IdeForm, notes: seq[string]): bool
proc compile*(ide: IdeForm): bool
proc run*(ide: IdeForm): bool

# -------------------------------------------------------------- quick fixes

proc editUnitFile(ide: IdeForm, file: string, change: proc(src: string): string): bool =
  ## Applies `change` to the unit's text: in its editor when it is open (the
  ## edit is then unsaved, one undo step), else in the file. True when it changed.
  let name = ide.unitOfFile(file)
  if name.len == 0: return false
  let ed = ide.editorOf(name)
  if ed != nil: return ed.editCode(change)
  try:
    let src = readFile(file)
    let res = change(src)
    if res == src: return false
    writeFile(file, res)
    result = true
  except CatchableError: discard

proc addImportTo(ide: IdeForm, file, module: string): bool =
  ide.editUnitFile(file, proc(src: string): string = addUserImport(src, module))

proc componentsOf(ide: IdeForm, file: string): seq[string] =
  ## The names of the components of the form of the unit `file` (empty for the
  ## program file and for plain units).
  if ide.project == nil: return
  let k = ide.project.findUnit(ide.unitOfFile(file))
  if k < 0: return
  let u = ide.project.units[k]
  if u.nfmPath.len == 0: return
  let nfm = ide.project.nfmPathOf(u)
  if fileExists(nfm):
    try: return componentNames(readFile(nfm), nfm.parentDir)
    except CatchableError: discard

proc fixesOfMessage(ide: IdeForm, m: Message): seq[QuickFix] =
  if ide.project == nil: return
  result = fixesFor(m, proc(): seq[string] = ide.componentsOf(m.file))
  if ide.project.importAll:             # everything is imported already
    result = result.filterIt(it.kind != fkAddImport)

proc rebuild(ide: IdeForm) =
  if ide.failedWasRun: discard ide.run()
  else: discard ide.compile()

proc applyQuickFix*(ide: IdeForm, msgIndex: int, fixIndex = 0): bool =
  ## Applies a fix of message `msgIndex`: an import (the module is chosen from a
  ## list when several declare the name) is added above the IDE's block, and the
  ## build that failed runs again; a rename replaces the name in place.
  let fixes = ide.messages.fixesOf(msgIndex)
  if fixIndex >= fixes.len or ide.busy: return false
  let fix = fixes[fixIndex]
  let m = ide.messages.msgs[msgIndex]
  case fix.kind
  of fkAddImport:
    var module = fix.modules[0]
    if fix.modules.len > 1:
      let i =
        if ide.pickItem != nil: ide.pickItem("Add import for " & fix.ident, fix.modules, 0)
        else: pickItemDefault("Add import for " & fix.ident, fix.modules, 0)
      if i < 0 or i >= fix.modules.len: return false
      module = fix.modules[i]
    if not ide.addImportTo(m.file, module):
      ide.say module & " is already imported"
      return false
    ide.say "Added import " & module & " to " & ide.unitOfFile(m.file)
    ide.rebuild()
    result = true
  of fkRename:
    result = ide.editUnitFile(m.file, proc(src: string): string =
      renameAt(src, m.line, m.col, fix.ident, fix.replacement))
    if result: ide.say "Replaced " & fix.ident & " with " & fix.replacement
    else: ide.say "Could not find " & fix.ident & " at that place"
    if result:
      ide.messages.fixes[msgIndex] = @[]    # the position is stale; the next build lists it again

proc quickFix*(ide: IdeForm): bool {.discardable.} =
  ## Ctrl+.: the fix of the selected message, else of the error at the caret,
  ## else of the first message that has one.
  if ide.project == nil: return false
  var k = ide.messages.selectedMessage
  if ide.messages.fixesOf(k).len == 0:
    k = -1
    let ed = ide.activeEditor
    if ed != nil and not (ed.isForm and ed.designerVisible):
      let line = ed.code.caretPos.line + 1
      for i, m in ide.messages.msgs:
        if m.hasLocation and m.line == line and ide.unitOfFile(m.file) == ed.unitName and
           ide.messages.fixesOf(i).len > 0:
          k = i
          break
    if k < 0: k = ide.messages.firstWithFix()
  if k < 0:
    ide.say "No quick fix available"
    return false
  ide.applyQuickFix(k)

proc wordAtCaret(ed: UnitEditor): string =
  let c = ed.code
  let sel = c.selectedText
  if sel.len > 0:
    return if sel.allIt(it in IdentChars) and sel[0] in IdentStartChars: sel else: ""
  let line = c.lineAt(c.caretPos.line)
  var a = min(c.caretPos.col, line.len)
  var b = a
  while a > 0 and line[a - 1] in IdentChars: dec a
  while b < line.len and line[b] in IdentChars: inc b
  if b > a and line[a] in IdentStartChars: line[a ..< b] else: ""

proc findUnitImport*(ide: IdeForm): bool {.discardable.} =
  ## Search > Find Unit (Ctrl+Shift+A): offers the import of the nimvcl module
  ## that declares the identifier at the caret (the selection, if any).
  let ed = ide.activeEditor
  if ide.project == nil or ed == nil: return false
  if ed.isForm and ed.designerVisible: ed.showCode()
  let word = ed.wordAtCaret
  if word.len == 0:
    ide.say "Put the caret on an identifier first"
    return false
  let mods = modulesFor(word)
  if mods.len == 0:
    ide.say "No nimvcl module declares " & word
    return false
  let i =
    if ide.pickItem != nil: ide.pickItem("Add import for " & word, mods, 0)
    else: pickItemDefault("Add import for " & word, mods, 0)
  if i < 0 or i >= mods.len: return false
  let target =
    if ide.isMainEditor(ed): ide.project.mainPath
    else:
      let k = ide.project.findUnit(ed.unitName)
      if k < 0: return false
      ide.project.nimPathOf(ide.project.units[k])
  result = ide.addImportTo(target, mods[i])
  ide.say(if result: "Added import " & mods[i] else: mods[i] & " is already imported")

proc autoAddImports(ide: IdeForm): bool =
  ## Project option "Add missing nimvcl imports automatically": after a failed
  ## build, adds every import that has exactly one candidate, says so in
  ## Messages and builds once more. True when it started that build.
  if not ide.project.autoImports or ide.autoRetried: return false
  var added: seq[string]
  for k in 0 ..< ide.messages.msgs.len:
    let fx = ide.messages.fixesOf(k)
    if fx.len == 0 or fx[0].kind != fkAddImport or fx[0].modules.len != 1: continue
    let m = ide.messages.msgs[k]
    let module = fx[0].modules[0]
    let unit = ide.unitOfFile(m.file)
    if ide.addImportTo(m.file, module):
      added.add "Added import " & module & " to " & unit & " (for " & fx[0].ident & ")"
  if added.len == 0: return false
  ide.saveAll()
  ide.autoRetried = true
  ide.compileWith(added)

proc compileDone(ide: IdeForm, ok: bool) =
  let dt = epochTime() - ide.buildStart
  ide.messages.finish()
  ide.lastBuildOk = ok
  inc ide.buildCount
  let lines = ide.countLines
  ide.lastBuildInfo = $lines & " lines, " & secs(dt)
  ide.setPart(spBuild, ide.lastBuildInfo)
  ide.setPart(spState, "Ready")
  if wasCancelled():
    ide.pendingRun = false
    ide.messages.addNote("Build cancelled", icInfo)
    ide.say "Build cancelled"
  elif ok:
    ide.messages.addNote("Build succeeded: " & ide.project.name & " (" & $ide.messages.warningCount &
                         " warnings, " & secs(dt) & ")", icSuccess)
    ide.say "Build succeeded"
    if ide.pendingRun:
      ide.pendingRun = false
      ide.startProgram()
  else:
    if ide.autoAddImports(): return        # building again, with the imports it added
    ide.failedWasRun = ide.pendingRun
    ide.pendingRun = false
    ide.messages.addNote("Build failed: " & $ide.messages.errorCount & " errors, " &
                         $ide.messages.warningCount & " warnings (" & secs(dt) & ")", icError)
    ide.say "Build failed"
    ide.markErrors()
    let first = ide.messages.firstError()
    if first >= 0: ide.messages.jump first
  ide.refreshActions()

proc compileWith(ide: IdeForm, notes: seq[string]): bool =
  if ide.project == nil or ide.busy: return false
  ide.saveAll()
  ide.messages.clear()
  ide.clearErrorMarkers()
  ide.messages.showMessages()
  for n in notes: ide.messages.addNote(n)
  if ide.project.nimvclSrc.len == 0:
    ide.messages.addNote(NimvclNotFound, icError)
    ide.say "nimvcl was not found"
    return false
  ide.setPart(spState, "Compiling...")
  ide.say "Compiling " & ide.project.name
  ide.buildStart = epochTime()
  let onLines = proc(lines: seq[string]) = ide.messages.feedLines(lines)
  let onDone = proc(ok: bool, exe: string) = ide.compileDone(ok)
  let started = compileProject(ide.project, onLines, onDone, ide.buildOptions)
  if not started:
    ide.setPart(spState, "Ready")
    return false
  ide.refreshActions()
  true

proc compile*(ide: IdeForm): bool =
  ## Project > Compile: saves everything, then runs the compiler in the
  ## background. Returns false when busy or without a project.
  ide.autoRetried = false
  ide.compileWith(@[])

proc run*(ide: IdeForm): bool =
  ## Run > Run: builds (the compiler knows what is out of date and does nothing
  ## when the program is current), then starts the program.
  if ide.project == nil or ide.busy: return false
  ide.saveAll()
  ide.pendingRun = true
  result = ide.compile()
  if not result: ide.pendingRun = false

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

# ------------------------------------------------------------------ messages

proc setShowHints*(ide: IdeForm, on: bool) =
  ## Run > Show Hints: asks the compiler for hints (from the next build) and
  ## shows or hides the ones listed.
  ide.settings.showHints = on
  ide.messages.showHints = on
  ide.saveSettings()
  ide.refreshActions()
  ide.say(if on: "Hints are shown (they come with the next build)" else: "Hints are hidden")

proc nextMessage*(ide: IdeForm): bool =
  ## F8 / Ctrl+Alt+Down: the next message that has a location, opened in the
  ## editor (after the last one it starts again at the first).
  result = ide.messages.jumpNext()
  if not result: ide.say "No more messages"

# ------------------------------------------------------------------ save as

proc reloadOthers(ide: IdeForm) =
  ## Re-reads every open unit (their files may have been rewritten on disk).
  for e in ide.editors: e.reloadFromDisk()

proc renameUnit*(ide: IdeForm, oldName, newName: string): bool =
  ## File > Save As: saves everything, then renames the unit through
  ## `Project.renameUnit` (its files, the imports and the `loadForm` path);
  ## the unit stays open under its new name. The form type keeps its name.
  if ide.project == nil: return false
  let name = newName.strip
  if ide.project.findUnit(oldName) < 0:
    ide.fail oldName & " is not a unit of the project"
    return false
  if name == oldName: return true
  ide.saveAll()
  let ed = ide.editorOf(oldName)
  let wasOpen = ed != nil
  let wasDesigner = ed != nil and ed.designerVisible
  if wasOpen and not ide.closeEditor(ed): return false
  try:
    ide.project.renameUnit(oldName, name)
    ide.project.save()
  except CatchableError as e:
    ide.fail "Cannot rename " & oldName & ": " & e.msg
    if wasOpen: discard ide.openUnit(oldName)
    return false
  ide.reloadOthers()
  ide.refreshProject()
  if wasOpen:
    let ne = ide.openUnit(name)
    if ne != nil and ne.isForm and not wasDesigner: ne.showCode()
  ide.say "Saved as " & name
  true

proc renameProject*(ide: IdeForm, newName: string): bool =
  ## File > Save Project As: renames the project (the `.nimproj` and the main
  ## file), the units stay.
  if ide.project == nil: return false
  let name = newName.strip
  if name == ide.project.name: return true
  ide.saveAll()
  let oldPath = ide.project.filePath
  let mainEd = ide.mainEditor
  if mainEd != nil and not ide.closeEditor(mainEd): return false
  try:
    ide.project.renameProject(name)
  except CatchableError as e:
    ide.fail "Cannot rename the project: " & e.msg
    if mainEd != nil: discard ide.openMain()
    return false
  ide.settings.removeRecent(oldPath)
  ide.rememberProject()
  ide.rebuildRecentMenu()
  ide.refreshProject()
  if mainEd != nil: discard ide.openMain()
  ide.say "Project saved as " & name
  true

proc askName(ide: IdeForm, caption, prompt: string, value: var string): bool =
  if ide.askText != nil: ide.askText(caption, prompt, value)
  else: inputQuery(caption, prompt, value)

proc saveAs*(ide: IdeForm, newName = ""): bool =
  ## File > Save As: the active unit gets a new name (asked for when `newName`
  ## is empty); for the program file it is the same as Save Project As.
  let ed = ide.activeEditor
  if ed == nil: return false
  var v = newName
  let isMain = ide.isMainEditor(ed)
  if v.len == 0:
    v = if isMain: ide.project.name else: ed.unitName
    if not ide.askName("Save As", if isMain: "Project name:" else: "Unit name:", v): return false
  if isMain: ide.renameProject(v) else: ide.renameUnit(ed.unitName, v)

proc saveProjectAs*(ide: IdeForm, newName = ""): bool =
  if ide.project == nil: return false
  var v = newName
  if v.len == 0:
    v = ide.project.name
    if not ide.askName("Save Project As", "Project name:", v): return false
  ide.renameProject(v)

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
  on aNewInheritedForm: discard ide.newInheritedForm()
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
  on aSaveAs: discard ide.saveAs()
  on aSaveProjectAs: discard ide.saveProjectAs()
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
  on aFindUnit: ide.findUnitImport()
  on aQuickFix: ide.quickFix()
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
  on aAddFont:
    let f =
      if ide.pickFile != nil: ide.pickFile("Add Font File", @[("Fonts", "ttf;otf")])
      else:
        let dlg = newOpenDialog(ide)
        dlg.title = "Add Font File"
        dlg.filters = @[("Fonts", "ttf;otf"), ("All files", "*")]
        if dlg.executeModal(): dlg.fileName else: ""
    if f.len > 0: discard ide.addFontFile(f)
  on aRemoveFromProject:
    let ed = ide.activeEditor
    if ed != nil: discard ide.removeFromProject(ed.unitName)
  on aViewUnits: discard ide.viewUnits()
  on aViewForms: discard ide.viewUnits(formsOnly = true)
  on aViewSource: discard ide.openMain()
  on aProjectOptions: ide.showProjectOptions()
  on aRunParameters: ide.showRunParameters()
  on aShowHints: ide.setShowHints(not ide.settings.showHints)
  on aNextMessage: discard ide.nextMessage()
  on aNextMessageAlt: discard ide.nextMessage()
  on aCompile: discard ide.compile()
  on aRun: discard ide.run()
  on aReset: ide.programReset()
  on aPointer:
    ide.palette.pick("")
  on aFindComponent: ide.palette.focusFilter()
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
  file.addAct a[aNewInheritedForm]
  file.addAct a[aOpenProject]
  ide.recentMenu = file.addItem("&Reopen")
  file.addSeparator()
  file.addAct a[aSave]
  file.addAct a[aSaveAs]
  file.addAct a[aSaveProjectAs]
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
  search.addAct a[aFindUnit]
  search.addAct a[aQuickFix]
  let view = m.addItem("&View")
  for id in [aViewProjectMgr, aViewInspector, aViewTree, aViewMessages]: view.addAct a[id]
  view.addSeparator()
  view.addAct a[aToggleView]
  view.addSeparator()
  view.addAct a[aViewUnits]
  view.addAct a[aViewForms]
  view.addAct a[aFindComponent]
  view.addSeparator()
  view.addAct a[aTheme]
  view.addItem("Reset &Layout", proc(s: MenuItem) = ide.resetLayout())
  let proj = m.addItem("&Project")
  for id in [aAddToProject, aAddFont, aRemoveFromProject, aViewSource]: proj.addAct a[id]
  proj.addSeparator()
  proj.addAct a[aProjectOptions]
  let run = m.addItem("&Run")
  for id in [aCompile, aRun, aReset]: run.addAct a[id]
  run.addSeparator()
  run.addAct a[aRunParameters]
  run.addSeparator()
  for id in [aNextMessage, aShowHints]: run.addAct a[id]
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
  ide.inspector.onGetFontFamilies = proc(s: Control, t: Obj): seq[string] =
    if ide.project != nil: ide.project.fontFamilies else: @[]
  ide.pages = newEditorPages()
  ide.pages.onCloseTab = proc(i: int) =
    if i >= 0 and i < ide.editors.len: discard ide.closeEditor(ide.editors[i])
  ide.pages.onChange = proc(sender: Control) =
    ide.bindActive()
    ide.sync()
  ide.projectTree = newProjectTree(nil, ide.ideIcons)
  ide.projectTree.onOpenUnit = proc(name: string) = discard ide.openUnit(name)
  ide.projectTree.onOpenMain = proc() = discard ide.openMain()
  ide.messages = newMessagesPanel(nil, ide.ideIcons)
  ide.messages.onJump = proc(file: string, line, col: int) = discard ide.jumpTo(file, line, col)
  ide.messages.showHints = ide.settings.showHints
  ide.messages.fixProvider = proc(m: Message): seq[QuickFix] = ide.fixesOfMessage(m)
  ide.messages.onQuickFix = proc(k: int) = discard ide.applyQuickFix(k)

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
  top.height = 72 + filterHeight       # the palette's filter edit sits above its tabs
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
  ide.palette.onDrop = proc(cls: string) =
    if ide.dropComponent(cls): ide.palette.clearFilter()
    ide.activeControl = nil
  ide.palette.onLeave = proc() = ide.activeControl = nil
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
  Application.addIdleHook("ide-sync", proc() = ide.flush())
  ide

proc projectArg*(args: openArray[string]): string =
  ## The path after `--project` (or of `--project=path`) on the command line,
  ## "" when there is none.
  for i, a in args:
    if a == "--project":
      if i + 1 < args.len: return args[i + 1]
    elif a.startsWith("--project="):
      return a["--project=".len .. ^1]

proc startup*(ide: IdeForm, defaultDir = "", project = "") =
  ## Opens `project` when given (`--project path`), else the last project,
  ## else a fresh `Project1` in `defaultDir` (`~/nimvcl-projects/Project1`; an
  ## existing one is reopened). A `project` that cannot be opened is reported
  ## and the usual choice follows.
  if project.len > 0 and ide.openProject(absolutePath(project)): return
  for path in ide.settings.recentProjects:
    if fileExists(path) and ide.openProject(path): return
  let dir = if defaultDir.len > 0: defaultDir else: defaultProjectsDir() / "Project1"
  let existing = dir / "Project1" & ProjectExt
  if fileExists(existing) and ide.openProject(existing): return
  discard ide.newApplication(dir, "Project1")
