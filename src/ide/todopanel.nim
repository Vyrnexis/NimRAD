## The To-Do List window: a Refresh button over a ListView with the columns
## priority, text, unit and line. A double click (or Enter) on an entry calls
## `onJump(file, line)`; the button calls `onRefresh`. The scan is `todoscan`
## and the wiring is in `outlinecmds`.

import std/strutils
import nimvcl
import ./todoscan

type
  TodoEntry* = object
    item*: TodoItem
    unitName*, file*: string

  TodoPanel* = ref object
    root*: Panel
    list*: ListView
    refreshButton*: Button
    onJump*: proc(file: string, line: int)
    onRefresh*: proc()
    entries*: seq[TodoEntry]     ## what the rows show, in order (item.tag = index)

proc captionOf(e: TodoEntry): string =
  var t = e.item.marker
  if e.item.text.len > 0: t.add ": " & e.item.text
  if e.item.owner.len > 0: t.add "  (" & e.item.owner & ")"
  if e.item.category.len > 0: t.add "  [" & e.item.category & "]"
  t

proc newTodoPanel*(parent: Container): TodoPanel =
  result = TodoPanel()
  let p = result
  p.root = newPanel(parent)
  p.root.align = alClient
  let bar = newPanel(p.root)
  bar.align = alTop
  bar.height = 34
  p.refreshButton = newButton(bar, "Refresh", 6, 4, 90, 26)
  p.refreshButton.onClick = proc(sender: Control) =
    if p.onRefresh != nil: p.onRefresh()
  p.list = newListView(p.root)
  p.list.align = alClient
  p.list.viewStyle = vsReport
  p.list.rowSelect = true
  p.list.columns.add("!", 40)
  p.list.columns.add("To-Do", 520)
  p.list.columns.add("Unit", 140)
  p.list.columns.add("Line", 60)
  let open = proc(index: int) =
    if index < 0 or index >= p.list.items.count: return
    let k = p.list.items[index].tag
    if k >= 0 and k < p.entries.len and p.onJump != nil:
      p.onJump(p.entries[k].file, p.entries[k].item.line)
  p.list.onItemDblClick = proc(sender: Control, index, column: int) = open(index)
  p.list.onKeyDown = proc(sender: Control, key: var Key, shift: ShiftState) =
    if key == keyEnter and shift == {}:
      open(p.list.itemIndex)
      key = Key(0)

proc setEntries*(p: TodoPanel, entries: seq[TodoEntry]) =
  ## Replaces the rows (the selected entry stays selected when it is still there).
  var keep = -1
  if p.list.itemIndex >= 0 and p.list.itemIndex < p.list.items.count:
    let k = p.list.items[p.list.itemIndex].tag
    if k >= 0 and k < p.entries.len:
      let old = p.entries[k]
      for i, e in entries:
        if e.file == old.file and e.item.line == old.item.line and e.item.text == old.item.text: keep = i
  p.entries = entries
  p.list.beginUpdate()
  try:
    p.list.items.clear()
    for i, e in entries:
      let it = p.list.items.add(if e.item.priority > 0: $e.item.priority else: "", e.captionOf, e.unitName, $e.item.line)
      it.tag = i
  finally:
    p.list.endUpdate()
  if keep >= 0: p.list.itemIndex = keep
