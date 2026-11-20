import std/[unittest, os, strutils, sequtils]
import ide/[project, findinfiles]

let root = expandFilename(getTempDir()) / ("nimrad-fif-" & $getCurrentProcessId())
removeDir root
createDir root
let dir = root / "app"
createDir dir

proc put(rel, text: string) =
  createDir parentDir(dir / rel)
  writeFile(dir / rel, text)

put "app.nim", "import unit1\nlet Needle = 1\nlet needle2 = 2\n"
put "unit1.nim", "proc NeedleProc() = discard\n# a needle here and a needle there\n"
put "unit1.nfm", "object Form1: TForm\n  caption = 'needle'\nend\n"
put "other/extra.nim", "var needle = 3\n"
put "build/out.nim", "var needle = 4\n"
put "build/nimcache/gen.nim", "var needle = 5\n"
put ".hidden/h.nim", "var needle = 6\n"
put "notes.txt", "needle\n"
put "big.nim", "x\n".repeat(10) & "needle\n"
let p = Project(filePath: dir / "app.nimproj", name: "app", mainFile: "app.nim",
                outputDir: "build", units: @[ProjectUnit(name: "unit1", nimPath: "unit1.nim")])

proc rel(f: string): string = f.relativePath(dir).replace('\\', '/')
proc lines(r: FindResult): seq[string] = r.hits.mapIt(it.file.rel & ":" & $it.line)

suite "find in files":
  test "the files of the two scopes":
    check p.projectFiles(fsUnits).map(rel) == @["app.nim", "unit1.nim"]
    check p.projectFiles(fsFolder).map(rel) == @["app.nim", "big.nim", "other/extra.nim",
                                                 "unit1.nfm", "unit1.nim"]

  test "case, whole word and a line only once":
    let files = p.projectFiles(fsUnits)
    var o = FindOptions(text: "needle")
    check findInFiles(files, o).lines == @["app.nim:2", "app.nim:3", "unit1.nim:1", "unit1.nim:2"]
    o.caseSensitive = true
    check findInFiles(files, o).lines == @["app.nim:3", "unit1.nim:2"]
    o = FindOptions(text: "needle", wholeWord: true)
    let r = findInFiles(files, o)
    check r.lines == @["app.nim:2", "unit1.nim:2"] and r.files == 2 and r.scanned == 2
    check r.hits[1].col == 5 and r.hits[1].text == "# a needle here and a needle there"

  test "regular expression, and a bad one":
    let files = p.projectFiles(fsFolder)
    var o = FindOptions(text: r"^var\s+needle\s*=", regex: true)
    check findInFiles(files, o).lines == @["other/extra.nim:1"]
    o = FindOptions(text: "(", regex: true)
    let r = findInFiles(files, o)
    check r.error.len > 0 and r.hits.len == 0
    check findInFiles(files, FindOptions(text: "")).hits.len == 0

  test "the form files are searched in the folder scope":
    let r = findInFiles(p.projectFiles(fsFolder), FindOptions(text: "needle", caseSensitive: true))
    check "unit1.nfm:2" in r.lines
    check not r.lines.anyIt(it.startsWith("build/") or it.startsWith(".hidden"))

  test "an edited text replaces the file, big files are skipped, hits are capped":
    let files = p.projectFiles(fsUnits)
    let edit = proc(f: string, text: var string): bool =
      if f.extractFilename == "app.nim":
        text = "nothing\nNEEDLE\n"
        return true
    check findInFiles(files, FindOptions(text: "needle"), edit).lines ==
      @["app.nim:2", "unit1.nim:1", "unit1.nim:2"]
    put "huge.nim", "needle\n".repeat(MaxFileSize div 7 + 10)
    let r = findInFiles(@[dir / "huge.nim", dir / "app.nim"], FindOptions(text: "needle"))
    check r.skipped == 1 and r.scanned == 1
    put "many.nim", "needle\n".repeat(MaxHits + 50)
    let m = findInFiles(@[dir / "many.nim"], FindOptions(text: "needle"))
    check m.truncated and m.hits.len == MaxHits
    removeFile dir / "huge.nim"
    removeFile dir / "many.nim"

removeDir root
