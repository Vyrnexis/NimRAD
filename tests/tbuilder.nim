import std/[unittest, os, strutils, times, sequtils]
import nimvcl
import ide/[project, builder, messages]

let root = getTempDir() / ("nimrad-build-" & $getCurrentProcessId())
removeDir root
createDir root

proc mkProject(name, src: string, runArgs: seq[string] = @[]): Project =
  let d = root / name
  createDir d
  writeFile(d / name & ".nim", src)
  result = Project(filePath: d / name & ".nimproj", name: name, mainFile: name & ".nim",
                   outputDir: "build", runArgs: runArgs)
  result.save()

var
  lines: seq[string]
  doneCalls, exitCalls: int
  doneOk: bool
  doneExe: string
  exitCode = -99
  uiThread = true

proc reset() =
  lines = @[]
  doneCalls = 0
  exitCalls = 0
  doneOk = false
  doneExe = ""
  exitCode = -99

proc addLine(l: string) = lines.add l
proc onDone(ok: bool, exe: string) =
  inc doneCalls
  doneOk = ok
  doneExe = exe
proc onExit(c: int) =
  inc exitCalls
  exitCode = c

proc pumpUntil(cond: proc(): bool, seconds = 60.0): bool =
  let t0 = epochTime()
  while not cond():
    if epochTime() - t0 > seconds: return false
    Application.processMessages(20)
  true

const okSrc = "echo \"hello from ok\"\n"
const failSrc = "proc f() =\n  echo undefinedThing\nf()\n"
const slowSrc = """
import std/os
echo "started"
stdout.flushFile
var i = 0
while true:
  inc i
  echo "tick ", i
  stdout.flushFile
  sleep(50)
"""
const treeSrc = """
import std/[os, osproc]
# a helper that shares our stdout: it keeps the pipe open after we are gone
discard startProcess("/bin/sleep", args = ["60"], options = {poParentStreams})
echo "ready"
stdout.flushFile
sleep(60000)
"""
const floodSrc = "var i = 0\nwhile true:\n  inc i\n  echo \"flood line \", i\n"
const stdinSrc = "echo \"stdin: \", readAll(stdin).len\n"
const argsSrc = "import std/os\nfor a in commandLineParams(): echo \"arg:\" & a\nquit 3\n"

Application.init()

suite "sync":
  test "compile ok":
    let p = mkProject("syncok", okSrc)
    var streamed: seq[string]
    let r = p.compileProjectSync(proc(l: string) = streamed.add l)
    check r.ok and r.exitCode == 0
    check r.exe == p.exePath and fileExists(r.exe)
    check streamed == r.lines
    let (code, out0) = runCapture(r.exe)
    check code == 0 and out0 == @["hello from ok"]

  test "compile failure":
    let p = mkProject("syncfail", failSrc)
    let r = p.compileProjectSync()
    check not r.ok and r.exe == ""
    let ms = parseMessages(r.lines.join("\n"))
    check ms.len >= 1 and ms[0].kind == mkError
    check expandFilename(ms[0].file) == expandFilename(p.mainPath) and ms[0].line == 2

  test "arguments":
    let p = mkProject("syncargs", okSrc)
    p.nimFlags = @["-d:release"]
    let a = p.compileArgs()
    check a[0] == "c"
    for x in ["--colors:off", "--listFullPaths:on", "--hints:off", "-d:release",
              "--outdir:" & p.outputPath]:
      check x in a
    check a[^1] == p.mainPath
    check a.anyIt(it.startsWith("--path:")) == (p.nimvclSrc.len > 0)

  test "defines, title and version":
    let p = mkProject("defargs", okSrc)
    p.defines = @["foo", "level=2"]
    p.title = "My App"
    p.version = "1.2"
    let a = p.compileArgs()
    for x in ["-d:foo", "-d:level=2", "-d:appTitle=My App", "-d:appVersion=1.2"]: check x in a
    var o = defaultBuildOptions()
    o.hints = true
    check "--hints:off" notin p.compileArgs(o)
    p.title = ""
    p.version = ""
    check not p.compileArgs().anyIt(it.startsWith("-d:app"))

  test "missing compiler":
    let p = mkProject("nocomp", okSrc)
    var o = defaultBuildOptions()
    o.nimExe = "/nonexistent/nim"
    let r = p.compileProjectSync(nil, o)
    check not r.ok
    check "cannot start" in r.lines[0]

suite "async":
  test "compile ok streams lines and reports the exe":
    reset()
    let p = mkProject("asyncok", okSrc)
    check buildState() == bsIdle
    check compileProject(p, addLine,
                         onDone)
    check buildState() == bsCompiling
    check not compileProject(p, nil, nil)          # busy
    check not runProject(p, nil, nil)
    check pumpUntil(proc(): bool = doneCalls > 0)
    check doneOk and doneExe == p.exePath and fileExists(doneExe)
    check buildState() == bsIdle
    check doneCalls == 1

  test "compile failure delivers the error line":
    reset()
    let p = mkProject("asyncfail", failSrc)
    check compileProject(p, addLine,
                         onDone)
    check pumpUntil(proc(): bool = doneCalls > 0)
    check not doneOk and doneExe == ""
    var ms: seq[Message]
    ms = parseMessages(lines.join("\n"))
    check ms.len >= 1 and ms[0].kind == mkError and ms[0].line == 2
    check buildState() == bsIdle

  test "run with arguments and exit code":
    reset()
    let p = mkProject("args", argsSrc, @["one", "two"])
    check p.compileProjectSync().ok
    check runProject(p, addLine,
                     onExit)
    check buildState() == bsRunning
    check pumpUntil(proc(): bool = exitCalls > 0)
    check lines == @["arg:one", "arg:two"]
    check exitCode == 3
    check buildState() == bsIdle

  test "run without a built program":
    let p = mkProject("nobuild", okSrc)
    check not runProject(p, nil, nil)
    check buildState() == bsIdle

  test "run and stop a long-running program":
    reset()
    let p = mkProject("slow", slowSrc)
    check p.compileProjectSync().ok
    check runProject(p, addLine,
                     onExit)
    check pumpUntil(proc(): bool = lines.len >= 3, 20)
    check lines[0] == "started"
    check lines[1].startsWith("tick ")
    check exitCalls == 0 and buildState() == bsRunning
    stopProject()
    check pumpUntil(proc(): bool = exitCalls > 0, 20)
    check exitCalls == 1
    check buildState() == bsIdle
    let n = lines.len
    discard pumpUntil(proc(): bool = false, 0.3)
    check lines.len == n                           # nothing after the stop
    # and the next run works
    reset()
    check runProject(p, addLine, onExit)
    check pumpUntil(proc(): bool = lines.len >= 2, 20)
    stopProject()
    check pumpUntil(proc(): bool = exitCalls > 0, 20)

  test "stopping a program also stops the helpers it started":
    when defined(posix):
      reset()
      let p = mkProject("tree", treeSrc)
      check p.compileProjectSync().ok
      check runProject(p, addLine, onExit)
      check pumpUntil(proc(): bool = lines.len >= 1, 20)
      let t0 = epochTime()
      stopProject()
      check pumpUntil(proc(): bool = exitCalls > 0, 20)
      check epochTime() - t0 < 10          # not when the helper ends after 60 s
      check wasCancelled()

  test "a program that floods the output can be stopped":
    reset()
    let p = mkProject("flood", floodSrc)
    check p.compileProjectSync().ok
    var batches, total: int
    check runProject(p, proc(ls: seq[string]) =
      inc batches
      total += ls.len, onExit)
    check pumpUntil(proc(): bool = total >= 20000, 30)
    check batches < total                  # lines arrive in chunks
    stopProject()
    check pumpUntil(proc(): bool = exitCalls > 0, 30)
    check buildState() == bsIdle

  test "a program reading its input sees the end of the file":
    reset()
    let p = mkProject("readinput", stdinSrc)
    check p.compileProjectSync().ok
    check runProject(p, addLine, onExit)
    check pumpUntil(proc(): bool = exitCalls > 0, 20)
    check lines == @["stdin: 0"]
    check not wasCancelled()

  test "cancel a compile":
    reset()
    let p = mkProject("cancel", okSrc)
    p.nimFlags = @["-d:release", "--forceBuild"]
    check compileProject(p, nil, onDone)
    cancelCompile()
    check pumpUntil(proc(): bool = doneCalls > 0)
    check buildState() == bsIdle
    # (the compile may have finished before the kill: both outcomes are fine)

Application.shutdown()
removeDir root
