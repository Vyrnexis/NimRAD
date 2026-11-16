import std/[unittest, os, strutils, sequtils]
import ide/ideconfig

let dir = getTempDir() / ("nimvclide-cfg-" & $getCurrentProcessId())
removeDir dir
createDir dir
let path = dir / "sub" / "settings.json"

suite "settings":
  test "missing file gives defaults":
    let s = loadSettings(path)
    check s.theme == "light" and s.nimPath == "nim" and s.editorFontSize == DefaultFontSize
    check s.recentProjects.len == 0 and s.layout == ""

  test "save and load":
    var s = defaultSettings()
    s.theme = "dark"
    s.editorFontSize = 16
    s.nimPath = "/usr/bin/nim"
    s.layout = "a|b\nc"
    s.addRecent("/p/one.nimproj")
    check saveSettings(s, path)
    check fileExists(path)
    let q = loadSettings(path)
    check q == s

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
    writeFile(path, """{"theme": 3, "editorFontSize": "big", "nimPath": "", "recentProjects": ["/a", 4, "/a", "/b"], "layout": "L"}""")
    let s = loadSettings(path)
    check s.theme == "light" and s.editorFontSize == DefaultFontSize and s.nimPath == "nim"
    check s.recentProjects == @["/a", "/b"]
    check s.layout == "L"

  test "unwritable location":
    check not saveSettings(defaultSettings(), "/proc/nope/settings.json")

removeDir dir
