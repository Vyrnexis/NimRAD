## The control imports of a form unit: the class table, the marker block edits
## and (the real check) that a unit with every class of the registry, every
## enum property and every event handler compiles with only those imports.

import std/[unittest, strutils, os, osproc, sequtils]
import nimvcl/dsl/[props, props_std, nfmsyntax]
import ide/[unitimports, codegen, project]

const unitText = """## unit1
{.push warning[UnusedImport]: off.}
import nimvcl/prelude
import nimvcl/dsl/formload
# nimvcl-ide: imports begin
# nimvcl-ide: imports end
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
    if l.strip == "# nimvcl-ide: imports end": inside = false
    if inside: result.add l
    if l.strip == "# nimvcl-ide: imports begin": inside = true

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
    s = s.replace("# nimvcl-ide: imports begin\n",
      "# nimvcl-ide: imports begin\nimport nimvcl/controls/[memo, edit]   # mine\n")
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
    let dir = getTempDir() / ("nimvclide-imports-" & $getCurrentProcessId())
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
    putEnv("SDL_VIDEO_DRIVER", "offscreen")
    putEnv("SDL_RENDER_DRIVER", "software")
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      echo output
      echo unit
    check code == 0
    if code == 0: removeDir dir

suite "prelude and older units":
  test "a unit that still has the old core imports compiles and runs":
    let dir = getTempDir() / ("nimvclide-oldimports-" & $getCurrentProcessId())
    removeDir dir
    discard newApplicationProject(dir, "app")
    var unit = readFile(dir / "unit1.nim")
    check "import nimvcl/prelude\n" in unit
    unit = unit.replace("import nimvcl/prelude\n",
      "import nimvcl/core/[control, form, application]\nimport nimvcl/controls/common\n")
    writeFile(dir / "unit1.nim", unit)
    putEnv("SDL_VIDEO_DRIVER", "offscreen")
    putEnv("SDL_RENDER_DRIVER", "software")
    let (output, code) = execCmdEx("nim c --hints:off --warnings:off --path:" &
      quoteShell(detectNimvclPath()) & " --nimcache:" & quoteShell(dir / "cache") &
      " --outdir:" & quoteShell(dir) & " -r " & quoteShell(dir / "app.nim") & " --smoke")
    if code != 0: echo output
    check code == 0
    if code == 0: removeDir dir
