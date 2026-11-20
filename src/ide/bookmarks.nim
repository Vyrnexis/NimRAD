## Numbered bookmarks (Delphi's Ctrl+Shift+0..9 and Ctrl+0..9) of one code
## editor. The editor shows a bookmark marker in the gutter; which slot
## (0 .. 9) owns the line is kept here, because nimvcl's markers have no number.
##
## nimvcl's markers follow their line when lines are inserted or removed, and
## a change listener on the model reports the same (first line, old count,
## new count), so the slots move by the same rule. A slot whose marker is gone
## (the text was loaded again) is forgotten when it is asked for.

import nimvcl

const BookmarkSlots* = 10

type
  Bookmarks* = ref object
    code: CodeEdit
    lines: array[BookmarkSlots, int]     ## -1: the slot is free

proc newBookmarks*(code: CodeEdit): Bookmarks =
  let b = Bookmarks(code: code)
  for i in 0 ..< BookmarkSlots: b.lines[i] = -1
  discard code.model.addChangeListener(proc(first, oldN, newN: int) =
    # the rule of nimvcl's `markersChanged`
    for i in 0 ..< BookmarkSlots:
      let l = b.lines[i]
      if l < 0: continue
      if l >= first + oldN: b.lines[i] = l + newN - oldN
      elif l >= first + newN: b.lines[i] = first + max(newN, 1) - 1)
  b

proc lineOf*(b: Bookmarks, slot: int): int =
  ## The line (0 based) of the bookmark, -1 when the slot is free.
  if slot notin 0 ..< BookmarkSlots: return -1
  let l = b.lines[slot]
  if l >= 0 and not b.code.hasMarker(l, MarkerKind.mkBookmark):
    b.lines[slot] = -1
    return -1
  b.lines[slot]

proc shared(b: Bookmarks, line, skip: int): bool =
  for i in 0 ..< BookmarkSlots:
    if i != skip and b.lines[i] == line: return true

proc clear*(b: Bookmarks, slot: int) =
  ## Frees the slot and removes its marker (when no other slot is on that line).
  let l = b.lineOf(slot)
  if l < 0: return
  b.lines[slot] = -1
  if not b.shared(l, slot): b.code.removeMarker(l, MarkerKind.mkBookmark)

proc set*(b: Bookmarks, slot, line: int) =
  ## Puts the bookmark `slot` on `line` (0 based), moving it from where it was.
  if slot notin 0 ..< BookmarkSlots or line notin 0 ..< b.code.lineCount: return
  b.clear slot
  b.lines[slot] = line
  b.code.addMarker(line, MarkerKind.mkBookmark)

proc toggle*(b: Bookmarks, slot, line: int): bool =
  ## Like Delphi: the bookmark on its own line is removed, otherwise it is put
  ## on `line`. True when it is set afterwards.
  if b.lineOf(slot) == line:
    b.clear slot
    false
  else:
    b.set(slot, line)
    b.lineOf(slot) == line
