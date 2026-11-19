## NimRAD, a Delphi 7-like RAD IDE for Nim built on nimvcl.
##
## Usage:
##
##     nimrad                 start the IDE (opens the last project)
##     nimrad --project FILE  start the IDE with the project FILE (.nimproj)
##     nimrad --nimvcl-path   print the nimvcl source folder projects are built with
##     nimrad --shots DIR     run the scripted session headless and save
##                            a PNG of every step into DIR
##
## Run `--shots` with `SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software`
## set in the environment so that no window opens.

import std/[os, strutils]
import nimvcl
import ide/[mainform, session, uniteditor, project, nimvclpath, ideconfig]

const usage = """NimRAD
  nimrad              start the IDE
  nimrad --project F  start the IDE and open the project F (.nimproj)
  nimrad --nimvcl-path  print where nimvcl's source is found
  nimrad --shots DIR  run the scripted session and save screenshots into DIR"""

proc shots(dir: string): int =
  createDir dir
  let work = getTempDir() / ("nimrad-shots-" & $getCurrentProcessId())
  removeDir work
  createDir work
  Application.init()
  let ide = newIdeForm(settingsFile = work / "settings.json")
  ide.showWindow(1360, 860)
  let r = ide.runScriptedSession(work, proc(name: string) =
    ide.shoot(dir / (name & ".png"))
    echo "wrote ", dir / (name & ".png"))
  if not r.ok:
    stderr.writeLine "session failed: " & r.error
    result = 1
  else:
    # one more picture for the docs: a compile error, with the jump to it
    let ed = ide.activeEditor
    ed.showCode()
    ide.activeControl = ed.code
    ed.code.caretPos = (ed.code.lineCount - 1, 0)
    ide.typeText "\nlet broken: int = \"oops\"\n"
    if ide.compile() and ide.waitIdle(180):
      ide.shoot(dir / "08-compile-error.png")
      echo "wrote ", dir / "08-compile-error.png"
  Application.shutdown()
  removeDir work

proc main() =
  let args = commandLineParams()
  if args.len >= 1 and args[0] in ["-h", "--help"]:
    echo usage
  elif args.len >= 1 and args[0] == "--nimvcl-path":
    let p = detectNimvclSrc()
    if p.len == 0:
      stderr.writeLine NimvclNotFound
      quit 1
    echo p
  elif args.len >= 1 and args[0] == "--shots":
    quit shots(if args.len >= 2: args[1] else: "build/shots")
  else:
    discard migrateLegacySettings()
    Application.init()
    let ide = newIdeForm()
    ide.startup(project = projectArg(args))
    Application.run(ide)

main()
