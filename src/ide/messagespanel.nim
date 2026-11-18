## The Messages window: a tab "Messages" (a ListView of the parsed compiler
## messages, one icon per kind) and a tab "Output" (the raw text of the
## compiler and of the running program).
##
## Double click on a message with a location calls `onJump(file, line, col)`
## (1-based, as the compiler prints them). Lines are fed one at a time with
## `feed`; `finish` completes the last message.
##
## Errors, warnings and hints have an icon each. `showHints = false` hides the
## hint rows (the messages are kept, so showing them again needs no rebuild).
## `jumpNext` goes to the next message that has a location, after the one
## last jumped to, wrapping at the end.
##
## Quick fixes: `fixProvider` (set by the IDE) gives the fixes of an error when
## it is added; the row says so (`[Ctrl+.  Add import ...]`), `fixesOf` returns
## them and the context menu item "Quick Fix" calls `onQuickFix(msgIndex)`.

import std/[os, strutils]
import nimvcl
import ./[messages, icons, quickfix]

type
  Row = object
    msg: int                   ## index into `msgs`, -1 for a note of the IDE
    text: string               ## notes only
    icon: int

  MessagesPanel* = ref object
    root*: PageControl
    list*: ListView
    output*: Memo
    onJump*: proc(file: string, line, col: int)
    fixProvider*: proc(m: Message): seq[QuickFix]
    onQuickFix*: proc(msgIndex: int)
    msgs*: seq[Message]        ## every message that has a row, hidden hints too (item.tag = index)
    fixes*: seq[seq[QuickFix]]  ## parallel to `msgs`
    errorCount*, warningCount*: int
    cursor*: int               ## index into `msgs` of the message last jumped to, -1 none
    fShowHints: bool
    rows: seq[Row]
    parser: MessageParser

proc iconOfKind(m: Message): int =
  case m.kind
  of MessageKind.mkError: icError
  of MessageKind.mkWarning: icWarning
  of MessageKind.mkHint: icHint
  of MessageKind.mkInfo: icInfo

proc firstLine(s: string): string =
  let i = s.find('\n')
  if i < 0: s.strip else: s[0 ..< i].strip

func shown(p: MessagesPanel, m: Message): bool =
  p.fShowHints or m.kind != MessageKind.mkHint

proc addItem(p: MessagesPanel, r: Row) =
  if r.msg < 0:
    let it = p.list.items.add(r.text)
    it.imageIndex = r.icon
    it.tag = -1
    return
  let m = p.msgs[r.msg]
  if not p.shown(m): return
  let label = case m.kind
    of MessageKind.mkError: "Error: "
    of MessageKind.mkWarning: "Warning: "
    of MessageKind.mkHint: "Hint: "
    of MessageKind.mkInfo: ""
  let where = if m.hasLocation: m.file.extractFilename else: ""
  let pos = if m.hasLocation: $m.line & ":" & $m.col else: ""
  var text = (if m.isTrace: "  at " else: label) & firstLine(m.text)
  if p.fixes[r.msg].len > 0: text.add "   [Ctrl+.  " & p.fixes[r.msg][0].title & "]"
  let it = p.list.items.add(text, where, pos)
  it.imageIndex = iconOfKind(m)
  it.tag = r.msg

proc addRow(p: MessagesPanel, m: Message) =
  let r = Row(msg: p.msgs.len)
  p.msgs.add m
  p.fixes.add(if p.fixProvider != nil: p.fixProvider(m) else: @[])
  p.rows.add r
  p.addItem r
  if m.kind == MessageKind.mkError: inc p.errorCount
  elif m.kind == MessageKind.mkWarning: inc p.warningCount

func fixesOf*(p: MessagesPanel, msgIndex: int): seq[QuickFix] =
  if msgIndex >= 0 and msgIndex < p.fixes.len: p.fixes[msgIndex] else: @[]

proc selectedMessage*(p: MessagesPanel): int =
  ## Index into `msgs` of the selected row, -1 when none.
  let i = p.list.itemIndex
  if i >= 0 and i < p.list.items.count: p.list.items[i].tag else: -1

proc firstWithFix*(p: MessagesPanel): int =
  for i in 0 ..< p.fixes.len:
    if p.fixes[i].len > 0: return i
  -1

func showHints*(p: MessagesPanel): bool = p.fShowHints
proc `showHints=`*(p: MessagesPanel, v: bool) =
  ## Shows or hides the hint rows (rebuilds the list).
  if v == p.fShowHints: return
  p.fShowHints = v
  p.list.items.clear()
  for r in p.rows: p.addItem r

proc wanted(m: Message): bool =
  ## Plain output lines (`CC: x.nim`, config hints) stay in the Output tab only.
  m.hasLocation or m.isTrace or m.kind in {MessageKind.mkError, MessageKind.mkWarning}

proc newMessagesPanel*(parent: Container, images: ImageList): MessagesPanel =
  ## `images` is the IDE icon list (`makeIdeIcons`).
  result = MessagesPanel(cursor: -1, fShowHints: true)
  let p = result
  p.root = newPageControl(parent)
  p.root.align = alClient
  let t1 = newTabSheet(p.root, "Messages")
  let t2 = newTabSheet(p.root, "Output")

  p.list = newListView(t1)
  p.list.align = alClient
  p.list.viewStyle = vsReport
  p.list.smallImages = images
  p.list.rowSelect = true
  p.list.columns.add("Message", 560)
  p.list.columns.add("File", 150)
  p.list.columns.add("Line", 70)
  p.list.onItemDblClick = proc(sender: Control, index, column: int) =
    if index < 0 or index >= p.list.items.count: return
    let k = p.list.items[index].tag
    if k >= 0 and k < p.msgs.len and p.msgs[k].hasLocation and p.onJump != nil:
      p.cursor = k
      p.onJump(p.msgs[k].file, p.msgs[k].line, p.msgs[k].col)

  let pm = newPopupMenu(p.root)
  let fixItem = pm.addItem("&Quick Fix", proc(s: MenuItem) =
    let k = p.selectedMessage
    if p.onQuickFix != nil: p.onQuickFix(k))
  pm.onPopup = proc(m: PopupMenu) =
    let k = p.selectedMessage
    let fx = p.fixesOf(k)
    fixItem.enabled = fx.len > 0
    fixItem.caption = if fx.len > 0: "&Quick Fix: " & fx[0].title else: "&Quick Fix"
  p.list.popupMenu = pm

  p.output = newMemo(t2)
  p.output.align = alClient
  p.output.readOnly = true
  p.output.font = currentTheme().monoFont

proc clear*(p: MessagesPanel) =
  p.list.items.clear()
  p.output.clear()
  p.msgs.setLen 0
  p.fixes.setLen 0
  p.rows.setLen 0
  p.cursor = -1
  p.errorCount = 0
  p.warningCount = 0
  p.parser = MessageParser()

proc addOutput*(p: MessagesPanel, line: string) =
  ## A line of raw text for the Output tab (which scrolls to the end).
  p.output.lines.add line
  p.output.caretPos = (p.output.lines.count - 1, 0)

proc feed*(p: MessagesPanel, line: string) =
  ## One line of compiler output: to the Output tab and to the parser.
  p.addOutput line
  p.parser.feed line
  for m in p.parser.take():
    if m.wanted: p.addRow m

proc finish*(p: MessagesPanel) =
  ## The output ended: completes the message that was still open.
  for m in p.parser.flush():
    if m.wanted: p.addRow m

proc addNote*(p: MessagesPanel, text: string, icon = icInfo) =
  ## A line of the IDE itself ("Build succeeded"), not from the compiler.
  let r = Row(msg: -1, text: text, icon: icon)
  p.rows.add r
  p.addItem r
  p.addOutput text

proc firstError*(p: MessagesPanel): int =
  ## Index into `msgs` of the first error with a location, or -1.
  for i, m in p.msgs:
    if m.kind == MessageKind.mkError and m.hasLocation: return i
  -1

proc rowOf*(p: MessagesPanel, msgIndex: int): int =
  for i in 0 ..< p.list.items.count:
    if p.list.items[i].tag == msgIndex: return i
  -1

proc select*(p: MessagesPanel, msgIndex: int) =
  ## Selects (and scrolls to) the row of message `msgIndex`.
  let r = p.rowOf(msgIndex)
  if r >= 0:
    p.list.itemIndex = r
    p.list.makeVisible(r)

proc showMessages*(p: MessagesPanel) = p.root.activePageIndex = 0
proc showOutput*(p: MessagesPanel) = p.root.activePageIndex = 1

proc jump*(p: MessagesPanel, msgIndex: int) =
  ## Does what a double click on that message does.
  if msgIndex >= 0 and msgIndex < p.msgs.len and p.msgs[msgIndex].hasLocation and p.onJump != nil:
    p.select msgIndex
    p.cursor = msgIndex
    let m = p.msgs[msgIndex]
    p.onJump(m.file, m.line, m.col)

proc nextJumpable*(p: MessagesPanel): int =
  ## The next message with a location (and a visible row) after `cursor`,
  ## wrapping around; -1 when there is none.
  let n = p.msgs.len
  for k in 1 .. n:
    let i = (p.cursor + k + n) mod n
    if p.msgs[i].hasLocation and p.shown(p.msgs[i]): return i
  -1

proc jumpNext*(p: MessagesPanel): bool {.discardable.} =
  ## F8: selects the next message and jumps to it (false: there is none).
  let i = p.nextJumpable()
  if i < 0: return false
  p.jump i
  true
