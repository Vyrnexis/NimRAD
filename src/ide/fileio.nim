## Writing the user's files: a crash or a full disk in the middle of a write
## must not leave a truncated file behind.

import std/[os, strutils]

proc relPosix*(path, base: string): string =
  ## `path` relative to `base`, with `/` separators (how paths are stored and imported).
  relativePath(path, base).replace('\\', '/')

proc writeFileAtomic*(path, content: string) =
  ## Writes to a temporary file next to `path` and renames it over `path`. The
  ## file keeps its permissions, a symbolic link is written through (the link
  ## stays, its target is replaced), and the temporary name has the process id,
  ## so two instances of the IDE do not use the same one.
  var target = path
  if symlinkExists(path):
    try: target = expandFilename(path)
    except OSError: discard                  # a dangling link: replaced as before
  let tmp = target & "." & $getCurrentProcessId() & ".tmp"
  try:
    writeFile(tmp, content)
    if fileExists(target):
      try: setFilePermissions(tmp, getFilePermissions(target))
      except OSError: discard
    moveFile(tmp, target)
  except CatchableError:
    try: removeFile tmp
    except OSError: discard
    raise
