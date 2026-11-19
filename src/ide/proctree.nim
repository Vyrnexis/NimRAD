## Child processes that can be stopped as a whole tree.
##
## `startChild` runs a program with stdout and stderr merged into one pipe.
## The child leads a process group (posix) or a job object (Windows), so
## `killTree` also ends the helpers it started (the C compiler of `nim c`, the
## processes a program spawned). The read end of the pipe then reaches its end,
## because nobody keeps the write end open any more.

import std/os
when defined(posix): import std/posix
else: import std/[osproc, streams]
when defined(windows): import std/winlean

type
  Child* = object
    pid*: int
    job*: int              ## Windows: the job object handle (0 elsewhere)
    when defined(posix):
      fd: cint
    else:
      process: Process

when defined(windows):
  proc createJobObjectW(attrs: pointer, name: WideCString): Handle
    {.stdcall, dynlib: "kernel32", importc: "CreateJobObjectW".}
  proc assignProcessToJobObject(job, process: Handle): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "AssignProcessToJobObject".}
  proc terminateJobObject(job: Handle, exitCode: cuint): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "TerminateJobObject".}
  proc openProcess(access: DWORD, inherit: WINBOOL, pid: DWORD): Handle
    {.stdcall, dynlib: "kernel32", importc: "OpenProcess".}
  proc terminateProcess(process: Handle, exitCode: cuint): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "TerminateProcess".}

proc resolveExe(exe: string): string =
  ## A bare name ("nim") is looked up in PATH; findExe also tries the
  ## executable suffixes of the platform (nim.exe, ...).
  result = exe
  if not (exe.isAbsolute or '/' in exe or '\\' in exe):
    let found = findExe(exe)
    if found.len > 0: result = found

when defined(posix):
  when defined(macosx):
    # macOS declares no `environ` for programs linked as a whole; ask libSystem
    proc nsGetEnviron(): ptr cstringArray {.importc: "_NSGetEnviron", header: "<crt_externs.h>".}
    template cEnviron: cstringArray = nsGetEnviron()[]
  else:
    var cEnviron {.importc: "environ", header: "<unistd.h>".}: cstringArray

  proc startChild*(exe: string, args: seq[string], workDir: string): Child =
    ## Raises `OSError` when the program cannot be started.
    let cmd = resolveExe(exe)
    if not fileExists(cmd): raise newException(OSError, "no such program")
    var fds: array[2, cint]
    if pipe(fds) != 0: raiseOSError(osLastError())
    discard fcntl(fds[0], F_SETFD, FD_CLOEXEC)
    var acts: Tposix_spawn_file_actions
    var attr: Tposix_spawnattr
    discard posix_spawn_file_actions_init(acts)
    discard posix_spawnattr_init(attr)
    defer:
      discard posix_spawn_file_actions_destroy(acts)
      discard posix_spawnattr_destroy(attr)
    # no input: a program that reads stdin sees the end of the file at once
    discard posix_spawn_file_actions_addopen(acts, 0, "/dev/null", O_RDONLY, 0)
    discard posix_spawn_file_actions_adddup2(acts, fds[1], 1)
    discard posix_spawn_file_actions_adddup2(acts, fds[1], 2)
    discard posix_spawn_file_actions_addclose(acts, fds[1])
    var mask, defaults: Sigset
    discard sigemptyset(mask)
    discard sigfillset(defaults)
    discard posix_spawnattr_setsigmask(attr, mask)
    discard posix_spawnattr_setsigdefault(attr, defaults)
    discard posix_spawnattr_setpgroup(attr, 0)       # its own group: pgid = its pid
    discard posix_spawnattr_setflags(attr, POSIX_SPAWN_SETSIGMASK or POSIX_SPAWN_SETSIGDEF or
                                           POSIX_SPAWN_SETPGROUP)
    var argv: seq[string]
    if workDir.len > 0:
      # posix_spawn cannot change directory: let the shell do it, then replace itself
      argv = @["sh", "-c", "cd \"$1\" || exit 127; shift; exec \"$@\"", "sh", workDir, cmd]
    else:
      argv = @[cmd]
    argv.add args
    let cargv = allocCStringArray(argv)
    defer: deallocCStringArray(cargv)
    var pid: Pid
    let prog = if workDir.len > 0: "/bin/sh" else: cmd
    let rc = posix_spawn(pid, prog.cstring, acts, attr, cargv, cEnviron)
    discard close(fds[1])
    if rc != 0:
      discard close(fds[0])
      raiseOSError(OSErrorCode(rc))
    Child(pid: int(pid), fd: fds[0])

  proc readSome*(c: var Child, buf: var string): int =
    ## Blocks until output is there; 0 = the end, -1 = failure.
    while true:
      result = posix.read(c.fd, addr buf[0], buf.len)
      if result < 0 and errno == EINTR: continue
      return

  proc waitChild*(c: var Child): int =
    ## The exit code (128 + signal when it was killed).
    discard close(c.fd)
    var status: cint
    while waitpid(Pid(c.pid), status, 0) < 0:
      if errno != EINTR: return -1
    if WIFSIGNALED(status): 128 + int(WTERMSIG(status)) else: int(WEXITSTATUS(status))

  proc killTree*(pid, job: int) =
    if pid <= 0: return
    discard kill(Pid(-pid), SIGKILL)
    discard kill(Pid(pid), SIGKILL)
else:
  proc startChild*(exe: string, args: seq[string], workDir: string): Child =
    let cmd = resolveExe(exe)
    result.process = startProcess(cmd, workDir, args, nil, {poUsePath, poStdErrToStdOut})
    result.pid = result.process.processID
    # no input: close our end of the stdin pipe so a program that reads it sees
    # the end of the file at once
    result.process.inputStream.close()
    when defined(windows):
      let job = createJobObjectW(nil, nil)
      if job != 0:
        let h = openProcess(0x0101, 0, DWORD(result.pid))     # SET_QUOTA or TERMINATE
        if h != 0:
          discard assignProcessToJobObject(job, h)
          discard closeHandle(h)
        result.job = int(job)

  proc readSome*(c: var Child, buf: var string): int =
    c.process.outputStream.readData(addr buf[0], buf.len)

  proc waitChild*(c: var Child): int =
    result = c.process.waitForExit()
    c.process.close()
    when defined(windows):
      if c.job != 0:
        discard closeHandle(Handle(c.job))
        c.job = 0

  proc killTree*(pid, job: int) =
    when defined(windows):
      if job != 0 and terminateJobObject(Handle(job), 1) != 0: return
      # no job (assignment failed): end at least the direct child
      if pid <= 0: return
      let h = openProcess(0x0001, 0, DWORD(pid))               # PROCESS_TERMINATE
      if h != 0:
        discard terminateProcess(h, 1)
        discard closeHandle(h)
