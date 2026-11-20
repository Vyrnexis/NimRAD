## Writing the user's files: a crash or a full disk in the middle of a write
## must not leave a truncated file behind.

import std/[os, strutils]

proc relPosix*(path, base: string): string =
  ## `path` relative to `base`, with `/` separators (how paths are stored and imported).
  relativePath(path, base).replace('\\', '/')

proc writeFileAtomic*(path, content: string) =
  ## Writes to a temporary file next to `path` and renames it over `path`.
  let tmp = path & ".tmp"
  try:
    writeFile(tmp, content)
    moveFile(tmp, path)
  except CatchableError:
    try: removeFile tmp
    except OSError: discard
    raise
