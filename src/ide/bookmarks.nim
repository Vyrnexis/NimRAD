## Numbered bookmarks (Delphi's Ctrl+Shift+0..9 and Ctrl+0..9) of one code
## editor. The editor shows a bookmark marker in the gutter; which slot
## (0 .. 9) owns the line is kept here, because nimvcl's markers have no number.
##
## nimvcl's markers are the truth: they follow their line when lines are
## inserted or removed, are dropped with a deleted line, are carried by
## Alt+Up/Down and come back with an undo. The slots follow them. A change
## listener on the model first moves the slots by the same rule as the markers
## (first line, old count, new count); `reconcile` then compares them with
## `markerLines`: a slot whose marker is not where the slot is takes the
## unclaimed marker on a neighbouring line (a moved line), else it is dropped
## and remembered in `lost`, so that the marker an undo puts back gets its slot
## again. A slot never stays on a line without a marker.

import nimvcl

const BookmarkSlots* = 10

type
  Bookmarks* = ref object
    code: CodeEdit
    lines: array[BookmarkSlots, int]     ## -1: the slot is free
    lost: array[BookmarkSlots, int]      ## where a dropped slot was, -1 none

func shifted(l, first, oldN, newN: int): int =
  ## The rule of nimvcl's `markersChanged`.
  if l >= first + oldN: l + newN - oldN
  elif l >= first + newN: first + max(newN, 1) - 1
  else: l

proc reconcile(b: Bookmarks) =
  let marks = b.code.markerLines(MarkerKind.mkBookmark)
  var claimed: seq[int]
  for i in 0 ..< BookmarkSlots:
    if b.lines[i] >= 0 and b.lines[i] in marks: claimed.add b.lines[i]
  for i in 0 ..< BookmarkSlots:
    let l = b.lines[i]
    if l < 0 or l in marks: continue
    b.lines[i] = -1
    for d in [1, -1]:                    # the line was moved up or down
      if l + d in marks and l + d notin claimed:
        b.lines[i] = l + d
        claimed.add l + d
        break
    if b.lines[i] < 0: b.lost[i] = l
  for i in 0 ..< BookmarkSlots:          # a marker put back (undo)
    let l = b.lost[i]
    if l >= 0 and b.lines[i] < 0 and l in marks and l notin claimed:
      b.lines[i] = l
      b.lost[i] = -1
      claimed.add l

proc newBookmarks*(code: CodeEdit): Bookmarks =
  let b = Bookmarks(code: code)
  for i in 0 ..< BookmarkSlots:
    b.lines[i] = -1
    b.lost[i] = -1
  code.onLinesMove = proc(e: CodeEdit, first, last, nbFirst, nbLast: int, up: bool) =
    ## Alt+Up/Down: the slots swap with their lines (before the markers do, so
    ## that `reconcile` finds them in place).
    let blk = last - first + 1
    let nb = nbLast - nbFirst + 1
    proc moved(l: int): int =
      if l in first .. last: l + (if up: -nb else: nb)
      elif l in nbFirst .. nbLast: l + (if up: blk else: -blk)
      else: l
    for i in 0 ..< BookmarkSlots:
      if b.lines[i] >= 0: b.lines[i] = moved(b.lines[i])
      if b.lost[i] >= 0: b.lost[i] = moved(b.lost[i])
  discard code.model.addChangeListener(proc(first, oldN, newN: int) =
    for i in 0 ..< BookmarkSlots:
      if b.lines[i] >= 0: b.lines[i] = shifted(b.lines[i], first, oldN, newN)
      if b.lost[i] >= 0: b.lost[i] = shifted(b.lost[i], first, oldN, newN)
    b.reconcile())
  b

proc lineOf*(b: Bookmarks, slot: int): int =
  ## The line (0 based) of the bookmark, -1 when the slot is free.
  if slot notin 0 ..< BookmarkSlots: return -1
  b.reconcile()
  b.lines[slot]

proc shared(b: Bookmarks, line, skip: int): bool =
  for i in 0 ..< BookmarkSlots:
    if i != skip and b.lines[i] == line: return true

proc clear*(b: Bookmarks, slot: int) =
  ## Frees the slot and removes its marker (when no other slot is on that line).
  let l = b.lineOf(slot)
  if l < 0: return
  b.lines[slot] = -1
  b.lost[slot] = -1
  if not b.shared(l, slot): b.code.removeMarker(l, MarkerKind.mkBookmark)

proc set*(b: Bookmarks, slot, line: int) =
  ## Puts the bookmark `slot` on `line` (0 based), moving it from where it was.
  if slot notin 0 ..< BookmarkSlots or line notin 0 ..< b.code.lineCount: return
  b.clear slot
  b.lines[slot] = line
  b.lost[slot] = -1
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
