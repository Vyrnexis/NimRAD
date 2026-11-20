import std/[unittest, os, osproc, strutils]
import ide/messages

let dir0 = getTempDir() / ("nimrad-msg-" & $getCurrentProcessId())
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

suite "runtime output":
  proc runAll(lines: seq[string], own: proc(f: string): bool = nil): seq[Message] =
    var p: RuntimeParser
    for l in lines: result.add p.feedRuntime(l, own)

  test "ordinary program output gives no message":
    check runAll(@["hello", "/a/b.nim(3) looks like a frame", "Error: not after a traceback"]).len == 0

  test "a traceback: header, frames, the exception at the innermost own frame":
    let own = proc(f: string): bool = f.startsWith("/proj/")
    let ms = runAll(@["Traceback (most recent call last)",
                      "/proj/main.nim(9) main", "/proj/unit1.nim(4) inner",
                      "/nim/lib/system/fatal.nim(53) sysFatal",
                      "Error: unhandled exception: boom [ValueError]", "after"], own)
    check ms.len == 5
    check ms[0].isTraceHead and ms[0].text == TraceHeader
    check ms[1].isTrace and ms[1].file == "/proj/main.nim" and ms[1].line == 9
    check ms[3].file == "/nim/lib/system/fatal.nim"
    check ms[4].kind == mkError and ms[4].text == "unhandled exception: boom [ValueError]"
    check ms[4].file == "/proj/unit1.nim" and ms[4].line == 4 and ms[4].hasLocation

  test "no own frame: the exception has no place; no predicate: the last frame":
    let lines = @["Traceback (most recent call last)", "/x/a.nim(2) f", "Error: unhandled exception: e [IOError]"]
    check not runAll(lines, proc(f: string): bool = false)[^1].hasLocation
    check runAll(lines)[^1].file == "/x/a.nim"

  test "reraised sections stay in the traceback; other lines end it":
    let ms = runAll(@["Traceback (most recent call last)", "/a.nim(1) a", "[[reraised from:", "/a.nim(2) b", "]]",
                      "/a.nim(3) c", "oops", "/a.nim(4) d"])
    check ms.len == 4          # header, a, b, c; the line after "oops" is plain output

suite "parser":
  test "a location-less error keeps the lines after it":
    let ms = parseMessages("Error: execution of an external compiler program 'gcc -c x.c' failed with exit code: 1\n\nx.c:3:1: error: boom\n/usr/bin/ld: cannot find -lfoo\nHint: next\n")
    check ms.len == 2
    check ms[0].kind == mkError
    check "x.c:3:1: error: boom" in ms[0].text and "cannot find -lfoo" in ms[0].text
    check ms[1].kind == mkHint
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
