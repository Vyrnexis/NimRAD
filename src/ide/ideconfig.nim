## User settings of the IDE, in `~/.config/nimrad/settings.json`
## (`$XDG_CONFIG_HOME` is honoured):
##
## ```json
## {"recentProjects": ["/home/me/app/app.nimproj"], "theme": "light",
##  "editorFontSize": 13, "nimPath": "nim", "layout": "", "showHints": false}
## ```
##
## `loadSettings` never fails: a missing or corrupt file, or a field of the
## wrong type, gives the default for that field. `saveSettings` writes through
## a temporary file so a crash cannot leave half a file.

import std/[json, os, strutils]
import ./fileio

const
  MaxRecent* = 10
  DefaultFontSize* = 13

type
  Settings* = object
    recentProjects*: seq[string]   ## most recent first, at most `MaxRecent`
    theme*: string                 ## "light" or "dark"
    editorFontSize*: int
    nimPath*: string               ## the compiler to run ("nim" = look in PATH)
    layout*: string                ## docking layout string (opaque to this module)
    showHints*: bool               ## compiler hints are requested and listed

proc defaultSettings*(): Settings =
  Settings(theme: "light", editorFontSize: DefaultFontSize, nimPath: "nim")

const LegacySettingsDirName* = "nimvcl-ide"   ## the folder before the rename to NimRAD

proc settingsDir*(): string = getConfigDir() / "nimrad"
proc settingsPath*(): string = settingsDir() / "settings.json"

proc addRecent*(s: var Settings, projectPath: string) =
  ## Moves `projectPath` to the front (no duplicates, capped at `MaxRecent`).
  var l = @[projectPath]
  for p in s.recentProjects:
    if p != projectPath and l.len < MaxRecent: l.add p
  s.recentProjects = l

proc removeRecent*(s: var Settings, projectPath: string) =
  var l: seq[string]
  for p in s.recentProjects:
    if p != projectPath: l.add p
  s.recentProjects = l

proc loadSettings*(path = settingsPath()): Settings =
  result = defaultSettings()
  var j: JsonNode
  try:
    j = parseJson(readFile(path))
  except CatchableError:
    return
  if j.kind != JObject: return
  if j.hasKey("recentProjects") and j["recentProjects"].kind == JArray:
    for e in j["recentProjects"]:
      if e.kind == JString and e.getStr.len > 0 and e.getStr notin result.recentProjects and
         result.recentProjects.len < MaxRecent:
        result.recentProjects.add e.getStr
  if j.hasKey("theme") and j["theme"].kind == JString and j["theme"].getStr.len > 0:
    result.theme = j["theme"].getStr
  if j.hasKey("editorFontSize") and j["editorFontSize"].kind == JInt:
    let n = j["editorFontSize"].getInt
    if n in 6 .. 96: result.editorFontSize = n
  if j.hasKey("nimPath") and j["nimPath"].kind == JString and j["nimPath"].getStr.strip.len > 0:
    result.nimPath = j["nimPath"].getStr
  if j.hasKey("layout") and j["layout"].kind == JString:
    result.layout = j["layout"].getStr
  if j.hasKey("showHints") and j["showHints"].kind == JBool:
    result.showHints = j["showHints"].getBool

proc saveSettings*(s: Settings, path = settingsPath()): bool =
  ## Returns false when the file cannot be written.
  try:
    createDir(parentDir(path))
    let j = %*{"recentProjects": s.recentProjects, "theme": s.theme,
               "editorFontSize": s.editorFontSize, "nimPath": s.nimPath,
               "layout": s.layout, "showHints": s.showHints}
    writeFileAtomic(path, j.pretty & "\n")
    true
  except CatchableError:
    false

proc migrateLegacySettings*(configDir = getConfigDir()): bool =
  ## One-time move of the settings of the pre-rename IDE (`nimvcl-ide`) to the
  ## `nimrad` folder under `configDir`. Does nothing when the new folder already
  ## exists or the old one does not. Returns true when something was moved;
  ## never raises (the IDE then simply starts with defaults).
  let old = configDir / LegacySettingsDirName
  let dest = configDir / "nimrad"
  if dirExists(dest) or not dirExists(old): return false
  try:
    moveDir(old, dest)
    true
  except CatchableError:
    try: removeDir(dest) except CatchableError: discard
    false
