## Project fonts: Project > Add Font File copies the file into <project>/fonts,
## records it in the .nimproj, the main file registers it at compile time; the
## built program smoke-runs with a label using the family; the Object
## Inspector offers Bundled / Project / System families.
import std/[unittest, os, strutils, json, sequtils]
import nimvcl
import nimvcl/controls/inspector
import ide/[mainform, session, project, builder, mainfile, uniteditor]

if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
putEnv("SDL_RENDER_DRIVER", "software")

let root = getTempDir() / ("nimvclide-fonts-" & $getCurrentProcessId())
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
    u = u.replace("# nimvcl-ide: imports begin\n", "# nimvcl-ide: imports begin\nimport nimvcl/controls/label\n")
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
    let src = "import x\n# nimvcl-ide: imports begin\nimport u\n# nimvcl-ide: imports end\nmain()\n"
    let t = setFonts(src, @["import a", "reg()"])
    check t == "import x\n# nimvcl-ide: imports begin\nimport u\n# nimvcl-ide: imports end\n" &
               "# nimvcl-ide: fonts begin\nimport a\nreg()\n# nimvcl-ide: fonts end\nmain()\n"
    check setFonts(t, @[]) == src.replace("main()", "# nimvcl-ide: fonts begin\n# nimvcl-ide: fonts end\nmain()")
    check setFonts(src, @[]) == src

removeDir root
