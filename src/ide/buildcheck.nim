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

import std/[os, json, times, strutils, sequtils, algorithm, tables]
{.push warning[Deprecated]: off.}
import std/sha1   # file content stamps; std/sha1 is deprecated in favour of the checksums package, kept to avoid a dependency
{.pop.}
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
  for d in skip:
    # the project lives inside the output (or nimcache) folder: every project
    # file would be left out, so nothing could be told about them
    if p.dir == d or p.dir.startsWith(d & DirSep):
      tooMany = true
      return
  let exe = p.exePath
  # the walk does not enter hidden folders (.git), nimcache or the output folder
  proc walk(dir: string, tooMany: var bool): seq[string] =
    for kind, f in walkDir(dir, skipSpecial = true):
      case kind
      of pcDir:
        let name = f.extractFilename
        if (name.len > 1 and name[0] == '.') or f in skip: continue
        result.add walk(f, tooMany)
      of pcFile, pcLinkToFile:
        # the `.nimproj` is not an input: what in it matters is in the arguments
        # (and the files it makes the IDE write), and Run > Parameters change it
        if f == exe or f == p.filePath or f.extractFilename.endsWith(".tmp"): continue
        result.add f
      else: discard
      if tooMany or result.len > MaxProjectFiles:
        tooMany = true
        return
  result = walk(p.dir, tooMany)

func toJson(f: FileStamp): JsonNode =
  %*{"path": f.path, "size": f.size, "mtime": f.mtime, "hash": f.hash}

func fileStamp(j: JsonNode): FileStamp =
  FileStamp(path: j["path"].getStr, size: j["size"].getBiggestInt, mtime: j["mtime"].getBiggestInt,
            hash: j["hash"].getStr)

proc takeSnapshot*(p: Project, args: seq[string], nimExe: string): Snapshot =
  ## Call just before the compiler starts.
  result = Snapshot(args: args, nimExe: nimExe, started: getTime())
  # a file whose size and time are those of the last stamp keeps its hash (the
  # stamp is older than the file's time by a margin, so it was not caught mid-edit)
  var prev = initTable[string, FileStamp]()
  var margin = fromUnix(0)
  let sp = p.stampPath(args)
  try:
    if sp.len > 0 and fileExists(sp):
      margin = getLastModificationTime(sp) - initDuration(seconds = 2)
      for f in parseFile(sp)["files"]:
        let st = f.fileStamp
        if st.hash.len > 0 and st.mtime >= 0: prev[st.path] = st
  except CatchableError: prev.clear()
  var hashed = 0'i64
  for f in p.projectFiles(args, result.tooMany):
    var st = stampOf(f)
    try:
      if st.size >= 0 and st.size <= MaxHashSize:
        let old = prev.getOrDefault(f)
        if old.hash.len > 0 and old.size == st.size and old.mtime == st.mtime and
           st.mtime < nanos(margin):
          st.hash = old.hash
        elif hashed + st.size <= MaxHashTotal:
          st.hash = $secureHashFile(f)
          hashed += st.size
    except CatchableError: discard
    result.files.add st

# ------------------------------------------------------------------- the stamp

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
    var verified = 0'i64
    for d in j["depfiles"]:
      let path = d[0].getStr
      var st = stampOf(path, d[1].getStr)
      if st.size < 0: return false                          # vanished during the build
      # a file replaced after the compiler read it (even with an older time, as
      # `cp -p` does) must not be stamped as current: compare with what was read
      if verified + st.size <= MaxHashTotal:
        if $secureHashFile(path) != st.hash: return false
        verified += st.size
      else:
        st.mtime = -1                                       # not verified: the hash decides later
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

func movesProgram(flags: seq[string]): bool =
  ## `--out`, `-o` or `--outdir` among the user's flags: the program is not where
  ## `exePath` says, so it cannot be checked.
  for f in flags:
    let name = f.strip(chars = {'-'}, trailing = false).split({':', '='})[0]
    if f.startsWith('-') and name in ["o", "out", "outdir"]: return true

proc isUpToDate*(p: Project, args: seq[string], nimExe: string): bool =
  ## Whether building with `args` would produce the program that is there.
  if movesProgram(p.nimFlags): return false
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
