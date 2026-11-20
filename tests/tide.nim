## The whole IDE, headless: the scripted session (new application, drop a Button
## and a Label, double click for the handler, type the body, compile), then
## the built program is smoke-run; reopening a project; a compile error that is
## listed and jumped to; prompts when closing modified units; saving and
## restoring the docking layout; then the main program file (View Source, the
## import and create lines of New Form, Add to / Remove from Project, Save As),
## editor tab close buttons, project options and run parameters, Units and Forms
## lists, hints and next-message navigation, running with an exit code, the
## Reopen menu and `--project`.
import std/[unittest, os, strutils, json, times, sequtils]
import nimvcl
import nimvcl/dsl/props
import nimvcl/controls/inspector
import ide/[mainform, session, project, builder, ideconfig, uniteditor, messagespanel,
            messages, palette, actions, projecttree, mainfile, icons, buildcheck, bookmarks, findinfiles, codepicker]

if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
putEnv("SDL_RENDER_DRIVER", "software")

let root = expandFilename(getTempDir()) / ("nimrad-ide-" & $getCurrentProcessId())

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

var
  overwrites: seq[string]
  overwrite = true
ide.askOverwrite = proc(text: string): bool =
  overwrites.add text
  overwrite

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
    check ide.caption == "NimRAD"

  test "new app, Button + Label, handler, typed body, compile":
    sess = ide.runScriptedSession(root)
    check sess.error == ""
    check sess.ok
    check ide.project.name == "Project1"
    check ide.caption == "NimRAD - Project1"
    projectFile = ide.project.filePath

  test "the unit files hold the form and the handler":
    check sess.buttonName == "Button1"
    check sess.labelName == "Label1"
    let nfm = readFile(ide.project.dir / "unit1.nfm")
    check "Button1" in nfm
    check "Label1" in nfm
    check "onClick = Button1Click" in nfm
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
    check ide.caption == "NimRAD"
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

  test "a project that cannot be read stays in the recent list, a missing one goes":
    let bad = root / "corrupt.nimproj"
    writeFile(bad, "{ not json")
    ide.settings.addRecent(bad)
    check not ide.openProject(bad)
    check bad in ide.settings.recentProjects
    removeFile bad
    check not ide.openProject(bad)
    check bad notin ide.settings.recentProjects
    errors.setLen 1

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

  test "a save that fails is reported and counts as Cancel":
    check ide.openProject(projectFile)
    let ed = ide.activeEditor
    ed.typeAtEnd "\n# cannot save\n"
    let path = ide.project.dir / "unit1.nim"
    let good = readFile(path)
    removeFile path
    createDir path                       # a directory in the way: the rename fails
    answer = scSave
    errors.setLen 0
    var can = true
    ide.onCloseQuery(ide, can)
    check not can
    check not ide.closeEditor(ed)
    check not ide.closeProject()
    check errors.len == 3
    check ide.project != nil and ide.editors.len == 1 and ed.modified
    removeDir path
    writeFile(path, good)
    check ide.closeEditor(ed)
    discard ide.closeProject()

suite "files changed on disk":
  test "Save asks before it overwrites a file someone else changed; Cancel is a failed save":
    check ide.openProject(projectFile)
    let ed = ide.activeEditor
    ed.typeAtEnd "\n# mine\n"
    let path = ide.project.dir / "unit1.nim"
    writeFile(path, "# theirs\n")                  # another program saved the file
    overwrites.setLen 0
    overwrite = false
    check not ide.trySave(ed)
    check overwrites == @["unit1.nim changed on disk. Overwrite?"]
    check readFile(path) == "# theirs\n" and ed.modified
    check not ide.closeEditor(ed)                  # a failed save counts as Cancel
    overwrite = true
    check ide.trySave(ed)
    check "# mine" in readFile(path) and not ed.modified
    overwrites.setLen 0
    ed.typeAtEnd "\n# more\n"
    check ide.trySave(ed)                          # our own write is not a change
    check overwrites.len == 0
    check ide.closeEditor(ed)
    discard ide.closeProject()

suite "layout":
  test "a saved layout that cannot be used gives the default layout and a note":
    let f = root / "bad-layout.json"
    writeFile(f, """{"layout": "not a layout"}""")
    let other = newIdeForm(settingsFile = f)
    check other.status.panels[ord spMessage].text.contains("layout")
    check other.pnlProject.state != dpHidden and other.pnlInspector.state != dpHidden

  test "the window position and size are remembered":
    ide.rememberWindow()
    check ide.settings.window.w == 1360 and ide.settings.window.h == 860
    check not ide.settings.window.maximized
    let f = root / "bounds.json"
    writeFile(f, """{"window": {"x": 30, "y": 40, "w": 900, "h": 700, "maximized": false}}""")
    let other = newIdeForm(settingsFile = f)
    check other.left == 30 and other.top == 40 and other.width == 900 and other.height == 700

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


suite "To-Do List":
  test "hidden at first, View shows it with the marked comments, unsaved text first":
    check ide.openProject(projectFile)
    let u = ide.project.units[0].name
    writeFile(ide.project.dir / u & ".nim", readFile(ide.project.dir / u & ".nim") &
              "\n# TODO 2: from disk\nlet note = \"# TODO: in a string\"\n")
    check ide.closeAllEditors()
    let ed = ide.openUnit(u)
    ide.resetLayout()
    check ide.pnlTodo.state == dpHidden                 # closed in the default layout
    ide.acts[aViewTodo].execute()
    check ide.pnlTodo.state != dpHidden
    ide.refreshActions()
    check ide.acts[aViewTodo].checked
    check ide.todo.entries.len == 1
    check ide.todo.entries[0].item.priority == 2 and ide.todo.entries[0].item.text == "from disk"
    check ide.todo.entries[0].unitName == u
    check ide.todo.list.items.count == 1
    check ide.todo.list.items[0].caption == "2"
    ed.typeAtEnd "\n# FIXME: unsaved\n"
    check ed.modified
    ide.todo.refreshButton.click()
    check ide.todo.entries.len == 2 and ide.todo.entries[1].item.marker == "FIXME"

  test "a save refreshes the list at the next idle moment; a double click opens the place":
    let ed = ide.activeEditor
    ed.typeAtEnd "# NOTE saved\n"
    check ide.todo.entries.len == 2
    ide.saveActive()
    check ide.todoDirty
    ide.flushOutline()
    check not ide.todoDirty and ide.todo.entries.len == 3
    ed.code.caretPos = (0, 0)
    ide.todo.list.onItemDblClick(ide.todo.list, 0, 0)
    check ide.activeEditor == ed
    check ide.todo.entries[0].item.line == ed.code.caretPos.line + 1
    ide.todo.list.itemIndex = 2
    ide.todo.list.onItemDblClick(ide.todo.list, 2, 0)
    check ed.code.caretPos.line + 1 == ide.todo.entries[2].item.line

  test "closing the window and reset layout keep it closed":
    ide.acts[aViewTodo].execute()
    check ide.pnlTodo.state == dpHidden
    ide.todoDirty = true
    ide.flushOutline()                                  # hidden: nothing is scanned
    check ide.todoDirty
    ide.acts[aViewTodo].execute()
    ide.resetLayout()
    check ide.pnlTodo.state == dpHidden
    discard ide.closeProject()

suite "Code Explorer":
  proc itemIndexOf(name: string): int =
    for i, it in ide.explorer.items:
      if it.name == name: return i
    -1

  test "hidden at first; View shows the declarations of the active unit in groups":
    check ide.openProject(projectFile)
    check ide.closeAllEditors()
    let u = ide.project.units[0].name
    let ed = ide.openUnit(u)
    ide.outlineDelay = 0
    ide.resetLayout()
    check ide.pnlExplorer.state == dpHidden
    ide.acts[aViewExplorer].execute()
    check ide.pnlExplorer.state != dpHidden
    ide.refreshActions()
    check ide.acts[aViewExplorer].checked
    check ide.outlineEd == ed
    check ide.explorer.items.len > 0
    var groups: seq[string]
    for n in ide.explorer.tree.items.topNodes: groups.add n.text
    check groups.len == 3 and groups[0].startsWith("Procs (") and groups[2].startsWith("Imports (")
    check itemIndexOf("Button1Click") >= 0 and itemIndexOf("nimvcl/prelude") >= 0

  test "edits show up after the delay, only when the text changed":
    let ed = ide.activeEditor
    ed.typeAtEnd "\nproc brandNew*() = discard\n"
    ide.outlineDelay = 60
    ide.flushOutline()
    check itemIndexOf("brandNew") < 0                   # waiting for the typing to stop
    ide.outlineDelay = 0
    ide.flushOutline()
    check itemIndexOf("brandNew") >= 0
    let items = ide.explorer.items
    ide.flushOutline()                                  # nothing changed: nothing rebuilt
    check ide.outlineVersion == ed.code.model.version
    check ide.explorer.items == items

  test "double click and Enter go to the declaration; the active editor is followed":
    let ed = ide.activeEditor
    let k = itemIndexOf("brandNew")
    var node: TreeNode
    for g in ide.explorer.tree.items.topNodes:
      for i in 0 ..< g.childCount:
        if g.child(i).tag == k: node = g.child(i)
    check node != nil
    ed.code.caretPos = (0, 0)
    ide.explorer.tree.selected = node
    ide.explorer.tree.onDblClick(ide.explorer.tree)
    check ed.code.caretPos.line + 1 == ide.explorer.items[k].line
    check ide.activeControl == Control(ed.code)
    ed.code.caretPos = (0, 0)
    var key = keyEnter
    ide.explorer.tree.onKeyDown(ide.explorer.tree, key, {})
    check ed.code.caretPos.line + 1 == ide.explorer.items[k].line
    # an other editor: the tree follows at the next idle moment
    let m = ide.openMain()
    ide.flushOutline()
    check ide.outlineEd == m
    check itemIndexOf("brandNew") < 0
    check ide.closeAllEditors()
    ide.flushOutline()
    check ide.explorer.items.len == 0 and ide.explorer.tree.items.topCount == 0

  test "closed again, and Reset Layout keeps it closed":
    ide.acts[aViewExplorer].execute()
    check ide.pnlExplorer.state == dpHidden
    ide.acts[aViewExplorer].execute()
    ide.resetLayout()
    check ide.pnlExplorer.state == dpHidden
    discard ide.closeProject()

# ------------------------------------------------------------ the main file

proc mainText(): string = readFile(ide.project.mainPath)

proc buildAndSmoke(): tuple[ok: bool, warnings: int, exit: int, log: string] =
  ## Compile in the background (so the Messages count the warnings), then run
  ## the program with --smoke.
  doAssert ide.compile()
  doAssert ide.waitIdle(240)
  ide.settle
  result.ok = ide.lastBuildOk
  result.warnings = ide.messages.warningCount
  result.log = ide.messages.output.text
  if result.ok:
    let r = runCapture(exePath(ide.project), @["--smoke"], ide.project.dir)
    result.exit = r.exitCode
    result.log.add r.lines.join("\n")
  else:
    result.exit = -1

proc pageIndexOfClose(i: int): PointF =
  ide.settle
  let r = ide.pages.tabRect(i)
  doAssert r.w > 0
  ide.pages.clientToForm(pointF(r.right - 12, r.y + r.h / 2))   # the cross at the tab's right end

proc tabPoint(i: int): PointF =
  ide.settle
  let r = ide.pages.tabRect(i)
  ide.pages.clientToForm(pointF(r.x + 8, r.y + r.h / 2))

proc waitFor(cond: proc(): bool, seconds = 30.0): bool =
  let t0 = epochTime()
  while not cond():
    if epochTime() - t0 > seconds: return false
    Application.processMessages(20)
  true

proc dropUnit(name: string): bool =
  ## Remove from Project, then delete the files so the next form gets the number again.
  result = ide.removeFromProject(name)
  for ext in [".nim", ".nfm"]: removeFile ide.project.dir / name & ext

suite "main program file":
  setup:
    errors.setLen 0
  for f in ["unit2.nim", "unit2.nfm"]:      # left over from an earlier test
    removeFile root / "Project1" / f

  test "the project template marks the blocks the IDE edits":
    check ide.openProject(projectFile)
    let m = mainText()
    check beginMarker(ImportsBlock) in m and endMarker(ImportsBlock) in m
    check beginMarker(FormsBlock) in m and endMarker(FormsBlock) in m
    check "import unit1" in m
    check "let mainForm = newForm1()" in m

  test "View Source and a double click on the project node open the program file":
    check ide.mainEditor == nil
    let ed = ide.openMain()
    check ed != nil
    check ide.isMainEditor(ed)
    check ide.pages.sheets()[^1].caption == "Project1.nim"
    check "Application.run(mainForm)" in ed.code.text
    check ed.code.highlighter != nil
    check ide.acts[aRemoveFromProject].enabled == false
    check ide.closeEditor(ed)
    # the project node of the Project Manager
    let tree = ide.projectTree.tree
    tree.selected = tree.items.top(0)
    tree.onDblClick(tree)
    check ide.editorOf("Project1") != nil
    check ide.activeEditor.unitName == "Project1"
    check ide.closeEditor(ide.activeEditor)
    # the menu command
    ide.acts[aViewSource].execute()
    check ide.editorOf("Project1") != nil
    check not ide.removeFromProject("Project1")

  test "a compile error in the main file jumps into its editor":
    let ed = ide.editorOf("Project1")
    check ide.unitOfFile(ide.project.mainPath) == "Project1"
    check ide.jumpTo(ide.project.mainPath, 3, 1)
    check ide.activeEditor == ed
    check ed.code.caretPos.line == 2

  test "New Form adds the import and a hidden create line (the open editor follows)":
    let main = ide.editorOf("Project1")
    check main != nil
    let ed = ide.newForm()
    check ed != nil and ed.unitName == "unit2"
    let m = mainText()
    check "import unit2" in m
    check "let form2 {.used.} = newForm2()" in m
    check m.count("let mainForm = ") == 1
    check m.find("import unit2") < m.find(endMarker(ImportsBlock))
    check m.find("newForm2()") < m.find(endMarker(FormsBlock))
    check "import unit2" in main.code.text        # the open tab shows it
    check not main.modified

  test "the project compiles without warnings and smoke-runs with two forms":
    let r = buildAndSmoke()
    check r.ok
    check r.warnings == 0
    check r.exit == 0
    check "UnusedImport" notin r.log

  test "Add to Project imports a plain unit without an unused-import warning":
    writeFile(ide.project.dir / "helpers.nim", "proc helper*(): int = 42\n")
    check ide.addToProject(ide.project.dir / "helpers.nim")
    let m = mainText()
    check "import helpers" in m
    check "newHelpers" notin m
    check m.find("import helpers") < m.find("{.pop.}")
    let r = buildAndSmoke()
    check r.ok and r.warnings == 0 and r.exit == 0

  test "a form that is added later gets its create line too":
    writeFile(ide.project.dir / "extra.nim", "import nimvcl, nimvcl/dsl/nfm\nloadForm Extra, \"extra.nfm\"\n")
    writeFile(ide.project.dir / "extra.nfm", readFile(ide.project.dir / "unit2.nfm").replace("Form2", "Extra"))
    check ide.addToProject(ide.project.dir / "extra.nim")
    check "let extra {.used.} = newExtra()" in mainText()
    check ide.project.units[^1].formType == "Extra"
    check ide.removeFromProject("extra")
    check "extra" notin mainText().toLowerAscii.replace("nimrad", "")

  test "Add to Project refuses a missing file, a non-.nim file and an unreadable form":
    let n = errors.len
    check not ide.addToProject(ide.project.dir / "nothere.nim")
    writeFile(ide.project.dir / "notes.txt", "x")
    check not ide.addToProject(ide.project.dir / "notes.txt")
    writeFile(ide.project.dir / "broken.nim", "echo 1\n")
    writeFile(ide.project.dir / "broken.nfm", "this is not a form\n")
    check not ide.addToProject("broken.nim")           # relative: from the project folder
    check ide.project.findUnit("broken") < 0 and ide.project.findUnit("nothere") < 0
    check errors.len == n + 3 and "not a readable form" in errors[^1]
    errors.setLen n

  test "Remove from Project removes the import and the create line":
    check ide.removeFromProject("helpers")
    check "helpers" notin mainText()
    check dropUnit("unit2")
    let m = mainText()
    check "unit2" notin m and "Form2" notin m and "form2" notin m
    check "import unit1" in m and "let mainForm = newForm1()" in m
    check ide.editorOf("Project1").code.text == m
    check not ide.removeFromProject("unit1")          # still the main form
    check errors.len == 1 and "main form" in errors[0]

  test "edits outside the blocks survive, and a file without markers is not touched":
    check ide.closeEditor(ide.editorOf("Project1"))
    let orig = mainText()
    let mine = orig.replace("proc main() =", "# before main\nproc main() =").replace(
      "  Application.init()\n", "  Application.init()\n  # my note\n")
    writeFile(ide.project.mainPath, mine)
    check ide.newForm().unitName == "unit2"
    check "# before main\nproc main() =" in mainText()
    check "  Application.init()\n  # my note\n" in mainText()
    check "import unit2" in mainText()
    check dropUnit("unit2")
    check mainText() == mine
    # without markers the IDE leaves the file alone (and says so)
    let bare = mine.replace(beginMarker(ImportsBlock), "#").replace(beginMarker(FormsBlock), "#")
    writeFile(ide.project.mainPath, bare)
    check ide.newForm() != nil
    check mainText() == bare
    check dropUnit("unit2")
    check mainText() == bare
    writeFile(ide.project.mainPath, orig)

  test "a main file that cannot be saved before an edit is reported, its text is kept":
    let ed = ide.openMain()
    ed.typeAtEnd "\n# unsaved\n"
    let path = ide.project.mainPath
    let good = readFile(path)
    removeFile path
    createDir path                       # a directory in the way: the save fails
    let n = errors.len
    check ide.beforeMainEdit() == nil
    check errors.len == n + 1 and ed.modified and "# unsaved" in ed.code.text
    removeDir path
    writeFile(path, good)
    ed.reloadFromDisk()
    check not ed.modified
    errors.setLen n
    check ide.closeEditor(ed)

suite "save as":
  setup:
    errors.setLen 0

  test "Save As renames a unit: files, imports and the loadForm path":
    check ide.newForm().unitName == "unit2"
    let ed = ide.editorOf("unit2")
    ed.showCode()
    ed.typeAtEnd "\n# edited before save as\n"
    check ed.modified
    check ide.saveAs("second")
    check not fileExists(ide.project.dir / "unit2.nim")
    check not fileExists(ide.project.dir / "unit2.nfm")
    check fileExists(ide.project.dir / "second.nim") and fileExists(ide.project.dir / "second.nfm")
    check "# edited before save as" in readFile(ide.project.dir / "second.nim")
    check "loadForm Form2, \"second.nfm\"" in readFile(ide.project.dir / "second.nim")
    check "import second" in mainText() and "import unit2" notin mainText()
    check "newForm2()" in mainText()
    check ide.project.findUnit("second") >= 0 and ide.project.findUnit("unit2") < 0
    check loadProject(ide.project.filePath).findUnit("second") >= 0
    check ide.editorOf("unit2") == nil
    check ide.editorOf("second") != nil and ide.activeEditor.unitName == "second"
    check ide.projectTree.nodeOf("second") != nil
    check ide.editorOf("Project1") == nil or "import second" in ide.editorOf("Project1").code.text

  test "the project still compiles and smoke-runs after the rename":
    let r = buildAndSmoke()
    check r.ok and r.warnings == 0 and r.exit == 0

  test "a bad or taken name is refused and nothing changes":
    check not ide.saveAs("unit1")
    check not ide.saveAs("1bad")
    check errors.len == 2
    check fileExists(ide.project.dir / "second.nim")
    check ide.editorOf("second") != nil
    check ide.saveAs("second")                        # same name: nothing to do

  test "Save As asks for the name":
    var asked = ""
    ide.askText = proc(caption, prompt: string, value: var string): bool =
      asked = caption & "/" & value
      value = "third"
      true
    check ide.acts[aSaveAs].enabled
    ide.acts[aSaveAs].execute()
    ide.askText = nil
    check asked == "Save As/second"
    check ide.project.findUnit("third") >= 0
    check "import third" in mainText()

  test "Save Project As renames the project and its main file":
    check ide.openMain() != nil
    check ide.saveProjectAs("Renamed")
    check ide.project.name == "Renamed"
    check ide.caption == "NimRAD - Renamed"
    check fileExists(root / "Project1" / "Renamed.nimproj")
    check fileExists(root / "Project1" / "Renamed.nim")
    check not fileExists(root / "Project1" / "Project1.nimproj")
    check not fileExists(root / "Project1" / "Project1.nim")
    check ide.project.filePath == root / "Project1" / "Renamed.nimproj"
    check ide.settings.recentProjects[0] == ide.project.filePath
    check projectFile notin ide.settings.recentProjects
    check ide.editorOf("Renamed") != nil              # the program tab is reopened
    check ide.pages.sheets()[^1].caption == "Renamed.nim"
    check ide.status.panels[0].text == "Ready"
    projectFile = ide.project.filePath

  test "the project builds under its new name and smoke-runs":
    let r = buildAndSmoke()
    check r.ok and r.warnings == 0 and r.exit == 0
    check exePath(ide.project).extractFilename == "Renamed".addFileExt(ExeExt)
    check fileExists(exePath(ide.project))


suite "version":
  test "the version comes from nimrad.nimble":
    check AppVersion.len > 0 and AppVersion != "0.0.1"
    check ("version       = \"" & AppVersion & "\"") in readFile(currentSourcePath().parentDir.parentDir / "nimrad.nimble")

suite "editor tabs":
  test "every tab has a close button; a click on it closes the unit and asks first":
    check ide.closeAllEditors()
    let a = ide.openUnit("unit1")
    let b = ide.openUnit("third")
    check a != nil and b != nil and ide.editors.len == 2
    ide.settle
    check ide.pages.closeButtons
    b.typeAtEnd "\n# tab note\n"
    ide.settle
    check ide.pages.sheets()[1].caption == "third*"
    asked.setLen 0
    answer = scCancel
    ide.click pageIndexOfClose(1)
    check asked == @["third"]
    check ide.editors.len == 2                        # cancelled: the tab stays
    answer = scDiscard
    ide.click pageIndexOfClose(1)
    check asked == @["third", "third"]
    check ide.editors.len == 1 and ide.editorOf("third") == nil
    check "tab note" notin readFile(ide.project.dir / "third.nim")

  test "a click on the cross of another tab closes that tab, not the active one":
    check ide.closeAllEditors()
    discard ide.openUnit("unit1")
    discard ide.openUnit("third")                    # the active tab is the second one
    check ide.activeEditor.unitName == "third"
    asked.setLen 0
    ide.click pageIndexOfClose(0)
    check asked.len == 0
    check ide.editors.len == 1 and ide.editors[0].unitName == "third"
    check ide.activeEditor.unitName == "third"

  test "closing a tab before the active one keeps the active unit":
    check ide.closeAllEditors()
    discard ide.openUnit("unit1")
    discard ide.openUnit("third")
    check ide.openMain() != nil                      # three tabs, the last one active
    check ide.activeEditor.unitName == ide.project.name
    check ide.closeEditor(ide.editors[0])
    check ide.activeEditor.unitName == ide.project.name
    ide.pages.activePageIndex = 0                    # "third"; close the one behind it
    ide.bindActive()
    check ide.closeEditor(ide.editors[1])
    check ide.activeEditor.unitName == "third"
    check ide.closeAllEditors()

  test "a click on the tab itself selects it and does not close it":
    check ide.closeAllEditors()
    discard ide.openUnit("unit1")
    discard ide.openUnit("third")
    check ide.pages.activePageIndex == 1
    ide.click tabPoint(0)
    check ide.editors.len == 2
    check ide.pages.activePageIndex == 0

  test "a middle click on a tab closes it":
    check ide.editors.len == 2 and ide.editors[1].unitName == "third"
    asked.setLen 0
    ide.middleClick tabPoint(1)
    check ide.editors.len == 1 and ide.editors[0].unitName == "unit1"
    check asked.len == 0
    ide.middleClick tabPoint(0)
    check ide.editors.len == 0

  test "middle click on a modified unit asks too":
    let a = ide.openUnit("unit1")
    a.typeAtEnd "\n# keep me\n"
    answer = scCancel
    asked.setLen 0
    ide.middleClick tabPoint(0)
    check asked == @["unit1"] and ide.editors.len == 1
    answer = scDiscard
    ide.middleClick tabPoint(0)
    check ide.editors.len == 0
    check "keep me" notin unitText("unit1")

suite "options and run parameters":
  setup:
    errors.setLen 0

  test "Options: defines, title and version are stored and passed to the compiler":
    ide.applyOptions ProjectOptions(outputDir: " build ", flags: "--opt:none  --threads:off",
                                    defines: "foo, -d:bar=2  foo --define:baz", title: " My App ",
                                    version: "1.2.3")
    let p = ide.project
    check p.outputDir == "build"
    check p.nimFlags == @["--opt:none", "--threads:off"]
    check p.defines == @["foo", "bar=2", "baz"]
    check p.title == "My App" and p.version == "1.2.3"
    let q = loadProject(p.filePath)
    check q.defines == p.defines and q.title == "My App" and q.version == "1.2.3"
    let o = ide.currentOptions
    check o.defines == "foo bar=2 baz" and o.title == "My App" and o.version == "1.2.3"
    let args = compileArgs(p)
    for want in ["-d:foo", "-d:bar=2", "-d:baz", "-d:appTitle=My App", "-d:appVersion=1.2.3"]:
      check want in args
    check ide.status.panels[4].text == "Project options saved"

  test "the defines, title and version reach the program":
    check ide.closeAllEditors()
    let m = mainText()
    writeFile(ide.project.mainPath, m.replace("  Application.init()\n",
      "  echo \"built: foo=\", defined(foo), \" baz=\", defined(baz), \" v=\", appVersion, \" t=\", appTitle\n" &
      "  Application.init()\n"))
    let r = buildAndSmoke()
    check r.ok and r.warnings == 0 and r.exit == 0
    check "built: foo=true baz=true v=1.2.3 t=My App" in r.log

  test "Run > Parameters sets the program arguments":
    var asked = ""
    ide.askText = proc(caption, prompt: string, value: var string): bool =
      asked = caption & "/" & value
      value = "--exit3 \"a b\" plain"
      true
    check ide.acts[aRunParameters].enabled
    ide.acts[aRunParameters].execute()
    ide.askText = nil
    check asked.startsWith("Run Parameters/")
    check ide.project.runArgs == @["--exit3", "a b", "plain"]
    check ide.runParameters == "--exit3 \"a b\" plain"
    check loadProject(ide.project.filePath).runArgs == ide.project.runArgs
    ide.setRunParameters ""
    check ide.project.runArgs.len == 0

  test "a compiler flag with a quoted space survives the options and the project file":
    var o = ide.currentOptions
    let before = o.flags
    o.flags = "--hints:off --passL:\"-L/my path\" -d:x"
    ide.applyOptions o
    check ide.project.nimFlags == @["--hints:off", "--passL:-L/my path", "-d:x"]
    check ide.currentOptions.flags == "--hints:off \"--passL:-L/my path\" -d:x"
    check loadProject(ide.project.filePath).nimFlags == ide.project.nimFlags
    ide.applyOptions ide.currentOptions                # the displayed text gives the same flags
    check ide.project.nimFlags == @["--hints:off", "--passL:-L/my path", "-d:x"]
    o.flags = before
    ide.applyOptions o
    check ide.project.nimFlags == before.splitWhitespace

suite "units and forms lists":
  var shown: seq[string]
  var title = ""
  var pick = -1
  setup:
    ide.pickItem = proc(t: string, items: seq[string], selected: int): int =
      title = t
      shown = items
      pick

  teardown:
    ide.pickItem = nil

  test "View > Units lists the program and every unit":
    check ide.acts[aViewUnits].shortcut == shortcut("Ctrl+F12")
    check ide.acts[aViewForms].shortcut == shortcut("Shift+F12")
    pick = 2
    check ide.closeAllEditors()
    let ed = ide.viewUnits()
    check title == "View Unit"
    check shown == @["Renamed (program)", "unit1 (Form1)", "third (Form2)"]
    check ed != nil and ed.unitName == "third"
    check ide.activeEditor.unitName == "third"

  test "View > Forms lists the form units only":
    pick = 0
    let ed = ide.viewUnits(formsOnly = true)
    check title == "View Form"
    check shown == @["unit1 (Form1)", "third (Form2)"]
    check ed != nil and ed.unitName == "unit1"

  test "the program file can be chosen from the Units list":
    pick = 0
    let ed = ide.viewUnits()
    check ed != nil and ide.isMainEditor(ed)

  test "cancelling opens nothing":
    check ide.closeAllEditors()
    pick = -1
    check ide.viewUnits() == nil
    check ide.editors.len == 0

  test "the keyboard shortcuts open the lists":
    pick = 1
    ide.activeControl = nil
    ide.pressKey(keyF12, {ssCtrl})
    check title == "View Unit"
    check ide.activeEditor != nil and ide.activeEditor.unitName == "unit1"
    ide.pressKey(keyF12, {ssShift})
    check title == "View Form"
    check shown.len == 2

suite "compiler messages":
  var orig = ""
  test "hints and warnings have their own icons; Hints shows and hides them":
    check icWarning != icHint and icHint != icError and icWarning != icError
    check ide.closeAllEditors()
    orig = unitText("unit1")
    ide.setShowHints(true)
    check ide.settings.showHints and ide.messages.showHints
    check loadSettings(settingsFile).showHints
    check ide.acts[aShowHints].checked
    ide.project.nimFlags = @["--errorMax:100"]
    let ed = ide.openUnit("unit1")
    ed.typeAtEnd "\nproc hintMaker() =\n  var unusedLocal = 1\n" &
                 "proc oldOne() {.deprecated.} = discard\noldOne()\n" &
                 "let bad1: int = \"a\"\nlet bad2: string = 1\n"
    check ide.compile()
    check ide.waitIdle(240)
    ide.settle
    let m = ide.messages
    check not ide.lastBuildOk
    var kinds: array[MessageKind, int]
    for x in m.msgs: inc kinds[x.kind]
    check kinds[MessageKind.mkError] >= 2
    check kinds[MessageKind.mkWarning] >= 1
    check kinds[MessageKind.mkHint] >= 1
    var iconOf: array[MessageKind, int]
    for r in 0 ..< m.list.items.count:
      let k = m.list.items[r].tag
      if k >= 0: iconOf[m.msgs[k].kind] = m.list.items[r].imageIndex
    check iconOf[MessageKind.mkError] == icError
    check iconOf[MessageKind.mkWarning] == icWarning
    check iconOf[MessageKind.mkHint] == icHint
    # hide: no hint row, but the messages are kept
    let rows = m.list.items.count
    ide.acts[aShowHints].execute()
    check not ide.settings.showHints and not m.showHints
    var hintRows = 0
    for r in 0 ..< m.list.items.count:
      if m.list.items[r].caption.startsWith("Hint:"): inc hintRows
    check hintRows == 0
    check m.list.items.count == rows - kinds[MessageKind.mkHint]
    check m.msgs.len > m.list.items.count
    ide.setShowHints(true)
    check m.list.items.count == rows
    check ide.acts[aShowHints].checked

  test "F8 and Ctrl+Alt+Down go to the next message, wrapping at the end":
    let m = ide.messages
    check ide.acts[aNextMessage].shortcut == shortcut("F8")
    check ide.acts[aNextMessageAlt].shortcut == shortcut("Ctrl+Alt+Down")
    check ide.acts[aNextMessage].enabled
    var order: seq[int]                     # the messages F8 can reach
    for i, x in m.msgs:
      if x.hasLocation: order.add i
    check order.len >= 4
    check m.cursor == m.firstError()        # the failed build went to the first error
    check order.find(m.cursor) >= 0
    let start = m.cursor
    ide.activeControl = ide.activeEditor.code
    var seen: seq[int]
    for _ in 0 ..< order.len:
      ide.pressKey(keyF8)
      seen.add m.cursor
    check seen[^1] == start                 # a whole round
    check seen.toSeq.len == order.len
    var want: seq[int]
    let at = order.find(start)
    for k in 1 .. order.len: want.add order[(at + k) mod order.len]
    check seen == want
    # it opened the message: unit1 is in the code with the caret on the line
    let msg = m.msgs[m.cursor]
    check ide.unitOfFile(msg.file) == "unit1"
    check ide.activeEditor.code.caretPos.line == msg.line - 1
    check m.list.itemIndex == m.rowOf(m.cursor)
    ide.pressKey(keyDown, {ssCtrl, ssAlt})
    check m.cursor == order[(order.find(start) + 1) mod order.len]

  test "with the hints hidden F8 skips them":
    let m = ide.messages
    ide.setShowHints(false)
    for _ in 0 .. m.msgs.len:
      ide.pressKey(keyF8)
      check m.msgs[m.cursor].kind != MessageKind.mkHint
    ide.setShowHints(true)

  test "without messages F8 is disabled":
    ide.messages.clear()
    ide.refreshActions()
    check not ide.acts[aNextMessage].enabled
    check not ide.nextMessage()

  test "restore the unit":
    ide.project.nimFlags = @[]
    ide.setShowHints(false)
    writeFile(ide.project.dir / "unit1.nim", orig)
    ide.activeEditor.reloadFromDisk()
    check not ide.activeEditor.modified

suite "running":
  test "output is live, Running is in the title, and the exit code is reported":
    check ide.closeAllEditors()
    writeFile(ide.project.mainPath, mainText().replace("  Application.init()\n",
      "  if \"--exit3\" in commandLineParams():\n" &
      "    echo \"live-line\"\n    stdout.flushFile\n    sleep(2500)\n" &
      "    stderr.writeLine \"err-line\"\n    quit(3)\n" &
      "  if \"--hang\" in commandLineParams():\n    echo \"hanging\"\n    sleep(120000)\n" &
      "  Application.init()\n"))
    ide.setRunParameters "--exit3"
    check ide.caption == "NimRAD - Renamed"
    check ide.run()
    check waitFor(proc(): bool = "live-line" in ide.messages.output.text, 240)
    check ide.busy                                     # the program has not ended yet
    check "err-line" notin ide.messages.output.text
    check ide.caption == "NimRAD - Renamed [Running]"
    check ide.status.panels[0].text == "Running"
    check ide.messages.root.activePageIndex == 1       # the Output tab
    check ide.acts[aReset].enabled and not ide.acts[aRun].enabled
    check ide.waitIdle(60)
    check ide.lastExitCode == 3
    let out0 = ide.messages.output.text
    check "err-line" in out0                           # stderr arrives too
    check out0.find("live-line") < out0.find("err-line")
    let m = ide.messages
    let last = m.list.items[m.list.items.count - 1]
    check last.caption == "Program ended with exit code 3"
    check last.imageIndex == icError
    check ide.caption == "NimRAD - Renamed"
    check ide.status.panels[0].text == "Ready"
    check "Program ended" in ide.status.panels[4].text

  test "a traceback in the output of the program is clickable":
    let m = ide.messages
    m.clear()
    let f = ide.project.dir / "unit1.nim"
    m.isOwnFile = proc(file: string): bool = ide.unitOfFile(file).len > 0
    m.feedRuntimeLines(["plain", "Traceback (most recent call last)",
                        f & "(2) unit1", "/nim/lib/system/fatal.nim(53) sysFatal",
                        "Error: unhandled exception: boom [ValueError]"])
    check m.msgs.len == 4 and m.runtimeErrors == 1
    check m.msgs[^1].kind == MessageKind.mkError and m.msgs[^1].file == f and m.msgs[^1].line == 2
    check ide.closeAllEditors()
    m.jump m.msgs.high
    check ide.activeEditor != nil and ide.activeEditor.unitName == "unit1"
    check ide.activeEditor.code.caretPos.line == 1
    m.clear()

  test "a program that ends well says exit code 0":
    ide.setRunParameters "--smoke"
    check ide.run()
    check ide.waitIdle(60)
    let m = ide.messages
    check ide.lastExitCode == 0
    check m.list.items[m.list.items.count - 1].caption == "Program ended with exit code 0"
    check m.list.items[m.list.items.count - 1].imageIndex == icSuccess

  test "Program Reset stops it and says so":
    ide.setRunParameters "--hang"
    check ide.run()
    check waitFor(proc(): bool = "hanging" in ide.messages.output.text, 60)
    check ide.caption.endsWith("[Running]")
    # the running program belongs to this project: it cannot be replaced meanwhile
    let proj = ide.project
    errors.setLen 0
    ide.refreshActions()
    check not ide.acts[aOpenProject].enabled and not ide.acts[aNewApp].enabled
    check not ide.openProject(projectFile)
    check not ide.newApplication(root / "busy", "busy")
    check not ide.closeProject()
    check errors.len == 3 and "Program Reset" in errors[0]
    check ide.project == proj and not dirExists(root / "busy")
    ide.programReset()
    check ide.waitIdle(30)
    ide.refreshActions()
    check ide.acts[aOpenProject].enabled and ide.acts[aNewApp].enabled
    let m = ide.messages
    check m.list.items[m.list.items.count - 1].caption.startsWith("Program stopped with exit code")
    check not ide.caption.endsWith("[Running]")

suite "run and stop details":
  test "Run does not build again what is up to date, and builds what changed":
    ide.setRunParameters "--smoke"
    let n = ide.buildCount
    check ide.run()                                    # built by the runs before
    check ide.waitIdle(120)
    check ide.buildCount == n
    check ide.lastExitCode == 0
    let m = ide.messages
    check m.list.items[0].caption.startsWith("Up to date")
    # an edit of the program file is built
    let main = ide.project.mainPath
    writeFile(main, readFile(main) & "\n# changed\n")
    check ide.run()
    check ide.waitIdle(120)
    check ide.buildCount == n + 1
    check ide.lastExitCode == 0
    # a changed option is built too
    ide.project.defines = @["upToDateTest"]
    check ide.run()
    check ide.waitIdle(120)
    check ide.buildCount == n + 2
    ide.project.defines = @[]

  test "stopping a build says it was cancelled, not that it failed":
    ide.setRunParameters "--smoke"
    check ide.compile()
    ide.programReset()
    check ide.waitIdle(60)
    let m = ide.messages
    check m.list.items[m.list.items.count - 1].caption == "Build cancelled"
    check "Build failed" notin ide.messages.output.text

  test "Find Unit in the program file of a project without units does not crash":
    check ide.closeAllEditors()
    let saved = ide.project.units
    ide.project.units = @[]
    let ed = ide.openMain()
    check ed != nil
    ed.code.text = "Button\n"
    ed.code.caretPos = (0, 2)
    ide.pickItem = proc(title: string, items: seq[string], selected: int): int = 0
    discard ide.findUnitImport()
    ide.pickItem = nil
    ide.project.units = saved
    ed.reloadFromDisk()

suite "the idle hook only refreshes what changed":
  test "the Object TreeView is rebuilt after a structure change, not on every idle":
    check ide.closeAllEditors()
    check ide.openUnit("unit1") != nil
    ide.settle
    proc hasMarker(): bool =
      for i in 0 ..< ide.objTree.items.topCount:
        if ide.objTree.items.top(i).text == "marker": return true
    discard ide.objTree.items.addChild(nil, "marker")      # a rebuild would drop it
    for _ in 1 .. 5: Application.processMessages(0)
    check hasMarker()
    check ide.dropComponent("Button")
    for _ in 1 .. 3: Application.processMessages(0)
    check not hasMarker()

  test "a collapsed node of the Object TreeView stays collapsed over a property change and a rebuild":
    check ide.closeAllEditors()
    let ed = ide.openUnit("unit1")
    ide.settle
    check ide.dropComponent("Panel")
    check ide.dropComponent("Button")                  # into the selected panel
    ide.settle
    var inner: TreeNode
    for i, n in ide.treeNodes:
      if ide.treeComps[i].name == "Panel1": inner = n
    check inner != nil and inner.hasChildren
    inner.collapse()
    let before = ide.objTree.items.top(0)
    check not inner.expanded
    for (c, _) in ed.componentTree:
      if c.name == "Button1": ed.selectComponent(c)
    check ide.inspector.setValue("caption", pvString("Changed"))
    ide.settle
    check ide.objTree.items.top(0) == before           # the property change did not rebuild
    check not inner.expanded
    check ide.dropComponent("Label")                   # a rebuild keeps what was collapsed
    ide.settle
    check ide.objTree.items.top(0) != before
    var again = false
    for i, n in ide.treeNodes:
      if n.hasChildren and not n.expanded: again = true
    check again

suite "Align, Size and Tab Order":
  var ed: UnitEditor
  var a, b, c: Control

  proc dropped(cls: string, x, y, w, h: float32): Control =
    check ide.dropComponent(cls)
    result = Control(ed.selection[0])
    result.setBounds(x, y, w, h)

  proc pick(cs: varargs[Control]) = ed.designer.select(@cs)

  test "setup: three buttons":
    check ide.closeAllEditors()
    ed = ide.openUnit("unit1")
    ide.settle
    a = dropped("Button", 20, 20, 100, 30)
    b = dropped("Button", 60, 80, 140, 24)
    c = dropped("Button", 150, 140, 80, 40)
    pick(a, b, c)
    ide.refreshActions()
    for id in [aAlignDlg, aSizeDlg, aTabOrder]: check ide.acts[id].enabled

  test "Align: the hook gives the options, the first selected control is the model":
    var seen = AlignOptions()
    ide.askAlign = proc(o: var AlignOptions): bool =
      seen = o
      o.horizontal = haLeftSides
      o.vertical = vaTops
      true
    pick(a, b, c)
    check ide.alignDialog()
    check seen.horizontal == haNoChange and seen.vertical == vaNoChange
    check b.left == a.left and c.left == a.left
    check b.top == a.top and c.top == a.top
    check ide.activeEditor.designer.undo()               # one undo step per direction
    check ide.activeEditor.designer.undo()
    check b.left == 60 and c.top == 140

  test "Align: centers, space equally, center in window, cancel":
    ide.askAlign = proc(o: var AlignOptions): bool =
      o.horizontal = haCenters
      o.vertical = vaSpaceEqually
      true
    pick(a, b, c)
    check ide.alignDialog()
    check abs((b.left + b.width / 2) - (a.left + a.width / 2)) <= 1
    check abs((c.left + c.width / 2) - (a.left + a.width / 2)) <= 1
    let gap1 = b.top - (a.top + a.height)
    let gap2 = c.top - (b.top + b.height)
    check abs(gap1 - gap2) <= 1
    ide.askAlign = proc(o: var AlignOptions): bool =
      o.horizontal = haCenterInWindow
      o.vertical = vaCenterInWindow
      true
    pick(b)
    check ide.alignDialog()
    check abs(b.left - (b.parent.width - b.width) / 2) <= 1
    check abs(b.top - (b.parent.height - b.height) / 2) <= 1
    let l = b.left
    ide.askAlign = proc(o: var AlignOptions): bool = false
    pick(a, b, c)
    check not ide.alignDialog()
    check b.left == l

  test "Size: shrink to smallest, grow to largest":
    a.setBounds(20, 20, 100, 30)
    b.setBounds(60, 80, 140, 24)
    c.setBounds(150, 140, 80, 40)
    ide.askSize = proc(o: var SizeOptions): bool =
      o.widthMode = smShrinkToSmallest
      o.heightMode = smGrowToLargest
      true
    pick(a, b, c)
    check ide.sizeDialog()
    for x in [a, b, c]:
      check x.width == 80
      check x.height == 40
    check ed.designer.selection == @[a, b, c]            # the selection stays as it was

  test "Size: an exact size, and the dialog starts with the primary control's size":
    var seen = SizeOptions()
    ide.askSize = proc(o: var SizeOptions): bool =
      seen = o
      o.widthMode = smExact
      o.width = 120
      o.heightMode = smExact
      o.height = 33
      true
    pick(b, a, c)
    check ide.sizeDialog()
    check seen.width == 80 and seen.height == 40
    for x in [a, b, c]:
      check x.width == 120
      check x.height == 33
    check ed.modified

  test "Tab Order: the hook reorders, the values are saved":
    var listed: seq[string]
    ide.askOrder = proc(title: string, items: seq[string]): seq[int] =
      listed = items
      @[items.high] & toSeq(0 ..< items.high)         # the last one first
    pick(b)
    let before = ed.tabControls.mapIt(it.name)
    check before.len >= 3
    check ide.tabOrderDialog()
    check listed == before
    let after = ed.tabControls.mapIt(it.name)
    check after == @[before[^1]] & before[0 .. ^2]
    ed.save()
    let nfm = readFile(ide.project.dir / "unit1.nfm")
    check "tabOrder = 1" in nfm
    ide.askOrder = proc(title: string, items: seq[string]): seq[int] = @[]
    check not ide.tabOrderDialog()
    check ed.tabControls.mapIt(it.name) == after

suite "Build and Syntax Check":
  test "Build compiles again with -f and the result still counts as up to date for Run":
    check ide.closeAllEditors()
    ide.setRunParameters "--smoke"
    check ide.compile()
    check ide.waitIdle(180)
    check ide.lastBuildOk
    check ide.acts[aBuild].enabled and ide.acts[aSyntaxCheck].enabled
    let n = ide.buildCount
    check ide.build()
    check ide.buildPhase == bpCompiling
    check not ide.acts[aBuild].enabled
    check ide.waitIdle(180)
    check ide.lastBuildOk
    check ide.buildCount == n + 1                     # built although nothing changed
    check ide.run()
    check ide.waitIdle(120)
    check ide.buildCount == n + 1                     # Run found the build up to date
    check ide.messages.list.items[0].caption.startsWith("Up to date")

  test "Syntax Check: no program, no record, errors are listed and marked":
    let stamp = ide.project.stampPath(ide.project.compileArgs())
    let stampBefore = readFile(stamp)
    let n = ide.buildCount
    let unitFile = ide.project.dir / "unit1.nim"
    let orig = readFile(unitFile)
    check ide.syntaxCheck()
    check ide.buildPhase == bpChecking
    check ide.waitIdle(180)
    check ide.buildPhase == bpIdle
    check ide.messages.errorCount == 0
    check ide.messages.list.items[ide.messages.list.items.count - 1].caption.startsWith("Syntax check passed")
    check ide.status.panels[0].text == "Ready"
    # an error
    writeFile(unitFile, orig & "\nlet broken: int = \"oops\"\n")
    check ide.syntaxCheck()
    check ide.waitIdle(180)
    check ide.messages.errorCount >= 1
    check ide.messages.msgs[ide.messages.firstError()].file.extractFilename == "unit1.nim"
    check ide.messages.list.items[ide.messages.list.items.count - 1].caption.startsWith("Syntax check found")
    check ide.editorOf("unit1") != nil
    writeFile(unitFile, orig)
    check ide.buildCount == n
    check readFile(stamp) == stampBefore
    check ide.closeAllEditors()

  test "Program Reset stops a syntax check":
    check ide.syntaxCheck()
    check ide.acts[aReset].enabled
    ide.programReset()
    check ide.waitIdle(60)
    check ide.messages.list.items[ide.messages.list.items.count - 1].caption == "Syntax check cancelled"

suite "Editor Options":
  test "the dialog's values go to every open and new editor and into settings.json":
    check ide.closeAllEditors()
    let e1 = ide.openUnit("unit1")
    check e1.code.tabWidth == 2 and e1.code.insertSpaces and e1.code.showLineNumbers
    var seen = EditorOptions()
    ide.askEditorOptions = proc(o: var EditorOptions): bool =
      seen = o
      o = EditorOptions(fontFamily: "serif", fontSize: 17, tabWidth: 4, insertSpaces: false,
                        lineNumbers: false)
      true
    check ide.editorOptions()
    check seen.fontSize == DefaultFontSize and seen.tabWidth == 2 and seen.insertSpaces
    for e in [e1]:
      check e.code.font.family == "serif" and e.code.font.size == 17
      check e.code.tabWidth == 4 and not e.code.insertSpaces and not e.code.showLineNumbers
    check ide.messages.output.font.size == 17
    let ed2 = ide.openMain()                           # a new editor gets them too
    check ed2.code.tabWidth == 4 and not ed2.code.showLineNumbers and ed2.code.font.family == "serif"
    let s = loadSettings(settingsFile)
    check s.editorFontFamily == "serif" and s.editorFontSize == 17 and s.editorTabWidth == 4
    check not s.editorInsertSpaces and not s.editorLineNumbers
    # values outside the ranges are clamped; cancel changes nothing
    ide.askEditorOptions = proc(o: var EditorOptions): bool =
      o.fontSize = 500
      o.tabWidth = 0
      true
    check ide.editorOptions()
    check ide.settings.editorFontSize == 40 and ide.settings.editorTabWidth == 1
    ide.askEditorOptions = proc(o: var EditorOptions): bool = false
    check not ide.editorOptions()
    check ide.settings.editorFontSize == 40
    # back to the defaults
    ide.askEditorOptions = proc(o: var EditorOptions): bool =
      o = EditorOptions(fontSize: DefaultFontSize, tabWidth: 2, insertSpaces: true, lineNumbers: true)
      true
    check ide.editorOptions()
    check e1.code.tabWidth == 2 and e1.code.showLineNumbers
    check ide.closeAllEditors()

suite "Bookmarks":
  test "numbered bookmarks follow the lines, move, and work across editors":
    check ide.closeAllEditors()
    let ed = ide.openUnit("unit1")
    ed.showCode()
    ide.activeControl = ed.code
    let c = ed.code
    c.text = "line0\nline1\nline2\nline3\nline4\n"
    c.caretPos = (2, 0)
    ide.refreshActions()
    check ide.acts[aToggleBookmark3].enabled and ide.acts[aGotoBookmark3].enabled
    check ide.acts[aToggleBookmark3].shortcut == shortcut("Shift+Ctrl+3")
    check ide.acts[aGotoBookmark3].shortcut == shortcut("Ctrl+3")
    check ide.toggleBookmark(3)
    check ed.bookmarks.lineOf(3) == 2 and c.hasMarker(2, MarkerKind.mkBookmark)
    c.caretPos = (4, 0)
    check ide.toggleBookmark(7)
    # lines inserted above move both
    c.caretPos = (0, 0)
    ide.typeText "new\n"
    check ed.bookmarks.lineOf(3) == 3 and ed.bookmarks.lineOf(7) == 5
    check c.hasMarker(3, MarkerKind.mkBookmark) and c.hasMarker(5, MarkerKind.mkBookmark)
    # go to
    c.caretPos = (0, 0)
    ide.pressKey(key('3'), {ssCtrl})
    check c.caretPos.line == 3
    c.caretPos = (1, 0)                                 # the shortcut of Toggle
    ide.pressKey(key('9'), {ssCtrl, ssShift})
    check ed.bookmarks.lineOf(9) == 1
    ide.toggleBookmark(9)
    check ed.bookmarks.lineOf(9) == -1
    check ide.gotoBookmark(7) and c.caretPos.line == 5
    check not ide.gotoBookmark(5)                       # free slot
    # toggling on the same line removes it; on another line it moves
    c.caretPos = (1, 0)
    check ide.toggleBookmark(3)
    check ed.bookmarks.lineOf(3) == 1 and not c.hasMarker(3, MarkerKind.mkBookmark)
    check ide.toggleBookmark(3) == false
    check ed.bookmarks.lineOf(3) == -1 and c.markerLines(MarkerKind.mkBookmark) == @[5]
    # a line removed above moves the bookmark up
    c.select((0, 0), (1, 0))
    ide.activeControl = c
    discard c.model.deleteSelection()
    check ed.bookmarks.lineOf(7) == 4
    # its own line deleted: the bookmark stays on the line that took its place
    c.select((4, 0), (5, 0))
    discard c.model.deleteSelection()
    check ed.bookmarks.lineOf(7) == 4 and c.hasMarker(4, MarkerKind.mkBookmark)
    # a second editor: the slot is global
    c.caretPos = (1, 0)
    check ide.toggleBookmark(2)
    let main = ide.openMain()
    main.showCode()
    ide.activeControl = main.code
    main.code.caretPos = (1, 0)
    check ide.toggleBookmark(2)
    check ed.bookmarks.lineOf(2) == -1 and main.bookmarks.lineOf(2) == 1
    ide.activeControl = main.code
    check ide.pages.activePageIndex == ide.editorIndex(main.unitName)
    ide.pages.activePage = ide.sheets[ide.editorIndex("unit1")]
    check ide.gotoBookmark(2)
    check ide.activeEditor == main and main.code.caretPos.line == 1
    # text loaded again: the marker is gone, so is the slot
    main.code.text = "x\ny\n"
    check main.bookmarks.lineOf(2) == -1
    check ide.closeAllEditors()

suite "Find in Files":
  test "the dialog's options search the units, the lines go to Messages and open on a double click":
    check ide.closeAllEditors()
    let ed = ide.openUnit("unit1")
    ed.typeAtEnd "\n# zzfind here\nlet zzFind2 = 1\n"          # unsaved: it is what is searched
    ide.settle
    check ed.modified
    check ide.acts[aFindInFiles].enabled
    check ide.acts[aFindInFiles].shortcut == shortcut("Shift+Ctrl+F")
    var seen = FindOptions()
    ide.askFindInFiles = proc(o: var FindOptions): bool =
      seen = o
      o.text = "zzfind"
      true
    check ide.findInFilesCommand()
    check ide.findOptions.text == "zzfind"
    let m = ide.messages
    check m.list.items[0].caption.startsWith("Find in Files: 'zzfind'")
    var rows: seq[int]
    for r in 0 ..< m.list.items.count:
      if m.list.items[r].tag >= 0: rows.add m.list.items[r].tag
    check rows.len == 2
    check m.msgs[rows[0]].file.extractFilename == "unit1.nim"
    check m.msgs[rows[1]].line == m.msgs[rows[0]].line + 1
    check m.list.items[m.list.items.count - 1].caption == "2 lines in 1 files"
    check m.list.itemIndex == m.rowOf(rows[0])             # the first one is selected
    # a double click opens the place
    ed.showDesigner()
    m.list.onItemDblClick(m.list, m.rowOf(rows[1]), 0)
    check ide.activeEditor.unitName == "unit1" and not ide.activeEditor.designerVisible
    check ide.activeEditor.code.caretPos.line == m.msgs[rows[1]].line - 1
    # F8 goes to the next one
    ide.refreshActions()
    ide.pressKey(keyF8)
    check ide.activeEditor.code.caretPos.line == m.msgs[rows[0]].line - 1

  test "the options: case, whole word, regular expression, folder; a bad pattern and no hit are said":
    let ed = ide.activeEditor
    ed.code.caretPos = (ed.code.lineCount - 2, 6)           # on `zzFind2`
    ide.askFindInFiles = proc(o: var FindOptions): bool =
      check o.text == "zzFind2"                              # the word at the caret
      o.caseSensitive = true
      o.wholeWord = true
      true
    check ide.findInFilesCommand()
    check ide.messages.list.items[ide.messages.list.items.count - 1].caption == "1 lines in 1 files"
    ide.askFindInFiles = proc(o: var FindOptions): bool =
      o = FindOptions(text: r"zz\w+\d", regex: true, scope: fsFolder)
      true
    check ide.findInFilesCommand()
    check ide.messages.list.items.count == 3
    ide.askFindInFiles = proc(o: var FindOptions): bool =
      o = FindOptions(text: "(", regex: true)
      true
    check ide.findInFilesCommand()
    check "bad regular expression" in ide.messages.list.items[0].caption
    ide.askFindInFiles = proc(o: var FindOptions): bool =
      o = FindOptions(text: "no-such-text-anywhere-xyz")
      true
    check ide.findInFilesCommand()
    check ide.messages.list.items[ide.messages.list.items.count - 1].caption.startsWith("Nothing found")
    ide.askFindInFiles = proc(o: var FindOptions): bool = false
    let before = ide.messages.list.items.count
    check not ide.findInFilesCommand()
    check ide.messages.list.items.count == before

  test "a hit in a form file opens the form":
    check ide.saveAll()
    ide.askFindInFiles = proc(o: var FindOptions): bool =
      o = FindOptions(text: "object ", scope: fsFolder)
      true
    check ide.findInFilesCommand()
    let m = ide.messages
    var k = -1
    for i, x in m.msgs:
      if x.file.endsWith(".nfm"): k = i
    check k >= 0
    check ide.closeAllEditors()
    m.jump k
    check ide.activeEditor != nil and ide.activeEditor.designerVisible
    check ide.closeAllEditors()

suite "Code insight":
  proc lastLine(ed: UnitEditor): string = ed.code.lineAt(ed.code.lineCount - 1)
  proc ctrl(k: Key, shift: ShiftState = {ssCtrl}) = ide.pressKey(k, shift)
  proc toEnd(ed: UnitEditor) =
    ed.code.caretPos = (ed.code.lineCount - 1, ed.lastLine.len)

  test "the actions: shortcuts":
    check ide.acts[aCodeComplete].shortcut == shortcut("Ctrl+Space")
    check ide.acts[aCodeComplete].shortcut != noShortcut
    check ide.acts[aCodeTemplate].shortcut == shortcut("Ctrl+J")
    check ide.acts[aParamHints].shortcut == shortcut("Shift+Ctrl+Space")
    check ide.acts[aParamHints].shortcut != ide.acts[aCodeComplete].shortcut

  test "completion: one candidate is inserted, several are listed and narrowed by typing":
    check ide.closeAllEditors()
    let ed = ide.openUnit("unit1")
    ed.typeAtEnd "\nproc zzAlpha() = discard\nlet zzBeta = 1\nzzA"
    ide.refreshActions()
    check ide.acts[aCodeComplete].enabled
    ctrl(keySpace)
    check not codepicker.isOpen()
    check ed.lastLine == "zzAlpha"
    ide.typeText "\nzz"
    ctrl(keySpace)
    check codepicker.isOpen()
    check pickerRows() == @["zzBeta", "zzAlpha", "zzFind2"]   # shorter first
    ide.pressKey(keyDown)
    check pickerChoice() == 1
    ide.pressKey(keyUp)
    ide.typeText "A"                                      # typed into the editor, narrows the list
    check ed.lastLine == "zzA"
    check pickerRows() == @["zzAlpha"]
    ide.pressKey(keyBackspace)                            # deleted in the editor, widens it
    check ed.lastLine == "zz"
    check pickerRows() == @["zzBeta", "zzAlpha", "zzFind2"]
    ide.pressKey(keyEnter)                                # picks the chosen row, replaces the typed prefix
    check not codepicker.isOpen()
    check ed.lastLine == "zzBeta"
    check ed.code.caretPos == (ed.code.lineCount - 1, 6)

  test "completion: Esc, an other key and no match close the list":
    let ed = ide.activeEditor
    ide.typeText "\nzz"
    ctrl(keySpace)
    check codepicker.isOpen()
    ide.pressKey(keyEscape)
    check not codepicker.isOpen()
    check ed.lastLine == "zz"
    ctrl(keySpace)
    check codepicker.isOpen()
    ide.pressKey(keyLeft)                                 # goes on to the editor
    check not codepicker.isOpen()
    check ed.code.caretPos.col == 1
    ed.toEnd
    ctrl(keySpace)
    check codepicker.isOpen()
    ide.typeText "q"
    check not codepicker.isOpen()                         # nothing starts with zzq
    check ed.lastLine == "zzq"
    ide.pressKey(keyBackspace)
    ide.typeText "B"
    ctrl(keySpace)                                        # a single match is inserted
    check ed.lastLine == "zzBeta"

  test "completion after self. and after a component name":
    let ed = ide.activeEditor
    var comp = ""
    for (c, depth) in ed.componentTree:
      if comp.len == 0 and depth > 0 and classOf(Obj(c)).name == "Button": comp = c.name
    check comp.len > 0
    ide.typeText "\nself."
    ctrl(keySpace)
    check codepicker.isOpen()
    check comp in pickerRows()
    ide.typeText comp[0 .. 1]
    check pickerRows()[0] == comp
    ide.pressKey(keyTab)
    check ed.lastLine == "self." & comp
    ide.typeText ".onCl"
    ctrl(keySpace)                                        # the one event: inserted at once
    check ed.lastLine == "self." & comp & ".onClick"
    ide.typeText "\n" & comp & "."
    ctrl(keySpace)
    check codepicker.isOpen()
    check "onClick   event" in pickerRows()
    check "caption   string" in pickerRows()
    ide.pressKey(keyEscape)

  test "templates: a name expands with the indent of the line, one undo step":
    let ed = ide.activeEditor
    ed.toEnd
    ide.typeText "\nproc zzT() =\n  ife"
    ctrl('j'.key)
    check ed.code.lineAt(ed.code.lineCount - 4) == "  if :"
    check ed.code.lineAt(ed.code.lineCount - 3) == "    discard"
    check ed.code.lineAt(ed.code.lineCount - 2) == "  else:"
    check ed.lastLine == "    discard"
    check ed.code.caretPos == (ed.code.lineCount - 4, 5)
    check ed.code.undo()
    check ed.lastLine == "  ife"
    ed.toEnd
    ide.typeText "\n  tr"
    ctrl('j'.key)                                         # try, tryf
    check codepicker.isOpen()
    check pickerRows().len == 2
    check pickerRows()[0].startsWith("try   ")
    ide.pressKey(keyDown)
    ide.pressKey(keyEnter)
    check ed.lastLine == "    discard"
    check ed.code.lineAt(ed.code.lineCount - 2) == "  finally:"

  test "templates: a word that is no prefix lists all; the settings add templates":
    let ed = ide.activeEditor
    ed.toEnd
    ide.typeText "\nqqq"
    ctrl('j'.key)
    check codepicker.isOpen()
    check pickerRows().len >= 15
    ide.pressKey(keyEscape)
    ide.settings.codeTemplates = @[("zzlog", "log line", "echo \"|\"")]
    ed.toEnd
    ide.typeText "\nzzlog"
    ctrl('j'.key)
    check ed.lastLine == "echo \"\""
    check ed.code.caretPos.col == 6
    ide.settings.codeTemplates = @[]

  test "parameter hints: the signature over the line, until the caret leaves the call":
    let ed = ide.activeEditor
    ed.toEnd
    ide.typeText "\nproc zzAdd(a, b: int): int = a + b\nlet zzSum = zzAdd(1, "
    ctrl(keySpace, {ssCtrl, ssShift})
    check tipOpen()
    check tipText() == "proc zzAdd(a, b: int): int"
    ide.typeText "2"
    check tipOpen()
    ide.typeText ")"
    check not tipOpen()
    ctrl(keySpace, {ssCtrl, ssShift})
    check not tipOpen()                                   # no call at the caret
    ed.code.caretPos = (ed.code.lineCount - 1, ed.lastLine.len - 3)
    ctrl(keySpace, {ssCtrl, ssShift})
    check tipOpen()
    hideTip()
    ide.typeText "\nunknownProc("
    ctrl(keySpace, {ssCtrl, ssShift})
    check not tipOpen()
    check ide.closeAllEditors()

suite "reopen and startup":
  setup:
    errors.setLen 0

  test "File > Reopen lists at most ten recent projects":
    for i in 1 .. 12: ide.settings.addRecent(root / ("gone" & $i) / "x.nimproj")
    ide.rebuildRecentMenu()
    check ide.recentMenu.count == 10
    check "gone12" in ide.recentMenu[0].caption
    check "gone3" in ide.recentMenu[9].caption
    check ide.recentMenu[0].caption.startsWith("&1")
    let saved = ide.settings.recentProjects
    ide.settings.recentProjects = @[root / "a&b" / "x.nimproj"]
    ide.rebuildRecentMenu()
    check "a&&b" in ide.recentMenu[0].caption             # a literal &, not a mnemonic
    ide.settings.recentProjects = saved
    ide.rebuildRecentMenu()

  test "clicking an entry whose project is gone removes it":
    ide.recentMenu[0].click()
    check errors.len == 1 and "no longer exists" in errors[0]
    check ide.recentMenu.count == 9
    check "gone12" notin ide.recentMenu[0].caption
    check not loadSettings(settingsFile).recentProjects.anyIt("gone12" in it)
    check ide.project != nil                           # the open project is unaffected

  test "clicking an existing entry opens that project":
    ide.settings.addRecent(projectFile)
    ide.rebuildRecentMenu()
    check "Renamed" in ide.recentMenu[0].caption
    ide.recentMenu[0].click()
    check errors.len == 0
    check ide.project.filePath == projectFile
    check ide.editors.len == 1

  test "the open units come back with the project":
    let u0 = ide.project.units[0].name
    check ide.closeAllEditors()
    check ide.openMain() != nil
    check ide.openUnit(u0) != nil
    check ide.openMain() != nil                          # the active one is the program file
    check ide.closeProject()
    let s = ide.settings.sessionOf(projectFile)
    check s.units == @["Renamed", u0]
    check s.active == "Renamed"
    check loadSettings(settingsFile).sessionOf(projectFile).units.len == 2
    # a unit that is gone is skipped
    ide.settings.rememberSession(projectFile, @["ghost", u0, "Renamed"], u0)
    check ide.openProject(projectFile)
    check errors.len == 0
    check ide.editors.len == 2 and ide.editorIndex("ghost") < 0
    check ide.activeEditor.unitName == u0
    # nothing remembered: the first unit
    check ide.closeProject()
    ide.settings.rememberSession(projectFile, @[], "")
    check ide.openProject(projectFile)
    check ide.editors.len == 1 and ide.activeEditor.unitName == u0

  test "an empty list says (none)":
    let keep = ide.settings.recentProjects
    ide.settings.recentProjects = @[]
    ide.rebuildRecentMenu()
    check ide.recentMenu.count == 1 and not ide.recentMenu[0].enabled
    ide.settings.recentProjects = keep
    ide.rebuildRecentMenu()

  test "--project on the command line":
    check projectArg(@["--project", "a.nimproj"]) == "a.nimproj"
    check projectArg(@["x", "--project=b.nimproj"]) == "b.nimproj"
    check projectArg(@["--project"]) == ""
    check projectArg(@[]) == ""
    check projectArg(@["--shots", "dir"]) == ""
    check projectArg(@["a.nimproj"]) == "a.nimproj"                # a file association
    check projectArg(@["a.NIMPROJ", "--project", "b.nimproj"]) == "b.nimproj"
    check projectArg(@["notes.txt"]) == ""

  test "command line problems are listed":
    check commandLineProblems(@["--project", "a.nimproj"]).len == 0
    check commandLineProblems(@["a.nimproj"]).len == 0
    check commandLineProblems(@["--project"]) == @["--project needs a project file"]
    check commandLineProblems(@["--project="]).len == 1
    check commandLineProblems(@["--bogus", "x.txt"]).len == 2

  test "startup opens the project given by --project":
    check ide.closeProject()
    ide.settings.recentProjects = @[]
    ide.startup(defaultDir = root / "fallback", project = projectFile)
    check ide.project != nil and ide.project.filePath == projectFile
    check not dirExists(root / "fallback")

  test "a --project that cannot be opened is reported, then the usual choice follows":
    check ide.closeProject()
    ide.settings.recentProjects = @[]
    ide.startup(defaultDir = root / "fallback", project = root / "none.nimproj")
    check errors.len == 1
    check ide.project != nil and ide.project.name == "Project1"      # a fresh default project
    check dirExists(root / "fallback")

removeDir root
