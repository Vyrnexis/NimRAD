## The component palette's search: the filter edit, the flat results group,
## the keyboard (Down / Up / Enter / Esc, the shortcut) and the drop onto the
## form.
import std/[unittest, os, strutils]
import nimvcl
import ide/[mainform, session, palette, actions, uniteditor, project]

if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
putEnv("SDL_RENDER_DRIVER", "software")

let root = getTempDir() / ("nimrad-palette-" & $getCurrentProcessId())
removeDir root
createDir root

Application.init()
let ide = newIdeForm(settingsFile = root / "settings.json")
ide.showWindow(1360, 860)
let pal = ide.palette

proc filterWith(text: string) =
  pal.filter.text = text
  pal.applyFilter()
  ide.settle

suite "palette search":
  test "typing filters across all tabs, case-insensitive, as one group":
    check not pal.filtering
    check pal.root.visible
    filterWith "BUT"
    check pal.filtering
    check not pal.root.visible
    check pal.matches == @["Button", "RadioButton"]
    filterWith "grid"
    check pal.matches == @["StringGrid", "DrawGrid"]       # from the Additional tab
    filterWith "timer"
    check pal.matches == @["Timer"]                        # from the System tab
    filterWith "zzz"
    check pal.matches.len == 0

  test "a word that is not in the class name finds the class":
    filterWith "tabs"
    check pal.matches == @["PageControl"]
    filterWith "multiline"
    check pal.matches == @["Memo"]
    filterWith "interval"
    check pal.matches == @["Timer"]
    filterWith "text box"
    check pal.matches == @["Edit", "Memo"]
    pal.clearFilter()

  test "clearing restores the tabs as they were" :
    pal.root.activePageIndex = 1
    filterWith "label"
    check pal.matches == @["Label"]
    check pal.root.activePageIndex == 1
    pal.clearFilter()
    ide.settle
    check not pal.filtering
    check pal.root.visible
    check pal.root.activePageIndex == 1
    check pal.root.pageCount == 4
    pal.root.activePageIndex = 0

  test "the highlight moves with Down and Up and wraps":
    filterWith "but"
    check pal.highlighted == "Button"
    ide.activeControl = pal.filter
    ide.pressKey(keyDown)
    check pal.highlighted == "RadioButton"
    ide.pressKey(keyDown)
    check pal.highlighted == "Button"
    ide.pressKey(keyUp)
    check pal.highlighted == "RadioButton"
    pal.clearFilter()

  test "the shortcut focuses the filter; Esc clears it and leaves":
    check ide.acts[aFindComponent].shortcut == shortcut("Ctrl+Alt+C")
    ide.activeControl = nil
    ide.pressKey(Key(ord('c')), {ssCtrl, ssAlt})
    check ide.activeControl == Control(pal.filter)
    ide.typeText "mem"
    check pal.matches == @["Memo"]
    ide.pressKey(keyEscape)
    check pal.filter.text == ""
    check not pal.filtering
    check ide.activeControl == nil

  test "Enter drops the highlighted component onto the form; the .nfm has it":
    check ide.newApplication(root / "Project1", "Project1")
    let ed = ide.activeEditor
    check ed.designedForm.children.len == 0
    ide.pressKey(Key(ord('c')), {ssCtrl, ssAlt})
    ide.typeText "button"
    ide.pressKey(keyEnter)
    check ed.designedForm.children.len == 1
    check ed.designedForm.children[0].name == "Button1"
    check ed.selection.len == 1
    check pal.filter.text == ""
    check not pal.filtering
    check pal.picked == ""
    ide.saveAll()
    check "object Button1: Button" in readFile(ide.project.dir / "unit1.nfm")

  test "a selected container receives the component":
    let ed = ide.activeEditor
    check ide.dropComponent("Panel")          # selected after the drop
    let panel = Container(ed.designedForm.children[1])
    check panel.name == "Panel1"
    check ide.dropComponent("Label")
    check panel.children.len == 1
    check panel.children[0].name == "Label1"
    ed.designer.select(ed.designedForm.children[0])   # Button1, in the form
    check ide.dropComponent("CheckBox")
    check panel.children.len == 1
    check ed.designedForm.children.len == 3

  test "a non-visual class becomes a tile":
    check ide.dropComponent("Timer")
    ide.saveAll()
    check "object Timer1: Timer" in readFile(ide.project.dir / "unit1.nfm")
