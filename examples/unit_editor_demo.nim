# UnitEditor demo: the form designer and the code view of one unit, with an
# ObjectInspector bound to it, on a project generated in a temp folder.
#
#   * pick a class in the palette (left), then click or drag on the form
#   * the inspector (right) edits the selection; double click an empty event
#     row, or a control on the form, to create its handler and jump to the code
#   * F12 switches between the form and its code, Ctrl+S saves, Ctrl+C / X / V
#     copy, cut and paste controls, Ctrl+Z / Ctrl+Y undo and redo
#
# Screenshot mode (headless):
#   SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software \
#     nim c -r examples/unit_editor_demo.nim --shots build/unit_editor_shots
#
# Build: nim c --outdir:build examples/unit_editor_demo.nim

import std/[os, strutils]
import nimvcl
import nimvcl/dsl/props
import nimvcl/controls/inspector
import ../src/ide/[project, uniteditor]

const Classes = ["Button", "Edit", "Label", "CheckBox", "RadioButton", "Panel",
                 "GroupBox", "ListBox", "ComboBox", "Memo", "ProgressBar",
                 "TrackBar", "Timer", "ImageList"]

type
  Demo = ref object of Form
    proj: Project
    ed: UnitEditor
    insp: ObjectInspector
    palette: ListBox
    status: Label

proc say(d: Demo, s: string) = d.status.caption = s

proc newDemo(dir: string): Demo =
  new result
  let d = result
  d.initForm()
  d.caption = "nimvcl-ide: unit editor"
  d.setBounds(0, 0, 1180, 720)
  d.proj = newApplicationProject(dir, "demo")
  d.status = newLabel(d, "Pick a class, then click on the form.")
  d.status.align = alBottom
  d.status.margins = spacing(10, 6)
  d.status.muted = true
  let left = newPanel(d, "", 0, 0, 150, 0)
  left.align = alLeft
  left.padding = spacing(8)
  let pl = newLabel(left, "Palette", 8, 8)
  pl.font = font(pl.font.family, pl.font.size, {fsBold})
  d.palette = newListBox(left, 8, 34, 134, 360)
  for c in Classes: d.palette.add c
  d.insp = newObjectInspector(d)
  d.insp.align = alRight
  d.insp.width = 330
  d.insp.margins = spacing(0, 6, 8, 6)
  let sp = newSplitter(d, alRight)
  sp.minSize = 240
  d.ed = newUnitEditor(d.proj, "unit1", d)
  d.ed.bindInspector(d.insp)
  d.ed.onMessage = proc(e: UnitEditor, m: string) = d.say m
  d.ed.onModifiedChanged = proc(e: UnitEditor) =
    d.caption = "nimvcl-ide: unit editor" & (if e.modified: " *" else: "")
  d.palette.onChange = proc(s: Control) =
    let i = d.palette.itemIndex
    if i >= 0:
      d.ed.beginCreate Classes[i]
      d.palette.itemIndex = -1
  d.addKeyHandler("demo", proc(key: var Key, shift: ShiftState) =
    if key == keyF12:
      d.ed.toggleView()
      key = Key(0)
    elif ssCtrl in shift and key == key('s'):
      d.ed.save()
      d.say "saved"
      key = Key(0))

# ------------------------------------------------------------ screenshots

proc shoot(f: Form, dir, name: string) =
  discard f.paintIfDirty()
  Application.paintForms()
  if not screenshotWithPopups(f, dir / (name & ".png")): quit "screenshot failed for " & name
  echo "wrote ", dir / (name & ".png")

proc ev(f: Form, kind: EventKind, p: PointF, clicks = 1, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: f.win.id, x: p.x, y: p.y,
                                     button: mbLeft, clicks: clicks, shift: shift))

proc click(f: Form, p: PointF, clicks = 1) =
  discard f.paintIfDirty()
  f.ev(ekMouseDown, p, clicks)
  f.ev(ekMouseUp, p, clicks)

proc drag(f: Form, a, b: PointF) =
  discard f.paintIfDirty()
  f.ev(ekMouseDown, a)
  f.ev(ekMouseMove, pointF((a.x + b.x) / 2, (a.y + b.y) / 2), shift = {ssLeft})
  f.ev(ekMouseMove, b, shift = {ssLeft})
  f.ev(ekMouseUp, b)

proc at(d: Demo, x, y: float32): PointF =
  let o = d.ed.designedForm.formOrigin
  pointF(o.x + x, o.y + y)

proc center(c: Control): PointF =
  pointF(c.formOrigin.x + c.width / 2, c.formOrigin.y + c.height / 2)

proc byName(d: Demo, name: string): Control =
  for (c, _) in d.ed.componentTree:
    if c.name == name and c of Control: return Control(c)

proc pick(d: Demo, cls: string, a, b: PointF) =
  d.ed.beginCreate cls
  d.drag(a, b)

proc shots(dir: string) =
  createDir dir
  Application.init()
  let tmp = getTempDir() / ("nimvcl-ide-demo-" & $getCurrentProcessId())
  removeDir tmp
  let d = newDemo(tmp)
  d.show()
  d.syncMetrics()
  d.shoot(dir, "1-empty-form")

  d.pick("Label", d.at(24, 24), d.at(120, 44))
  d.pick("Edit", d.at(24, 56), d.at(240, 82))
  d.pick("Button", d.at(24, 104), d.at(124, 134))
  d.pick("Button", d.at(140, 104), d.at(240, 134))
  d.pick("CheckBox", d.at(24, 152), d.at(200, 176))
  d.pick("ListBox", d.at(264, 24), d.at(380, 160))
  d.ed.beginCreate "Timer"
  let b1 = d.byName("Button1")
  d.click(b1.center)
  discard d.insp.setValue("caption", pvString("Save"))
  d.shoot(dir, "2-designer-selected")

  # a handler through a double click, then the code view
  d.click(b1.center, 2)
  d.shoot(dir, "3-code-handler")
  d.ed.showDesigner()
  d.ed.selectComponent(d.byName("Button1"))
  d.insp.tab = itEvents
  d.shoot(dir, "4-back-to-designer-events")
  d.insp.tab = itProperties

  Application.theme = themeDark()
  d.ed.selectComponent(d.byName("Button1"))
  d.shoot(dir, "5-dark-designer")
  d.ed.showCode()
  d.shoot(dir, "6-dark-code")
  Application.shutdown()
  removeDir tmp

proc main() =
  let args = commandLineParams()
  if args.len >= 1 and args[0] == "--shots":
    shots(if args.len >= 2: args[1] else: "build/unit_editor_shots")
  else:
    Application.init()
    let d = newDemo(getTempDir() / ("nimvcl-ide-demo-" & $getCurrentProcessId()))
    Application.run(d)

when isMainModule:
  main()
