## Menus, toolbars, docking and the wiring of the actions of the window.

import nimvcl
import nimvcl/controls/inspector
import std/[strutils, tables]
import nimvcl/dsl/[props, props_std]
import ./[bookmarks, project, messages, ideconfig, icons, actions, palette,
          projecttree, messagespanel, todopanel, codeexplorer, uniteditor, quickfix,
          ideform, ideeditors, designcmds, projectcommands, buildcontroller,
          quickfixes, findcmds, codecmds, outlinecmds]

proc setDark*(ide: IdeForm, dark: bool) =
  ide.settings.theme = if dark: "dark" else: "light"
  Application.theme = if dark: themeDark() else: themeLight()
  ide.applyEditorFont()
  ide.refreshActions()

proc editorOptions*(ide: IdeForm): bool {.discardable.} =
  ## Tools > Editor Options: the dialog gives the new values, which are applied
  ## to every editor and kept in the settings.
  let s = ide.settings
  var o = EditorOptions(fontFamily: s.editorFontFamily, fontSize: s.editorFontSize,
                        tabWidth: s.editorTabWidth, insertSpaces: s.editorInsertSpaces,
                        lineNumbers: s.editorLineNumbers)
  if ide.askEditorOptions == nil or not ide.askEditorOptions(o): return false
  ide.settings.editorFontFamily = o.fontFamily.strip
  ide.settings.editorFontSize = clamp(o.fontSize, 6, 40)
  ide.settings.editorTabWidth = clamp(o.tabWidth, 1, 16)
  ide.settings.editorInsertSpaces = o.insertSpaces
  ide.settings.editorLineNumbers = o.lineNumbers
  ide.applyEditorFont()
  ide.saveSettings()
  true

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
  d.modal(r):
    if r == mrOk:
      ide.applyOptions ProjectOptions(outputDir: outDir.text, flags: flags.text,
                                      defines: defs.text, title: title.text, version: version.text,
                                      autoImports: autoImp.checked, importAll: impAll.checked)

template withDesigner(ide: IdeForm, d, body: untyped) =
  ## Runs `body` with `d` the designer of the active editor, when that is a form.
  let ed = ide.activeEditor
  if ed != nil and ed.isForm:
    let d = ed.designer
    body

proc connectBookmark(ide: IdeForm, slot: int) =
  # a proc of its own: a closure made in the loop would see the last slot
  ide.acts[ActId(ord(aToggleBookmark0) + slot)].onExecute = proc(x: Action) =
    ide.toggleBookmark(slot)
  ide.acts[ActId(ord(aGotoBookmark0) + slot)].onExecute = proc(x: Action) =
    ide.gotoBookmark(slot)

proc connectActions*(ide: IdeForm) =
  let a = ide.acts
  template on(id: ActId, body: untyped) =
    a[id].onExecute = proc(x: Action) =
      body
  on aNewApp: discard ide.newApplication()
  on aNewForm: discard ide.newForm()
  on aNewInheritedForm: discard ide.newInheritedForm()
  on aOpenProject:
    let f = ide.pickFile("Open Project", @[("nimvcl projects", "nimproj")])
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
  on aCodeComplete: ide.completeCode()
  on aCodeTemplate: ide.insertTemplate()
  on aParamHints: ide.parameterHints()
  on aRevertProp: ide.revertProperty()
  on aRevertComponent: ide.revertComponent()
  on aAlignDlg: ide.alignDialog()
  on aSizeDlg: ide.sizeDialog()
  on aTabOrder: ide.tabOrderDialog()
  on aFind: ide.findText(false)
  on aReplace: ide.findText(true)
  on aFindUnit: ide.findUnitImport()
  on aQuickFix: ide.quickFix()
  on aFindNext: ide.findNext()
  on aFindInFiles: ide.findInFilesCommand()
  on aGotoLine: ide.gotoLineDialog()
  on aViewProjectMgr: ide.toggleDockPanel(ide.pnlProject)
  on aViewInspector: ide.toggleDockPanel(ide.pnlInspector)
  on aViewTree: ide.toggleDockPanel(ide.pnlTree)
  on aViewMessages: ide.toggleDockPanel(ide.pnlMessages)
  on aViewTodo: ide.toggleTodo()
  on aViewExplorer: ide.toggleExplorer()
  on aToggleView: ide.toggleView()
  on aTheme:
    ide.setDark(not ide.isDark)
    ide.saveSettings()
  on aAddToProject:
    let f = ide.pickFile("Add to Project", @[("Nim units", "nim")])
    if f.len > 0: discard ide.addToProject(f)
  on aAddFont:
    let f = ide.pickFile("Add Font File", @[("Fonts", "ttf;otf")])
    if f.len > 0: discard ide.addFontFile(f)
  on aRemoveFont: discard ide.removeFont()
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
  on aCompile: discard ide.compile()
  on aBuild: discard ide.build()
  on aSyntaxCheck: discard ide.syntaxCheck()
  on aRun: discard ide.run()
  on aReset: ide.programReset()
  on aPointer:
    ide.palette.pick("")
  on aFindComponent: ide.palette.focusFilter()
  on aBringToFront:
    ide.withDesigner(d): d.bringToFront()
  on aSendToBack:
    ide.withDesigner(d): d.sendToBack()
  on aAlignLefts:
    ide.withDesigner(d): d.alignSelection(aeLefts)
  on aAlignTops:
    ide.withDesigner(d): d.alignSelection(aeTops)
  on aCenterH:
    ide.withDesigner(d): d.centerInParent(true, false)
  on aCenterV:
    ide.withDesigner(d): d.centerInParent(false, true)
  for i in 0 ..< BookmarkSlots: ide.connectBookmark i
  on aEditorOptions: ide.editorOptions()
  on aAbout:
    messageDlg(AppName & " " & AppVersion & "\n\nA Delphi-style IDE for building windowed\n" &
               "applications with nimvcl.", mtInformation, {mbOK}, mbOK, "About")

proc addAct(m: MenuItem, a: Action): MenuItem {.discardable.} =
  result = m.addItem(a.caption)
  result.action = a

proc buildMenu*(ide: IdeForm) =
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
  edit.addSeparator()
  for id in [aCodeComplete, aCodeTemplate, aParamHints]: edit.addAct a[id]
  edit.addSeparator()
  edit.addAct a[aRevertProp]
  edit.addAct a[aRevertComponent]
  edit.addSeparator()
  for id in [aAlignDlg, aSizeDlg, aTabOrder]: edit.addAct a[id]
  let search = m.addItem("&Search")
  for id in [aFind, aReplace, aFindNext, aFindInFiles]: search.addAct a[id]
  search.addSeparator()
  search.addAct a[aGotoLine]
  search.addAct a[aFindUnit]
  search.addAct a[aQuickFix]
  search.addSeparator()
  let toggles = search.addItem("&Toggle Bookmarks")
  let gotos = search.addItem("Go to &Bookmark")
  for i in 0 ..< BookmarkSlots:
    toggles.addAct a[ActId(ord(aToggleBookmark0) + i)]
    gotos.addAct a[ActId(ord(aGotoBookmark0) + i)]
  let view = m.addItem("&View")
  for id in [aViewProjectMgr, aViewInspector, aViewTree, aViewMessages, aViewTodo, aViewExplorer]: view.addAct a[id]
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
  for id in [aAddToProject, aAddFont, aRemoveFont, aRemoveFromProject, aViewSource]: proj.addAct a[id]
  proj.addSeparator()
  proj.addAct a[aProjectOptions]
  proj.addSeparator()
  proj.addAct a[aBuild]
  proj.addAct a[aSyntaxCheck]
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

proc buildToolbars*(ide: IdeForm, parent: Container) =
  let a = ide.acts
  proc fill(bar: ToolBar, groups: openArray[seq[ActId]]) =
    ## One group of buttons after the other, a separator between them.
    bar.images = ide.ideIcons
    for g, ids in groups:
      if g > 0: newToolButton(bar, kind = tbsSeparator)
      for id in ids:
        let b = newToolButton(bar, "", tbsButton)
        b.action = a[id]
        b.showCaption = false
  let bar1 = newToolBar(parent)
  bar1.fill [@[aNewApp, aOpenProject, aSave, aSaveAll], @[aNewForm, aAddToProject, aRemoveFromProject],
             @[aUndo, aRedo]]
  let bar2 = newToolBar(parent)
  bar2.fill [@[aCompile, aRun, aReset], @[aToggleView], @[aViewProjectMgr, aViewInspector,
             aViewTree, aViewMessages]]

proc buildDocking*(ide: IdeForm) =
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
  # the inspector's context menu: put an inherited property or component back
  let pm = newPopupMenu(ide)
  # the popup acts on the row that was right-clicked, not just the selected one
  var clickedProp = ""
  ide.inspector.onContextMenu = proc(s: Control, prop: string, p: PointF) =
    clickedProp = prop
  let revProp = pm.addItem(ide.acts[aRevertProp].caption,
                           proc(s: MenuItem) = ide.revertProperty(clickedProp))
  let revComp = pm.addItem(ide.acts[aRevertComponent].caption, proc(s: MenuItem) = ide.revertComponent())
  pm.onPopup = proc(m: PopupMenu) =
    revProp.enabled = ide.canRevertProperty(clickedProp)
    revComp.enabled = ide.canRevertComponent
  ide.inspector.popupMenu = pm
  ide.pages = newPageControl()
  ide.pages.closeButtons = true
  ide.pages.onTabClose = proc(s: Control, i: int, allow: var bool) =
    allow = false                  # the IDE closes the unit (asking to save first)
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

  ide.todo = newTodoPanel(nil)
  ide.todo.onJump = proc(file: string, line: int) = discard ide.jumpTo(file, line, 1)
  ide.todo.onRefresh = proc() = ide.refreshTodos()

  ide.explorer = newCodeExplorer(nil, ide.ideIcons)
  ide.explorer.onJump = proc(line: int) = ide.explorerJump(line)

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
  # the To-Do List is a tab of Messages, closed until View asks for it
  ide.pnlTodo = mk("todo", "To-Do List", ide.todo.root, icHint)
  site.dock(ide.pnlTodo, ide.pnlMessages)
  ide.pnlTodo.hide()
  ide.pnlExplorer = mk("explorer", "Code Explorer", ide.explorer.tree, icUnit)
  site.dock(ide.pnlExplorer, ide.pnlTree)
  ide.pnlExplorer.hide()
  ide.pnlEditors.activate()
  ide.defaultLayout = site.saveLayout()
