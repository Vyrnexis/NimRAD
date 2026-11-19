## Makes the pictures of README.md, docs/user-guide.md and docs/tutorial.md.
##
##     SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software \
##       nim c -r scripts/docshots.nim docs/images
##
## The IDE is driven headless through simulated mouse and keyboard events (the
## helpers of `src/ide/session.nim`); nothing opens a window.

import std/[os, strutils]
import nimvcl
import nimvcl/dsl/props
import nimvcl/controls/inspector
import ../src/ide/[mainform, session, uniteditor, project, palette, messagespanel]

proc compName(ed: UnitEditor, cls: string): Component =
  for (c, _) in ed.componentTree:
    if c.name == cls: return c

proc place(ide: IdeForm, ed: UnitEditor, cls: string, x, y: float) =
  ide.click ide.palette.buttonRect(cls).center
  ide.click ed.designedForm.clientToForm(pointF(x, y))

proc pick(ide: IdeForm, ed: UnitEditor, name: string) =
  ed.designer.select(Control(ed.compName(name)))
  ide.settle

proc setp(ide: IdeForm, prop: string, v: PropValue) =
  doAssert ide.inspector.setValue(prop, v), "cannot set " & prop
  ide.settle

proc shot(ide: IdeForm, dir, name: string) =
  ide.shoot(dir / (name & ".png"))
  echo "wrote ", dir / (name & ".png")

proc main() =
  let dir = if paramCount() >= 1: paramStr(1) else: "docs/images"
  createDir dir
  let work = getTempDir() / ("nimrad-docshots-" & $getCurrentProcessId())
  removeDir work
  createDir work
  Application.init()
  let ide = newIdeForm(settingsFile = work / "settings.json")
  ide.showWindow(1360, 860)
  ide.settings.editorFontSize = 15

  # ------------------------------------------------------------ tutorial
  doAssert ide.newApplication(work / "FirstApp", "FirstApp")
  var ed = ide.activeEditor
  ide.place ed, "Label", 40, 30
  ide.place ed, "Edit", 40, 80
  ide.place ed, "Button", 40, 130
  ide.pick ed, "Button1"
  ide.setp "caption", pvString("Copy")
  ide.pick ed, "Label1"
  ide.setp "caption", pvString("(nothing yet)")
  ide.pick ed, "Edit1"
  ide.setp "text", pvString("Hello, world")
  ide.pick ed, "Button1"
  ide.shot dir, "tutorial-1-properties"
  ide.doubleClick Control(ed.compName("Button1")).controlCenter
  ide.activeControl = ed.code
  let line = ed.code.caretPos.line
  let l = ed.code.lineAt(line)
  ed.code.select((line, l.len - l.strip(trailing = false).len), (line, l.len))
  ide.typeText "self.Label1.caption = self.Edit1.text"
  ide.shot dir, "tutorial-2-code"
  doAssert ide.compile() and ide.waitIdle(180) and ide.lastBuildOk
  ide.shot dir, "tutorial-3-built"

  # the running program: the same controls in a window of their own
  let app = newForm(nil, 360, 220)
  app.caption = "Form1"
  app.position = poScreenCenter
  let lab = newLabel(app, "Hello, world", 40, 30, 200)
  discard lab
  let edt = newEdit(app, "", 40, 80, 200)
  edt.text = "Hello, world"
  discard newButton(app, "Copy", 40, 130, 100, 32)
  app.show()
  app.syncMetrics()
  discard app.paintIfDirty()
  Application.paintForms()
  doAssert screenshotWithPopups(app, dir / "tutorial-4-running.png")
  echo "wrote ", dir / "tutorial-4-running.png"
  app.freeWindow()

  # ------------------------------------------------------------ README
  doAssert ide.newApplication(work / "Colours", "Colours")
  ed = ide.activeEditor
  ide.place ed, "Panel", 24, 24
  ide.pick ed, "Panel1"
  ide.setp "width", pvInt(330)
  ide.setp "height", pvInt(150)
  ide.setp "color", pvColor(hex"#2f6f9f")
  ide.place ed, "Label", 400, 30
  ide.place ed, "Label", 400, 70
  ide.place ed, "Edit", 400, 110
  ide.place ed, "Button", 400, 160
  ide.pick ed, "Label1"
  ide.setp "caption", pvString("Red caption")
  ide.inspector.setExpanded("font", true)
  ide.setp "font.color", pvColor(hex"#c0392b")
  ide.pick ed, "Label2"
  ide.setp "caption", pvString("Green caption")
  ide.setp "font.color", pvColor(hex"#1e8449")
  ide.pick ed, "Button1"
  ide.setp "caption", pvString("OK")
  ide.setp "color", pvColor(hex"#f5b041")
  ide.pick ed, "Panel1"
  ide.shot dir, "ide-designer"

  ide.setDark(true)
  ide.shot dir, "ide-dark"
  ide.setDark(false)

  # palette search
  ide.palette.focusFilter()
  ide.typeText "grid"
  ide.shot dir, "ide-palette-search"
  ide.palette.clearFilter()

  # an inherited form
  ide.saveAll()
  doAssert ide.newInheritedForm("unit1") != nil
  ed = ide.activeEditor
  ide.place ed, "CheckBox", 400, 220
  ide.pick ed, "Button1"
  ide.shot dir, "ide-inherited"

  # code and a successful build
  ed = ide.openUnit("unit1")
  ide.pick ed, "Button1"
  ide.doubleClick Control(ed.compName("Button1")).controlCenter
  ide.activeControl = ed.code
  let ln = ed.code.caretPos.line
  let ll = ed.code.lineAt(ln)
  ed.code.select((ln, ll.len - ll.strip(trailing = false).len), (ln, ll.len))
  ide.typeText "self.Label1.caption = \"Clicked\""
  doAssert ide.compile() and ide.waitIdle(180) and ide.lastBuildOk
  ide.shot dir, "ide-code-build"

  # a compile error and the jump to it
  ed.showCode()
  ide.activeControl = ed.code
  ed.code.caretPos = (ed.code.lineCount - 1, 0)
  ide.typeText "\nlet broken: int = \"oops\"\n"
  doAssert ide.compile() and ide.waitIdle(180)
  ide.shot dir, "ide-compile-error"

  Application.shutdown()
  removeDir work

main()
