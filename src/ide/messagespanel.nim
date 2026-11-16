## The Messages window: a tab "Messages" (a ListView of the parsed compiler
## messages, one icon per kind) and a tab "Output" (the raw text of the
## compiler and of the running program).
##
## Double click on a message with a location calls `onJump(file, line, col)`
## (1-based, as the compiler prints them). Lines are fed one at a time with
## `feed`; `finish` completes the last message.

import std/[os, strutils]
import nimvcl
import ./[messages, icons]

type
  MessagesPanel* = ref object
    root*: PageControl
    list*: ListView
    output*: Memo
    onJump*: proc(file: string, line, col: int)
    msgs*: seq[Message]        ## the messages that have a row (item.tag = index)
    errorCount*, warningCount*: int
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

proc addRow(p: MessagesPanel, m: Message) =
  let label = case m.kind
    of MessageKind.mkError: "Error: "
    of MessageKind.mkWarning: "Warning: "
    of MessageKind.mkHint: "Hint: "
    of MessageKind.mkInfo: ""
  let where = if m.hasLocation: m.file.extractFilename else: ""
  let pos = if m.hasLocation: $m.line & ":" & $m.col else: ""
  let it = p.list.items.add((if m.isTrace: "  at " else: label) & firstLine(m.text), where, pos)
  it.imageIndex = iconOfKind(m)
  it.tag = p.msgs.len
  p.msgs.add m
  if m.kind == MessageKind.mkError: inc p.errorCount
  elif m.kind == MessageKind.mkWarning: inc p.warningCount

proc wanted(m: Message): bool =
  ## Plain output lines (`CC: x.nim`, config hints) stay in the Output tab only.
  m.hasLocation or m.isTrace or m.kind in {MessageKind.mkError, MessageKind.mkWarning}

proc newMessagesPanel*(parent: Container, images: ImageList): MessagesPanel =
  ## `images` is the IDE icon list (`makeIdeIcons`).
  result = MessagesPanel()
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
      p.onJump(p.msgs[k].file, p.msgs[k].line, p.msgs[k].col)

  p.output = newMemo(t2)
  p.output.align = alClient
  p.output.readOnly = true
  p.output.font = currentTheme().monoFont

proc clear*(p: MessagesPanel) =
  p.list.items.clear()
  p.output.clear()
  p.msgs.setLen 0
  p.errorCount = 0
  p.warningCount = 0
  p.parser = MessageParser()

proc addOutput*(p: MessagesPanel, line: string) =
  p.output.lines.add line

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
  let it = p.list.items.add(text)
  it.imageIndex = icon
  it.tag = -1
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
    let m = p.msgs[msgIndex]
    p.onJump(m.file, m.line, m.col)
