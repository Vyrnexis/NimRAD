## Compile, run and stop, as one state machine: `IdeForm.buildPhase` says
## what is going on, `builder` does the work in the background.
##
##     bpIdle --compile--> bpCompiling --ok--> bpIdle
##     bpIdle --run------> bpCompilingForRun --ok--> bpRunning --exit--> bpIdle
##     a failed build with new imports (project option) goes on in bpRetrying /
##     bpRetryingForRun, once; a failure or a stop ends in bpIdle.

import nimvcl
import std/[os, strutils, times]
import ./[nimvclpath, project, builder, messages, ideconfig, icons,
          messagespanel, uniteditor, ideform, ideeditors, quickfixes]

proc buildOptions(ide: IdeForm): BuildOptions =
  result = defaultBuildOptions()
  result.nimExe = ide.settings.nimPath
  result.hints = ide.settings.showHints

proc countLines(ide: IdeForm): int =
  if ide.project == nil: return 0
  var files = @[ide.project.mainPath]
  for u in ide.project.units: files.add ide.project.nimPathOf(u)
  for f in files:
    try: result += readFile(f).countLines
    except CatchableError: discard

proc secs(t: float): string = formatFloat(t, ffDecimal, 1) & " s"

proc clearErrorMarkers(ide: IdeForm) =
  for e in ide.editors: e.code.clearMarkers(MarkerKind.mkError)

proc markErrors(ide: IdeForm) =
  for m in ide.messages.msgs:
    if m.kind == MessageKind.mkError and m.hasLocation:
      let ed = ide.editorOf(ide.unitOfFile(m.file))
      if ed != nil: ed.code.addMarker(max(m.line - 1, 0), MarkerKind.mkError)

proc forRun(phase: BuildPhase): bool = phase in {bpCompilingForRun, bpRetryingForRun}

proc compileDone(ide: IdeForm, ok: bool)

proc startProgram(ide: IdeForm) =
  let p = ide.project
  ide.messages.addOutput "--- running " & p.exePath.extractFilename & " ---"
  # the program's stdout and stderr arrive line by line while it runs
  let onLines = proc(lines: seq[string]) = ide.messages.addOutputLines(lines)
  let onExit = proc(code: int) =
    ide.buildPhase = bpIdle
    ide.lastExitCode = code
    let stopped = wasCancelled()
    let how = if stopped: "stopped" else: "ended"
    ide.messages.addNote("Program " & how & " with exit code " & $code,
                         if code == 0: icSuccess elif stopped: icInfo else: icError)
    ide.setPart(spState, "Ready")
    ide.say "Program " & how & " (exit code " & $code & ")"
    ide.updateCaption()
    ide.refreshActions()
  let started = runProject(p, onLines, onExit)
  if started:
    ide.buildPhase = bpRunning
    ide.messages.showOutput()
    ide.setPart(spState, "Running")
    ide.say "Running " & p.name
    ide.updateCaption()
  else:
    ide.fail "Cannot start " & p.exePath
  ide.refreshActions()
proc startBuild(ide: IdeForm, phase: BuildPhase, notes: seq[string] = @[]): bool =
  ## Saves everything and starts the compiler; `phase` is where the controller
  ## goes when it started.
  if ide.project == nil or ide.busy: return false
  ide.saveAll()
  ide.messages.clear()
  ide.clearErrorMarkers()
  ide.messages.showMessages()
  for n in notes: ide.messages.addNote(n)
  if ide.project.nimvclSrc.len == 0:
    ide.messages.addNote(NimvclNotFound, icError)
    ide.say "nimvcl was not found"
    return false
  ide.setPart(spState, "Compiling...")
  ide.say "Compiling " & ide.project.name
  ide.buildStart = epochTime()
  let onLines = proc(lines: seq[string]) = ide.messages.feedLines(lines)
  let onDone = proc(ok: bool, exe: string) = ide.compileDone(ok)
  if not compileProject(ide.project, onLines, onDone, ide.buildOptions):
    ide.setPart(spState, "Ready")
    return false
  ide.buildPhase = phase
  ide.refreshActions()
  true

proc compile*(ide: IdeForm): bool =
  ## Project > Compile: saves everything, then runs the compiler in the
  ## background. Returns false when busy or without a project.
  ide.startBuild(bpCompiling)

proc run*(ide: IdeForm): bool =
  ## Run > Run: builds (the compiler knows what is out of date and does nothing
  ## when the program is current), then starts the program.
  ide.startBuild(bpCompilingForRun)

proc compileDone(ide: IdeForm, ok: bool) =
  let phase = ide.buildPhase
  ide.buildPhase = bpIdle
  let dt = epochTime() - ide.buildStart
  ide.messages.finish()
  ide.lastBuildOk = ok
  inc ide.buildCount
  let lines = ide.countLines
  ide.lastBuildInfo = $lines & " lines, " & secs(dt)
  ide.setPart(spBuild, ide.lastBuildInfo)
  ide.setPart(spState, "Ready")
  if wasCancelled():
    ide.messages.addNote("Build cancelled", icInfo)
    ide.say "Build cancelled"
  elif ok:
    ide.messages.addNote("Build succeeded: " & ide.project.name & " (" & $ide.messages.warningCount &
                         " warnings, " & secs(dt) & ")", icSuccess)
    ide.say "Build succeeded"
    if phase.forRun: ide.startProgram()
  else:
    if phase in {bpCompiling, bpCompilingForRun}:
      let added = ide.autoAddImports()
      if added.len > 0:
        ide.saveAll()
        # building again, with the imports it added
        if ide.startBuild(if phase.forRun: bpRetryingForRun else: bpRetrying, added): return
    ide.failedPhase = if phase.forRun: bpCompilingForRun else: bpCompiling
    ide.messages.addNote("Build failed: " & $ide.messages.errorCount & " errors, " &
                         $ide.messages.warningCount & " warnings (" & secs(dt) & ")", icError)
    ide.say "Build failed"
    ide.markErrors()
    let first = ide.messages.firstError()
    if first >= 0: ide.messages.jump first
  ide.refreshActions()

proc programReset*(ide: IdeForm) =
  ## Run > Program Reset: stops the running program (or the compiler).
  case buildState()
  of bsRunning: stopProject()
  of bsCompiling: cancelCompile()
  of bsIdle: discard

proc waitIdle*(ide: IdeForm, seconds = 120.0): bool =
  ## Runs the event loop until no build or program is active (scripts, tests).
  let t0 = epochTime()
  while ide.busy:
    if epochTime() - t0 > seconds: return false
    Application.processMessages(20)
  Application.processMessages(0)
  true

proc applyQuickFix*(ide: IdeForm, msgIndex: int, fixIndex = 0): bool =
  ## Applies a fix of message `msgIndex` (see `applyFix`); after an added
  ## import the build that failed runs again.
  let outcome = ide.applyFix(msgIndex, fixIndex)
  if outcome == foAddedImport:
    if ide.failedPhase == bpCompilingForRun: discard ide.run()
    else: discard ide.compile()
  outcome != foNone

proc quickFix*(ide: IdeForm): bool {.discardable.} =
  ## Ctrl+.: the fix of the selected message, else of the error at the caret,
  ## else of the first message that has one.
  let k = ide.fixTarget()
  k >= 0 and ide.applyQuickFix(k)
