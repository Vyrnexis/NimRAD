## Is the program up to date? A build that nothing changed for is skipped by
## Run, instead of starting `nim c` just to find that out.
##
## The compiler is asked to record what it read (`-d:nimBetterRun`: its
## `<nimcache>/<program>.json` then lists every file of the build with a SHA-1,
## `depfiles`: the modules, nimvcl, the standard library, the config files).
## After a successful build `recordBuild` writes a stamp next to it
## (`nimrad-build.json`) that holds
##
## * the compiler arguments and the compiler executable,
## * the program (size and time),
## * every file of the compiler's `depfiles` with its hash, size and time,
## * every file of the project folder (forms, fonts, images, configs: the
##   compiler does not list what a macro reads with `staticRead`, nor a file
##   that is new) with hash, size and time; not the `.nimproj` itself, whose
##   settings are in the arguments (Run > Parameters changes it, and must not
##   cause a build).
##
## `isUpToDate` is true only when all of it is as recorded: a file whose size
## or time differs counts as unchanged when its content hash is still the
## recorded one (a touched file), anything else means build. Whenever
## something cannot be told (no stamp, unreadable file, too many files) the
## answer is false, so a doubt always builds.
##
## The file times and hashes of the project folder are taken before the
## compiler starts (`takeSnapshot`), so an edit made during the build is seen
## as a change by the next check; files of the compiler's list that were
## modified since the build started are checked by hash only.

import std/[os, json, times, sha1, strutils, sequtils, algorithm]
import ./project

const
  StampName* = "nimrad-build.json"
  StampVersion = 1
  MaxProjectFiles = 4000       ## a larger folder is not tracked: always build
  MaxHashSize = 4_000_000'i64  ## bigger project files are compared by size and time only
  MaxHashTotal = 64_000_000'i64 ## so are the files after this many bytes were hashed (UI thread)

type
  FileStamp = object
    path: string
    size: int64
    mtime: int64               ## nanoseconds since the epoch, -1 = unknown (compare by hash)
    hash: string               ## "" = none

  Snapshot* = object
    ## What the project folder looked like before the compiler started.
    args: seq[string]
    nimExe: string
    started: Time
    files: seq[FileStamp]
    tooMany: bool

func nanos(t: Time): int64 = t.toUnix * 1_000_000_000'i64 + t.nanosecond.int64

proc stampOf(path: string, hash = "", keepTime = true): FileStamp =
  ## Size and time of the file now (size -1: not readable).
  result = FileStamp(path: path, size: -1, mtime: -1, hash: hash)
  try:
    let fi = getFileInfo(path)
    result.size = fi.size
    if keepTime: result.mtime = nanos(fi.lastWriteTime)
  except OSError: discard

proc sameFile(f: FileStamp): bool =
  ## Whether the file is still what `f` recorded.
  var fi: FileInfo
  try: fi = getFileInfo(f.path)
  except OSError: return false
  if fi.kind notin {pcFile, pcLinkToFile}: return false
  if fi.size == f.size and f.mtime >= 0 and nanos(fi.lastWriteTime) == f.mtime: return true
  if f.hash.len == 0: return false
  try: result = $secureHashFile(f.path) == f.hash
  except CatchableError: result = false

# ------------------------------------------------------------------ locations

proc nimcacheDir*(p: Project, args: seq[string]): string =
  ## The compiler's `--nimcache` of this build (the last one given wins; "" when
  ## the arguments name none).
  for a in args:
    for pre in ["--nimcache:", "--nimcache="]:
      if a.startsWith(pre): result = a[pre.len .. ^1]
  if result.len > 0 and not result.isAbsolute: result = p.dir / result

proc stampPath*(p: Project, args: seq[string]): string =
  let d = nimcacheDir(p, args)
  if d.len > 0: d / StampName else: ""

proc compilerJson(p: Project, args: seq[string]): string =
  let d = nimcacheDir(p, args)
  if d.len > 0: d / p.exePath.splitFile.name & ".json" else: ""

proc compilerFile(nimExe: string): string =
  ## The compiler executable as found now ("" when there is none).
  if nimExe.len == 0: return ""
  if nimExe.isAbsolute or DirSep in nimExe: (if fileExists(nimExe): nimExe else: "")
  else: findExe(nimExe)

# ------------------------------------------------------------ project files

proc projectFiles(p: Project, args: seq[string], tooMany: var bool): seq[string] =
  ## Every file of the project folder except what the build writes (the output
  ## and nimcache folders, the program) and hidden folders.
  var skip = @[p.outputPath, nimcacheDir(p, args)]
  skip.keepItIf it.len > 0
  let exe = p.exePath
  for f in walkDirRec(p.dir, yieldFilter = {pcFile, pcLinkToFile}, followFilter = {pcDir},
                      skipSpecial = true):
    # the `.nimproj` is not an input: what in it matters is in the arguments (and
    # the files it makes the IDE write), and Run > Parameters change it
    if f == exe or f == p.filePath: continue
    let rel = relativePath(f, p.dir)
    var hidden = false
    for part in rel.parentDir.split({DirSep, AltSep}):
      if part.len > 1 and part[0] == '.': hidden = true
    if hidden: continue
    if skip.anyIt(f.startsWith(it & DirSep)): continue
    if f.extractFilename.endsWith(".tmp"): continue
    result.add f
    if result.len > MaxProjectFiles:
      tooMany = true
      return

proc takeSnapshot*(p: Project, args: seq[string], nimExe: string): Snapshot =
  ## Call just before the compiler starts.
  result = Snapshot(args: args, nimExe: nimExe, started: getTime())
  var hashed = 0'i64
  for f in p.projectFiles(args, result.tooMany):
    var h = ""
    try:
      let size = getFileSize(f)
      if size <= MaxHashSize and hashed + size <= MaxHashTotal:
        h = $secureHashFile(f)
        hashed += size
    except CatchableError: discard
    result.files.add stampOf(f, h)

# ------------------------------------------------------------------- the stamp

func toJson(f: FileStamp): JsonNode =
  %*{"path": f.path, "size": f.size, "mtime": f.mtime, "hash": f.hash}

func fileStamp(j: JsonNode): FileStamp =
  FileStamp(path: j["path"].getStr, size: j["size"].getBiggestInt, mtime: j["mtime"].getBiggestInt,
            hash: j["hash"].getStr)

proc recordBuild*(p: Project, snap: Snapshot): bool {.discardable.} =
  ## After a successful build: writes the stamp. False (and no stamp) when the
  ## compiler did not leave the list of the files it read.
  let sp = p.stampPath(snap.args)
  let cj = p.compilerJson(snap.args)
  if sp.len == 0 or cj.len == 0: return false
  try: removeFile sp
  except OSError: discard
  if snap.tooMany or not fileExists(cj) or not fileExists(p.exePath): return false
  try:
    let j = parseFile(cj)
    if j.kind != JObject or not j.hasKey("depfiles") or j["depfiles"].kind != JArray or
       j["depfiles"].len == 0: return false
    var deps = newJArray()
    for d in j["depfiles"]:
      let path = d[0].getStr
      var st = stampOf(path, d[1].getStr)
      if st.size < 0: return false                          # vanished during the build
      try:
        if getLastModificationTime(path) >= snap.started - initDuration(seconds = 1):
          st.mtime = -1                                     # maybe changed since: use the hash
      except OSError: return false
      deps.add toJson(st)
    var files = newJArray()
    for f in snap.files: files.add toJson(f)
    let comp = compilerFile(snap.nimExe)
    if comp.len == 0: return false
    writeFile(sp, $(%*{"version": StampVersion, "args": snap.args, "nimExe": snap.nimExe,
                       "compiler": toJson(stampOf(comp)),
                       "exe": toJson(stampOf(p.exePath)),
                       "deps": deps, "files": files}))
    result = true
  except CatchableError:
    try: removeFile sp
    except OSError: discard

proc isUpToDate*(p: Project, args: seq[string], nimExe: string): bool =
  ## Whether building with `args` would produce the program that is there.
  let sp = p.stampPath(args)
  if sp.len == 0 or not fileExists(sp) or not fileExists(p.exePath): return false
  try:
    let j = parseFile(sp)
    if j["version"].getInt != StampVersion: return false
    if j["args"].getElems.mapIt(it.getStr) != args or j["nimExe"].getStr != nimExe: return false
    let comp = compilerFile(nimExe)
    if comp.len == 0 or comp != j["compiler"].fileStamp.path or
       not j["compiler"].fileStamp.sameFile: return false
    let exe = j["exe"].fileStamp
    if exe.path != p.exePath or not exe.sameFile: return false
    for d in j["deps"]:
      if not d.fileStamp.sameFile: return false
    # the project folder: the same files, each unchanged
    var tooMany = false
    let now = p.projectFiles(args, tooMany)
    if tooMany: return false
    let recorded = j["files"].getElems.mapIt(it.fileStamp)
    if recorded.len != now.len: return false
    var names = now
    names.sort()
    var known = recorded.mapIt(it.path)
    known.sort()
    if names != known: return false
    for f in recorded:
      if not f.sameFile: return false
    result = true
  except CatchableError:
    result = false
