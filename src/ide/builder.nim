## Compile and run a project.
##
## * `compileProject` starts `nim c` in a worker thread; every output line and
##   the end of the build are delivered on the UI thread through nimvcl's
##   `runOnUi`, so the callbacks may touch controls. They are called from
##   `Application.run` (or `processMessages`), never from the worker.
## * `runProject` starts the built program as a child process; its stdout and
##   stderr (merged) are streamed the same way. `stopProject` kills it.
## * `compileProjectSync` / `runCapture` do the same on the calling thread
##   (tests, command-line use); they need no running UI loop.
##
## State is `idle`, `compiling` or `running`; only one thing runs at a time.
## All the non-`Sync` procs must be called from the UI thread.
##
## `runOnUi` handlers cannot capture, so the callbacks live in module globals
## that are only touched on the UI thread; every message carries the serial
## number of its job, and messages of a job that was cancelled are dropped.

import std/[os, osproc, strutils, atomics, streams]
when defined(posix): import std/posix
import nimvcl
import ./project

type
  BuildState* = enum bsIdle, bsCompiling, bsRunning

  BuildOptions* = object
    nimExe*: string        ## the compiler to run, "nim" = look it up in PATH
    hints*: bool           ## false adds `--hints:off`
    extraArgs*: seq[string]

  CompileResult* = object
    ok*: bool
    exe*: string           ## path of the built program (when ok)
    exitCode*: int
    lines*: seq[string]    ## compile only: the whole output (sync variant)

  LineProc* = proc(line: string)
  DoneProc* = proc(ok: bool, exe: string)
  ExitProc* = proc(exitCode: int)

proc defaultBuildOptions*(): BuildOptions =
  BuildOptions(nimExe: "nim", hints: false)

# ---------------------------------------------------------------- arguments

proc exePath*(p: Project): string =
  ## Where `nim c` puts the program: `<outputDir>/<main file stem>`.
  p.outputPath / (p.mainFile.splitFile.name & ExeExt)

proc compileArgs*(p: Project, opts = defaultBuildOptions()): seq[string] =
  ## Arguments of the `nim` command (without the executable itself).
  result = @["c", "--colors:off", "--listFullPaths:on"]
  if not opts.hints: result.add "--hints:off"
  result.add p.nimFlags
  let src = p.nimvclSrc
  if src.len > 0: result.add "--path:" & src
  result.add "--outdir:" & p.outputPath
  result.add opts.extraArgs
  result.add p.mainPath

# ----------------------------------------------------------- process streams

type JobCtl = object
  pid: Atomic[int]
  stop: Atomic[bool]

proc killPid(pid: int) =
  if pid <= 0: return
  when defined(posix):
    discard kill(Pid(pid), SIGKILL)
  else:
    discard execShellCmd("taskkill /pid " & $pid & " /f /t")

proc streamProcess(exe: string, args: seq[string], workDir: string,
                   emit: proc(line: string) {.gcsafe.}, ctl: ptr JobCtl): int =
  ## Runs the process with stdout and stderr merged, calling `emit` for every
  ## line, and returns its exit code (-1 when it cannot be started).
  var p: Process
  try:
    p = startProcess(exe, workDir, args, nil, {poUsePath, poStdErrToStdOut})
  except OSError as e:
    emit "cannot start " & exe & ": " & e.msg
    return -1
  if ctl != nil:
    ctl.pid.store p.processID
    if ctl.stop.load: killPid p.processID     # stop requested before the pid was known
  # Read the pipe directly: the buffered `outputStream` waits for a full buffer.
  let h = p.outputHandle
  var buf = newString(4096)
  var acc = ""
  while true:
    let n = when defined(posix): posix.read(cint(h), addr buf[0], buf.len)
            else: p.outputStream.readData(addr buf[0], buf.len)
    when defined(posix):
      if n < 0 and errno == EINTR: continue
    if n <= 0: break
    acc.add buf[0 ..< n]
    var start = 0
    while true:
      let nl = acc.find('\n', start)
      if nl < 0: break
      var line = acc[start ..< nl]
      if line.endsWith('\r'): line.setLen line.len - 1
      emit line
      start = nl + 1
    if start > 0: acc = acc[start .. ^1]
  if acc.len > 0: emit acc
  result = p.waitForExit()
  if ctl != nil: ctl.pid.store 0
  p.close()

# --------------------------------------------------------------- sync variants

proc compileProjectSync*(p: Project, onLine: LineProc = nil,
                         opts = defaultBuildOptions()): CompileResult =
  ## Compiles on the calling thread; `onLine` (optional) gets each line, and
  ## all lines are also returned in `lines`.
  createDir p.outputPath
  var lines: seq[string]
  let code = streamProcess(opts.nimExe, p.compileArgs(opts), p.dir,
    proc(l: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        lines.add l
        if onLine != nil: onLine(l), nil)
  result = CompileResult(ok: code == 0, exitCode: code, lines: lines,
                         exe: if code == 0: p.exePath else: "")

proc runCapture*(exe: string, args: seq[string] = @[], workDir = "",
                 onLine: LineProc = nil): tuple[exitCode: int, lines: seq[string]] =
  ## Runs a program on the calling thread and collects its merged output.
  var lines: seq[string]
  let code = streamProcess(exe, args, workDir,
    proc(l: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        lines.add l
        if onLine != nil: onLine(l), nil)
  (code, lines)

# ------------------------------------------------------------- async variants

type
  JobKind = enum jkCompile, jkRun

  JobArgs = object
    kind: JobKind
    serial: int
    exe: string
    args: seq[string]
    dir: string
    outExe: string

  LineMsg = object
    kind: JobKind
    serial: int
    line: string

  DoneMsg = object
    kind: JobKind
    serial: int
    code: int
    exe: string

var
  ctls: array[JobKind, JobCtl]          # shared with the workers
  threads: array[JobKind, Thread[JobArgs]]
  threadUsed: array[JobKind, bool]      # UI thread only from here on
  gState = bsIdle
  gSerial = 0
  gOnLine: array[JobKind, LineProc]
  gOnCompileDone: DoneProc
  gOnExit: ExitProc

proc buildState*(): BuildState = gState

proc deliverLine(m: LineMsg) =
  if m.serial == gSerial and gOnLine[m.kind] != nil:
    try: gOnLine[m.kind](m.line)
    except CatchableError: discard

proc deliverDone(m: DoneMsg) =
  if m.serial != gSerial: return
  gState = bsIdle
  try:
    case m.kind
    of jkCompile:
      let cb = gOnCompileDone
      gOnCompileDone = nil
      if cb != nil: cb(m.code == 0, if m.code == 0: m.exe else: "")
    of jkRun:
      let cb = gOnExit
      gOnExit = nil
      if cb != nil: cb(m.code)
  except CatchableError: discard

proc worker(a: JobArgs) {.thread.} =
  let kind = a.kind
  let serial = a.serial
  var code = -1
  {.cast(gcsafe).}:
    code = streamProcess(a.exe, a.args, a.dir,
      proc(l: string) {.gcsafe.} =
        runOnUi(LineMsg(kind: kind, serial: serial, line: l), deliverLine),
      addr ctls[kind])
  runOnUi(DoneMsg(kind: kind, serial: serial, code: code, exe: a.outExe), deliverDone)

proc startJob(kind: JobKind, a: JobArgs) =
  if threadUsed[kind]:
    joinThread threads[kind]      # the previous worker has delivered its end
  ctls[kind].stop.store false
  ctls[kind].pid.store 0
  threadUsed[kind] = true
  createThread(threads[kind], worker, a)

proc compileProject*(p: Project, onLine: LineProc, onDone: DoneProc,
                     opts = defaultBuildOptions()): bool =
  ## Starts the compiler in a worker thread. Returns false (and does nothing)
  ## when a build or program is already running. `onLine` and `onDone` run on
  ## the UI thread; `onDone(ok, exe)` gets `exe = ""` when the build failed.
  if gState != bsIdle: return false
  createDir p.outputPath
  inc gSerial
  gState = bsCompiling
  gOnLine[jkCompile] = onLine
  gOnCompileDone = onDone
  startJob(jkCompile, JobArgs(kind: jkCompile, serial: gSerial, exe: opts.nimExe,
                              args: p.compileArgs(opts), dir: p.dir, outExe: p.exePath))
  true

proc runProject*(p: Project, onLine: LineProc, onExit: ExitProc): bool =
  ## Starts the built program (`exePath`) with the project's `runArgs`; its
  ## output goes to `onLine`, and `onExit(code)` is called when it ends (also
  ## after `stopProject`). Returns false when busy or when there is no program.
  if gState != bsIdle or not fileExists(p.exePath): return false
  inc gSerial
  gState = bsRunning
  gOnLine[jkRun] = onLine
  gOnExit = onExit
  startJob(jkRun, JobArgs(kind: jkRun, serial: gSerial, exe: p.exePath,
                          args: p.runArgs, dir: p.dir, outExe: p.exePath))
  true

proc stopJob(kind: JobKind) =
  ctls[kind].stop.store true
  killPid ctls[kind].pid.load

proc stopProject*() =
  ## Kills the running program (its `onExit` still fires). No-op otherwise.
  if gState == bsRunning: stopJob jkRun

proc cancelCompile*() =
  ## Kills a running compiler (`onDone(false, "")` still fires).
  if gState == bsCompiling: stopJob jkCompile
