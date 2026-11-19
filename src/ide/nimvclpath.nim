## Finding the nimvcl source folder (the one that holds `nimvcl.nim`), which
## the IDE passes as `--path:` when it compiles a user's project.
##
## Order: `$NIMVCL_SRC` (override), the folder this IDE was compiled against,
## then `nimble path nimvcl`. The result is "" when nothing is found.

import std/[os, osproc, strutils, compilesettings, times]

proc isNimvclSrc*(dir: string): bool =
  dir.len > 0 and fileExists(dir / "nimvcl.nim")

proc bakedNimvclSrc(): string {.compileTime.} =
  ## The `--path` entry the compiler used to find nimvcl while building the IDE.
  for p in querySettingSeq(searchPaths):
    if p.len > 0 and fileExists(p / "nimvcl.nim"): return normalizedPath(p)

const compiledAgainst* = bakedNimvclSrc()

proc nimblePathOfNimvcl(): string =
  let nimble = findExe("nimble")
  if nimble.len == 0: return ""
  try:
    let (o, code) = execCmdEx(quoteShell(nimble) & " path nimvcl")
    if code != 0: return ""
    # The path is the last line (nimble may print notes first).
    let ls = o.strip().split('\n')
    if ls.len > 0: return ls[^1].strip()
  except OSError, IOError:
    discard

proc resolveNimvclSrc*(env, baked: string, nimblePath: proc(): string): string =
  ## The first of `env`, `baked`, `nimblePath()` that holds `nimvcl.nim`.
  for c in [env, baked]:
    if isNimvclSrc(c): return normalizedPath(c)
  if nimblePath != nil:
    # `nimble path` gives the package folder; nimvcl keeps its code in `src/`.
    let n = nimblePath()
    for c in [n / "src", n]:
      if isNimvclSrc(c): return normalizedPath(c)

var cache: tuple[env, path: string, at: float]   ## the last answer (UI thread only)

const NotFoundAgain = 5.0   ## seconds before "not found" is looked up again

proc forgetNimvclSrc*() =
  ## Drops the remembered answer of `detectNimvclSrc` (it looks again).
  cache = ("", "", 0.0)

proc detectNimvclSrc*(): string =
  ## The nimvcl source folder; the answer is remembered, because the last step
  ## starts `nimble` (a visible pause on the UI thread, once per compile). A
  ## folder that is gone is looked for again, and so is "not found" after a few
  ## seconds.
  let env = getEnv("NIMVCL_SRC")
  let now = epochTime()
  if cache.at > 0 and cache.env == env:
    if cache.path.len > 0:
      if isNimvclSrc(cache.path): return cache.path
    elif now - cache.at < NotFoundAgain: return ""
  result = resolveNimvclSrc(env, compiledAgainst, nimblePathOfNimvcl)
  cache = (env, result, now)

const NimvclNotFound* =
  "nimvcl was not found. Install it with `nimble install nimvcl` (or " &
  "`nimble install https://github.com/Vyrnexis/nimvcl`), or set NIMVCL_SRC " &
  "to the `src` folder of a nimvcl checkout, or set the nimvcl path in " &
  "Project > Options."
