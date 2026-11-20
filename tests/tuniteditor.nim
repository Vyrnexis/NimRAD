import std/[unittest, os, osproc, strutils, sequtils]
import headless
import nimvcl
import nimvcl/dsl/[props, props_std]
import nimvcl/controls/inspector
import ide/[project, builder, uniteditor, codegen]

let root = getTempDir() / ("nimrad-unitedit-" & $getCurrentProcessId())
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
  headlessCmd(quoteShell(p.exePath) & " --smoke")

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

proc keepHandler(r: Rig) =
  ## Puts a line of the user's into the handler the caret is in (a handler that
  ## is still the bare stub is removed on save).
  discard r.ed.code.insertAt((r.ed.code.caretLine, 2), "# mine\n  ")

suite "unit editor":
  test "a unit that cannot be written stays modified":
    let r = rig("savefail")
    let path = r.proj.dir / "util.nim"
    writeFile(path, "var x = 1\n")
    discard r.proj.addUnit("util", "util.nim")
    let u = newUnitEditor(r.proj, "util", r.host)
    discard u.code.model.replace((0, 8), (0, 9), "2")
    check u.modified
    removeFile path
    createDir path                    # a directory in the way: the rename fails
    expect CatchableError: u.save()
    check u.modified
    check u.code.fileName == path
    removeDir path
    u.save()
    check not u.modified
    check readFile(path) == "var x = 2\n"

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
    r.keepHandler()
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
    check not r.insp.setValue("name", pvString("okButton"))
    check e1.name == "Edit1"
    check r.insp.lastError.contains("already used")
    check not r.insp.setValue("name", pvString("2bad"))
    check e1.name == "Edit1"
    check r.insp.lastError.contains("valid identifier")
    check not r.insp.setValue("name", pvString("proc"))
    check e1.name == "Edit1"
    check r.insp.setValue("name", pvString("Edit9"))
    check e1.name == "Edit9"
    check r.insp.lastError == ""

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
    r.keepHandler()
    r.ed.save()
    let nfm = readFile(r.proj.dir / "unit1.nfm")
    check nfm.contains("object Timer1: Timer")
    check nfm.contains("onTimer = Timer1Timer")
    check nfm.contains("object ImageList1: ImageList")
    check r.proj.compiles()
    r.ed.reloadFromDisk()
    check r.ed.designer.nonVisuals.len == 2
    check r.ed.componentTree.anyIt(it[0].name == "Timer1")

  test "closing the editor stops the form's timers":
    let r = rig("appTimer")
    r.ed.beginCreate "Timer"
    var t: Timer
    for (c, _) in r.ed.componentTree:
      if c of Timer: t = Timer(c)
    check t != nil
    t.enabled = true
    r.ed.dispose()
    check not t.enabled

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
    r.keepHandler()
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nfm").contains("onShow = FormShow")
    check r.proj.compiles()

  test "resizing the design root resizes the form and its frame":
    let r = rig("app6b")
    let body = r.ed.designedForm
    let frame = body.parent
    body.setBounds(body.left, body.top, 420, 260)
    check frame.width > 420 and frame.height > 260
    r.ed.save()
    let nfm = readFile(r.proj.dir / "unit1.nfm")
    check nfm.contains("width = 420")
    check nfm.contains("height = 260")

  test "line endings are preserved":
    let r = rig("app7")
    let nfm = readFile(r.proj.dir / "unit1.nfm").replace("\n", "\r\n")
    let nim = readFile(r.proj.dir / "unit1.nim").replace("\n", "\r\n")
    writeFile(r.proj.dir / "unit1.nfm", nfm)
    writeFile(r.proj.dir / "unit1.nim", nim)
    r.ed.reloadFromDisk()
    discard r.dropButton()
    r.host.click(r.ed.find("Button1").center, 2)
    r.keepHandler()
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

  test "double click makes the default event of the class":
    let r = rig("defev")
    r.ed.beginCreate "Edit"
    let body = r.ed.designedForm
    r.host.click(pointF(body.formOrigin.x + 40, body.formOrigin.y + 40))
    let edit = r.ed.find("Edit1")
    check edit != nil
    r.host.click(edit.center, 2)
    check r.ed.code.text.contains("proc Edit1Change(self: Form1, sender: Control) =")
    check not r.ed.code.text.contains("Edit1Click")
    check defaultEvent(r.ed.componentTree[0][0]) == "onShow"     # the form
    check defaultEvent(newCheckBox(nil, "x")) == "onChange"
    check defaultEvent(newButton(nil, "x")) == "onClick"
    check defaultEvent(newTimer(nil)) == "onTimer"

  test "save removes a handler that is still the generated stub":
    let r = rig("emptyh")
    let b = r.dropButton()
    r.host.click(b.center, 2)
    check r.ed.code.text.contains("proc Button1Click")
    r.ed.save()
    check not readFile(r.proj.dir / "unit1.nim").contains("Button1Click")
    check not readFile(r.proj.dir / "unit1.nfm").contains("onClick")
    check handlerNameOf(Obj(b), "onClick") == ""
    check not r.ed.modified
    check r.proj.compiles()

  test "save keeps a handler with content and one that other code calls":
    let r = rig("emptyh2")
    let b = r.dropButton()
    r.host.click(b.center, 2)
    r.keepHandler()
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nim").contains("proc Button1Click")
    check readFile(r.proj.dir / "unit1.nfm").contains("onClick = Button1Click")
    # a second button sharing an empty handler with code that calls it
    r.ed.beginCreate "Button"
    let body = r.ed.designedForm
    r.host.click(pointF(body.formOrigin.x + 40, body.formOrigin.y + 120))
    let b2 = r.ed.find("Button2")
    check b2 != nil
    r.host.click(b2.center, 2)
    let last = r.ed.code.lineCount - 1
    discard r.ed.code.insertAt((last, r.ed.code.lineAt(last).len),
                               "\nproc other(self: Form1) =\n  Button2Click(self, nil)\n")
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nim").contains("proc Button2Click")
    check readFile(r.proj.dir / "unit1.nfm").contains("onClick = Button2Click")

  test "a handler stub is one undo step and the caret stays":
    let r = rig("undo1")
    let b = r.dropButton()
    let before = r.ed.code.text
    r.ed.showCode()
    r.ed.code.gotoLine(0, 3)
    r.ed.showDesigner()
    r.host.click(b.center, 2)           # inserts proc Button1Click
    check r.ed.code.text.contains("proc Button1Click")
    r.ed.code.undo()
    check r.ed.code.text == before
    check r.ed.code.caretLine == 0
    check r.ed.code.caretCol == 3

  test "imports follow a .nfm edited outside the designer, on open and on reload":
    let r = rig("imp1")
    check not r.ed.code.text.contains("controls/button")
    r.ed.save()
    let nfm = r.proj.dir / "unit1.nfm"
    var text = readFile(nfm)
    text = text.replace("\nend", "\n  object Button1: Button\n  end\nend")
    writeFile(nfm, text)
    r.ed.reloadFromDisk()
    check r.ed.code.text.contains("import nimvcl/controls/button")
    check r.ed.modified
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nim").contains("import nimvcl/controls/button")
    # opening the unit picks it up as well (the .nim on disk lacks the import)
    var nim = readFile(r.proj.dir / "unit1.nim").replace("import nimvcl/controls/button\n", "")
    writeFile(r.proj.dir / "unit1.nim", nim)
    let e2 = newUnitEditor(r.proj, "unit1", r.host)
    check e2.code.text.contains("import nimvcl/controls/button")

suite "renaming a handler in the Object Inspector":
  test "the proc follows the new name; a handler another event uses is not renamed":
    let r = rig("apphrename")
    let b = r.dropButton()
    r.host.click(b.center, 2)           # stub Button1Click
    r.ed.showCode()
    r.ed.code.text = r.ed.code.text.replace("  discard\n", "  self.Button1.caption = \"x\"\n")
    r.ed.showDesigner()
    r.ed.selectComponent(Component(b))
    r.insp.tab = itEvents
    check r.insp.setValue("onClick", pvEvent("OkClick"))
    let code = r.ed.code.text
    check "proc OkClick(self: Form1, sender: Control) =" in code
    check "proc Button1Click" notin code
    check code.count("proc OkClick") == 1
    check "self.Button1.caption = \"x\"" in code            # the body came along
    # a second button shares the handler; renaming the first one's leaves the shared proc
    r.ed.beginCreate "Button"
    r.host.click(pointF(r.ed.designedForm.formOrigin.x + 40, r.ed.designedForm.formOrigin.y + 120))
    let b2 = r.ed.find("Button2")
    r.ed.selectComponent(Component(b2))
    check r.insp.setValue("onClick", pvEvent("OkClick"))
    check r.ed.code.text.count("proc OkClick") == 1             # it exists: nothing is made
    r.ed.selectComponent(Component(b))
    check r.insp.setValue("onClick", pvEvent("Other"))
    check "proc OkClick(self: Form1, sender: Control) =" in r.ed.code.text
    check "proc Other(self: Form1, sender: Control) =" in r.ed.code.text
    r.ed.save()
    check r.proj.compiles()

suite "a form with a component class of the project":
  test "the unit imports the unit that defines it, and the program builds and runs":
    let p = newApplicationProject(root / "custom", "custom")
    let dir = p.dir
    writeFile(dir / "badge.nim", """## badge
import nimvcl
import nimvcl/dsl/[props, props_std]

type Badge* = ref object of Panel
  fLevel: int
proc level*(b: Badge): int = b.fLevel
proc `level=`*(b: Badge, v: int) = b.fLevel = v
proc newBadge*(parent: Container = nil): Badge =
  new result
  result.initPanel(parent)
  if parent != nil: parent.insertControl result

registerClass(Badge, parent = Panel):
  category Data:
    level: int
""")
    discard p.addUnit("badge", "badge.nim")
    p.save()
    writeFile(dir / "unit1.nfm", """object Form1: Form
  width = 640
  height = 480
  caption = 'Form1'
  object Badge1: Badge
    left = 10
    top = 10
    width = 80
    height = 30
    level = 3
  end
end
""")
    let host = newHost()
    let e = newUnitEditor(p, "unit1", host)
    # the IDE does not know the class, so the designer cannot show the form ...
    check e.loadError.len > 0 and e.designer == nil
    # ... but the unit has what the compiler needs
    check "import badge\n" in e.code.text
    check "import nimvcl/controls/panel" notin e.code.text
    e.save()
    check "import badge\n" in readFile(dir / "unit1.nim")
    check p.compiles()
    let sm = p.smoke()
    if sm.exitCode != 0: echo sm.output
    check sm.exitCode == 0
    # the object goes: the import goes with it
    writeFile(dir / "unit1.nfm", "object Form1: Form\n  width = 640\n  height = 480\n  caption = 'Form1'\nend\n")
    e.reloadFromDisk()
    check "import badge" notin e.code.text

removeDir root                           # the projects built here are large
