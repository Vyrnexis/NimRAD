## NimRAD, a Delphi 7-like RAD IDE for Nim built on nimvcl.
##
## Usage:
##
##     nimrad                 start the IDE (opens the last project)
##     nimrad --project FILE  start the IDE with the project FILE (.nimproj)
##     nimrad FILE.nimproj    the same (what a file association passes)
##     nimrad --nimvcl-path   print the nimvcl source folder projects are built with
##
## The scripted session that makes the screenshots of the documentation is not
## part of the program: see `scripts/docshots.nim`.

import std/os
import nimvcl
import ide/[mainform, nimvclpath, ideconfig]

const usage = """NimRAD
  nimrad              start the IDE
  nimrad --project F  start the IDE and open the project F (.nimproj)
  nimrad F.nimproj    the same
  nimrad --nimvcl-path  print where nimvcl's source is found"""

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
  else:
    for problem in commandLineProblems(args): stderr.writeLine "nimrad: " & problem
    discard migrateLegacySettings()
    Application.init()
    let ide = newIdeForm()
    ide.startup(project = projectArg(args))
    Application.run(ide)

main()
