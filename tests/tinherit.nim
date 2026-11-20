## Visual form inheritance in the IDE: File > New Inherited Form (the project
## side and the unit editor), inherited components in the designer, saving only
## the differences, building and smoke-running the project, and a changed
## ancestor showing up in the descendant without any copy.
import std/[unittest, os, osproc, strutils, sequtils]
import headless
import nimvcl
import nimvcl/dsl/props
import nimvcl/controls/inspector
import ide/[project, builder, uniteditor, mainform, actions, session]

if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
putEnv("SDL_RENDER_DRIVER", "software")

let root = getTempDir() / ("nimrad-inherit-" & $getCurrentProcessId())
removeDir root
createDir root

Application.init()

proc newHost(): Form =
  result = newForm(nil, 1100, 700)
  result.show()
  result.syncMetrics()

proc ev(f: Form, kind: EventKind, p: PointF, clicks = 1) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: p.x, y: p.y,
                                     button: mbLeft, clicks: clicks))

proc click(f: Form, p: PointF) =
  discard f.paintIfDirty()
  f.ev(ekMouseDown, p)
  f.ev(ekMouseUp, p)

proc find(e: UnitEditor, name: string): Control =
  for (c, _) in e.componentTree:
    if c.name == name and c of Control: return Control(c)

proc smoke(p: Project): tuple[output: string, exitCode: int] =
  headlessCmd(quoteShell(p.exePath) & " --smoke")

proc compiles(p: Project): bool =
  let r = p.compileProjectSync()
  if not r.ok: echo r.lines.join("\n")
  r.ok

let host = newHost()
let insp = newObjectInspector(host)
insp.align = alRight
insp.width = 300

var proj: Project

suite "inherited forms in the IDE":
  test "an ancestor with a button; the project model creates the descendant":
    proj = newApplicationProject(root / "app", "app")
    let e1 = newUnitEditor(proj, "unit1", host)
    e1.beginCreate "Button"
    let body = e1.designedForm
    host.click(pointF(body.formOrigin.x + 40, body.formOrigin.y + 40))
    check e1.find("Button1") != nil
    e1.save()
    check "object Button1: Button" in readFile(root / "app" / "unit1.nfm")
    let u = proj.newInheritedFormUnit("unit1")
    check u.name == "unit2" and u.formType == "Form2" and u.ancestor == "unit1"
    check readFile(root / "app" / "unit2.nfm") ==
          "inherited Form2: Form2\n  ancestor = 'unit1.nfm'\nend\n"
    let nim = readFile(root / "app" / "unit2.nim")
    check "import unit1\n" in nim and "loadForm Form2, \"unit2.nfm\"" in nim
    check "import unit2\n" in readFile(root / "app" / "app.nim")
    proj.save()
    check loadProject(proj.filePath).units[1].ancestor == "unit1"
    check proj.descendantsOf("unit1") == @["unit2"]
    check proj.formUnits.len == 2
    # it builds and runs as it is
    check proj.compiles()
    check proj.smoke().exitCode == 0

  test "the ancestor cannot be removed while a form inherits from it":
    expect ProjectError: proj.removeUnit("unit1")

  test "inherited components: cannot be deleted or renamed, can be edited; new ones can be added":
    let e2 = newUnitEditor(proj, "unit2", host)
    check e2.loadError == ""
    e2.bindInspector(insp)
    let b = e2.find("Button1")
    check b != nil and b.inherited
    e2.selectComponent(b)
    check not e2.deleteSelection()
    check e2.find("Button1") != nil
    insp.setValue("name", pvString("Renamed"))
    check b.name == "Button1"
    check "ancestor" in insp.lastError
    insp.setValue("caption", pvString("Hello"))
    check Button(b).caption == "Hello"
    # a new control
    e2.beginCreate "Label"
    let body = e2.designedForm
    host.click(pointF(body.formOrigin.x + 120, body.formOrigin.y + 100))
    let lab = e2.find("Label1")
    check lab != nil and not lab.inherited
    e2.save()
    let nfm = readFile(root / "app" / "unit2.nfm")
    check nfm.startsWith("inherited Form2: Form2\n  ancestor = 'unit1.nfm'\n")
    check "  inherited Button1: Button\n    caption = 'Hello'\n  end\n" in nfm
    check "  object Label1: Label\n" in nfm
    check "object Button1" notin nfm
    check "import nimvcl/controls/label" in readFile(root / "app" / "unit2.nim")
    check not e2.modified
    # saved forms reopen the same, and save again byte for byte
    let e2b = newUnitEditor(proj, "unit2", host)
    check e2b.find("Label1") != nil and e2b.find("Button1").inherited
    check Button(e2b.find("Button1")).caption == "Hello"
    e2b.save()
    check readFile(root / "app" / "unit2.nfm") == nfm
    check proj.compiles()
    check proj.smoke().exitCode == 0

  test "a change to the ancestor reaches the descendant (no stale copy)":
    let nfm1 = root / "app" / "unit1.nfm"
    writeFile(nfm1, readFile(nfm1).replace("caption = 'Form1'", "caption = 'Ancestor says hi'")
                                  .replace("caption = 'Button1'", "caption = 'Pushed'"))
    let e2 = newUnitEditor(proj, "unit2", host)
    check e2.loadError == ""
    check Button(e2.find("Button1")).caption == "Hello"    # the descendant's own change stays
    let nfm2 = readFile(root / "app" / "unit2.nfm")
    check "Ancestor says hi" notin nfm2                    # nothing was copied
    check proj.compiles()
    check proj.smoke().exitCode == 0
    # and a form that overrides nothing takes the new button caption
    let u3 = proj.newInheritedFormUnit("unit1")
    let e3 = newUnitEditor(proj, u3.name, host)
    check Button(e3.find("Button1")).caption == "Pushed"

  test "a component the descendants depend on cannot be renamed or deleted in the ancestor":
    let e1 = newUnitEditor(proj, "unit1", host)
    e1.bindInspector(insp)
    let b = e1.find("Button1")
    e1.selectComponent(b)
    insp.setValue("name", pvString("OkBtn"))
    check b.name == "Button1"
    check "unit2" in insp.lastError
    check not e1.deleteSelection()
    check e1.find("Button1") != nil
    # a component nobody inherits can still be renamed
    e1.beginCreate "Label"
    let body = e1.designedForm
    host.click(pointF(body.formOrigin.x + 200, body.formOrigin.y + 150))
    let lab = e1.find("Label1")
    e1.selectComponent(lab)
    insp.setValue("name", pvString("Title"))
    check lab.name == "Title"

  test "descendant of a descendant; renaming the ancestor updates the files":
    let u = proj.newInheritedFormUnit("unit2", "leaf")
    check u.ancestor == "unit2"
    check readFile(root / "app" / "leaf.nfm").contains("ancestor = 'unit2.nfm'")
    check proj.descendantsOf("unit1").len == 3
    let eL = newUnitEditor(proj, "leaf", host)
    check eL.loadError == ""
    check eL.find("Label1") != nil and eL.find("Label1").inherited
    check proj.compiles()
    proj.renameUnit("unit2", "second")
    check readFile(root / "app" / "leaf.nfm").contains("ancestor = 'second.nfm'")
    check proj.units.filterIt(it.name == "leaf")[0].ancestor == "second"
    check proj.compiles()
    check proj.smoke().exitCode == 0

suite "handlers of inherited components":
  test "a handler bound in the descendant is generated there and builds":
    let e = newUnitEditor(proj, "second", host)
    e.bindInspector(insp)
    e.selectComponent(e.find("Button1"))
    let b = e.find("Button1")
    let at = pointF(b.formOrigin.x + b.width / 2, b.formOrigin.y + b.height / 2)
    discard host.paintIfDirty()
    host.ev(ekMouseDown, at, 1)
    host.ev(ekMouseUp, at, 1)
    host.ev(ekMouseDown, at, 2)          # double click: the default event's handler
    host.ev(ekMouseUp, at, 2)
    check "proc Button1Click(self: Form2" in e.code.text
    e.save()
    check "  inherited Button1: Button\n" in readFile(root / "app" / "second.nfm")
    check "onClick = Button1Click" in readFile(root / "app" / "second.nfm")
    check proj.compiles()
    check proj.smoke().exitCode == 0

proc dblClick(e: UnitEditor, c: Control) =
  let at = pointF(c.formOrigin.x + c.width / 2, c.formOrigin.y + c.height / 2)
  discard host.paintIfDirty()
  host.ev(ekMouseDown, at, 1)
  host.ev(ekMouseUp, at, 1)
  host.ev(ekMouseDown, at, 2)
  host.ev(ekMouseUp, at, 2)

suite "same handler name in ancestor and descendant":
  test "the descendant's Button1Click runs, and can call the ancestor's":
    let p = newApplicationProject(root / "ovr", "ovr")
    let e1 = newUnitEditor(p, "unit1", host)
    e1.beginCreate "Button"
    host.click(pointF(e1.designedForm.formOrigin.x + 40, e1.designedForm.formOrigin.y + 40))
    e1.dblClick(e1.find("Button1"))               # Button1Click in unit1
    check "proc Button1Click(self: Form1" in e1.code.text
    e1.code.text = e1.code.text.replace("proc Button1Click(self: Form1, sender: Control) =\n  discard",
      "var trace*: seq[string]\n\nproc Button1Click*(self: Form1, sender: Control) =\n  trace.add \"F1\"")
    e1.code.saveToFile(root / "ovr" / "unit1.nim")
    e1.save()
    let u2 = p.newInheritedFormUnit("unit1")
    p.save()
    let e2 = newUnitEditor(p, u2.name, host)
    e2.dblClick(e2.find("Button1"))               # the same name, in the descendant
    let code2 = e2.code.text
    check "proc Button1Click(self: Form2, sender: Control) =" in code2
    check "Button1Click(Form1(self), sender)" in code2         # the hint
    e2.code.text = code2.replace("  discard\n", "  trace.add \"F2\"\n  Button1Click(Form1(self), sender)\n")
    e2.code.saveToFile(root / "ovr" / "unit2.nim")
    e2.save()
    check "inherited Button1" notin readFile(root / "ovr" / "unit2.nfm")   # nothing to write
    var main = readFile(root / "ovr" / "ovr.nim")
    main = main.replace("  when appTitle.len > 0:", "  if \"--click\" in commandLineParams():\n" &
                        "    form2.Button1.onClick(form2.Button1)\n    mainForm.Button1.onClick(mainForm.Button1)\n" &
                        "    echo trace\n    quit(0)\n  when appTitle.len > 0:")
    main = main.replace("import std/os\n", "import std/os\nimport unit1\n")
    writeFile(root / "ovr" / "ovr.nim", main)
    check p.compiles()
    let (o, code) = headlessCmd(quoteShell(p.exePath) & " --click")
    check code == 0
    check o.strip == "@[\"F2\", \"F1\", \"F1\"]"         # Form2's, its call of Form1's, then Form1's own

suite "File > New Inherited Form":
  test "the command lists the forms, creates the unit and opens it":
    let ide = newIdeForm(settingsFile = root / "settings.json")
    ide.showWindow(1360, 860)
    var errors: seq[string]
    ide.showError = proc(text: string) = errors.add text
    ide.refreshActions()
    check not ide.acts[aNewInheritedForm].enabled           # no project
    check ide.newApplication(root / "ide", "ideapp")
    ide.refreshActions()
    check ide.acts[aNewInheritedForm].enabled
    var offered: seq[string]
    ide.pickItem = proc(t: string, items: seq[string], selected: int): int =
      offered = items
      0
    let ed = ide.newInheritedForm()
    check offered == @["unit1 (Form1)"]
    check ed != nil and ed.unitName == "unit2"
    check ide.project.units[1].ancestor == "unit1"
    check ide.editors.len == 2
    check ed.isForm and ed.loadError == ""
    check errors.len == 0
    check ide.project.compileProjectSync().ok
    ide.pickItem = nil
    ide.showWindow()

suite "Revert to Inherited":
  var rp: Project
  var anc, des: UnitEditor
  var button: Control

  proc nfmOf(unit: string): string = readFile(root / "rev" / unit & ".nfm")

  test "setup: an ancestor with a button and a label, a descendant that changes them":
    rp = newApplicationProject(root / "rev", "rev")
    anc = newUnitEditor(rp, "unit1", host)
    anc.beginCreate "Button"
    host.click(pointF(anc.designedForm.formOrigin.x + 40, anc.designedForm.formOrigin.y + 40))
    anc.beginCreate "Label"
    host.click(pointF(anc.designedForm.formOrigin.x + 40, anc.designedForm.formOrigin.y + 120))
    anc.bindInspector(insp)
    anc.selectComponent(anc.find("Button1"))
    insp.setValue("caption", pvString("Anc"))
    anc.save()
    let u = rp.newInheritedFormUnit("unit1")
    rp.save()
    des = newUnitEditor(rp, u.name, host)
    des.bindInspector(insp)
    button = des.find("Button1")
    check button != nil and button.inherited
    des.selectComponent(button)
    insp.setValue("caption", pvString("Mine"))
    insp.setValue("left", pvFloat(150))
    insp.setValue("width", pvFloat(222))
    des.selectComponent(des.find("Label1"))
    insp.setValue("caption", pvString("Changed label"))
    des.save()
    let nfm = nfmOf("unit2")
    check "caption = 'Mine'" in nfm and "left = 150" in nfm and "width = 222" in nfm
    check "caption = 'Changed label'" in nfm

  test "a changed property can be reverted; an unchanged or own one cannot":
    let c = Component(button)
    check des.canRevert(c, "caption")
    check des.canRevert(c, "left")
    check des.canRevert(c, "width")
    check not des.canRevert(c, "top")                  # not changed
    check not des.canRevert(c, "name")
    check not des.canRevert(c, "noSuchProperty")
    check not anc.canRevert(Component(anc.find("Button1")), "caption")   # the ancestor itself
    check des.revertProperty(c, "caption")
    check Button(button).caption == "Anc"
    check not des.canRevert(c, "caption")
    check not des.revertProperty(c, "caption")         # nothing left to do
    check des.modified

  test "the inspector marks overridden properties of the selection":
    des.selectComponent(des.find("Label1"))
    check insp.overridden("caption")
    check not insp.overridden("top")
    des.selectComponent(Component(button))
    check insp.overridden("left") and insp.overridden("width")
    check not insp.overridden("caption")             # reverted above
    check not anc.overridden("left")                 # the ancestor has nothing to override
    anc.bindInspector(insp)
    anc.selectComponent(anc.find("Button1"))
    check not insp.overridden("caption")
    des.bindInspector(insp)
    des.selectComponent(Component(button))

  test "the reverted property leaves the .nfm of the descendant, the others stay":
    des.save()
    let nfm = nfmOf("unit2")
    check "caption = 'Mine'" notin nfm
    check "left = 150" in nfm and "width = 222" in nfm

  test "another property reverts on its own":
    check des.revertProperty(Component(button), "width")
    check button.width != 222
    des.save()
    let nfm = nfmOf("unit2")
    check "width = 222" notin nfm and "left = 150" in nfm

  test "a whole component: every changed property, and its block disappears":
    check des.canRevertComponent(Component(button))
    check des.revertComponent(Component(button)) == 1
    check button.left == anc.find("Button1").left
    check not des.canRevertComponent(Component(button))
    check des.revertComponent(Component(button)) == 0
    des.save()
    check "inherited Button1" notin nfmOf("unit2")
    check "inherited Label1" in nfmOf("unit2")         # the label was not touched

  test "the form itself reverts too; an own component does not":
    let form = des.componentTree[0][0]
    des.selectComponent(form)
    insp.setValue("caption", pvString("Descendant title"))
    check des.canRevert(form, "caption")
    check des.revertProperty(form, "caption")
    check Form(form).caption == "Form1"
    des.beginCreate "Label"
    host.click(pointF(des.designedForm.formOrigin.x + 200, des.designedForm.formOrigin.y + 200))
    let own = des.find("Label2")
    check own != nil and not own.inherited
    check not des.canRevertComponent(Component(own))
    check des.revertComponent(Component(own)) == 0

  test "the saved descendant still builds":
    des.save()
    check "caption = 'Descendant title'" notin nfmOf("unit2")
    check rp.compiles()
    check rp.smoke().exitCode == 0

suite "Revert to Inherited in the IDE":
  test "the Edit menu actions and the Object Inspector menu follow the selection":
    let ide = newIdeForm(settingsFile = root / "settings-rev.json")
    ide.showWindow(1360, 860)
    var errors: seq[string]
    ide.showError = proc(text: string) = errors.add text
    check ide.openProject(root / "rev" / "rev.nimproj")
    let ed = ide.openUnit("unit2")
    check ed != nil
    let ancEd = ide.openUnit("unit1")
    ide.sync()
    check not ide.acts[aRevertProp].enabled              # the ancestor form
    check not ide.acts[aRevertComponent].enabled
    discard ide.openUnit("unit2")
    ide.sync()
    ed.selectComponent(ed.find("Button1"))
    ide.inspector.selectProp("caption")
    ide.inspector.setValue("caption", pvString("Edited"))
    ide.sync()
    check ide.acts[aRevertProp].enabled and ide.acts[aRevertComponent].enabled
    check ide.canRevertProperty and ide.canRevertComponent
    ide.acts[aRevertProp].execute()
    ide.sync()
    check Button(ed.find("Button1")).caption == "Anc"
    check not ide.canRevertProperty and not ide.canRevertComponent
    check ide.status.panels[4].text.len > 0
    # a component of its own: nothing to revert
    ed.selectComponent(ed.find("Label2"))
    ide.sync()
    check not ide.acts[aRevertProp].enabled
    check errors.len == 0
    discard ancEd
    ide.showWindow()

suite "an ancestor that is saved while its descendants are open":
  let ide = newIdeForm(settingsFile = root / "settings-live.json")
  ide.showWindow(1360, 860)
  var errors: seq[string]
  ide.showError = proc(text: string) = errors.add text
  var a, d: UnitEditor

  proc comp(ed: UnitEditor, name: string): Component =
    for (c, _) in ed.componentTree:
      if c.name == name: return c

  proc setOn(ed: UnitEditor, name, prop: string, v: PropValue) =
    discard ide.openUnit(ed.unitName)
    ed.selectComponent(ed.comp(name))
    check ide.inspector.setValue(prop, v)

  proc nfm(unit: string): string = readFile(root / "live" / unit & ".nfm")

  test "setup: an ancestor with a button and a label, and its open descendant":
    check ide.newApplication(root / "live", "live")
    a = ide.openUnit("unit1")
    ide.dropComponent("Button")
    ide.dropComponent("Label")
    ide.saveAll()
    d = ide.newInheritedForm("unit1")
    check d != nil and d.unitName == "unit2"
    check Button(d.comp("Button1")).caption == "Button1"

  test "a clean descendant shows the new state of the ancestor and keeps its selection":
    ide.saveAll()                                          # imports follow the classes: clean now
    check not d.modified
    discard ide.openUnit("unit2")
    d.selectComponent(d.comp("Label1"))
    a.setOn("Button1", "caption", pvString("Two"))
    ide.saveActive()
    check Button(d.comp("Button1")).caption == "Two"
    check not d.modified
    check d.selection.len == 1 and d.selection[0].name == "Label1"
    check d.comp("Button1").inherited

  test "unsaved changes of the descendant (form and code) survive; nothing is copied":
    d.setOn("Button1", "left", pvFloat(222))
    d.code.text = d.code.text & "\n# my note\n"
    check d.designModified and d.modified
    a.setOn("Button1", "caption", pvString("Three"))
    a.setOn("Button1", "width", pvFloat(150))
    ide.saveActive()                                       # the ancestor
    let b = Button(d.comp("Button1"))
    check b.caption == "Three" and b.width == 150          # the new inherited state
    check b.left == 222                                    # the descendant's own change
    check d.designModified
    check d.code.text.endsWith("# my note\n")
    check d.comp("Button1").inherited
    discard ide.openUnit("unit2")
    ide.saveActive()
    let n2 = nfm("unit2")
    check "left = 222" in n2
    check "caption" notin n2.split("inherited Button1")[^1].split("end")[0]
    check "width = 150" notin n2 and "Three" notin n2
    check not d.modified

  test "both open and modified: Save All writes each as differences and refreshes":
    a.setOn("Button1", "caption", pvString("Four"))
    d.setOn("Button1", "left", pvFloat(230))
    ide.saveAll()
    check "Four" in nfm("unit1")
    check "left = 230" in nfm("unit2") and "Four" notin nfm("unit2")
    check Button(d.comp("Button1")).caption == "Four" and Control(d.comp("Button1")).left == 230
    check not a.modified and not d.modified

  test "closing the window saves the same way (descendants first, with the rebase)":
    ide.askSave = proc(unitName: string): SaveChoice = scSave
    a.setOn("Button1", "caption", pvString("Five"))
    d.setOn("Button1", "left", pvFloat(240))
    var can = true
    ide.onCloseQuery(ide, can)
    check can
    check "Five" in nfm("unit1")
    check "left = 240" in nfm("unit2") and "Five" notin nfm("unit2")
    check not a.modified and not d.modified
    check Button(d.comp("Button1")).caption == "Five"

  test "an override of something the ancestor no longer has is dropped, with a message":
    d.setOn("Label1", "caption", pvString("Mine"))
    check d.designModified
    let pending = d.pendingDesign
    check "inherited Label1" in pending
    var text = nfm("unit1")
    let at = text.find("object Label1: Label")
    check at >= 0
    let stop = text.find("  end\n", at) + "  end\n".len
    writeFile(root / "live" / "unit1.nfm", text[0 ..< at] & text[stop .. ^1])
    var said: seq[string]
    let hooked = d.onMessage
    d.onMessage = proc(e: UnitEditor, msg: string) =
      said.add msg
      hooked(e, msg)
    check d.rebaseOnAncestor(pending)
    check d.comp("Label1") == nil
    check d.comp("Button1") != nil and d.loadError == ""
    check d.designModified                        # the dropped override: save to forget it
    check said.anyIt("no longer" in it)
    d.save()
    check "Label1" notin nfm("unit2")

  test "no errors were reported":
    check errors.len == 0
    ide.showWindow()

suite "an open descendant after its ancestor was renamed":
  test "the editor follows the project's unit (the hint names the ancestor's form)":
    let p = newApplicationProject(root / "rn", "rn")
    let e1 = newUnitEditor(p, "unit1", host)
    e1.beginCreate "Button"
    host.click(pointF(e1.designedForm.formOrigin.x + 40, e1.designedForm.formOrigin.y + 40))
    e1.dblClick(e1.find("Button1"))                  # the ancestor has a Button1Click
    e1.save()
    discard p.newInheritedFormUnit("unit1")
    p.save()
    let e2 = newUnitEditor(p, "unit2", host)
    p.renameUnit("unit1", "base")
    e2.reloadFromDisk()
    e2.dblClick(e2.find("Button1"))
    check "replaces Form1's Button1Click" in e2.code.text
    e2.save()
    check not fileExists(p.dir / "unit2.nim.tmp")      # saved through a temporary file
    check readFile(p.dir / "unit2.nim") == e2.code.text
    check e2.code.fileName == p.dir / "unit2.nim"
