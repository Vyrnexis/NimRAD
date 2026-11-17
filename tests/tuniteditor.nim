import std/[unittest, os, osproc, strutils, sequtils]
import nimvcl
import nimvcl/dsl/props
import nimvcl/controls/inspector
import ide/[project, builder, uniteditor, codegen]

let root = getTempDir() / ("nimvclide-unitedit-" & $getCurrentProcessId())
removeDir root
createDir root

Application.init()

proc newHost(): Form =
  result = newForm(nil, 1100, 700)
  result.show()
  result.syncMetrics()

proc ev(f: Form, kind: EventKind, p: PointF, clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: p.x, y: p.y,
                                     button: mbLeft, clicks: clicks, shift: shift))

proc click(f: Form, p: PointF, clicks = 1) =
  discard f.paintIfDirty()
  f.ev(ekMouseDown, p, clicks)
  f.ev(ekMouseUp, p, clicks)

proc center(c: Control): PointF =
  pointF(c.formOrigin.x + c.width / 2, c.formOrigin.y + c.height / 2)

proc find(e: UnitEditor, name: string): Control =
  for (c, _) in e.componentTree:
    if c.name == name and c of Control: return Control(c)

proc tileCenter(e: UnitEditor, i: int): PointF =
  let t = e.designer.nonVisuals[i]
  let o = e.designedForm.formOrigin
  pointF(o.x + t.left + t.width / 2, o.y + t.top + t.height / 2)

proc smoke(p: Project): tuple[output: string, exitCode: int] =
  execCmdEx("SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software " &
            quoteShell(p.exePath) & " --smoke 2>&1")

proc compiles(p: Project): bool =
  let r = p.compileProjectSync()
  if not r.ok: echo r.lines.join("\n")
  r.ok

type Rig = object
  host: Form
  proj: Project
  ed: UnitEditor
  insp: ObjectInspector

proc rig(name: string): Rig =
  result.proj = newApplicationProject(root / name, name)
  result.host = newHost()
  result.ed = newUnitEditor(result.proj, "unit1", result.host)
  result.insp = newObjectInspector(result.host)
  result.insp.align = alRight
  result.insp.width = 300
  result.ed.bindInspector(result.insp)
  discard result.host.paintIfDirty()

proc dropButton(r: Rig): Control =
  let body = r.ed.designedForm
  r.ed.beginCreate "Button"
  r.host.click(pointF(body.formOrigin.x + 40, body.formOrigin.y + 40))
  r.ed.find("Button1")

suite "unit editor":
  test "a form unit has both views, a plain unit only code":
    let r = rig("views")
    check r.ed.isForm
    check r.ed.designer != nil
    check r.ed.designedForm != nil
    check r.ed.designerVisible
    check r.ed.code.text.contains("loadForm Form1")
    check not r.ed.modified
    r.ed.toggleView()
    check not r.ed.designerVisible
    check r.ed.code.visible
    r.ed.toggleView()
    check r.ed.designerVisible
    check not r.ed.code.visible
    r.ed.showCode()
    check not r.ed.designerVisible
    r.ed.showDesigner()
    check r.ed.designerVisible
    # a plain unit
    writeFile(r.proj.dir / "util.nim", "proc twice*(x: int): int = x * 2\n")
    discard r.proj.addUnit("util", "util.nim")
    let u = newUnitEditor(r.proj, "util", r.host)
    check not u.isForm
    check u.designer == nil
    check u.designedForm == nil
    check not u.designerVisible
    check u.code.text.contains("twice")
    u.showDesigner()
    check not u.designerVisible

  test "drop a button, edit, double click, save, compile and run":
    let r = rig("app1")
    var sel = 0
    var mods = 0
    r.ed.onSelectionChanged = proc(e: UnitEditor) = inc sel
    r.ed.onModifiedChanged = proc(e: UnitEditor) = inc mods
    let b = r.dropButton()
    check b != nil
    check b.name == "Button1"
    check b of Button
    check r.ed.modified
    check mods >= 1
    check sel >= 1
    check r.ed.selection.len == 1
    check r.ed.selection[0] == Component(b)
    check r.insp.targets.len == 1
    # caption through the inspector
    check r.insp.setValue("caption", pvString("Go"))
    check b.caption == "Go"
    # double click: stub + code view
    r.host.click(b.center, 2)
    check r.ed.code.text.contains("proc Button1Click(self: Form1, sender: Control) =")
    check not r.ed.designerVisible
    check r.ed.code.caretLine > 0
    r.ed.save()
    check not r.ed.modified
    let nfm = readFile(r.proj.dir / "unit1.nfm")
    check nfm.contains("object Button1: Button")
    check nfm.contains("onClick = Button1Click")
    check nfm.contains("caption = 'Go'")
    check readFile(r.proj.dir / "unit1.nim").contains("proc Button1Click")
    check r.proj.compiles()
    let (o, c) = smoke(r.proj)
    check c == 0
    if c != 0: echo o

  test "rename a component updates the code and still compiles":
    let r = rig("app2")
    let b = r.dropButton()
    r.host.click(b.center, 2)           # stub Button1Click
    r.ed.showCode()
    # use the button in the handler
    r.ed.code.text = r.ed.code.text.replace("  discard\n", "  self.Button1.caption = \"x\"\n")
    r.ed.showDesigner()
    check r.insp.setValue("name", pvString("okButton"))
    check b.name == "okButton"
    check r.ed.code.text.contains("self.okButton.caption")
    check not r.ed.code.text.contains("Button1.caption")
    check r.ed.code.text.contains("proc Button1Click")      # handlers keep their names
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nfm").contains("object okButton: Button")
    check r.proj.compiles()
    # refused: duplicate, invalid, keyword
    r.ed.beginCreate "Edit"
    r.host.click(pointF(r.ed.designedForm.formOrigin.x + 40, r.ed.designedForm.formOrigin.y + 120))
    let e1 = r.ed.find("Edit1")
    check e1 != nil
    var msg = ""
    r.ed.onMessage = proc(e: UnitEditor, m: string) = msg = m
    discard r.insp.setValue("name", pvString("okButton"))
    check e1.name == "Edit1"
    check msg.contains("already used")
    discard r.insp.setValue("name", pvString("2bad"))
    check e1.name == "Edit1"
    check msg.contains("valid identifier")
    discard r.insp.setValue("name", pvString("proc"))
    check e1.name == "Edit1"

  test "copy and paste gives a unique name":
    let r = rig("app3")
    let b = r.dropButton()
    discard r.insp.setValue("caption", pvString("Copy me"))
    check r.ed.copySelection()
    check r.ed.paste()
    let sel = r.ed.selection
    check sel.len == 1
    check sel[0].name == "Button2"
    check Control(sel[0]).left == b.left + r.ed.designer.grid
    check Button(sel[0]).caption == "Copy me"
    check r.ed.paste()
    check r.ed.selection[0].name == "Button3"
    # cut removes, paste brings back
    r.ed.designer.select(Control(r.ed.find("Button2")))
    check r.ed.cutSelection()
    check r.ed.find("Button2") == nil
    check r.ed.paste()
    check r.ed.find("Button2") != nil
    # delete keeps handlers in the code
    r.ed.selectComponent(r.ed.find("Button1"))
    r.host.click(r.ed.find("Button1").center, 2)
    r.ed.showDesigner()
    r.ed.selectComponent(r.ed.find("Button1"))
    check r.ed.deleteSelection()
    check r.ed.find("Button1") == nil
    check r.ed.code.text.contains("proc Button1Click")
    check r.ed.undo()
    check r.ed.find("Button1") != nil

  test "non-visual components are tiles and survive a save":
    let r = rig("app4")
    r.ed.beginCreate "Timer"
    check r.ed.designer.nonVisuals.len == 1
    check r.ed.selection[0].name == "Timer1"
    r.ed.beginCreate "ImageList"
    check r.ed.designer.nonVisuals.len == 2
    # events: double click on a tile creates onTimer
    r.host.click(r.ed.tileCenter(0), 2)
    check r.ed.code.text.contains("proc Timer1Timer(self: Form1,")
    r.ed.save()
    let nfm = readFile(r.proj.dir / "unit1.nfm")
    check nfm.contains("object Timer1: Timer")
    check nfm.contains("onTimer = Timer1Timer")
    check nfm.contains("object ImageList1: ImageList")
    check r.proj.compiles()
    r.ed.reloadFromDisk()
    check r.ed.designer.nonVisuals.len == 2
    check r.ed.componentTree.anyIt(it[0].name == "Timer1")

  test "reloadFromDisk matches the files":
    let r = rig("app5")
    let b = r.dropButton()
    discard r.insp.setValue("caption", pvString("Saved"))
    r.ed.save()
    let before = readFile(r.proj.dir / "unit1.nfm")
    # more edits that are not saved
    discard r.insp.setValue("caption", pvString("Unsaved"))
    r.ed.beginCreate "Edit"
    r.host.click(pointF(r.ed.designedForm.formOrigin.x + 40, r.ed.designedForm.formOrigin.y + 120))
    r.ed.code.text = "# changed\n"
    check r.ed.modified
    r.ed.reloadFromDisk()
    check not r.ed.modified
    check r.ed.find("Edit1") == nil
    check Button(r.ed.find("Button1")).caption == "Saved"
    check r.ed.code.text.contains("loadForm Form1")
    check readFile(r.proj.dir / "unit1.nfm") == before
    r.ed.save()                       # nothing changed: files stay as they are
    check readFile(r.proj.dir / "unit1.nfm") == before

  test "the form itself: caption and size":
    let r = rig("app6")
    r.ed.designer.select(Control(r.ed.designedForm))
    check r.ed.selection[0].name == "Form1"
    check r.insp.setValue("caption", pvString("Hello"))
    check r.insp.setValue("width", pvFloat(500))
    check r.ed.designedForm.width == 500
    r.ed.save()
    let nfm = readFile(r.proj.dir / "unit1.nfm")
    check nfm.contains("caption = 'Hello'")
    check nfm.contains("width = 500")
    # a form handler
    r.insp.tab = itEvents
    r.insp.selectProp("onShow")
    r.insp.dispatchDouble(r.insp.indexOfProp("onShow"))
    check r.ed.code.text.contains("proc FormShow(self: Form1, sender: Control) =")
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nfm").contains("onShow = FormShow")
    check r.proj.compiles()

  test "line endings are preserved":
    let r = rig("app7")
    let nfm = readFile(r.proj.dir / "unit1.nfm").replace("\n", "\r\n")
    let nim = readFile(r.proj.dir / "unit1.nim").replace("\n", "\r\n")
    writeFile(r.proj.dir / "unit1.nfm", nfm)
    writeFile(r.proj.dir / "unit1.nim", nim)
    r.ed.reloadFromDisk()
    discard r.dropButton()
    r.host.click(r.ed.find("Button1").center, 2)
    r.ed.save()
    let n2 = readFile(r.proj.dir / "unit1.nfm")
    check "\r\n" in n2
    check not n2.replace("\r\n", "").contains("\n")
    let c2 = readFile(r.proj.dir / "unit1.nim")
    check "\r\n" in c2
    check not c2.replace("\r\n", "").contains("\n")
    check c2.contains("Button1Click")

  test "gotoLine is 1-based and shows the code":
    let r = rig("app8")
    r.ed.gotoLine(3, 1)
    check not r.ed.designerVisible
    check r.ed.code.caretLine == 2
    check r.ed.code.caretCol == 0

  test "a broken form leaves the code view":
    let p = newApplicationProject(root / "broken", "broken")
    writeFile(p.dir / "unit1.nfm", "object Form1: Form\n  nonsense = 1\nend\n")
    let h = newHost()
    let e = newUnitEditor(p, "unit1", h)
    check e.loadError.len > 0
    check e.designer == nil
    check e.code.visible
    e.save()                          # does not touch the .nfm
    check readFile(p.dir / "unit1.nfm").contains("nonsense")
