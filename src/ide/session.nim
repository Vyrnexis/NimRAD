## A scripted IDE session driven through simulated input events, used by
## `scripts/docshots.nim` (screenshots) and by `tests/tide.nim` (no screenshots).
## It is not part of the `nimrad` program.
##
## 1. a new application, 2. a Button and a Label dropped on the form (palette
## click, then a click on the form), 3. the Button selected so the inspector
## shows it, 4. a double click creating its click handler (code view),
## 5. `self.Label1.caption = "Hi"` typed into the handler, 6. Compile (the
## event loop runs until the background build ends), 7. the messages, 8. dark theme.

import std/[os, strutils, times]
import nimvcl
import nimvcl/dsl/props
import ./[mainform, uniteditor, project, palette, messagespanel]

type
  ShotProc* = proc(name: string)

  SessionResult* = object
    ok*: bool
    error*: string
    projectDir*: string
    buttonName*, labelName*: string
    handlerLine*: int

# ------------------------------------------------------------------ input

proc settle*(ide: IdeForm, rounds = 2) =
  ## Lets the UI catch up: queued procs, idle hooks, layout and paint.
  for _ in 1 .. rounds:
    Application.processMessages(0)
    discard ide.paintIfDirty()
    ide.sync()

proc fire(ide: IdeForm, kind: EventKind, p: PointF, clicks = 1, shift: ShiftState = {},
          button = mbLeft) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: ide.win.id, x: p.x, y: p.y,
                                     button: button, clicks: clicks, shift: shift))

proc center*(r: RectF): PointF = pointF(r.x + r.w / 2, r.y + r.h / 2)

proc click*(ide: IdeForm, p: PointF) =
  ide.fire(ekMouseMove, p)
  ide.fire(ekMouseDown, p)
  ide.fire(ekMouseUp, p)
  ide.settle

proc middleClick*(ide: IdeForm, p: PointF) =
  ide.fire(ekMouseMove, p)
  ide.fire(ekMouseDown, p, button = mbMiddle)
  ide.fire(ekMouseUp, p, button = mbMiddle)
  ide.settle

proc doubleClick*(ide: IdeForm, p: PointF) =
  ide.fire(ekMouseMove, p)
  ide.fire(ekMouseDown, p, 1)
  ide.fire(ekMouseUp, p, 1)
  ide.fire(ekMouseDown, p, 2)
  ide.fire(ekMouseUp, p, 2)
  ide.settle

proc typeText*(ide: IdeForm, text: string) =
  Application.dispatch(PlatformEvent(kind: ekTextInput, windowId: ide.win.id, text: text))
  ide.settle

proc pressKey*(ide: IdeForm, k: Key, shift: ShiftState = {}) =
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: ide.win.id, key: k, shift: shift))
  Application.dispatch(PlatformEvent(kind: ekKeyUp, windowId: ide.win.id, key: k, shift: shift))
  ide.settle

proc controlCenter*(c: Control): PointF =
  c.clientToForm(pointF(c.width / 2, c.height / 2))

proc showWindow*(ide: IdeForm, w = 1360, h = 860) =
  ide.show()
  ide.syncMetrics()
  ide.win.setLogicalSize(w.float32, h.float32)
  ide.syncMetrics()
  ide.settle

proc shoot*(ide: IdeForm, path: string) =
  ide.settle
  discard ide.paintIfDirty()
  Application.paintForms()
  if not screenshotWithPopups(ide, path): raise newException(IOError, "screenshot failed: " & path)

# ------------------------------------------------------------------ script

proc findControl(root: Container, className: string): Control =
  for c in root.children:
    if classOf(Obj(c)) != nil and classOf(Obj(c)).name == className: return c

proc runScriptedSession*(ide: IdeForm, workDir: string, shot: ShotProc = nil): SessionResult =
  ## Runs the session in `workDir/Project1` (created); `shot(name)` is called
  ## after each step when given.
  template step(name: string) =
    ide.settle
    if shot != nil: shot(name)
  template check(cond: bool, msg: string) =
    if not cond:
      result.error = msg
      return

  # 1. new application
  let dir = workDir / "Project1"
  result.projectDir = dir
  check ide.newApplication(dir, "Project1"), "newApplication failed"
  var ed = ide.activeEditor
  check ed != nil and ed.isForm and ed.designerVisible, "the new form is not in the designer"
  step "01-new-application"

  # 2. a Button and a Label: pick on the palette, click on the form
  for (cls, x, y) in [("Button", 48.0, 52.0), ("Label", 48.0, 118.0)]:
    ide.settle
    let r = ide.palette.buttonRect(cls)
    check r.w > 0, "no palette button for " & cls
    ide.click r.center
    check ide.palette.picked == cls, cls & " was not picked"
    check ed.designer.creating == cls, "the designer is not creating " & cls
    ide.click ed.designedForm.clientToForm(pointF(x, y))
    check ed.designer.creating.len == 0, cls & " was not placed"
    check ide.palette.picked.len == 0, "the palette did not go back to the pointer"
  step "02-components"

  let button = findControl(ed.designedForm, "Button")
  let label = findControl(ed.designedForm, "Label")
  check button != nil and label != nil, "Button or Label missing on the form"
  result.buttonName = button.name
  result.labelName = label.name

  # 3. select the Button so the inspector shows it
  ide.click button.controlCenter
  check ed.selection.len == 1 and ed.selection[0] == Component(button), "the Button is not selected"
  step "03-inspector"

  # 4. double click: the click handler appears in the code
  ide.doubleClick button.controlCenter
  check not ed.designerVisible, "double click did not switch to the code"
  let line = ed.code.caretPos.line
  result.handlerLine = line
  check (button.name & "Click") in ed.code.text, "no handler for " & button.name
  step "04-handler"

  # 5. type the body (replacing the stub's `discard`)
  ide.activeControl = ed.code
  let l = ed.code.lineAt(line)
  ed.code.select((line, l.len - l.strip(trailing = false).len), (line, l.len))
  # components are fields under their own name (`Label1`), so the exact name is used
  ide.typeText "self." & label.name & ".caption = \"Hi\""
  check ed.code.lineAt(line).contains("caption = \"Hi\""), "typing did not reach the code"
  check ed.modified, "the unit is not marked modified"
  step "05-typed"

  # 6. compile and wait for the background build
  check ide.compile(), "compile did not start"
  check ide.waitIdle(180), "the build did not finish"
  ide.settle
  check ide.lastBuildOk, "the build failed: " & ide.messages.output.text
  # 7. the messages show success
  step "06-compiled"

  # 8. dark theme
  ide.setDark(true)
  step "07-dark"
  ide.setDark(false)
  result.ok = true
