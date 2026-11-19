import std/[unittest, os, osproc, strutils]
import ide/messages

let dir0 = getTempDir() / ("nimvclide-msg-" & $getCurrentProcessId())
createDir dir0
let dir = when defined(macosx): expandFilename(dir0) else: dir0   # the compiler prints real paths (macOS: /private/var/...)


proc nimOut(name, src: string, run = false, extra = ""): string =
  ## Compiles `src` (and runs it) and returns the merged output.
  let f = dir / name & ".nim"
  writeFile(f, src)
  let cmd = "nim c --colors:off --listFullPaths:on --hints:off " & extra &
            " --nimcache:" & quoteShell(dir / "cache-" & name) & " --outdir:" & quoteShell(dir) &
            (if run: " -r " else: " ") & quoteShell(f)
  execCmdEx(cmd).output

suite "single lines":
  test "windows paths with a drive letter":
    let m = parseLine("C:\\Users\\me\\app (1)\\unit1.nim(3, 11) Error: undeclared identifier: 'y'")
    check m.kind == mkError and m.line == 3 and m.col == 11
    check m.file == "C:\\Users\\me\\app (1)\\unit1.nim"
    check m.text == "undeclared identifier: 'y'"

  test "error":
    let m = parseLine("/a/b.nim(3, 11) Error: undeclared identifier: 'y'")
    check m.kind == mkError
    check m.file == "/a/b.nim"
    check m.line == 3 and m.col == 11
    check m.text == "undeclared identifier: 'y'"
  test "warning and hint":
    check parseLine("/a/b.nim(2, 12) Warning: imported and not used: 'os' [UnusedImport]").kind == mkWarning
    let h = parseLine("/a/b.nim(2, 1) Hint: 'x' is declared but not used [XDeclaredButNotUsed]")
    check h.kind == mkHint and h.line == 2
    let h2 = parseLine("Hint: mm: orc; threads: on [GCStats]")
    check h2.kind == mkHint and h2.file == ""
  test "file names with parentheses":
    let m = parseLine("/tmp/a(1)/x.nim(3, 4) Error: boom")
    check m.file == "/tmp/a(1)/x.nim" and m.line == 3 and m.col == 4
  test "traceback entries":
    let m = parseLine("/a/b.nim(3) inner")
    check m.isTrace and m.file == "/a/b.nim" and m.line == 3 and m.text == "inner"
    let n = parseLine("/a/b.nim outer")
    check n.isTrace and n.file == "/a/b.nim" and n.line == 0 and n.text == "outer"
  test "other lines are info":
    check parseLine("CC: system.nim").kind == mkInfo
    check parseLine("hello (3) world").kind == mkInfo
    check not parseLine("hello (3) world").isTrace
    check parseLine("Error: unhandled exception: boom [ValueError]").kind == mkError

suite "captured compiler output":
  test "undeclared identifier":
    let ms = parseMessages(nimOut("undecl", "proc f() =\n  let a = 1\n  echo b\nf()\n"))
    check ms.len == 1
    check ms[0].kind == mkError
    check ms[0].file == dir / "undecl.nim"
    check ms[0].line == 3 and ms[0].col == 8
    check "undeclared identifier: 'b'" in ms[0].text

  test "type mismatch with a multi-line text":
    let ms = parseMessages(nimOut("mism", "let a: int = \"x\"\n"))
    check ms.len == 1 and ms[0].kind == mkError
    check ms[0].line == 1
    check "type mismatch" in ms[0].text

  test "generic instantiation notes go to the error":
    let ms = parseMessages(nimOut("gen",
      "proc foo[T](x: T) =\n  let z = x + \"a\"\nproc bar() =\n  foo(3)\nbar()\n"))
    check ms.len == 1
    check ms[0].kind == mkError and ms[0].line == 2
    check ms[0].notes.len >= 1
    check ms[0].notes[0].line == 4
    check "template/generic instantiation of `foo`" in ms[0].notes[0].text
    check "Expression: x + \"a\"" in ms[0].text      # continuation lines kept
    check "[1] x: int" in ms[0].text

  test "warnings and hints, then success":
    let out0 = nimOut("warn", "proc f() {.deprecated.} = discard\nf()\n", extra = "--hints:on")
    let ms = parseMessages(out0)
    var warn, hints = 0
    for m in ms:
      if m.kind == mkWarning:
        inc warn
        check m.file == dir / "warn.nim" and m.line == 2
      if m.kind == mkHint: inc hints
    check warn == 1
    check hints > 0

  test "runtime traceback":
    let out0 = nimOut("trace", "proc inner(n: int) =\n  if n > 2: raise newException(ValueError, \"boom\")\n  inner(n + 1)\nproc outer() = inner(0)\nouter()\n", run = true)
    let ms = parseMessages(out0)
    var traces: seq[Message]
    var err: Message
    for m in ms:
      if m.isTrace: traces.add m
      elif m.kind == mkError and "unhandled exception" in m.text: err = m
    check traces.len >= 4
    check traces[0].file == dir / "trace.nim"
    check traces[^1].text == "inner" and traces[^1].line == 2
    check "boom" in err.text

suite "parser":
  test "streaming equals whole-text parsing":
    let text = nimOut("stream", "proc foo[T](x: T) =\n  let z = x + \"a\"\nfoo(3)\n")
    var p: MessageParser
    var got: seq[Message]
    for l in text.splitLines:
      p.feed l
      got.add p.take()
    got.add p.flush()
    check got.len == parseMessages(text).len
    check got[0].text == parseMessages(text)[0].text
removeDir dir
