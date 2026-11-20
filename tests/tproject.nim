import std/[unittest, os, osproc, strutils, json, sequtils]
import headless
when defined(posix): import std/posix
import ide/[project, builder]

let root = expandFilename(getTempDir()) / ("nimrad-proj-" & $getCurrentProcessId())
removeDir root
createDir root

proc smoke(p: Project): tuple[output: string, exitCode: int] =
  headlessCmd(quoteShell(p.exePath) & " --smoke")

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

  test "the format version and the application version are separate keys":
    let p = Project(filePath: root / "fv" / "fv.nimproj", name: "fv", mainFile: "fv.nim",
                    outputDir: "build", version: "2.5")
    let j = p.toJson
    check j["formatVersion"].getInt == FormatVersion
    check j["version"].getStr == "2.5"
    createDir root / "fv"
    p.save()
    check loadProject(p.filePath).version == "2.5"

  test "a file from a newer IDE is refused":
    createDir root / "newer"
    writeFile(root / "newer" / "n.nimproj", """{"formatVersion": 99, "name": "n"}""")
    expect ProjectError: discard loadProject(root / "newer" / "n.nimproj")

  test "fields this version does not know survive a save":
    createDir root / "keep"
    writeFile(root / "keep" / "k.nimproj",
              """{"formatVersion": 1, "name": "k", "future": {"a": [1, 2]}, "autoImports": true}""")
    let p = loadProject(root / "keep" / "k.nimproj")
    p.autoImports = false
    p.save()
    let j = parseJson(readFile(p.filePath))
    check j["future"]["a"].len == 2
    check not j.hasKey("autoImports")
    check j["formatVersion"].getInt == 1

  test "saving an unchanged project does not touch the file":
    let p = Project(filePath: root / "fv" / "same.nimproj", name: "same", mainFile: "same.nim",
                    outputDir: "build")
    p.save()
    let t = getLastModificationTime(p.filePath)
    sleep 1100
    p.save()
    check getLastModificationTime(p.filePath) == t

  test "defaults and tolerance":
    writeFile(root / "min.nimproj", """{"name": "m", "units": [1, {"name": "x"}], "nimFlags": "bad"}""")
    let p = loadProject(root / "min.nimproj")
    check p.outputDir == "build" and p.mainFile == "m.nim"
    check p.units.len == 0 and p.nimFlags.len == 0
    writeFile(root / "bad.nimproj", "not json")
    expect ProjectError: discard loadProject(root / "bad.nimproj")
    expect ProjectError: discard loadProject(root / "missing.nimproj")

  test "nimvcl path detection":
    let found = detectNimvclPath().replace(DirSep, '/')
    check found.endsWith("nimvcl/src") or found == ""
    let p = Project(filePath: root / "x.nimproj", nimvclPath: "../elsewhere/src")
    check p.nimvclSrc == root.parentDir / "elsewhere" / "src"

suite "unknown keys in records":
  test "unit and font records keep the keys this version does not know":
    createDir root / "keep2"
    writeFile(root / "keep2" / "k.nimproj", """{"name": "k",
      "units": [{"name": "u", "nim": "u.nim", "nfm": "", "isForm": false, "formType": "",
                 "future": {"a": 1}}],
      "fonts": [{"file": "fonts/F.ttf", "family": "F", "style": "regular", "license": "OFL"}]}""")
    let p = loadProject(root / "keep2" / "k.nimproj")
    p.save()
    let j = parseJson(readFile(p.filePath))
    check j["units"][0]["future"]["a"].getInt == 1
    check j["fonts"][0]["license"].getStr == "OFL"

suite "project options and names":
  test "defines, title and version are saved and become compiler arguments":
    let p = Project(filePath: root / "o" / "o.nimproj", name: "o", mainFile: "o.nim",
                    outputDir: "build", defines: @["foo", "level=2"], title: "My App",
                    version: "1.0")
    createDir root / "o"
    p.save()
    let q = loadProject(p.filePath)
    check q.defines == @["foo", "level=2"] and q.title == "My App" and q.version == "1.0"
    check "\"defines\"" in readFile(p.filePath)
    let a = compileArgs(q)
    check "-d:foo" in a and "-d:level=2" in a
    check "-d:appTitle=My App" in a and "-d:appVersion=1.0" in a
    let e = loadProject(root / "min.nimproj")
    check e.defines.len == 0 and e.title == "" and e.version == ""
    check not compileArgs(e).anyIt(it.startsWith("-d:app"))

suite "new application":
  test "files are created from the templates":
    let p = newApplicationProject(root / "app", "hello")
    for f in ["hello.nimproj", "hello.nim", "unit1.nim", "unit1.nfm", "nim.cfg"]:
      check fileExists(root / "app" / f)
    check readFile(root / "app" / "unit1.nim").contains("loadForm Form1, \"unit1.nfm\"")
    check readFile(root / "app" / "unit1.nfm").contains("caption = 'Form1'")
    check readFile(root / "app" / "unit1.nfm").contains("width = 640")
    check readFile(root / "app" / "hello.nim").contains("import unit1")
    check readFile(root / "app" / "hello.nim").contains("import nimvcl/prelude")
    check readFile(root / "app" / "unit1.nim").contains("import nimvcl/prelude")
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
    # the main file imports it and creates the form (between the markers)
    let main = readFile(root / "app" / "hello.nim")
    check "import unit2\n" in main and "let form2 {.used.} = newForm2()\n" in main
    check "unit3" notin main and "Form3" notin main        # removed again with its unit
    let r = p.build()
    check r.ok
    check p.smoke().exitCode == 0

  test "rename a unit updates files and imports":
    let p = loadProject(root / "app" / "hello.nimproj")
    p.renameUnit("unit2", "second")
    check p.findUnit("second") >= 0 and p.findUnit("unit2") < 0
    check fileExists(root / "app" / "second.nim") and fileExists(root / "app" / "second.nfm")
    check not fileExists(root / "app" / "unit2.nim")
    check readFile(root / "app" / "hello.nim").contains("import second\n")
    check not readFile(root / "app" / "hello.nim").contains("import unit2")
    check readFile(root / "app" / "second.nim").contains("loadForm Form2, \"second.nfm\"")
    expect ProjectError: p.renameUnit("second", "unit1")
    expect ProjectError: p.renameUnit("nope", "x")
    p.save()
    check loadProject(p.filePath).units[1].nimPath == "second.nim"
    let r = p.build()
    check r.ok
    check p.smoke().exitCode == 0

suite "paths":
  test "a project opened through a symlink uses the real paths the compiler prints":
    when defined(posix):
      let p = newApplicationProject(root / "real", "real")
      createSymlink(root / "real", root / "link")
      let q = loadProject(root / "link" / "real.nimproj")
      check q.filePath == expandFilename(root / "real") / "real.nimproj"
      check q.unitOfFile(expandFilename(root / "real" / "unit1.nim")) == "unit1"
      check q.unitOfFile(root / "link" / "unit1.nim") == "unit1"     # found through the link too
      check q.unitOfFile(q.mainPath) == "real"
      check q.unitOfFile(root / "real" / "nope.nim") == ""
      discard p

suite "units outside the program's folder":
  test "they are imported by a path relative to the program and still build":
    let app = root / "outside" / "app"
    let p = newApplicationProject(app, "app")
    createDir root / "outside" / "ext"
    createDir app / "sub"
    writeFile(root / "outside" / "ext" / "helper.nim", "const helperValue* = 42\n")
    writeFile(app / "sub" / "local.nim", "const localValue* = 1\n")
    let h = p.addUnit("helper", root / "outside" / "ext" / "helper.nim")
    let l = p.addUnit("local", app / "sub" / "local.nim")
    check p.addToMain(h) and p.addToMain(l)
    let main = readFile(p.mainPath)
    check "import ../ext/helper\n" in main and "import sub/local\n" in main
    check p.build().ok
    check p.smoke().exitCode == 0
    # removing takes the same lines out
    p.removeUnit("helper")
    check "ext/helper" notin readFile(p.mainPath)
    # renaming a unit in another folder follows the import
    p.renameUnit("local", "nearby")
    check "import sub/nearby\n" in readFile(p.mainPath)
    check fileExists(app / "sub" / "nearby.nim")
    check p.build().ok

suite "symlinked paths":
  test "a unit named through a symlink is stored by its real path":
    when defined(posix):
      let real = root / "unitreal"
      createDir real / "lib"
      writeFile(real / "lib" / "util.nim", "const util* = 1\n")
      createSymlink(real, root / "unitlink")
      let p = newApplicationProject(real / "app", "app")
      let u = p.addUnit("util", root / "unitlink" / "lib" / "util.nim")
      check u.nimPath == "../lib/util.nim"
      check p.importPath(u, p.mainPath.parentDir) == "../lib/util"

suite "renaming is all or nothing":
  test "a write that fails puts the moved files back":
    # root writes into a read-only folder, so the failure can't be forced (CI containers)
    if (when defined(posix): geteuid() == 0 else: true):
      skip()
    else:
      let app = root / "atomic" / "app"
      let p = newApplicationProject(app, "app")
      createDir app / "sub"
      writeFile(app / "sub" / "foo.nim", "const foo* = 1\n")
      discard p.addUnit("foo", app / "sub" / "foo.nim")
      p.addToMain(p.units[^1])
      p.save()
      let mainBefore = readFile(p.mainPath)
      let before = p.units
      setFilePermissions(app, {fpUserRead, fpUserExec})        # the program's folder is read-only
      try:
        expect CatchableError: p.renameUnit("foo", "bar")
      finally:
        setFilePermissions(app, {fpUserRead, fpUserWrite, fpUserExec})
      check fileExists(app / "sub" / "foo.nim") and not fileExists(app / "sub" / "bar.nim")
      check readFile(p.mainPath) == mainBefore
      check p.units == before

suite "rename the project":
  test "the project file and the main file move, the units stay":
    let p = loadProject(root / "app" / "hello.nimproj")
    expect ProjectError: p.renameProject("1bad")
    expect ProjectError: p.renameProject("unit1")           # a unit has that name
    writeFile(root / "app" / "taken.nimproj", "{}")
    expect ProjectError: p.renameProject("taken")
    check fileExists(root / "app" / "hello.nimproj")        # nothing happened
    p.renameProject("world")
    check p.name == "world" and p.mainFile == "world.nim"
    check p.filePath == root / "app" / "world.nimproj"
    check fileExists(root / "app" / "world.nimproj") and fileExists(root / "app" / "world.nim")
    check not fileExists(root / "app" / "hello.nimproj") and not fileExists(root / "app" / "hello.nim")
    let q = loadProject(p.filePath)
    check q.name == "world" and q.units.len == 2
    check readFile(root / "app" / "world.nim").contains("import unit1")
    check q.build().ok
    check q.exePath.extractFilename == "world".addFileExt(ExeExt)
    check q.smoke().exitCode == 0

suite "units and forms: names and invariants":
  test "a stray .nfm makes New Form take the next number":
    let p = newApplicationProject(root / "nums", "nums")
    writeFile(root / "nums" / "unit2.nfm", "object Form2: Form\nend\n")
    let u = p.newFormUnit()
    check u.name == "unit3" and u.formType == "Form3"

  test "two units cannot get the same form type":
    let p = loadProject(root / "nums" / "nums.nimproj")
    check p.newFormUnit("bar").formType == "Bar"
    check p.newFormUnit("barForm").formType == "BarForm"
    var msg = ""
    try: discard p.newFormUnit("Bar")                  # would be BarForm again
    except ProjectError as e: msg = e.msg
    check msg.len > 0
    check p.units.filterIt(it.formType == "BarForm").len == 1

  test "a unit name that would give a form the name of a nimvcl class is refused":
    let p = loadProject(root / "nums" / "nums.nimproj")
    for n in ["button", "label", "form"]:
      expect ProjectError: discard p.newFormUnit(n)
    expect ProjectError: discard p.newFormUnit("proc")           # a keyword
    check p.findUnit("button") < 0 and not fileExists(root / "nums" / "button.nim")

  test "a new application does not overwrite files that are there":
    createDir root / "taken"
    writeFile(root / "taken" / "taken.nim", "echo 1\n")
    expect ProjectError: discard newApplicationProject(root / "taken", "taken")
    check readFile(root / "taken" / "taken.nim") == "echo 1\n"
    createDir root / "cfg"
    writeFile(root / "cfg" / "nim.cfg", "-d:mine\n")
    expect ProjectError: discard newApplicationProject(root / "cfg", "other")
    check readFile(root / "cfg" / "nim.cfg") == "-d:mine\n"

  test "the unit of the main form cannot be removed from the model either":
    let p = newApplicationProject(root / "mainform", "mainform")
    expect ProjectError: p.removeUnit("unit1")
    check p.findUnit("unit1") >= 0
    let u = p.newFormUnit()                            # the main form is still unit1's
    p.removeUnit(u.name)
    check p.findUnit(u.name) < 0


removeDir root
