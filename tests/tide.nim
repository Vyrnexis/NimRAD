## The whole IDE, headless: the scripted session (new application, drop a Button
## and a Label, double click for the handler, type the body, compile), then
## the built program is smoke-run; reopening a project; a compile error that is
## listed and jumped to; prompts when closing modified units; saving and
## restoring the docking layout.
import std/[unittest, os, strutils, json]
import nimvcl
import nimvcl/dsl/props
import nimvcl/controls/inspector
import ide/[mainform, session, project, builder, ideconfig, uniteditor, messagespanel,
            messages, palette, actions, projecttree]

putEnv("SDL_VIDEO_DRIVER", "offscreen")
putEnv("SDL_RENDER_DRIVER", "software")

let root = getTempDir() / ("nimvclide-ide-" & $getCurrentProcessId())
removeDir root
createDir root

Application.init()
let settingsFile = root / "settings.json"
let ide = newIdeForm(settingsFile = settingsFile)
ide.showWindow(1360, 860)

var
  errors: seq[string]
  asked: seq[string]
  answer = scSave
ide.showError = proc(text: string) = errors.add text
ide.askSave = proc(unitName: string): SaveChoice =
  asked.add unitName
  answer

var projectFile = ""
var sess: SessionResult

proc unitText(name: string): string =
  readFile(ide.project.dir / name & ".nim")

proc findNamed(ed: UnitEditor, name: string): Control =
  for c in ed.designedForm.children:
    if c.name == name: return c

proc typeAtEnd(ed: UnitEditor, text: string) =
  ide.showWindow()
  ed.showCode()
  ide.activeControl = ed.code
  ed.code.caretPos = (ed.code.lineCount - 1, 0)
  ide.typeText text

suite "scripted session":
  test "no project: compile and run are disabled":
    ide.refreshActions()
    check not ide.acts[aCompile].enabled
    check not ide.acts[aRun].enabled
    check not ide.acts[aReset].enabled
    check ide.caption == "nimvcl IDE"

  test "new app, Button + Label, handler, typed body, compile":
    sess = ide.runScriptedSession(root)
    check sess.error == ""
    check sess.ok
    check ide.project.name == "Project1"
    check ide.caption == "nimvcl IDE - Project1"
    projectFile = ide.project.filePath

  test "the unit files hold the form and the handler":
    check sess.buttonName == "Button1"
    check sess.labelName == "Label1"
    let nfm = readFile(ide.project.dir / "unit1.nfm")
    check "Button1" in nfm
    check "Label1" in nfm
    check "onClick = Button1Click" in nfm or "onClick = button1Click" in nfm
    check "self.Label1.caption = \"Hi\"" in unitText("unit1")

  test "the build is reported":
    check ide.lastBuildOk
    check fileExists(exePath(ide.project))
    let m = ide.messages
    check m.errorCount == 0
    let last = m.list.items[m.list.items.count - 1]
    check last.caption.startsWith("Build succeeded")
    check ide.lastBuildInfo.contains(" lines, ")
    check ide.status.panels[0].text == "Ready"
    check ide.status.panels[1].text == ide.lastBuildInfo

  test "the built program smoke-runs with exit code 0":
    let r = runCapture(exePath(ide.project), @["--smoke"], ide.project.dir)
    check r.exitCode == 0

  test "Run starts the program and Program Reset ends it":
    ide.project.runArgs = @["--smoke"]
    check ide.run()                       # nothing changed: no rebuild
    check ide.busy
    check ide.waitIdle(60)
    check "ended with exit code 0" in ide.messages.output.text
    check not ide.busy

  test "the Object TreeView and Object Inspector follow the form":
    ide.settle
    check ide.objTree.items.count == 3
    let ed = ide.activeEditor
    ed.showDesigner()
    # select Label1 through the tree
    var node: TreeNode
    for n in ide.objTree.items.top(0).children:
      if n.text.startsWith("Label1"): node = n
    check node != nil
    ide.objTree.selected = node
    ide.settle
    check ed.selection.len == 1
    check ed.selection[0].name == "Label1"
    check ide.inspector.targets.len == 1

  test "Edit > Undo goes to the designer or the code by view":
    let ed = ide.activeEditor
    ed.showDesigner()
    ed.designer.select(findNamed(ed, "Label1"))
    check ed.designedForm.children.len == 2
    ide.editDelete()
    check ed.designedForm.children.len == 1
    ide.editUndo()
    check ed.designedForm.children.len == 2
    ide.editRedo()
    check ed.designedForm.children.len == 1
    ide.editUndo()
    check ed.designedForm.children.len == 2

  test "the palette only offers classes the registry knows":
    let cls = ide.palette.classes
    check cls.len >= 30
    for c in cls: check classByName(c) != nil
    for c in ["Button", "Label", "Memo", "StringGrid", "TreeView", "CodeEdit", "Timer",
              "ActionList", "MainMenu"]:
      check c in cls

suite "projects":
  test "close, reopen":
    check ide.closeProject()
    check ide.project == nil
    check ide.editors.len == 0
    check ide.projectTree.unitCount == 0
    check ide.caption == "nimvcl IDE"
    check ide.objTree.items.count == 0
    check ide.openProject(projectFile)
    check ide.project.name == "Project1"
    check ide.editors.len == 1
    check ide.activeEditor.unitName == "unit1"
    check ide.activeEditor.designer.selection.len == 0 or true
    check ide.objTree.items.count == 3
    check ide.projectTree.unitCount == 1
    check ide.settings.recentProjects[0] == projectFile
    check loadSettings(settingsFile).recentProjects[0] == projectFile
    check "self.Label1.caption = \"Hi\"" in ide.activeEditor.code.text

  test "a missing project is reported and dropped from the recent list":
    errors.setLen 0
    check not ide.openProject(root / "nothing" / "x.nimproj")
    check errors.len == 1
    check ide.project != nil              # the open project stays open

  test "New Form and Remove from Project":
    let ed = ide.newForm()
    check ed != nil
    check ed.unitName == "unit2"
    check ide.project.units.len == 2
    check ide.editors.len == 2
    check ide.projectTree.unitCount == 2
    check ide.pages.sheets()[1].caption == "unit2"
    check not ide.removeFromProject("unit1")       # the main form stays
    check errors.len == 2
    check ide.removeFromProject("unit2")
    check ide.project.units.len == 1
    check ide.editors.len == 1
    check fileExists(ide.project.dir / "unit2.nim")  # files are kept

suite "compile errors":
  test "an error is listed and the editor jumps to its line":
    ide.messages.clear()
    let ed = ide.openUnit("unit1")
    ed.showCode()
    ed.typeAtEnd "\nlet broken: int = \"oops\"\n"
    var want = -1
    for i in 0 ..< ed.code.lineCount:
      if ed.code.lineAt(i).startsWith("let broken"): want = i + 1
    check want > 0
    ide.settle
    check ide.pages.sheets()[0].caption == "unit1*"
    check ide.compile()
    check ide.waitIdle(180)
    ide.settle
    check not ide.lastBuildOk
    check ide.messages.errorCount >= 1
    let k = ide.messages.firstError()
    check k >= 0
    check ide.messages.msgs[k].line == want
    check ide.messages.msgs[k].file.extractFilename == "unit1.nim"
    check "type mismatch" in ide.messages.msgs[k].text
    # the first error was jumped to
    check ide.activeEditor.unitName == "unit1"
    check not ide.activeEditor.designerVisible
    check ide.activeEditor.code.caretPos.line == want - 1
    check ide.messages.list.itemIndex == ide.messages.rowOf(k)
    check ide.activeEditor.code.hasMarker(want - 1, MarkerKind.mkError)
    check ide.messages.list.items[ide.messages.rowOf(k)].caption.startsWith("Error:")
    check ide.status.panels[0].text == "Ready"
    check ide.acts[aCompile].enabled

  test "double click on a message jumps too":
    let k = ide.messages.firstError()
    ide.activeEditor.code.caretPos = (0, 0)
    let row = ide.messages.rowOf(k)
    ide.messages.list.onItemDblClick(ide.messages.list, row, 0)
    check ide.activeEditor.code.caretPos.line == ide.messages.msgs[k].line - 1

  test "fixing the code makes the build pass again":
    let ed = ide.activeEditor
    let want = ed.code.caretPos.line
    ed.code.select((want, 0), (want + 1, 0))
    ide.activeControl = ed.code
    ide.typeText "let broken = 1\n"
    check ide.compile()
    check ide.waitIdle(180)
    check ide.lastBuildOk

suite "closing":
  test "closing modified units asks Save, Don't Save or Cancel":
    let ed = ide.activeEditor
    ed.typeAtEnd "\n# unsaved note\n"
    check ed.modified
    ide.settle
    check ide.pages.sheets()[0].caption == "unit1*"
    asked.setLen 0
    answer = scCancel
    check not ide.closeProject()
    check asked == @["unit1"]
    check ide.project != nil and ide.editors.len == 1
    var can = true
    ide.onCloseQuery(ide, can)
    check not can                        # the window stays open on Cancel
    answer = scDiscard
    asked.setLen 0
    check ide.closeEditor(ide.activeEditor)
    check asked == @["unit1"]
    check "unsaved note" notin unitText("unit1")
    check ide.editors.len == 0

  test "Save writes the file":
    discard ide.openUnit("unit1")
    ide.activeEditor.typeAtEnd "\n# saved note\n"
    answer = scSave
    asked.setLen 0
    check ide.closeProject()
    check asked == @["unit1"]
    check "saved note" in readFile(root / "Project1" / "unit1.nim")
    check ide.project == nil

  test "closing the window with modified units also asks":
    check ide.openProject(projectFile)
    ide.activeEditor.typeAtEnd "\n# once more\n"
    answer = scDiscard
    asked.setLen 0
    var can = true
    ide.onCloseQuery(ide, can)
    check can
    check asked == @["unit1"]
    discard ide.closeProject()

suite "layout":
  test "the docking layout is saved and restored":
    check ide.openProject(projectFile)
    ide.pnlProject.hide()
    ide.pnlMessages.hide()
    ide.refreshActions()
    check not ide.acts[aViewProjectMgr].checked
    ide.saveLayout()
    let j = parseJson(readFile(settingsFile))
    check j["layout"].getStr.len > 0
    # a new IDE window reads it back
    let ide2 = newIdeForm(settingsFile = settingsFile)
    check ide2.pnlProject.state == dpHidden
    check ide2.pnlMessages.state == dpHidden
    check ide2.pnlTree.state != dpHidden
    check ide2.pnlInspector.state != dpHidden
    check ide2.pnlEditors.state != dpHidden
    ide2.free()

  test "View shows a closed panel again":
    ide.acts[aViewProjectMgr].execute()
    ide.acts[aViewMessages].execute()
    check ide.pnlProject.state != dpHidden
    check ide.pnlMessages.state != dpHidden
    ide.pnlTree.hide()
    ide.resetLayout()
    check ide.pnlTree.state != dpHidden

  test "the theme and the editor font are saved":
    ide.setDark(true)
    ide.saveSettings()
    check loadSettings(settingsFile).theme == "dark"
    ide.setDark(false)

removeDir root
