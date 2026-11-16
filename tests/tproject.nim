import std/[unittest, os, osproc, strutils, json]
import ide/[project, builder]

let root = getTempDir() / ("nimvclide-proj-" & $getCurrentProcessId())
removeDir root
createDir root

proc smoke(p: Project): tuple[output: string, exitCode: int] =
  execCmdEx("SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software " &
            quoteShell(p.exePath) & " --smoke 2>&1")

proc build(p: Project): CompileResult =
  result = p.compileProjectSync()
  if not result.ok: echo result.lines.join("\n")

suite "project file":
  test "save and load round trip":
    let p = Project(filePath: root / "rt" / "rt.nimproj", name: "rt", mainFile: "rt.nim",
                    outputDir: "build", nimFlags: @["-d:release", "--opt:size"],
                    runArgs: @["--x", "a b"], nimvclPath: "../nimvcl/src")
    createDir root / "rt"
    discard p.addUnit("u1", root / "rt" / "sub" / "u1.nim", "sub/u1.nfm")
    discard p.addUnit("plain", "plain.nim")
    p.save()
    let q = loadProject(p.filePath)
    check q.name == "rt" and q.mainFile == "rt.nim" and q.outputDir == "build"
    check q.nimFlags == @["-d:release", "--opt:size"]
    check q.runArgs == @["--x", "a b"]
    check q.units.len == 2
    check q.units[0].nimPath == "sub/u1.nim"        # stored relative
    check q.nimPathOf(q.units[0]) == root / "rt" / "sub" / "u1.nim"
    check q.units[0].isForm and not q.units[1].isForm
    check q.nfmPathOf(q.units[1]) == ""

  test "defaults and tolerance":
    writeFile(root / "min.nimproj", """{"name": "m", "units": [1, {"name": "x"}], "nimFlags": "bad"}""")
    let p = loadProject(root / "min.nimproj")
    check p.outputDir == "build" and p.mainFile == "m.nim"
    check p.units.len == 0 and p.nimFlags.len == 0
    writeFile(root / "bad.nimproj", "not json")
    expect ProjectError: discard loadProject(root / "bad.nimproj")
    expect ProjectError: discard loadProject(root / "missing.nimproj")

  test "nimvcl path detection":
    check detectNimvclPath().endsWith("nimvcl/src") or detectNimvclPath() == ""
    let p = Project(filePath: root / "x.nimproj", nimvclPath: "../elsewhere/src")
    check p.nimvclSrc == root.parentDir / "elsewhere" / "src"

suite "new application":
  test "files are created from the templates":
    let p = newApplicationProject(root / "app", "hello")
    for f in ["hello.nimproj", "hello.nim", "unit1.nim", "unit1.nfm", "nim.cfg"]:
      check fileExists(root / "app" / f)
    check readFile(root / "app" / "unit1.nim").contains("loadForm Form1, \"unit1.nfm\"")
    check readFile(root / "app" / "unit1.nfm").contains("caption = 'Form1'")
    check readFile(root / "app" / "unit1.nfm").contains("width = 640")
    check readFile(root / "app" / "hello.nim").contains("import unit1")
    check readFile(root / "app" / "nim.cfg").contains("--path:")
    check "${" notin readFile(root / "app" / "hello.nim")
    check p.units.len == 1 and p.units[0].formType == "Form1"
    check loadProject(root / "app" / "hello.nimproj").units.len == 1

  test "bad names":
    expect ProjectError: discard newApplicationProject(root / "b", "1bad")
    expect ProjectError: discard newApplicationProject(root / "b", "has space")

  test "the new project builds and starts":
    let p = loadProject(root / "app" / "hello.nimproj")
    let r = p.build()
    check r.ok
    check fileExists(p.exePath)
    let (o, code) = p.smoke()
    check code == 0
    if code != 0: echo o

  test "a new form unit builds":
    let p = loadProject(root / "app" / "hello.nimproj")
    let u = p.newFormUnit()
    check u.name == "unit2" and u.formType == "Form2"
    check fileExists(root / "app" / "unit2.nim") and fileExists(root / "app" / "unit2.nfm")
    check p.units.len == 2
    check p.newFormUnit().name == "unit3"
    p.removeUnit("unit3", deleteFiles = true)
    check not fileExists(root / "app" / "unit3.nim")
    p.save()
    # the main file must import it to compile it; add an import and a handler
    let main = root / "app" / "hello.nim"
    writeFile(main, readFile(main).replace("import unit1\n", "import unit1, unit2\n"))
    let r = p.build()
    check r.ok
    check p.smoke().exitCode == 0

  test "rename a unit updates files and imports":
    let p = loadProject(root / "app" / "hello.nimproj")
    p.renameUnit("unit2", "second")
    check p.findUnit("second") >= 0 and p.findUnit("unit2") < 0
    check fileExists(root / "app" / "second.nim") and fileExists(root / "app" / "second.nfm")
    check not fileExists(root / "app" / "unit2.nim")
    check readFile(root / "app" / "hello.nim").contains("import unit1, second")
    check readFile(root / "app" / "second.nim").contains("loadForm Form2, \"second.nfm\"")
    expect ProjectError: p.renameUnit("second", "unit1")
    expect ProjectError: p.renameUnit("nope", "x")
    p.save()
    check loadProject(p.filePath).units[1].nimPath == "second.nim"
    let r = p.build()
    check r.ok
    check p.smoke().exitCode == 0

removeDir root
