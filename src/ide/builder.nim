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
## that are only touched on the UI thread. The output of a job is delivered in
## batches (what one read of the pipe returned), and the worker waits while the
## UI still has a backlog, so a program that prints in a loop can neither
## flood the event queue nor use up memory. Stopping kills the whole process
## tree (see `proctree`).

import std/[os, strutils, atomics]
import nimvcl
import ./[project, proctree, buildcheck]
when defined(macosx): import ./sdllink

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
  LinesProc* = proc(lines: seq[string])
    ## The output as it arrives: all the lines of one chunk at once.
  DoneProc* = proc(ok: bool, exe: string)
  ExitProc* = proc(exitCode: int)

proc defaultBuildOptions*(): BuildOptions =
  BuildOptions(nimExe: "nim", hints: false)

# ---------------------------------------------------------------- arguments

# macOS: programs link SDL at build time (see sdllink.nim for why).
proc sdlLinkArgs(): seq[string] =
  when defined(macosx):
    for l in SdlLibs: result.add "--dynlibOverride:" & l
    result.add "--passL:" & sdlPassL()

proc compileArgs*(p: Project, opts = defaultBuildOptions()): seq[string] =
  ## Arguments of the `nim` command (without the executable itself).
  result = @["c", "--colors:off", "--listFullPaths:on"]
  # the compiler leaves the list of the files it read next to its cache, which
  # is what `isUpToDate` works from (see buildcheck)
  result.add "-d:nimBetterRun"
  result.add "--nimcache:" & (p.outputPath / "nimcache")
  if not opts.hints: result.add "--hints:off"
  result.add "--errorMax:100"             # list all the errors, as Delphi does (nimFlags may override)
  result.add p.nimFlags
  for d in p.defines:
    result.add "-d:" & d
  if p.title.len > 0: result.add "-d:appTitle=" & p.title
  if p.version.len > 0: result.add "-d:appVersion=" & p.version
  let src = p.nimvclSrc
  if src.len > 0: result.add "--path:" & src
  result.add sdlLinkArgs()
  result.add "--outdir:" & p.outputPath
  result.add opts.extraArgs
  result.add p.mainPath

# ----------------------------------------------------------- process streams

type JobCtl = object
  pid: Atomic[int]
  job: Atomic[int]       # Windows job object of the process
  stop: Atomic[bool]

proc killTree(ctl: ptr JobCtl) =
  killTree(ctl.pid.load, ctl.job.load)

proc streamProcess(exe: string, args: seq[string], workDir: string,
                   emit: proc(lines: seq[string]) {.gcsafe.}, ctl: ptr JobCtl): int =
  ## Runs the process with stdout and stderr merged, calling `emit` with the
  ## lines of every chunk read, and returns its exit code (-1 when it cannot
  ## be started).
  var child: Child
  try:
    child = startChild(exe, args, workDir)
  except CatchableError as e:
    emit @["cannot start " & exe & ": " & e.msg]
    return -1
  if ctl != nil:
    ctl.job.store child.job
    ctl.pid.store child.pid
    if ctl.stop.load: killTree ctl           # stop requested before the pid was known
  try:
    var buf = newString(16384)
    var acc = ""
    while true:
      let n = child.readSome(buf)
      if n <= 0: break
      acc.add buf[0 ..< n]
      var batch: seq[string]
      var start = 0
      while true:
        let nl = acc.find('\n', start)
        if nl < 0: break
        var line = acc[start ..< nl]
        if line.endsWith('\r'): line.setLen line.len - 1
        batch.add line
        start = nl + 1
      if start > 0: acc = acc[start .. ^1]
      if batch.len > 0: emit batch
    if acc.len > 0: emit @[acc]
  except CatchableError:
    killTree(child.pid, child.job)       # nobody reads its output any more
    raise
  finally:
    result = child.waitChild()           # always: the child is never left unwaited
    if ctl != nil:
      ctl.pid.store 0
      ctl.job.store 0

# --------------------------------------------------------------- sync variants

proc isUpToDate*(p: Project, opts = defaultBuildOptions()): bool =
  ## Whether the program of the last successful build is still what building
  ## now would give (see `buildcheck`); false at any doubt.
  fileExists(p.exePath) and buildcheck.isUpToDate(p, p.compileArgs(opts), opts.nimExe)

proc compileProjectSync*(p: Project, onLine: LineProc = nil,
                         opts = defaultBuildOptions()): CompileResult =
  ## Compiles on the calling thread; `onLine` (optional) gets each line, and
  ## all lines are also returned in `lines`.
  createDir p.outputPath
  var lines: seq[string]
  let args = p.compileArgs(opts)
  let snap = takeSnapshot(p, args, opts.nimExe)
  let code = streamProcess(opts.nimExe, args, p.dir,
    proc(ls: seq[string]) {.gcsafe.} =
      {.cast(gcsafe).}:
        for l in ls:
          lines.add l
          if onLine != nil: onLine(l), nil)
  if code == 0: recordBuild(p, snap)
  result = CompileResult(ok: code == 0, exitCode: code, lines: lines,
                         exe: if code == 0: p.exePath else: "")

proc runCapture*(exe: string, args: seq[string] = @[], workDir = "",
                 onLine: LineProc = nil): tuple[exitCode: int, lines: seq[string]] =
  ## Runs a program on the calling thread and collects its merged output.
  var lines: seq[string]
  let code = streamProcess(exe, args, workDir,
    proc(ls: seq[string]) {.gcsafe.} =
      {.cast(gcsafe).}:
        for l in ls:
          lines.add l
          if onLine != nil: onLine(l), nil)
  (code, lines)

# ------------------------------------------------------------- async variants

const MaxBacklog = 16          ## batches the UI may be behind before the worker waits

type
  JobKind = enum jkCompile, jkRun

  JobArgs = object
    kind: JobKind
    exe: string
    args: seq[string]
    dir: string
    outExe: string

  LinesMsg = object
    kind: JobKind
    lines: seq[string]

  DoneMsg = object
    kind: JobKind
    code: int
    exe: string

var
  ctls: array[JobKind, JobCtl]          # shared with the workers
  threads: array[JobKind, Thread[JobArgs]]
  threadUsed: array[JobKind, bool]      # UI thread only from here on
  backlog: Atomic[int]                  # batches sent and not yet delivered
  gState = bsIdle
  gCancelled = false
  gProject: Project                     # the project being compiled (for the stamp)
  gSnapshot: Snapshot
  gOnLines: array[JobKind, LinesProc]
  gOnCompileDone: DoneProc
  gOnExit: ExitProc

proc buildState*(): BuildState = gState

proc wasCancelled*(): bool =
  ## Whether the job that just ended (see the `onDone` / `onExit` callbacks) was
  ## stopped by `cancelCompile` / `stopProject`.
  gCancelled

proc deliverLines(m: LinesMsg) =
  discard backlog.fetchSub 1
  let cb = gOnLines[m.kind]
  if cb != nil: cb(m.lines)

proc deliverDone(m: DoneMsg) =
  gState = bsIdle
  case m.kind
  of jkCompile:
    if m.code == 0 and gProject != nil: recordBuild(gProject, gSnapshot)
    gProject = nil
    let cb = gOnCompileDone
    gOnCompileDone = nil
    if cb != nil: cb(m.code == 0, if m.code == 0: m.exe else: "")
  of jkRun:
    let cb = gOnExit
    gOnExit = nil
    if cb != nil: cb(m.code)

proc worker(a: JobArgs) {.thread.} =
  let kind = a.kind
  var code = -1
  let emit = proc(ls: seq[string]) {.gcsafe.} =
    # let the UI catch up instead of piling batches into its queue
    while backlog.load >= MaxBacklog and not ctls[kind].stop.load: sleep 2
    discard backlog.fetchAdd 1
    runOnUi(LinesMsg(kind: kind, lines: ls), deliverLines)
  try:
    {.cast(gcsafe).}:
      code = streamProcess(a.exe, a.args, a.dir, emit, addr ctls[kind])
  except CatchableError as e:
    code = -1
    try: emit @["internal error: " & e.msg]
    except CatchableError: discard
  finally:
    # the IDE leaves its busy state only through this message: it is always sent
    runOnUi(DoneMsg(kind: kind, code: code, exe: a.outExe), deliverDone)

proc startJob(kind: JobKind, a: JobArgs, onLines: LinesProc) =
  if threadUsed[kind]:
    joinThread threads[kind]      # the previous worker has delivered its end
  ctls[kind].stop.store false
  ctls[kind].pid.store 0
  ctls[kind].job.store 0
  backlog.store 0
  gCancelled = false
  gOnLines[kind] = onLines
  threadUsed[kind] = true
  createThread(threads[kind], worker, a)

proc eachLine(onLine: LineProc): LinesProc =
  if onLine == nil: return nil
  result = proc(lines: seq[string]) =
    for l in lines: onLine(l)

proc compileProject*(p: Project, onLines: LinesProc, onDone: DoneProc,
                     opts = defaultBuildOptions()): bool =
  ## Starts the compiler in a worker thread. Returns false (and does nothing)
  ## when a build or program is already running. `onLines` and `onDone` run on
  ## the UI thread; `onDone(ok, exe)` gets `exe = ""` when the build failed.
  if gState != bsIdle: return false
  createDir p.outputPath
  gState = bsCompiling
  gOnCompileDone = onDone
  let args = p.compileArgs(opts)
  gProject = p
  gSnapshot = takeSnapshot(p, args, opts.nimExe)
  startJob(jkCompile, JobArgs(kind: jkCompile, exe: opts.nimExe, args: args,
                              dir: p.dir, outExe: p.exePath), onLines)
  true

proc compileProject*(p: Project, onLine: LineProc, onDone: DoneProc,
                     opts = defaultBuildOptions()): bool =
  compileProject(p, eachLine(onLine), onDone, opts)

proc runProject*(p: Project, onLines: LinesProc, onExit: ExitProc): bool =
  ## Starts the built program (`exePath`) with the project's `runArgs`; its
  ## output goes to `onLines`, and `onExit(code)` is called when it ends (also
  ## after `stopProject`). Returns false when busy or when there is no program.
  if gState != bsIdle or not fileExists(p.exePath): return false
  gState = bsRunning
  gOnExit = onExit
  startJob(jkRun, JobArgs(kind: jkRun, exe: p.exePath, args: p.runArgs, dir: p.dir,
                          outExe: p.exePath), onLines)
  true

proc runProject*(p: Project, onLine: LineProc, onExit: ExitProc): bool =
  runProject(p, eachLine(onLine), onExit)

proc stopJob(kind: JobKind) =
  gCancelled = true
  ctls[kind].stop.store true
  killTree addr ctls[kind]

proc stopProject*() =
  ## Kills the running program and everything it started (its `onExit` still
  ## fires). No-op otherwise.
  if gState == bsRunning: stopJob jkRun

proc cancelCompile*() =
  ## Kills a running compiler and its helpers (`onDone(false, "")` still fires).
  if gState == bsCompiling: stopJob jkCompile
