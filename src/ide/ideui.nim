## Menus, toolbars, docking and the wiring of the actions of the window.

import nimvcl
import nimvcl/controls/inspector
import std/[strutils, tables]
import nimvcl/dsl/[props, props_std]
import ./[project, messages, ideconfig, icons, actions, palette,
          projecttree, messagespanel, uniteditor, editortabs, quickfix,
          ideform, ideeditors, projectcommands, buildcontroller,
          quickfixes]

proc setDark*(ide: IdeForm, dark: bool) =
  ide.settings.theme = if dark: "dark" else: "light"
  Application.theme = if dark: themeDark() else: themeLight()
  ide.applyEditorFont()
  ide.refreshActions()

proc editorOptions*(ide: IdeForm) =
  var v = $ide.settings.editorFontSize
  let ok = ide.askText("Editor Options", "Font size (6 - 40):", v)
  if not ok: return
  try:
    let n = parseInt(v.strip)
    if n notin 6 .. 40: raise newException(ValueError, "range")
    ide.settings.editorFontSize = n
    ide.applyEditorFont()
    ide.saveSettings()
  except ValueError:
    ide.say "Font size must be a number from 6 to 40"

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
  on aRevertProp: ide.revertProperty()
  on aRevertComponent: ide.revertComponent()
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
  edit.addAct a[aRevertProp]
  edit.addAct a[aRevertComponent]
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
  for id in [aAddToProject, aAddFont, aRemoveFont, aRemoveFromProject, aViewSource]: proj.addAct a[id]
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

proc buildToolbars*(ide: IdeForm, parent: Container) =
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
  let revProp = pm.addItem(ide.acts[aRevertProp].caption, proc(s: MenuItem) = ide.revertProperty())
  let revComp = pm.addItem(ide.acts[aRevertComponent].caption, proc(s: MenuItem) = ide.revertComponent())
  pm.onPopup = proc(m: PopupMenu) =
    revProp.enabled = ide.canRevertProperty
    revComp.enabled = ide.canRevertComponent
  ide.inspector.popupMenu = pm
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
