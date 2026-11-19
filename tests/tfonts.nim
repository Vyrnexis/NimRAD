## Project fonts: Project > Add Font File copies the file into <project>/fonts,
## records it in the .nimproj, the main file registers it at compile time; the
## built program smoke-runs with a label using the family; the Object
## Inspector offers Bundled / Project / System families.
import std/[unittest, os, strutils, json, sequtils]
import nimvcl
import nimvcl/controls/inspector
import ide/[mainform, session, project, builder, mainfile, uniteditor, actions, idedialogs]

if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
putEnv("SDL_RENDER_DRIVER", "software")

let root = getTempDir() / ("nimrad-fonts-" & $getCurrentProcessId())
removeDir root
createDir root

# an existing font file of nimvcl serves as the "project font"
let srcFont = currentSourcePath().parentDir.parentDir.parentDir / "nimvcl" / "src" / "nimvcl" / "assets" /
              "fonts" / "NotoSansMono-Regular.ttf"
doAssert fileExists(srcFont)

Application.init()
let ide = newIdeForm(settingsFile = root / "settings.json")
ide.showWindow(1360, 860)
var errors: seq[string]
ide.showError = proc(text: string) = errors.add text

suite "project fonts":
  test "a project to work in":
    check ide.newApplication(root / "fontapp", "FontApp")
    check ide.project != nil
    check "fonts begin" in readFile(ide.project.mainPath)

  test "Add Font File copies, records and registers the font":
    check ide.addFontFile(srcFont)
    check errors.len == 0
    let p = ide.project
    check fileExists(p.dir / "fonts" / "NotoSansMono-Regular.ttf")
    check p.fonts.len == 1
    check p.fonts[0].file == "fonts/NotoSansMono-Regular.ttf"
    check p.fonts[0].family == "Noto Sans Mono"
    check p.fonts[0].style == "regular"
    let j = parseJson(readFile(p.filePath))
    check j["fonts"][0]["file"].getStr == "fonts/NotoSansMono-Regular.ttf"
    check j["fonts"][0]["family"].getStr == "Noto Sans Mono"
    let m = readFile(p.mainPath)
    check "const projectFont1Regular = staticRead(\"fonts/NotoSansMono-Regular.ttf\")" in m
    check "registerFontFamilyData(\"Noto Sans Mono\", projectFont1Regular)" in m
    check m.find("fonts begin") < m.find("registerFontFamilyData") and
          m.find("registerFontFamilyData") < m.find("fonts end")
    check fontSource(font("Noto Sans Mono")) == "registered"
    check loadProject(p.filePath).fonts == p.fonts
    # adding the same file again changes nothing
    check ide.addFontFile(srcFont)
    check p.fonts.len == 1
    check readFile(p.mainPath).count("registerFontFamilyData(") == 1
    check readFile(p.mainPath).count("staticRead(") == 1

  test "a bad file is refused":
    writeFile(root / "notafont.ttf", "garbage")
    check not ide.addFontFile(root / "notafont.ttf")
    check not ide.addFontFile(root / "x.txt")
    check errors.len == 2
    check ide.project.fonts.len == 1

  test "the Inspector offers Bundled, Project and System families":
    let ed = ide.activeEditor
    check ed != nil
    ide.inspector.inspect(ed.designedForm)
    let items = ide.inspector.fontFamilyItems
    check items[0] == FontGroupBundled
    check "sans" in items and "mono" in items
    let pi = items.find(FontGroupProject)
    check pi > 0
    check items[pi + 1] == "Noto Sans Mono"
    if systemFontFamilies().len > 0:
      check items.find(FontGroupSystem) > pi
      check items[^1] != "Noto Sans Mono"

  test "the built program uses the project font and smoke-runs":
    let p = ide.project
    writeFile(p.dir / "unit1.nfm", """object Form1: Form
  width = 640
  height = 480
  caption = 'Form1'
  object Label1: Label
    left = 20
    top = 20
    caption = 'Project font'
    font.family = 'Noto Sans Mono'
  end
end
""")
    var u = readFile(p.dir / "unit1.nim")
    u = u.replace("# nimrad: imports begin\n", "# nimrad: imports begin\nimport nimvcl/controls/label\n")
    writeFile(p.dir / "unit1.nim", u)
    # the embedded copy must work without the fonts folder at run time
    let res = p.compileProjectSync()
    if not res.ok: echo res.lines.join("\n")
    check res.ok
    let r = runCapture(exePath(p), @["--smoke"], p.dir)
    check r.exitCode == 0
    removeDir p.dir / "fonts"
    let r2 = runCapture(exePath(p), @["--smoke"], p.dir)
    check r2.exitCode == 0

  test "main file without the fonts block gets one":
    let src = "import x\n# nimrad: imports begin\nimport u\n# nimrad: imports end\nmain()\n"
    let t = setFonts(src, @["import a", "reg()"])
    check t == "import x\n# nimrad: imports begin\nimport u\n# nimrad: imports end\n" &
               "# nimrad: fonts begin\nimport a\nreg()\n# nimrad: fonts end\nmain()\n"
    check setFonts(t, @[]) == src.replace("main()", "# nimrad: fonts begin\n# nimrad: fonts end\nmain()")
    check setFonts(src, @[]) == src

suite "removing a font":
  test "the choice list is the confirmation; cancelling changes nothing":
    let p = ide.project
    check ide.addFontFile(srcFont)
    check p.fonts.len == 1 and fileExists(p.dir / "fonts" / "NotoSansMono-Regular.ttf")
    ide.refreshActions()
    check ide.acts[aRemoveFont].enabled
    var offered: seq[string]
    var title = ""
    ide.pickItem = proc(t: string, items: seq[string], selected: int): int =
      title = t
      offered = items
      -1
    check not ide.removeFont()
    check offered == @["Noto Sans Mono (regular)  fonts/NotoSansMono-Regular.ttf"]
    check "deletes" in title
    check p.fonts.len == 1 and fileExists(p.dir / "fonts" / "NotoSansMono-Regular.ttf")
    check "registerFontFamilyData(" in readFile(p.mainPath)

  test "Remove Font takes it out of the project, the main file and the folder":
    let p = ide.project
    ide.pickItem = proc(t: string, items: seq[string], selected: int): int = 0
    check ide.removeFont()
    check p.fonts.len == 0 and p.fontFamilies.len == 0
    check not fileExists(p.dir / "fonts" / "NotoSansMono-Regular.ttf")
    check not dirExists(p.dir / "fonts")
    let m = readFile(p.mainPath)
    check "registerFontFamilyData" notin m and "staticRead" notin m
    check "fonts begin" in m and "fonts end" in m            # the markers stay for the next font
    check loadProject(p.filePath).fonts.len == 0
    ide.refreshActions()
    check not ide.acts[aRemoveFont].enabled
    check "Removed font Noto Sans Mono" in ide.status.panels[4].text
    check errors.len == 2                                    # only the two refusals from before
    check "noto sans mono" notin registeredFontFamilies()    # unregistered in this session too

  test "without fonts there is nothing to remove":
    check not ide.removeFont()
    check "no fonts" in ide.status.panels[4].text

  test "a font that is not in the project is refused":
    let n = errors.len
    check ide.addFontFile(srcFont)
    check not ide.removeFont("fonts/Nope.ttf")
    check errors.len == n + 1
    check ide.project.fonts.len == 1

  test "the project model: a shared file stays, a file outside the folder stays":
    let p = ide.project
    p.fonts.add ProjectFont(file: "fonts/NotoSansMono-Regular.ttf", family: "Other", style: "bold")
    writeFile(p.dir / "elsewhere.ttf", "x")
    p.fonts.add ProjectFont(file: "elsewhere.ttf", family: "Else", style: "regular")
    discard p.removeFont("fonts/NotoSansMono-Regular.ttf")     # one of two entries with that file
    check fileExists(p.dir / "fonts" / "NotoSansMono-Regular.ttf")
    discard p.removeFont("elsewhere.ttf")
    check fileExists(p.dir / "elsewhere.ttf")
    expect ProjectError: discard p.removeFont("elsewhere.ttf")
    discard p.removeFont("fonts/NotoSansMono-Regular.ttf")     # the last one
    check not fileExists(p.dir / "fonts" / "NotoSansMono-Regular.ttf")
    check p.fonts.len == 0

  test "the project builds without the font":
    ide.pickItem = pickItemDefault
    ide.project.syncFontsBlock()                 # the model-only removal above left the block
    check "staticRead" notin readFile(ide.project.mainPath)
    let r = ide.project.compileProjectSync()
    if not r.ok: echo r.lines.join("\n")
    check r.ok

  test "closing the project unregisters its fonts":
    check ide.addFontFile(srcFont)
    check "noto sans mono" in registeredFontFamilies()
    check ide.closeProject()
    check "noto sans mono" notin registeredFontFamilies()

removeDir root
