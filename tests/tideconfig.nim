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
