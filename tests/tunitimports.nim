## The control imports of a form unit: the class table, the marker block edits
## and (the real check) that a unit with every class of the registry, every
## enum property and every event handler compiles with only those imports.

import std/[unittest, strutils, os, osproc, sequtils, times]
import nimvcl/dsl/[props, props_std, nfmsyntax]
import ide/[unitimports, codegen, project, nimsource]

const unitText = """## unit1
{.push warning[UnusedImport]: off.}
import nimvcl/prelude
import nimvcl/dsl/formload
# nimrad: imports begin
# nimrad: imports end
{.pop.}

loadForm Form1, "unit1.nfm"
"""

func formWith(classes: varargs[string]): string =
  result = "object Form1: Form\n"
  for i, c in classes:
    result.add "  object obj" & $i & ": " & c & "\n  end\n"
  result.add "end\n"

func blockLines(src: string): seq[string] =
  var inside = false
  for l in src.splitLines:
    if l.strip == "# nimrad: imports end": inside = false
    if inside: result.add l
    if l.strip == "# nimrad: imports begin": inside = true

suite "class table":
  test "every creatable class of the registry has a module that exists":
    let src = absolutePath(detectNimvclPath())
    check src.len > 0
    for ci in allClasses():
      if ci.abstract or ci.name in ["Form", "Component", "Control"]: continue
      let m = moduleOf(ci.name)
      check m.len > 0
      if m.len > 0: check fileExists(src / m & ".nim")
    check moduleOf("Form") == "" and moduleOf("MyOwnControl") == ""

suite "importsFor":
  test "sorted, one entry per module":
    check importsFor(formWith("Edit", "Button", "Label", "Button")) ==
      @["nimvcl/controls/button", "nimvcl/controls/edit", "nimvcl/controls/label"]
    check importsFor(formWith("Panel", "GroupBox")) == @["nimvcl/controls/panel"]

  test "nested classes and unknown ones":
    let t = "object Form1: Form\n  object p: Panel\n    object b: Button\n    end\n    object c: Custom\n    end\n  end\nend\n"
    check importsFor(t) == @["nimvcl/controls/button", "nimvcl/controls/panel"]
    check importsFor("not a form file") == newSeq[string]()

  test "a Frame root needs its module":
    check importsFor("object Frame1: Frame\nend\n") == @["nimvcl/controls/frame"]

suite "syncImports":
  test "adding a ListBox adds its import; deleting the last one removes it":
    let a = syncFromNfm(unitText, formWith("Button"))
    check blockLines(a) == @["import nimvcl/controls/button"]
    let b = syncFromNfm(a, formWith("Button", "ListBox"))
    check blockLines(b) == @["import nimvcl/controls/button", "import nimvcl/controls/listbox"]
    let c = syncFromNfm(b, formWith("Button", "ListBox", "ListBox"))
    check c == b
    let d = syncFromNfm(c, formWith("Button"))        # the last ListBox is gone
    check d == a
    check syncFromNfm(d, formWith()) == unitText

  test "user imports are untouched":
    var s = unitText.replace("import nimvcl/dsl/formload\n",
      "import nimvcl/dsl/formload\nimport std/[os, strutils]\nimport nimvcl/controls/button\n")
    s = s.replace("# nimrad: imports begin\n",
      "# nimrad: imports begin\nimport nimvcl/controls/[memo, edit]   # mine\n")
    s &= "\nimport nimvcl/controls/combobox\n"
    let t = syncFromNfm(s, formWith("Button", "Edit", "ComboBox", "ListBox"))
    check "import std/[os, strutils]" in t
    check "import nimvcl/controls/[memo, edit]   # mine" in t
    check t.count("import nimvcl/controls/button") == 1        # already imported outside
    check t.count("import nimvcl/controls/combobox") == 1
    check "import nimvcl/controls/listbox" in blockLines(t)
    let u = syncFromNfm(t, formWith())
    check "import std/[os, strutils]" in u
    check "import nimvcl/controls/[memo, edit]   # mine" in u
    check "import nimvcl/controls/button" in u                 # the user's own line stays
    check "import nimvcl/controls/listbox" notin u
    check "import nimvcl/controls/combobox" in u

  test "a file without the block is never changed":
    let old = "import nimvcl\n\nloadForm Form1, \"unit1.nfm\"\n"
    check syncFromNfm(old, formWith("Button", "Edit")) == old

  test "crlf files keep their line ending":
    let s = unitText.replace("\n", "\r\n")
    let t = syncFromNfm(s, formWith("Button"))
    check "import nimvcl/controls/button\r\n" in t
    check t.count("\r\n") == t.count("\n")
    check syncFromNfm(t, formWith()) == s

  test "a form file that does not parse removes the managed imports only":
    let a = syncFromNfm(unitText, formWith("Button"))
    check syncFromNfm(a, "broken") == unitText

# ------------------------------------------------ compile with every class

const nestedIn = {"MenuItem": "MainMenu", "StatusPanel": "StatusBar",
                  "ListColumn": "ListView", "TabSheet": "PageControl",
                  "ToolButton": "ToolBar", "Action": "ActionList"}

proc nestedParent(cls: string): string =
  for (c, p) in nestedIn:
    if c == cls: return p

var handlers: seq[(string, string, string)]   # (handler, class, event)

proc addProps(n: NfmNode, ci: ClassInfo) =
  ## Every enum and set property at its last value, every event bound.
  for p in propsOf(ci):
    if p.name.contains('.'): continue
    case p.kind
    of pkEnum:
      if p.enumNames.len > 1:
        n.props.add NfmProp(name: p.name, value: NfmValue(kind: nvIdent, text: p.enumNames[^1]))
    of pkSet:
      if p.enumNames.len > 0:
        n.props.add NfmProp(name: p.name, value: NfmValue(kind: nvSet, items: @[p.enumNames[^1]]))
    of pkEvent:
      let h = "on_" & ci.name & "_" & p.name
      n.props.add NfmProp(name: p.name, value: NfmValue(kind: nvIdent, text: h))
      if h notin handlers.mapIt(it[0]): handlers.add (h, ci.name, p.name)
    else: discard

proc everyClassForm(): string =
  let root = NfmNode(name: "Form1", className: "Form")
  var count = 0
  proc node(ci: ClassInfo): NfmNode =
    inc count
    # plain objects (status panels, list columns) have no name
    result = NfmNode(name: (if ci.parent == nil: "" else: "obj" & $count), className: ci.name)
    addProps(result, ci)
  for ci in allClasses():
    if ci.abstract or ci.name in ["Form", "Frame"] or nestedParent(ci.name).len > 0: continue
    let n = node(ci)
    let kid = block:
      var k = ""
      for (c, p) in nestedIn:
        if p == ci.name: k = c
      k
    if kid.len > 0: n.children.add node(classByName(kid))
    root.children.add n
  addProps(root, classByName("Form"))
  writeNfm(root)

suite "generated unit compiles":
  test "every class, enum property and event handler of the registry":
    let dir = getTempDir() / ("nimrad-imports-" & $getCurrentProcessId())
    removeDir dir
    let proj = newApplicationProject(dir, "app")        # the units the IDE generates
    let nfm = everyClassForm()
    check handlers.len > 20
    var unit = readFile(dir / "unit1.nim")
    for (h, cls, ev) in handlers:
      unit = ensureHandlerFor(unit, "Form1", cls, ev, h).text
    unit = syncFromNfm(unit, nfm)
    writeFile(dir / "unit1.nfm", nfm)
    writeFile(dir / "unit1.nim", unit)
    check proj.mainFile == "app.nim"
    let cmd = "nim c --hints:off --warnings:off --path:" & quoteShell(detectNimvclPath()) &
              " --nimcache:" & quoteShell(dir / "cache") & " --outdir:" & quoteShell(dir) &
              " -r " & quoteShell(dir / "app.nim") & " --smoke"
    if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
    putEnv("SDL_RENDER_DRIVER", "software")
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      echo output
      echo unit
    check code == 0
    if code == 0: removeDir dir

suite "prelude and older units":
  test "a unit that still has the old core imports compiles and runs":
    let dir = getTempDir() / ("nimrad-oldimports-" & $getCurrentProcessId())
    removeDir dir
    discard newApplicationProject(dir, "app")
    var unit = readFile(dir / "unit1.nim")
    check "import nimvcl/prelude\n" in unit
    unit = unit.replace("import nimvcl/prelude\n",
      "import nimvcl/core/[control, form, application]\nimport nimvcl/controls/common\n")
    writeFile(dir / "unit1.nim", unit)
    if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
    putEnv("SDL_RENDER_DRIVER", "software")
    let (output, code) = execCmdEx("nim c --hints:off --warnings:off --path:" &
      quoteShell(detectNimvclPath()) & " --nimcache:" & quoteShell(dir / "cache") &
      " --outdir:" & quoteShell(dir) & " -r " & quoteShell(dir / "app.nim") & " --smoke")
    if code != 0: echo output
    check code == 0
    if code == 0: removeDir dir

suite "reading imports":
  test "groups, aliases, comments and lists that go on in the next line":
    let src = "import std/os  # import nimvcl/x\n" &
              "import nimvcl/controls/[button, edit as e], strutils\n" &
              "import a,\n  b/[c,\n    d]\n" &
              "const s = \"\"\"\nimport hidden\n\"\"\"\n"
    check importedModules(src) == @["std/os", "nimvcl/controls/button", "nimvcl/controls/edit",
                                    "strutils", "a", "b/c", "b/d"]
    check importsModule(src, "nimvcl/controls/edit")
    check not importsModule(src, "nimvcl/controls/label")

  test "a module imported in a group is not added a second time to the block":
    let src = "import nimvcl/controls/[button, edit]  # mine\n" &
              "# nimrad: imports begin\n# nimrad: imports end\n"
    check syncImports(src, @["nimvcl/controls/button"]) == src

  test "names that are keywords or have double underscores are refused":
    for bad in ["block", "type", "a__b", "a_", "1a", ""]: check not validName(bad)
    check validName("my_unit") and validName("Unit1")

suite "units written before the rename":
  test "old markers and the old import-all tag are still recognised":
    let src = "import nimvcl/prelude\n# nimvcl-ide: imports begin\n# nimvcl-ide: imports end\n"
    let s = syncImports(src, @["nimvcl/controls/button"])
    check s == "import nimvcl/prelude\n# nimvcl-ide: imports begin\nimport nimvcl/controls/button\n# nimvcl-ide: imports end\n"
    let all = "import nimvcl   # nimvcl-ide: all\n# nimvcl-ide: imports begin\n# nimvcl-ide: imports end\n"
    check setImportAll(all, false).startsWith("import nimvcl/prelude\n")
    check setImportAll(src, true).startsWith("import nimvcl   # nimrad: all\n")

suite "classes of the user's":
  const badgeUnit = """## badge
import nimvcl
type Badge* = ref object of Panel
  fLevel: int   # registerClass(Fake) in a comment
proc newBadge*(parent: Container = nil): Badge =
  new result
  result.initPanel(parent)
  if parent != nil: parent.insertControl result

registerClass(Badge, parent = Panel):
  category Data:
    level: int
registerClass(Gauge, parent = Control)
const s = "registerClass(InString)"
type
  Plain = object
    x: int
  Meter*[T] = ref object of Control
  Handle = ref int
"""

  test "the classes a unit declares or registers":
    check declaredClasses(badgeUnit) == @["Badge", "Gauge", "Meter"]
    check declaredClasses("") == newSeq[string]()
    check declaredClasses("type X = ref object of RootObj\n") == @["X"]
    check declaredClasses("let registerClassX = 1\nobject of\n") == newSeq[string]()

  test "importsFor names the module of a class of the user's":
    let user = @[("Badge", "badge"), ("Meter", "sub/meter")]
    let t = formWith("Button", "Badge", "Meter", "Unknown")
    check importsFor(t, "", user) == @["badge", "nimvcl/controls/button", "sub/meter"]
    check importsFor(t) == @["nimvcl/controls/button"]            # without the list: as before
    check moduleOf("Badge", user) == "badge" and moduleOf("Badge") == ""
    check moduleOf("Button", user) == "nimvcl/controls/button"

  test "syncFromNfm adds the unit's import, keeps it while an object uses the class, drops it after":
    let user = @[("Badge", "badge")]
    let a = syncFromNfm(unitText, formWith("Button", "Badge"), "", false, user)
    check blockLines(a) == @["import badge", "import nimvcl/controls/button"]
    let b = syncFromNfm(a, formWith("Badge", "Badge"), "", false, user)
    check blockLines(b) == @["import badge"]
    let c = syncFromNfm(b, formWith("Label"), "", false, user)
    check blockLines(c) == @["import nimvcl/controls/label"]
    check syncFromNfm(c, formWith("Label"), "", false, user) == c       # idempotent

  test "a line of the block that is not a project module is the user's":
    var src = unitText.replace("# nimrad: imports begin\n", "# nimrad: imports begin\nimport mystuff\n")
    let a = syncFromNfm(src, formWith("Badge"), "", false, @[("Badge", "badge")])
    check blockLines(a) == @["import mystuff", "import badge"]
    check blockLines(syncFromNfm(a, formWith("Label"), "", false, @[("Badge", "badge")])) ==
          @["import mystuff", "import nimvcl/controls/label"]

  test "a module imported elsewhere in the unit is not added again":
    let src = unitText.replace("import nimvcl/dsl/formload\n", "import nimvcl/dsl/formload\nimport badge\n")
    check syncFromNfm(src, formWith("Badge"), "", false, @[("Badge", "badge")]) == src

  test "with all of nimvcl imported only the user's modules are in the block":
    let a = syncFromNfm(unitText, formWith("Button", "Badge"), "", true, @[("Badge", "badge")])
    check blockLines(a) == @["import badge"]

suite "project classes":
  let dir = getTempDir() / ("nimrad-userclass-" & $getCurrentProcessId())
  removeDir dir
  var proj: Project

  test "units that provide classes, found by the project":
    proj = newApplicationProject(dir, "app")
    writeFile(dir / "badge.nim", "type Badge* = ref object of RootObj\n")
    createDir dir / "widgets"
    writeFile(dir / "widgets" / "meter.nim", "registerClass(Meter, parent = Control)\n")
    discard proj.addUnit("badge", "badge.nim")
    discard proj.addUnit("meter", "widgets/meter.nim")
    check proj.userClassImports("unit1") == @[("Badge", "badge"), ("Meter", "widgets/meter")]
    check proj.userClassImports("meter") == @[("Badge", "../badge")]   # not itself; paths from its folder
    check proj.userClassImports() == @[("Badge", "badge"), ("Meter", "widgets/meter")]

  test "the scan follows the file":
    sleep 20
    writeFile(dir / "badge.nim", "type Dial* = ref object of RootObj\n")
    setLastModificationTime(dir / "badge.nim", getLastModificationTime(dir / "badge.nim") + initDuration(seconds = 3))
    check proj.userClassImports("unit1")[0] == ("Dial", "badge")

  test "classImports of the project file win and survive saving":
    proj.classImports = @[("Dial", "mylib/dial"), ("Gauge", "mylib/gauge")]
    check proj.userClassImports("unit1")[0 .. 1] == @[("Dial", "mylib/dial"), ("Gauge", "mylib/gauge")]
    proj.save()
    let back = loadProject(proj.filePath)
    check back.classImports == proj.classImports
    check "classImports" in readFile(proj.filePath)
    proj.classImports = @[]
    proj.save()
    check "classImports" notin readFile(proj.filePath)

  test "a form that uses a class of the project gets the import (rewriteImports)":
    writeFile(dir / "badge.nim", "type Badge* = ref object of RootObj\n")
    var nfm = readFile(dir / "unit1.nfm")
    nfm = nfm.replace("end\n", "  object Badge1: Badge\n  end\nend\n")
    writeFile(dir / "unit1.nfm", nfm)
    check proj.rewriteImports().len == 1
    check "import badge\n" in readFile(dir / "unit1.nim")
    check proj.rewriteImports().len == 0

  removeDir dir
