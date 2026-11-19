## Quick fixes of the Messages window, Find unit and the import options.
##
## The first suites are pure (message texts, edits of the source). Then a real
## project is built by the IDE: a missing import (`newProgressBar`) and a
## component name in the wrong case (`self.edit1`) are fixed from Messages, the
## option "Add missing nimvcl imports automatically" fixes an import by itself,
## Find unit adds an import for the identifier at the caret, and the option
## "Import all of nimvcl" rewrites the units and still builds.
import std/[unittest, os, strutils, json, sequtils]
import nimvcl
import ide/[mainform, session, project, builder, uniteditor, messagespanel, messages,
            actions, quickfix, unitimports, symbols, symbolindex]

if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
putEnv("SDL_RENDER_DRIVER", "software")

const unitText = """## unit1
{.push warning[UnusedImport]: off.}
import nimvcl/prelude
import nimvcl/dsl/formload
# nimrad: imports begin
import nimvcl/controls/edit
# nimrad: imports end
{.pop.}

loadForm Form1, "unit1.nfm"
"""

func err(text: string, line = 5, col = 3): Message =
  Message(kind: MessageKind.mkError, file: "/p/unit1.nim", line: line, col: col, text: text)

suite "fixesFor":
  test "an unknown nimvcl identifier offers its module":
    let f = fixesFor(err("undeclared identifier: 'newProgressBar'"), [])
    check f.len == 1 and f[0].kind == fkAddImport
    check f[0].modules == @["nimvcl/controls/progressbar"]
    check f[0].title == "Add import nimvcl/controls/progressbar"
    check fixesFor(err("undeclared identifier: 'nothingLikeIt'"), []).len == 0

  test "several modules give a chooser entry":
    var dup = ""
    for (m, names) in symbolIndexData:
      for n in names.split(' '):
        if modulesFor(n).len > 1: dup = n
    check dup.len > 0
    let f = fixesFor(err("undeclared identifier: '" & dup & "'"), [])
    check f.len == 1 and f[0].modules.len > 1

  test "a component in the wrong case: field, routine and identifier forms":
    for text in ["undeclared field: 'edit1' for type unit1.Form1 [type declared in x.nim(3, 2)]",
                 "attempting to call undeclared routine: 'edit1'",
                 "undeclared identifier: 'edit1'"]:
      let f = fixesFor(err(text), ["Form1", "Edit1", "Button1"])
      check f.len == 1 and f[0].kind == fkRename and f[0].replacement == "Edit1"
      check f[0].title == "Did you mean Edit1?"
    check fixesFor(err("undeclared field: 'edit2'"), ["Edit1"]).len == 0
    check fixesFor(err("undeclared field: 'EDIT1'"), ["Edit1"]).len == 0   # more than the first letter
    check fixesFor(err("undeclared field: 'Edit1'"), ["Edit1"]).len == 0   # it is there

  test "warnings and other errors have none":
    check fixesFor(Message(kind: MessageKind.mkWarning, file: "a.nim", line: 1, col: 1,
                           text: "undeclared identifier: 'newButton'"), []).len == 0
    check fixesFor(err("type mismatch"), []).len == 0

suite "edits":
  test "the import goes above the IDE block, after the user imports":
    let a = addUserImport(unitText, "nimvcl/controls/progressbar")
    check a == unitText.replace("# nimrad: imports begin",
      "import nimvcl/controls/progressbar\n# nimrad: imports begin")
    let b = addUserImport(a, "nimvcl/controls/trackbar")
    let lines = b.splitLines
    check lines.find("import nimvcl/controls/progressbar") < lines.find("import nimvcl/controls/trackbar")
    check lines.find("import nimvcl/controls/trackbar") < lines.find("# nimrad: imports begin")
    check addUserImport(b, "nimvcl/controls/trackbar") == b             # twice is once
    # the managed block is not touched by a sync afterwards
    check syncFromNfm(b, "object Form1: Form\n  object Edit1: Edit\n  end\nend\n") == b

  test "already imported: by its own line, in a group, or through nimvcl":
    check addUserImport(unitText, "nimvcl/controls/edit") == unitText
    let g = unitText.replace("import nimvcl/dsl/formload", "import nimvcl/dsl/formload, std/os\nimport nimvcl/controls/[memo, tree]")
    check addUserImport(g, "nimvcl/controls/memo") == g
    check addUserImport(unitText.replace("import nimvcl/prelude", "import nimvcl"), "nimvcl/controls/memo") ==
      unitText.replace("import nimvcl/prelude", "import nimvcl")

  test "a file without the block: after its last import; the program file too":
    let plain = "## x\nimport std/os\nimport nimvcl/core/form,\n  nimvcl/core/control\n\nproc a() = discard\n"
    check addUserImport(plain, "nimvcl/controls/edit") ==
      "## x\nimport std/os\nimport nimvcl/core/form,\n  nimvcl/core/control\nimport nimvcl/controls/edit\n\nproc a() = discard\n"
    check addUserImport("## doc\n\nproc a() = discard\n", "nimvcl/controls/edit") ==
      "## doc\n\nimport nimvcl/controls/edit\nproc a() = discard\n"
    let prog = "import std/os\nimport nimvcl/prelude\n# nimrad: imports begin\nimport unit1\n# nimrad: imports end\n"
    check addUserImport(prog, "nimvcl/controls/edit") ==
      "import std/os\nimport nimvcl/prelude\nimport nimvcl/controls/edit\n# nimrad: imports begin\nimport unit1\n# nimrad: imports end\n"

  test "line endings are kept":
    let crlf = unitText.replace("\n", "\r\n")
    check addUserImport(crlf, "nimvcl/controls/memo").count("\r\n") == crlf.count("\r\n") + 1

  test "rename picks the occurrence nearest to the column":
    let src = "a\n  self.edit1.text = edit1.text & \"edit1\"\n"
    check renameAt(src, 2, 8, "edit1", "Edit1") == "a\n  self.Edit1.text = edit1.text & \"edit1\"\n"
    check renameAt(src, 2, 22, "edit1", "Edit1") == "a\n  self.edit1.text = Edit1.text & \"edit1\"\n"
    check renameAt(src, 9, 1, "edit1", "Edit1") == src
    check renameAt("let myedit1 = 1\n", 1, 1, "edit1", "Edit1") == "let myedit1 = 1\n"   # whole words only

  test "component names of a form, ancestors included":
    check componentNames("object Form1: Form\n  object Edit1: Edit\n  end\n  object P: Panel\n    object B: Button\n    end\n  end\nend\n") ==
      @["Form1", "Edit1", "P", "B"]

suite "import all (text)":
  test "on and off are exact opposites; the block follows the form":
    let nfm = "object Form1: Form\n  object Edit1: Edit\n  end\nend\n"
    let on = setImportAll(unitText, true)
    check "import nimvcl   # nimrad: all" in on
    check "import nimvcl/prelude" notin on
    check "import nimvcl/controls/edit" notin on
    check syncFromNfm(on, nfm, "", true) == on            # stays empty while it is on
    let off = syncFromNfm(setImportAll(on, false), nfm)
    check off == unitText
    # the user's own `import nimvcl` is not the IDE's and stays
    let mine = unitText.replace("import nimvcl/prelude", "import nimvcl")
    check setImportAll(mine, false) == mine

  test "the project stores the options only when on":
    let j = Project(filePath: "/tmp/x.nimproj", name: "x", mainFile: "x.nim", outputDir: "build").toJson
    check not j.hasKey("autoImports") and not j.hasKey("importAll")
    let k = Project(filePath: "/tmp/x.nimproj", name: "x", mainFile: "x.nim", outputDir: "build",
                    autoImports: true, importAll: true).toJson
    check k["autoImports"].getBool and k["importAll"].getBool

# --------------------------------------------------------------- the IDE

let root = getTempDir() / ("nimrad-quickfix-" & $getCurrentProcessId())
removeDir root
createDir root

Application.init()
let ide = newIdeForm(settingsFile = root / "settings.json")
ide.showWindow(1360, 860)

var errors: seq[string]
var picked: seq[string]
var pickIndex = 0
ide.showError = proc(text: string) = errors.add text
ide.askSave = proc(unitName: string): SaveChoice = scSave
ide.pickItem = proc(title: string, items: seq[string], selected: int): int =
  picked = items
  pickIndex

proc unitSrc(): string = readFile(ide.project.dir / "unit1.nim")
proc mainSrc(): string = readFile(ide.project.mainPath)

proc build(): bool =
  check ide.compile()
  check ide.waitIdle(240)
  ide.settle
  ide.lastBuildOk

proc noteTexts(): seq[string] =
  for i in 0 ..< ide.messages.list.items.count:
    if ide.messages.list.items[i].tag < 0: result.add ide.messages.list.items[i].caption

proc fixOf(substr: string): int =
  ## Index of the first message whose text has `substr`.
  for i, m in ide.messages.msgs:
    if substr in m.text and m.kind == MessageKind.mkError: return i
  -1

suite "quick fixes in a project":
  test "setup: a form with Edit1 and a handler that needs two fixes":
    check ide.newApplication(root / "app", "app")
    check ide.closeAllEditors()
    let d = ide.project.dir
    writeFile(d / "unit1.nfm", "object Form1: Form\n  caption = 'Form1'\n  width = 320\n  height = 200\n" &
              "  object Edit1: Edit\n    left = 10\n    top = 10\n    onChange = Edit1Change\n  end\nend\n")
    writeFile(d / "unit1.nim", unitText &
      "\nproc Edit1Change(self: Form1, sender: Control) =\n" &
      "  discard newProgressBar(self)\n" &
      "  self.edit1.text = \"x\"\n")
    ide.project.nimFlags = @["--errorMax:100"]
    check ide.openUnit("unit1") != nil
    check errors.len == 0

  test "the build fails with both errors and Messages offers the fixes":
    check not build()
    let a = fixOf("newProgressBar")
    let b = fixOf("edit1")
    check a >= 0 and b >= 0
    check ide.messages.fixesOf(a)[0].kind == fkAddImport
    check ide.messages.fixesOf(a)[0].modules == @["nimvcl/controls/progressbar"]
    check ide.messages.fixesOf(b)[0].kind == fkRename
    check ide.messages.fixesOf(b)[0].replacement == "Edit1"
    # the rows say so
    check ide.messages.list.items[ide.messages.rowOf(a)].caption.contains("[Ctrl+.  Add import nimvcl/controls/progressbar]")
    check ide.messages.list.items[ide.messages.rowOf(b)].caption.contains("Did you mean Edit1?")
    check ide.acts[aQuickFix].shortcut == shortcut("Ctrl+.")
    check ide.acts[aQuickFix].enabled

  test "Did you mean Edit1? replaces the occurrence (no rebuild)":
    let b = fixOf("edit1")
    let builds = ide.buildCount
    check ide.applyQuickFix(b)
    ide.settle
    check not ide.busy and ide.buildCount == builds
    ide.saveAll()
    check "self.Edit1.text = \"x\"" in unitSrc()
    check "self.edit1" notin unitSrc()

  test "Add import: above the IDE block, then the failed build runs again":
    let a = fixOf("newProgressBar")
    check ide.acts[aQuickFix].enabled
    ide.messages.select a                    # Ctrl+. works on the selected message
    ide.acts[aQuickFix].execute()
    check ide.busy                           # the compile that failed runs again
    check ide.waitIdle(240)
    ide.settle
    check ide.lastBuildOk
    let lines = unitSrc().splitLines
    let at = lines.find("import nimvcl/controls/progressbar")
    check at > 0
    check at < lines.find("# nimrad: imports begin")
    check lines.find("import nimvcl/controls/edit") > lines.find("# nimrad: imports begin")
    check lines.count("import nimvcl/controls/progressbar") == 1

  test "a name with several modules asks which one":
    var dup = ""
    for (m, names) in symbolIndexData:
      for n in names.split(' '):
        if modulesFor(n).len > 1: dup = n
    let mods = modulesFor(dup)
    ide.messages.clear()
    ide.messages.feed(ide.project.dir / "unit1.nim" & "(9, 3) Error: undeclared identifier: '" & dup & "'")
    ide.messages.finish()
    check ide.messages.fixesOf(0).len == 1
    pickIndex = 1
    check ide.applyQuickFix(0)
    check picked == mods
    check ide.waitIdle(240)                  # the rebuild it started (it saves everything)
    check ("import " & mods[1]) in unitSrc().splitLines
    pickIndex = 0

  test "the automatic option adds a single-candidate import itself and builds once more":
    check ide.closeAllEditors()
    ide.project.nimFlags = @["--errorMax:100"]
    let src = unitSrc().splitLines.filterIt(it != "import nimvcl/controls/progressbar").join("\n")
    writeFile(ide.project.dir / "unit1.nim", src)
    check "newProgressBar" in src and "import nimvcl/controls/progressbar" notin src
    # off by default: one failing build, nothing added
    let before = ide.buildCount
    check not build()
    check ide.buildCount == before + 1
    check "import nimvcl/controls/progressbar" notin unitSrc()
    ide.applyOptions ProjectOptions(outputDir: "build", flags: "--errorMax:100", autoImports: true)
    check ide.project.autoImports and loadProject(ide.project.filePath).autoImports
    check ide.currentOptions.autoImports
    let b2 = ide.buildCount
    check build()                            # failed, fixed itself, built again
    check ide.buildCount == b2 + 2
    check "import nimvcl/controls/progressbar" in unitSrc()
    check noteTexts().anyIt("Added import nimvcl/controls/progressbar to unit1" in it)
    ide.applyOptions ProjectOptions(outputDir: "build", flags: "--errorMax:100")
    check not ide.project.autoImports

suite "find unit":
  test "the import of the identifier at the caret is offered and added":
    let ed = ide.openUnit("unit1")
    ed.showCode()
    ide.activeControl = ed.code
    ed.code.caretPos = (ed.code.lineCount - 1, 0)
    ide.typeText "\nlet tb = newTrackBar\n"
    var row = -1
    for i in 0 ..< ed.code.lineCount:
      if ed.code.lineAt(i).startsWith("let tb"): row = i
    check row >= 0
    ed.code.caretPos = (row, 12)             # inside `newTrackBar`
    check ide.acts[aFindUnit].shortcut == shortcut("Shift+Ctrl+A")
    ide.acts[aFindUnit].execute()
    check picked == @["nimvcl/controls/trackbar"]
    ide.saveAll()
    let lines = unitSrc().splitLines
    check lines.find("import nimvcl/controls/trackbar") in 1 ..< lines.find("# nimrad: imports begin")
    # again: nothing to add
    ide.acts[aFindUnit].execute()
    check unitSrc().count("import nimvcl/controls/trackbar") == 1
    check ide.status.panels[4].text.contains("already imported")

  test "an identifier nimvcl does not declare, and no identifier":
    let ed = ide.activeEditor
    ed.code.caretPos = (0, 1)
    ide.acts[aFindUnit].execute()
    check ide.status.panels[4].text.len > 0
    ed.code.caretPos = (ed.code.lineCount - 1, 0)
    ide.acts[aFindUnit].execute()
    check ide.status.panels[4].text.contains("identifier")

suite "import all":
  test "on: every unit and the program import nimvcl, the block is empty, it builds":
    check ide.closeAllEditors()
    ide.applyOptions ProjectOptions(outputDir: "build", flags: "--errorMax:100", importAll: true)
    check ide.project.importAll and loadProject(ide.project.filePath).importAll
    for src in [unitSrc(), mainSrc()]:
      check "import nimvcl   # nimrad: all" in src
      check "import nimvcl/prelude" notin src
    check "import nimvcl/controls/edit" notin unitSrc()        # the managed block is empty
    check "import nimvcl/controls/trackbar" in unitSrc()       # the user's import stays
    check build()
    let r = runCapture(exePath(ide.project), @["--smoke"], ide.project.dir)
    check r.exitCode == 0

  test "a new form follows the mode and saving does not refill the block":
    let u = ide.newForm()
    check u != nil
    check "import nimvcl   # nimrad: all" in readFile(ide.project.dir / "unit2.nim")
    let ed = ide.openUnit("unit1")
    ed.save()
    check "import nimvcl/controls/edit" notin unitSrc()

  test "off: the prelude and the controls of the form come back, and it builds":
    ide.saveAll()
    ide.applyOptions ProjectOptions(outputDir: "build", flags: "--errorMax:100", importAll: false)
    check not ide.project.importAll
    for src in [unitSrc(), mainSrc()]:
      check "import nimvcl/prelude" in src
      check "# nimrad: all" notin src
    check "import nimvcl/controls/edit" in unitSrc()
    check build()
    let r = runCapture(exePath(ide.project), @["--smoke"], ide.project.dir)
    check r.exitCode == 0
    check errors.len == 0
    removeDir root
