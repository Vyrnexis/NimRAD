## The up-to-date check of Run: a build nothing changed for is skipped; an edit
## of a unit, of a module outside the project, of a form or font file, a flag,
## a new file or a replaced program builds again.
import std/[unittest, os, strutils, times]
import ide/[project, builder, buildcheck]

let root = getTempDir() / ("nimrad-bcheck-" & $getCurrentProcessId())
removeDir root
createDir root
createDir root / "lib"
writeFile root / "lib" / "helper.nim", "proc helperValue*(): int = 1\n"

let dir = root / "app"
createDir dir
writeFile dir / "app.nim", "import unit1, helper\necho helperValue() + unit1Value()\n"
writeFile dir / "unit1.nim", "proc unit1Value*(): int = 2\n"
writeFile dir / "data.txt", "one\n"
let p = Project(filePath: dir / "app.nimproj", name: "app", mainFile: "app.nim",
                outputDir: "build", nimFlags: @["--path:" & (root / "lib")])
p.save()

proc build(): bool =
  let r = p.compileProjectSync()
  if not r.ok: echo r.lines.join("\n")
  r.ok

proc current(): bool = p.isUpToDate()

suite "up to date":
  test "nothing was built yet":
    check not current()

  test "after a build, with nothing changed":
    check build()
    check current()
    check current()

  test "touching a file or saving it unchanged keeps it up to date":
    let f = dir / "unit1.nim"
    let text = readFile f
    sleep 20
    writeFile f, text
    setLastModificationTime(f, getLastModificationTime(f) + initDuration(seconds = 5))
    check current()

  test "a changed unit builds again":
    writeFile dir / "unit1.nim", "proc unit1Value*(): int = 3\n"
    check not current()
    check build()
    check current()

  test "a changed module outside the project builds again":
    writeFile root / "lib" / "helper.nim", "proc helperValue*(): int = 10\n"
    check not current()
    check build()
    check current()

  test "the project file changing (Run > Parameters) is not a reason to build":
    p.runArgs = @["--other"]
    p.save()
    check current()
    p.runArgs = @[]
    p.save()
    check current()

  test "a file the compiler does not list (read by a macro) builds again":
    writeFile dir / "data.txt", "two\n"
    check not current()
    check build()
    check current()

  test "a new file in the project builds again":
    writeFile dir / "extra.nim", "discard\n"
    check not current()
    check build()
    check current()
    removeFile dir / "extra.nim"
    check not current()
    check build()

  test "a flag builds again":
    p.defines = @["foo"]
    check not current()
    check build()
    check current()
    p.defines = @[]
    check not current()
    check build()
    check current()

  test "a replaced or missing program builds again":
    let exe = p.exePath
    let keep = readFile exe
    removeFile exe
    check not current()
    check build()
    check current()
    # a program that was built some other way
    sleep 20
    writeFile exe, keep & " "
    check not current()
    check build()
    check current()

  test "a failed build is not up to date afterwards":
    writeFile dir / "unit1.nim", "proc unit1Value*(): int = nope\n"
    check not build()
    check not current()
    writeFile dir / "unit1.nim", "proc unit1Value*(): int = 2\n"
    check build()
    check current()

  test "no stamp, no skip":
    removeFile p.stampPath(p.compileArgs())
    check not current()
    check build()
    check current()

  test "an output folder that holds the project always builds":
    let d2 = root / "flat"
    createDir d2
    writeFile d2 / "flat.nim", "echo 1\n"
    let q = Project(filePath: d2 / "flat.nimproj", name: "flat", mainFile: "flat.nim",
                    outputDir: ".")
    q.save()
    check q.compileProjectSync().ok
    check not q.isUpToDate()

  test "--out, -o or --outdir in the flags always builds":
    let keep = p.nimFlags
    for f in ["-o:app", "--out=app", "--outdir:build"]:
      p.nimFlags = keep & @[f]
      check build()
      check not current()
    p.nimFlags = keep
    check build()
    check current()

  test "the program that is skipped is the one that runs":
    let r = runCapture(p.exePath)
    check r.exitCode == 0 and r.lines == @["12"]

removeDir root
