## The editors of the window: tabs, the Object TreeView, the state of the
## actions, `sync`, and the Edit and Search commands that go to the active
## editor. `flush` (the idle hook) only refreshes what an editor reported.

import nimvcl
import nimvcl/controls/inspector
import std/[os, strutils, algorithm]
import nimvcl/dsl/[props, props_std]
import ./[project, builder, ideconfig, icons, actions, palette,
          projecttree, messagespanel, uniteditor, ideform]


# object tree -----------------------------------------------------------

proc classNameOfComp*(c: Component): string =
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
    # what the user collapsed, and where the tree was scrolled, survive a rebuild of the
    # same form's tree (by component name)
    let sameForm = ide.treeOwner == ed
    ide.treeOwner = ed
    var collapsed: seq[string]
    let scrollY = if sameForm: ide.objTree.scrollPosY else: 0.0
    if sameForm:
      for i, n in ide.treeNodes:
        if n.hasChildren and not n.expanded and i < ide.treeComps.len:
          collapsed.add ide.treeComps[i].name
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
    if collapsed.len > 0:
      for i, n in ide.treeNodes:
        if n.hasChildren and ide.treeComps[i].name in collapsed: n.collapse()
    ide.objTree.endUpdate()
    if scrollY > 0: ide.objTree.scrollTo(ide.objTree.scrollPosX, scrollY)
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

# editing ---------------------------------------------------------------

proc routeToDesigner*(ide: IdeForm): bool =
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

# inherited forms -------------------------------------------------------

proc singleSelected(ide: IdeForm): Component =
  let ed = ide.activeEditor
  if ed == nil or not ed.isForm or not ed.isInherited: return nil
  let sel = ed.selection
  if sel.len == 1: sel[0] else: nil

proc canRevertProperty*(ide: IdeForm, prop = ""): bool =
  ## The property (default: the Object Inspector's selected one) differs from
  ## the ancestor form's.
  let c = ide.singleSelected
  let prop = if prop.len > 0: prop else: ide.inspector.selectedProp
  c != nil and prop.len > 0 and ide.activeEditor.canRevert(c, prop)

proc canRevertComponent*(ide: IdeForm): bool =
  let c = ide.singleSelected
  c != nil and ide.activeEditor.canRevertComponent(c)

proc revertProperty*(ide: IdeForm, prop = ""): bool {.discardable.} =
  ## Edit > Revert to Inherited (the Object Inspector's menu passes the row that
  ## was clicked): the property (default: the selected one) goes back to the
  ## ancestor's value and leaves the `.nfm` of this form when it is saved.
  let c = ide.singleSelected
  let prop = if prop.len > 0: prop else: ide.inspector.selectedProp
  if c == nil or prop.len == 0:
    ide.say "Select a property of an inherited component first"
    return false
  result = ide.activeEditor.revertProperty(c, prop)
  ide.say(if result: "Reverted " & c.name & "." & prop & " to the inherited value"
          else: c.name & "." & prop & " already is the inherited value")

proc revertComponent*(ide: IdeForm): bool {.discardable.} =
  ## Edit > Revert Component to Inherited: every property of the selected
  ## inherited component goes back to the ancestor's.
  let c = ide.singleSelected
  if c == nil:
    ide.say "Select an inherited component first"
    return false
  let n = ide.activeEditor.revertComponent(c)
  result = n > 0
  ide.say(if n > 0: "Reverted " & $n & " properties of " & c.name & " to the inherited values"
          else: c.name & " is the same as in the ancestor form")

# search ----------------------------------------------------------------

proc codeOfActive*(ide: IdeForm): CodeEdit =
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
  let ok = ide.askText("Go to Line Number", "Enter new line number:", v)
  if ok:
    try:
      let n = parseInt(v.strip)
      c.gotoLine(max(n - 1, 0))
    except ValueError:
      ide.say "Not a line number: " & v

# panels ----------------------------------------------------------------

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

# selection -------------------------------------------------------------

proc selectionChanged*(ide: IdeForm) =
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
  elif ed == nil:
    ide.inspector.inspect(newSeq[Obj]())
  ide.bound = ed
  ide.treeSig = "\0"
  ide.actionsDirty = true
  ide.refreshTree()
  if ed != nil: ide.projectTree.selectUnit(ed.unitName)

# actions state ---------------------------------------------------------

proc refreshActions*(ide: IdeForm) =
  let a = ide.acts
  let ed = ide.activeEditor
  let busy = ide.busy
  let hasProject = ide.project != nil
  let designer = ide.routeToDesigner
  let hasSel = designer and ed.designer.selection.len > 0
  for id in [aNewApp, aOpenProject]: a[id].enabled = not busy     # the build belongs to this project
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
  for id in [aAlignDlg, aSizeDlg, aTabOrder]: a[id].enabled = hasSel
  a[aRevertProp].enabled = designer and ide.canRevertProperty      # the Inspector's selected row differs
  a[aRevertComponent].enabled = designer and ide.canRevertComponent
  for id in [aFind, aReplace, aFindNext, aGotoLine]: a[id].enabled = ed != nil
  a[aFindUnit].enabled = ed != nil
  a[aQuickFix].enabled = hasProject and ide.messages.firstWithFix() >= 0
  a[aToggleView].enabled = ed != nil and ed.isForm
  a[aAddToProject].enabled = hasProject
  a[aAddFont].enabled = hasProject
  a[aRemoveFont].enabled = hasProject and ide.project.fonts.len > 0
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
  for id in [aBuild, aSyntaxCheck]: a[id].enabled = hasProject and not busy
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

proc watchedState(ide: IdeForm): WatchedState =
  ## The few things the action states depend on that nobody tells us about.
  for p in [ide.pnlProject, ide.pnlInspector, ide.pnlTree, ide.pnlMessages]:
    result.panels = result.panels * 2 + (if p.state != dpHidden: 1 else: 0)
  result.msgs = ide.messages.msgs.len
  result.units = if ide.project == nil: -1 else: ide.project.units.len
  result.state = buildState()
  result.prop = ide.inspector.selectedProp     # Revert to Inherited follows the selected row

proc flush*(ide: IdeForm) =
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

# units -----------------------------------------------------------------

proc hookEditor(ide: IdeForm, ed: UnitEditor) =
  ed.onSelectionChanged = proc(e: UnitEditor) = ide.selectionChanged()
  ed.onModifiedChanged = proc(e: UnitEditor) =
    ide.actionsDirty = true
    ide.updateTabs()
    ide.updateStatus()
  ed.onDesignChanged = proc(e: UnitEditor) =
    ide.actionsDirty = true       # not the tree: it shows names and classes, see onStructureChanged
    ide.updateTabs()
  ed.onStructureChanged = proc(e: UnitEditor) = ide.treeDirty = true   # components added, removed, renamed, moved
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
  ide.applyEditorOptions ed
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

proc afterMainEdit*(ide: IdeForm, ed: UnitEditor) =
  if ed != nil: ed.reloadFromDisk()

proc saveEditor*(ide: IdeForm, ed: UnitEditor) =
  ## Saves one unit. When its form file is about to change, the open forms that
  ## inherit from it are rebuilt on top of the new file afterwards (see
  ## `UnitEditor.rebaseOnAncestor`); their own unsaved form changes are taken
  ## before the file is written, so they are kept.
  var kids: seq[UnitEditor]
  var pending: seq[string]
  if ed.isForm and ed.designModified and ide.project != nil:
    for name in ide.project.descendantsOf(ed.unitName):
      let k = ide.editorOf(name)
      if k != nil and k.isForm and k != ed:
        kids.add k
        pending.add k.pendingDesign()
  ed.save()
  for i, k in kids: k.rebaseOnAncestor(pending[i])

proc trySave*(ide: IdeForm, ed: UnitEditor): bool =
  ## `saveEditor`, but a failure (read-only file, disk full) is reported and
  ## gives false instead of raising. A file that someone else changed since it was
  ## read is only overwritten when `askOverwrite` agrees; if not, nothing is
  ## written and the answer is false (a failed save).
  let changed = ed.changedOnDisk
  if changed.len > 0 and ide.askOverwrite != nil and
     not ide.askOverwrite(changed.join(" and ") & " changed on disk. Overwrite?"):
    ide.say "Not saved: " & changed.join(" and ") & " changed on disk"
    return false
  try:
    ide.saveEditor(ed)
    result = true
  except CatchableError as e:
    ide.fail "Cannot save " & ed.unitName & ": " & e.msg

proc beforeMainEdit*(ide: IdeForm): UnitEditor =
  ## Call before the project edits the main file on disk: an open editor of it
  ## is saved first, so no change of the user is lost, and returned for `afterMainEdit`.
  ## When the save fails (reported) nil comes back: the editor keeps its unsaved
  ## text and is not reloaded from the changed file.
  let ed = ide.mainEditor
  if ed != nil and ide.trySave(ed): result = ed

proc closeEditor*(ide: IdeForm, ed: UnitEditor): bool =
  ## Closes a unit's tab; asks what to do with unsaved changes (false = the
  ## user cancelled).
  let i = ide.editors.find(ed)
  if i < 0: return true
  if ed.modified:
    let choice = ide.askSave(ed.unitName)
    case choice
    of scCancel: return false
    of scSave:
      if not ide.trySave(ed): return false     # a failed save counts as Cancel
    of scDiscard: discard
  if ide.bound == ed:
    if ed.isForm: ed.designer.cancelCreate()
    ed.unbindInspector()
    ide.bound = nil
  let keep = if ide.activeIndex == i: nil else: ide.activeEditor  # a background tab stays active
  let sheet = ide.sheets[i]
  ide.editors.delete i
  ide.sheets.delete i
  ed.dispose()
  sheet.free()
  if ide.editors.len > 0:
    let k = if keep != nil: ide.editors.find(keep) else: -1
    ide.pages.activePageIndex = if k >= 0: k else: min(i, ide.editors.len - 1)
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
  let ok = ide.trySave(ed)
  ide.updateTabs()
  if ok: ide.say "Saved " & ed.unitName

proc depth(ide: IdeForm, ed: UnitEditor): int =
  ## How many forms the unit's form inherits from, one after the other.
  if ide.project == nil: return 0
  var name = ed.unitName
  while result < 16:
    let i = ide.project.findUnit(name)
    if i < 0 or ide.project.units[i].ancestor.len == 0: break
    name = ide.project.units[i].ancestor
    inc result

proc saveEditors*(ide: IdeForm, eds: seq[UnitEditor]): bool =
  ## Saves the given units in an order that is safe for inheritance; false
  ## (reported) at the first one that cannot be written.
  # descendants first: their form files hold differences from the ancestor file as
  # it is on disk, so they are written before an ancestor changes it
  var order = eds
  order.sort(proc(a, b: UnitEditor): int = cmp(ide.depth(b), ide.depth(a)))
  for e in order:
    if not ide.trySave(e): return false
  true

proc saveAll*(ide: IdeForm): bool {.discardable.} =
  ## Saves every unit and the project; false (reported) when one cannot be written.
  result = ide.saveEditors(ide.editors) and ide.trySaveProject()
  ide.updateTabs()
  if result: ide.say "All saved"

proc refreshProject*(ide: IdeForm) =
  ide.projectTree.refresh(ide.project)
  ide.updateCaption()
  ide.updateTabs()
  ide.actionsDirty = true
  let ed = ide.activeEditor
  if ed != nil: ide.projectTree.selectUnit(ed.unitName)

# jumping ---------------------------------------------------------------

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

# messages --------------------------------------------------------------

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
