## The popups of code insight: a pick list under the word being typed
## (completion, templates) and a one line hint over the line (parameter hints).
## Pure glue on nimvcl's `showPopup`; what the rows are and what picking does
## are the caller's (`codecmds`).
##
## The list is a menu popup (`pkMenu`): nimvcl hands every key of the form to
## the topmost popup's content while the editor keeps the focus, so the content
## (`PickPanel`) decides: Up, Down, PageUp, PageDown move the choice, Enter and
## Tab pick, Esc closes (nimvcl does that), letters and digits are typed into the
## editor and narrow the list (it closes when nothing is left, or the caret
## leaves the word), Backspace deletes and widens it, every other key closes
## the list and is given to the editor. A click in the list picks, a click
## elsewhere or losing the focus closes it (nimvcl).
##
## The hint is a tooltip popup (`pkTooltip`): no input, it stays until
## `hideTip`.

import std/[strutils, sequtils]
import nimvcl
import nimvcl/core/popup

const
  VisibleRows = 8
  MinWidth = 180'f32
  MaxWidth = 520'f32

type
  Refilter* = proc(prefix: string): seq[string]
    ## The rows for the text typed since the start of the word (empty: nothing fits).
  Accept* = proc(row: int, a, b: CodePos)
    ## `row` of the last list was picked; the word to replace is from `a` to `b`.

  PickPanel = ref object of Container
    code: CodeEdit
    list: ListBox
    start: CodePos
    refilter: Refilter
    accept: Accept
    popup: PopupWindow
    done: bool

  TipPanel = ref object of Container
    text: string

var
  current: PickPanel
  tip: PopupWindow
  tipOf: string              ## what the hint is about (`codecmds` closes it when the caret leaves it)

# ------------------------------------------------------------------- the list

proc isOpen*(): bool = current != nil and not current.done

proc pickerRows*(): seq[string] =
  ## The rows shown now (for tests).
  if current != nil:
    for i in 0 ..< current.list.count: result.add current.list.itemText(i)

proc pickerChoice*(): int =
  if current != nil: current.list.itemIndex else: -1

proc closePicker*() =
  if current != nil and not current.done:
    let p = current.popup
    current.done = true
    if p != nil: closePopup(p)

proc pick(p: PickPanel) =
  let row = p.list.itemIndex
  let a = p.start
  let b = p.code.caretPos
  let accept = p.accept
  closePicker()
  if row >= 0 and accept != nil: accept(row, a, b)

proc narrow(p: PickPanel) =
  ## After the editor changed: the list of the word now before the caret.
  let c = p.code.caretPos
  if c.line != p.start.line or c.col < p.start.col or c.line >= p.code.lineCount:
    closePicker()
    return
  let line = p.code.lineAt(c.line)
  let prefix = line[min(p.start.col, line.len) ..< min(c.col, line.len)]
  let rows = p.refilter(prefix)
  if rows.len == 0:
    closePicker()
    return
  p.list.items = rows
  p.list.itemIndex = 0
  p.list.makeVisible 0

proc isWordText(t: string): bool =
  t.len > 0 and t.allIt(it in IdentChars or ord(it) >= 0x80)

method doKeyDown*(p: PickPanel, key: var Key, shift: ShiftState) =
  if p.done: return
  if key in [keyLCtrl, keyRCtrl, keyLShift, keyRShift, keyLAlt, keyRAlt]: return
  if key == keyEscape: return                       # nimvcl closes the popup
  if shift * {ssCtrl, ssAlt} == {}:
    if key in [keyUp, keyDown, keyPageUp, keyPageDown]:
      p.list.doKeyDown(key, shift)
      key = Key(0)
      return
    if key == keyEnter or key == keyTab:
      key = Key(0)
      p.pick()
      return
    if key == keyBackspace:
      var k = key
      key = Key(0)
      p.code.doKeyDown(k, shift)
      if not p.done: p.narrow()
      return
  var k = key
  key = Key(0)
  let code = p.code
  closePicker()
  code.doKeyDown(k, shift)

method doKeyPress*(p: PickPanel, text: var string) =
  if p.done: return
  var t = text
  text = ""
  let code = p.code
  if isWordText(t):
    code.doKeyPress(t)
    if not p.done: p.narrow()
  else:
    closePicker()
    code.doKeyPress(t)

proc rowHeight(owner: Form): float32 =
  let ctx = owner.ctx
  if ctx != nil and not ctx.isClosed:
    max(ceil(ctx.fontMetrics(Control(owner).font).lineHeight) + 8, 16)
  else: 22

proc textWidth(owner: Form, s: string): float32 =
  let ctx = owner.ctx
  if ctx != nil and not ctx.isClosed:
    ctx.measureDevice(s, Control(owner).font)[0] / ctx.scale
  else: float32(s.len) * 8

proc showPicker*(owner: Form, code: CodeEdit, start: CodePos, items: seq[string],
                 refilter: Refilter, accept: Accept): bool {.discardable.} =
  ## Opens the list of `items` under `start`, the start of the word being
  ## completed (the caret is at its end or after). False when it cannot be shown.
  closePicker()
  if items.len == 0 or owner == nil or not owner.hasWindow or not owner.visible: return false
  let ih = rowHeight(owner)
  var w = MinWidth
  for s in items: w = max(w, textWidth(owner, s) + 28)
  w = min(w, MaxWidth)
  let h = float32(min(items.len, VisibleRows)) * ih + 2
  let list = newListBox()
  list.showFocusRect = false
  list.tabStop = false
  list.font = Control(owner).font
  list.parentColor = true
  list.itemHeight = ih
  list.items = items
  list.align = alClient
  list.setBounds(0, 0, w, h)
  list.itemIndex = 0
  let panel = PickPanel(code: code, list: list, start: start, refilter: refilter, accept: accept)
  panel.initContainer()
  panel.setBounds(0, 0, w, h)
  panel.insertControl list
  list.onClick = proc(s: Control) =
    if current == panel and not panel.done and list.itemIndex >= 0: panel.pick()
  let pt = code.pointOfPos(start)
  let anchor = code.clientToForm(rectF(pt.x, pt.y, 1, code.rowHeight))
  current = panel
  try:
    panel.popup = showPopup(owner, panel, anchor, plBelow, pkMenu)
  except CatchableError:
    current = nil
    panel.removeControl list
    list.free()
    return false
  panel.popup.onClosed = proc(q: PopupWindow) =
    panel.done = true
    if current == panel: current = nil
    panel.removeControl list
    list.free()
  panel.popup.ui.focusControl(list)
  true

# ------------------------------------------------------------------ the hint

method paint*(t: TipPanel, c: Canvas) =
  let th = t.theme
  c.fillRect(t.clientRect, th.tooltipBg)
  c.frameRect(t.clientRect, th.tooltipBorder, 1)
  c.textRect(t.text, t.font, t.clientRect.inflate(-6), th.tooltipText, taLeft, vaCenter)

proc tipOpen*(): bool = tip != nil and tip.isOpen

proc tipKey*(): string = tipOf

proc tipText*(): string =
  if tipOpen(): TipPanel(tip.content).text else: ""

proc hideTip*() =
  tipOf = ""
  if tip != nil:
    let p = tip
    tip = nil
    if p.isOpen: closePopup(p)

proc showTip*(owner: Form, code: CodeEdit, at: CodePos, text, key: string): bool {.discardable.} =
  ## The one line `text` over the line of `at`; `key` is what it is about.
  hideTip()
  if text.len == 0 or owner == nil or not owner.hasWindow or not owner.visible: return false
  let t = TipPanel(text: text)
  t.initContainer()
  t.font = Control(owner).font
  let w = min(textWidth(owner, text) + 16, 900'f32)
  let h = rowHeight(owner) + 4
  t.setBounds(0, 0, w, h)
  let pt = code.pointOfPos(at)
  let anchor = code.clientToForm(rectF(pt.x, pt.y, 1, code.rowHeight))
  try:
    tip = showPopup(owner, t, anchor, plAbove, pkTooltip)
  except CatchableError:
    tip = nil
    return false
  tip.onClosed = proc(q: PopupWindow) =
    if tip == q: tip = nil
  tipOf = key
  true
