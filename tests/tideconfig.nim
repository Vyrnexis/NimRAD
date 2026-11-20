import std/[unittest, os, strutils, sequtils]
import ide/ideconfig

let dir = getTempDir() / ("nimrad-cfg-" & $getCurrentProcessId())
removeDir dir
createDir dir
let path = dir / "sub" / "settings.json"

suite "settings":
  test "missing file gives defaults":
    let s = loadSettings(path)
    check s.theme == "light" and s.nimPath == "nim" and s.editorFontSize == DefaultFontSize
    check s.recentProjects.len == 0 and s.layout == "" and not s.showHints

  test "save and load":
    var s = defaultSettings()
    s.theme = "dark"
    s.editorFontSize = 16
    s.nimPath = "/usr/bin/nim"
    s.layout = "a|b\nc"
    s.showHints = true
    s.window = (120, 40, 1280, 800, true)
    s.addRecent("/p/one.nimproj")
    check saveSettings(s, path)
    check fileExists(path)
    let q = loadSettings(path)
    check q == s

  test "code templates: round trip, bad entries are dropped":
    var s = defaultSettings()
    check s.codeTemplates.len == 0
    s.codeTemplates = @[("log", "echo a line", "echo \"|\"")]
    check saveSettings(s, path)
    check loadSettings(path).codeTemplates == s.codeTemplates
    writeFile(path, """{"codeTemplates": [{"name": "ok", "code": "x|"}, {"name": "no code"}, {"name": "bad name", "code": "x"}, 5, {"code": "y"}]}""")
    check loadSettings(path).codeTemplates == @[("ok", "", "x|")]
    writeFile(path, """{"codeTemplates": "nope"}""")
    check loadSettings(path).codeTemplates.len == 0

  test "sessions: round trip, newest first, capped, bad entries dropped":
    var s = defaultSettings()
    s.rememberSession("/p/a.nimproj", @["a", "u1"], "u1")
    s.rememberSession("/p/b.nimproj", @["b"], "b")
    s.rememberSession("/p/a.nimproj", @["a"], "a")
    check s.sessions.len == 2 and s.sessions[0].project == "/p/a.nimproj"
    check s.sessionOf("/p/a.nimproj") == ("/p/a.nimproj", @["a"], "a")
    check s.sessionOf("/p/none.nimproj").units.len == 0
    check saveSettings(s, path)
    check loadSettings(path).sessions == s.sessions
    s.rememberSession("/p/b.nimproj", @[], "")          # nothing open: forgotten
    check s.sessions.len == 1
    for i in 1 .. 30: s.rememberSession("/p/x" & $i & ".nimproj", @["u"], "u")
    check s.sessions.len == MaxSessions and s.sessions[0].project == "/p/x30.nimproj"
    writeFile(path, """{"sessions": [{"project": "/p", "units": ["a", 3], "active": 1}, {"project": "/q"}, 7, {"units": ["x"]}]}""")
    check loadSettings(path).sessions == @[("/p", @["a"], "")]
    writeFile(path, """{"sessions": "nope"}""")
    check loadSettings(path).sessions.len == 0

  test "editor options: defaults, round trip, old files and bad values":
    let d = defaultSettings()
    check d.editorTabWidth == 2 and d.editorInsertSpaces and d.editorLineNumbers and d.editorFontFamily == ""
    var s = defaultSettings()
    s.editorFontFamily = "DejaVu Sans Mono"
    s.editorTabWidth = 4
    s.editorInsertSpaces = false
    s.editorLineNumbers = false
    check saveSettings(s, path)
    check loadSettings(path) == s
    writeFile(path, """{"theme": "dark", "editorFontSize": 15, "somethingNew": 1}""")   # an old file
    let o = loadSettings(path)
    check o.editorFontSize == 15 and o.editorTabWidth == 2 and o.editorInsertSpaces and o.editorLineNumbers
    writeFile(path, """{"editorTabWidth": 99, "editorInsertSpaces": "no", "editorLineNumbers": 0, "editorFontFamily": 7}""")
    let b = loadSettings(path)
    check b.editorTabWidth == 2 and b.editorInsertSpaces and b.editorLineNumbers and b.editorFontFamily == ""

  test "the window bounds are kept only when they make sense":
    writeFile(path, """{"window": {"x": -5, "y": 7, "w": 1000, "h": 700, "maximized": true}}""")
    check loadSettings(path).window == (-5, 7, 1000, 700, true)
    writeFile(path, """{"window": {"x": 1, "y": 2, "w": 10, "h": 700}}""")        # too small
    check loadSettings(path).window.w == 0
    writeFile(path, """{"window": {"x": 1, "w": 1000, "h": 700}}""")             # no y
    check loadSettings(path).window.w == 0
    writeFile(path, """{"window": "big"}""")
    check loadSettings(path).window.w == 0

  test "recent projects: front, no duplicates, max 10":
    var s = defaultSettings()
    for i in 1 .. 12: s.addRecent("/p/" & $i)
    check s.recentProjects.len == MaxRecent
    check s.recentProjects[0] == "/p/12"
    s.addRecent("/p/5")
    check s.recentProjects[0] == "/p/5"
    check s.recentProjects.count("/p/5") == 1
    check s.recentProjects.len == MaxRecent
    s.removeRecent("/p/5")
    check "/p/5" notin s.recentProjects

  test "corrupt file":
    writeFile(path, "{ not json")
    check loadSettings(path) == defaultSettings()
    writeFile(path, "[1, 2]")
    check loadSettings(path) == defaultSettings()

  test "wrong field types fall back per field":
    writeFile(path, """{"theme": 3, "editorFontSize": "big", "nimPath": "", "recentProjects": ["/a", 4, "/a", "/b"], "layout": "L", "showHints": "yes"}""")
    let s = loadSettings(path)
    check s.theme == "light" and s.editorFontSize == DefaultFontSize and s.nimPath == "nim"
    check s.recentProjects == @["/a", "/b"]
    check s.layout == "L" and not s.showHints

  test "unwritable location":
    # a plain file where the settings folder should be: createDir cannot succeed
    let blocker = dir / "blocker"
    writeFile(blocker, "x")
    check not saveSettings(defaultSettings(), blocker / "nope" / "settings.json")

removeDir dir

suite "settings folder rename":
  test "the nimvcl-ide folder is moved to nimrad once":
    let cfg = dir / "cfg"
    createDir(cfg / "nimvcl-ide")
    writeFile(cfg / "nimvcl-ide" / "settings.json", """{"theme": "dark"}""")
    check migrateLegacySettings(cfg)
    check not dirExists(cfg / "nimvcl-ide")
    check loadSettings(cfg / "nimrad" / "settings.json").theme == "dark"
    check not migrateLegacySettings(cfg)

  test "an existing nimrad folder wins and the old one is left alone":
    let cfg = dir / "cfg2"
    createDir(cfg / "nimvcl-ide")
    createDir(cfg / "nimrad")
    writeFile(cfg / "nimvcl-ide" / "settings.json", """{"theme": "dark"}""")
    check not migrateLegacySettings(cfg)
    check fileExists(cfg / "nimvcl-ide" / "settings.json")
    check not fileExists(cfg / "nimrad" / "settings.json")

  test "nothing to migrate":
    check not migrateLegacySettings(dir / "cfg3")

removeDir dir
