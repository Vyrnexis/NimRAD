## User settings of the IDE, in `~/.config/nimrad/settings.json`
## (`$XDG_CONFIG_HOME` is honoured):
##
## ```json
## {"recentProjects": ["/home/me/app/app.nimproj"], "theme": "light",
##  "editorFontSize": 13, "editorFontFamily": "", "editorTabWidth": 2,
##  "editorInsertSpaces": true, "editorLineNumbers": true, "nimPath": "nim", "layout": "", "showHints": false,
##  "window": {"x": 100, "y": 60, "w": 1360, "h": 860, "maximized": false},
##  "codeTemplates": [{"name": "log", "description": "echo a line", "code": "echo \"|\""}],
##  "sessions": [{"project": "/home/me/app/app.nimproj", "units": ["app", "unit1"], "active": "unit1"}]}
## ```
##
## `sessions` remember which units were open in a project when it was closed
## (most recent first, at most `MaxSessions`), so reopening it brings them back;
## the `.nimproj` itself stays free of editor state.
##
## `codeTemplates` are the user's own Ctrl+J templates (`codeinsight`: `|` is
## where the caret goes); an entry without a name made of letters, digits and
## `_`, or without code, is ignored.
##
## `loadSettings` never fails: a missing or corrupt file, or a field of the
## wrong type, gives the default for that field. `saveSettings` writes through
## a temporary file so a crash cannot leave half a file.

import std/[json, os, strutils, sequtils]
import ./fileio

const
  MaxRecent* = 10
  MaxSessions* = 20
  MaxSessionUnits = 200
  DefaultFontSize* = 13
  DefaultTabWidth* = 2
  MinWindowW* = 480              ## smaller saved windows are ignored
  MinWindowH* = 320

type
  Settings* = object
    recentProjects*: seq[string]   ## most recent first, at most `MaxRecent`
    theme*: string                 ## "light" or "dark"
    editorFontSize*: int
    editorFontFamily*: string      ## "" = the theme's monospace font
    editorTabWidth*: int           ## 1 .. 16
    editorInsertSpaces*: bool      ## Tab inserts spaces instead of a tab character
    editorLineNumbers*: bool       ## line numbers in the gutter
    nimPath*: string               ## the compiler to run ("nim" = look in PATH)
    layout*: string                ## docking layout string (opaque to this module)
    showHints*: bool               ## compiler hints are requested and listed
    window*: WindowState           ## where the main window was (w = 0: never saved)
    codeTemplates*: seq[UserTemplate]  ## the user's own code templates (Ctrl+J)
    sessions*: seq[Session]        ## the open units of closed projects, most recent first

  Session* = tuple[project: string, units: seq[string], active: string]
    ## The units open in a project (tab order) and the one that was active.

  UserTemplate* = tuple[name, description, code: string]

  WindowState* = tuple[x, y, w, h: int, maximized: bool]
    ## Position and size of the window when it is not maximized, and whether it was.

proc defaultSettings*(): Settings =
  Settings(theme: "light", editorFontSize: DefaultFontSize, editorTabWidth: DefaultTabWidth,
           editorInsertSpaces: true, editorLineNumbers: true, nimPath: "nim")

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

proc rememberSession*(s: var Settings, project: string, units: seq[string], active: string) =
  ## Keeps the open units of `project` (replacing its earlier entry, which moves
  ## to the front); no units forgets the project.
  var l: seq[Session]
  if units.len > 0: l.add (project, units, active)
  for e in s.sessions:
    if e.project != project and l.len < MaxSessions: l.add e
  s.sessions = l

proc sessionOf*(s: Settings, project: string): Session =
  ## What was open in `project`; no units when nothing is remembered.
  for e in s.sessions:
    if e.project == project: return e

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
  if j.hasKey("editorFontFamily") and j["editorFontFamily"].kind == JString:
    result.editorFontFamily = j["editorFontFamily"].getStr.strip
  if j.hasKey("editorTabWidth") and j["editorTabWidth"].kind == JInt:
    let n = j["editorTabWidth"].getInt
    if n in 1 .. 16: result.editorTabWidth = n
  if j.hasKey("editorInsertSpaces") and j["editorInsertSpaces"].kind == JBool:
    result.editorInsertSpaces = j["editorInsertSpaces"].getBool
  if j.hasKey("editorLineNumbers") and j["editorLineNumbers"].kind == JBool:
    result.editorLineNumbers = j["editorLineNumbers"].getBool
  if j.hasKey("nimPath") and j["nimPath"].kind == JString and j["nimPath"].getStr.strip.len > 0:
    result.nimPath = j["nimPath"].getStr
  if j.hasKey("layout") and j["layout"].kind == JString:
    result.layout = j["layout"].getStr
  if j.hasKey("showHints") and j["showHints"].kind == JBool:
    result.showHints = j["showHints"].getBool
  if j.hasKey("codeTemplates") and j["codeTemplates"].kind == JArray:
    for e in j["codeTemplates"]:
      if e.kind != JObject: continue
      proc str(k: string): string =
        if e.hasKey(k) and e[k].kind == JString: e[k].getStr else: ""
      let t: UserTemplate = (str("name").strip, str("description"), str("code"))
      if t.name.len > 0 and t.code.len > 0 and
         t.name.allIt(it in {'a'..'z', 'A'..'Z', '0'..'9', '_'}) and result.codeTemplates.len < 200:
        result.codeTemplates.add t
  if j.hasKey("sessions") and j["sessions"].kind == JArray:
    for e in j["sessions"]:
      if e.kind != JObject or result.sessions.len >= MaxSessions: continue
      let proj = if e.hasKey("project") and e["project"].kind == JString: e["project"].getStr else: ""
      var units: seq[string]
      if e.hasKey("units") and e["units"].kind == JArray:
        for u in e["units"]:
          if u.kind == JString and u.getStr.len > 0 and units.len < MaxSessionUnits: units.add u.getStr
      let active = if e.hasKey("active") and e["active"].kind == JString: e["active"].getStr else: ""
      if proj.len > 0 and units.len > 0 and result.sessions.allIt(it.project != proj):
        result.sessions.add (proj, units, active)
  if j.hasKey("window") and j["window"].kind == JObject:
    let w = j["window"]
    proc num(k: string, lo, hi: int): int =
      if w.hasKey(k) and w[k].kind == JInt and w[k].getInt in lo .. hi: w[k].getInt
      else: low(int)
    let (x, y, ww, hh) = (num("x", -32000, 32000), num("y", -32000, 32000),
                          num("w", MinWindowW, 20000), num("h", MinWindowH, 20000))
    if low(int) notin [x, y, ww, hh]:           # all four or nothing
      result.window = (x, y, ww, hh, false)
    if w.hasKey("maximized") and w["maximized"].kind == JBool:
      result.window.maximized = w["maximized"].getBool

proc saveSettings*(s: Settings, path = settingsPath()): bool =
  ## Returns false when the file cannot be written.
  try:
    createDir(parentDir(path))
    let j = %*{"recentProjects": s.recentProjects, "theme": s.theme,
               "editorFontSize": s.editorFontSize, "editorFontFamily": s.editorFontFamily,
               "editorTabWidth": s.editorTabWidth, "editorInsertSpaces": s.editorInsertSpaces,
               "editorLineNumbers": s.editorLineNumbers, "nimPath": s.nimPath,
               "layout": s.layout, "showHints": s.showHints,
               "codeTemplates": s.codeTemplates.mapIt(%*{"name": it.name, "description": it.description, "code": it.code}),
               "sessions": s.sessions.mapIt(%*{"project": it.project, "units": it.units, "active": it.active}),
               "window": {"x": s.window.x, "y": s.window.y, "w": s.window.w, "h": s.window.h,
                          "maximized": s.window.maximized}}
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
