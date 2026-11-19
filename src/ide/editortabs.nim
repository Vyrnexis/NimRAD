## `EditorPages`: the PageControl of the editor tabs, with a close button
## (a small cross) at the right end of every tab. A click on the cross, or a
## click with the middle mouse button anywhere on a tab, calls `onCloseTab(i)`;
## closing (and asking about unsaved changes) is up to the owner.
##
## The room for the cross comes from blank space added to the tab's text
## (`sheetTabText`), so the tab strip itself is the stock PageControl one.

import std/strutils
import nimvcl

type
  EditorPages* = ref object of PageControl
    onCloseTab*: proc(index: int)
    fHot: int                   ## tab whose cross is under the mouse, -1 none

const
  GlyphSize = 14'f32            ## side of the (square) hit area of a cross
  Room = 18'f32                 ## width reserved for it at the end of a tab
  TabPadding = 14'f32           ## the PageControl's side padding of a tab text

proc roomText(p: EditorPages): string =
  ## Blanks that are at least `Room` wide in the tab font.
  let w = max(p.textWidth(" ", p.font), 1'f32)
  " ".repeat(int(Room / w) + 1)

method sheetTabText*(p: EditorPages, s: TabSheet): string =
  s.caption & p.roomText

proc closeRect*(p: EditorPages, i: int): RectF =
  ## The cross of tab `i` in client coordinates (empty when it is not shown).
  let r = p.tabRect(i)
  if r.w <= 0: return rectF(0, 0, 0, 0)
  let room = p.textWidth(p.roomText, p.font)
  let cx = r.right - TabPadding - room / 2
  let right = p.width - 2 - (if p.overflowing: 42'f32 else: 0'f32)
  if cx + GlyphSize / 2 > right: return rectF(0, 0, 0, 0)
  rectF(cx - GlyphSize / 2, r.y + (r.h - GlyphSize) / 2, GlyphSize, GlyphSize)

proc closeCrossAt(p: EditorPages, x, y: float32): int =
  ## The tab whose cross contains the point, else -1.
  let i = p.tabAt(x, y)
  if i >= 0 and p.closeRect(i).contains(pointF(x, y)): i else: -1

method paint*(p: EditorPages, c: Canvas) =
  procCall paint(PageControl(p), c)
  let th = p.theme
  for i in p.firstVisibleTab ..< p.tabCount:
    let r = p.closeRect(i)
    if r.w <= 0: continue
    let hot = p.fHot == i
    if hot: c.fillRoundRect(r, th.radius, th.hover)
    let col = if hot or i == p.tabIndex: th.text else: th.textMuted
    let m = 4'f32
    c.line(r.x + m, r.y + m, r.right - m, r.bottom - m, col, 1.4)
    c.line(r.right - m, r.y + m, r.x + m, r.bottom - m, col, 1.4)

method doMouseDown*(p: EditorPages, button: MouseButton, shift: ShiftState,
                    x, y: float32) =
  let i = p.tabAt(x, y)
  if i >= 0 and p.onCloseTab != nil and
     (button == mbMiddle or (button == mbLeft and p.closeCrossAt(x, y) == i)):
    p.onCloseTab(i)
    return
  procCall doMouseDown(TabBase(p), button, shift, x, y)

method doMouseMove*(p: EditorPages, shift: ShiftState, x, y: float32) =
  let h = p.closeCrossAt(x, y)
  if h != p.fHot:
    p.fHot = h
    p.invalidate()
  procCall doMouseMove(TabBase(p), shift, x, y)

method doMouseLeave*(p: EditorPages) =
  p.fHot = -1
  procCall doMouseLeave(TabBase(p))

proc newEditorPages*(): EditorPages =
  ## A page control without a parent yet (it is docked into a panel later).
  new result
  result.initPageControl(nil)
  result.fHot = -1
