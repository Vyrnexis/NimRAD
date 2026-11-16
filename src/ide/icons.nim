## Procedurally drawn icons of the IDE: no image files. Every icon is a small
## "inside" test on a unit square (`proc(u, v: float): bool`), rasterised at 2x
## with 3x3 supersampling into an `ImageList`.
##
## * `makeIdeIcons()`: command, message and project-tree icons (`ic*` constants).
## * `makePaletteIcons()`: one icon per component class of the palette.

import std/[math, tables]
import nimvcl

type Shape = proc(u, v: float): bool

const
  icNewApp* = 0
  icNewForm* = 1
  icOpen* = 2
  icSave* = 3
  icSaveAll* = 4
  icUndo* = 5
  icRedo* = 6
  icCut* = 7
  icCopy* = 8
  icPaste* = 9
  icDelete* = 10
  icFind* = 11
  icCompile* = 12
  icRun* = 13
  icReset* = 14
  icToggle* = 15
  icProjectMgr* = 16
  icInspectorIc* = 17
  icMessagesIc* = 18
  icError* = 19
  icWarning* = 20
  icHint* = 21
  icInfo* = 22
  icSuccess* = 23
  icPointer* = 24
  icAdd* = 25
  icRemove* = 26
  icOptions* = 27
  icUnit* = 28
  icFormUnit* = 29
  icProject* = 30
  icTreeIc* = 31
  icClose* = 32
  icExit* = 33
  icHelp* = 34
  icCount* = 35

  blue = rgb(0x3b, 0x7c, 0xe0)
  green = rgb(0x2f, 0xa4, 0x6a)
  red = rgb(0xd9, 0x4a, 0x4a)
  amber = rgb(0xe8, 0x9a, 0x1c)
  violet = rgb(0x84, 0x64, 0xd8)
  slate = rgb(0x78, 0x88, 0x9c)

# ------------------------------------------------------------------ shapes

proc rc(u, v, x0, y0, x1, y1: float): bool = u >= x0 and u <= x1 and v >= y0 and v <= y1

proc frame(u, v, x0, y0, x1, y1: float, w = 0.09): bool =
  rc(u, v, x0, y0, x1, y1) and not rc(u, v, x0 + w, y0 + w, x1 - w, y1 - w)

proc disc(u, v, cx, cy, r: float): bool = (u - cx) * (u - cx) + (v - cy) * (v - cy) <= r * r

proc ring(u, v, cx, cy, r, w: float): bool =
  let d = sqrt((u - cx) * (u - cx) + (v - cy) * (v - cy))
  d <= r and d >= r - w

proc seg(u, v, x1, y1, x2, y2, w: float): bool =
  let dx = x2 - x1
  let dy = y2 - y1
  let l2 = dx * dx + dy * dy
  let t = if l2 == 0: 0.0 else: clamp(((u - x1) * dx + (v - y1) * dy) / l2, 0.0, 1.0)
  let px = x1 + t * dx
  let py = y1 + t * dy
  (u - px) * (u - px) + (v - py) * (v - py) <= (w / 2) * (w / 2)

proc poly(u, v: float, pts: openArray[(float, float)]): bool =
  ## Even-odd point in polygon.
  var j = pts.len - 1
  for i in 0 ..< pts.len:
    let (xi, yi) = pts[i]
    let (xj, yj) = pts[j]
    if (yi > v) != (yj > v) and u < (xj - xi) * (v - yi) / (yj - yi) + xi:
      result = not result
    j = i

proc makeIcon(size: int, color: Color, inside: Shape): Image =
  let n = size * 2
  result = newImage(n, n)
  for y in 0 ..< n:
    for x in 0 ..< n:
      var hit = 0
      for sy in 0 .. 2:
        for sx in 0 .. 2:
          if inside((x.float + (sx.float + 0.5) / 3) / n.float,
                    (y.float + (sy.float + 0.5) / 3) / n.float):
            inc hit
      if hit > 0: result.setPixel(x, y, rgba(color.r.int, color.g.int, color.b.int, hit * 255 div 9))

proc sWindow(u, v: float): bool =
  rc(u, v, 0.06, 0.12, 0.94, 0.3) or frame(u, v, 0.06, 0.12, 0.94, 0.88, 0.08)
proc sFolder(u, v: float): bool = rc(u, v, 0.06, 0.3, 0.94, 0.84) or rc(u, v, 0.06, 0.16, 0.4, 0.32)
proc sFloppy(u, v: float): bool =
  rc(u, v, 0.1, 0.1, 0.9, 0.9) and not rc(u, v, 0.28, 0.1, 0.72, 0.38) and
    not rc(u, v, 0.26, 0.56, 0.74, 0.9)
proc sFile(u, v: float): bool =
  (rc(u, v, 0.2, 0.08, 0.8, 0.92) and not (u > 0.56 and v < 0.32 and (u - 0.56) > (0.32 - v))) and
    not rc(u, v, 0.32, 0.5, 0.68, 0.58) and not rc(u, v, 0.32, 0.68, 0.68, 0.76)
proc sTree(u, v: float): bool =
  rc(u, v, 0.08, 0.1, 0.34, 0.24) or rc(u, v, 0.18, 0.24, 0.24, 0.8) or
    rc(u, v, 0.24, 0.42, 0.4, 0.5) or rc(u, v, 0.24, 0.72, 0.4, 0.8) or
    rc(u, v, 0.4, 0.34, 0.92, 0.58) or rc(u, v, 0.4, 0.66, 0.92, 0.88)
proc sSliders(u, v: float): bool =
  rc(u, v, 0.1, 0.22, 0.9, 0.3) or rc(u, v, 0.1, 0.46, 0.9, 0.54) or rc(u, v, 0.1, 0.7, 0.9, 0.78) or
    rc(u, v, 0.55, 0.12, 0.67, 0.4) or rc(u, v, 0.26, 0.36, 0.38, 0.64) or rc(u, v, 0.66, 0.6, 0.78, 0.88)
proc sBubble(u, v: float): bool =
  frame(u, v, 0.08, 0.14, 0.92, 0.72, 0.09) or rc(u, v, 0.22, 0.72, 0.38, 0.9) or
    rc(u, v, 0.26, 0.32, 0.74, 0.4) or rc(u, v, 0.26, 0.48, 0.56, 0.56)
proc sGear(u, v: float): bool =
  ring(u, v, 0.5, 0.5, 0.3, 0.13) or rc(u, v, 0.43, 0.06, 0.57, 0.24) or
    rc(u, v, 0.43, 0.76, 0.57, 0.94) or rc(u, v, 0.06, 0.43, 0.24, 0.57) or
    rc(u, v, 0.76, 0.43, 0.94, 0.57) or seg(u, v, 0.22, 0.22, 0.32, 0.32, 0.14) or
    seg(u, v, 0.78, 0.22, 0.68, 0.32, 0.14) or seg(u, v, 0.22, 0.78, 0.32, 0.68, 0.14) or
    seg(u, v, 0.78, 0.78, 0.68, 0.68, 0.14)
proc sUndo(u, v: float): bool =
  poly(u, v, [(0.06, 0.4), (0.36, 0.14), (0.36, 0.66)]) or seg(u, v, 0.3, 0.4, 0.66, 0.4, 0.13) or
    seg(u, v, 0.66, 0.4, 0.88, 0.6, 0.13) or seg(u, v, 0.88, 0.6, 0.66, 0.82, 0.13) or
    seg(u, v, 0.66, 0.82, 0.4, 0.82, 0.13)
proc sRedo(u, v: float): bool = sUndo(1 - u, v)
proc sCut(u, v: float): bool =
  seg(u, v, 0.3, 0.08, 0.68, 0.66, 0.1) or seg(u, v, 0.7, 0.08, 0.32, 0.66, 0.1) or
    ring(u, v, 0.26, 0.78, 0.17, 0.08) or ring(u, v, 0.74, 0.78, 0.17, 0.08)
proc sCopy(u, v: float): bool =
  frame(u, v, 0.1, 0.1, 0.62, 0.7, 0.09) or
    (frame(u, v, 0.38, 0.3, 0.9, 0.9, 0.09) or rc(u, v, 0.46, 0.38, 0.82, 0.82))
proc sPaste(u, v: float): bool =
  frame(u, v, 0.14, 0.16, 0.86, 0.92, 0.09) or rc(u, v, 0.34, 0.06, 0.66, 0.26) or
    rc(u, v, 0.28, 0.42, 0.72, 0.5) or rc(u, v, 0.28, 0.62, 0.72, 0.7)
proc sDelete(u, v: float): bool =
  seg(u, v, 0.2, 0.2, 0.8, 0.8, 0.16) or seg(u, v, 0.8, 0.2, 0.2, 0.8, 0.16)
proc sFind(u, v: float): bool = ring(u, v, 0.42, 0.42, 0.34, 0.11) or seg(u, v, 0.66, 0.66, 0.9, 0.9, 0.16)
proc sRun(u, v: float): bool = poly(u, v, [(0.26, 0.1), (0.9, 0.5), (0.26, 0.9)])
proc sSquare(u, v: float): bool = rc(u, v, 0.2, 0.2, 0.8, 0.8)
proc sToggle(u, v: float): bool =
  seg(u, v, 0.1, 0.3, 0.74, 0.3, 0.12) or poly(u, v, [(0.66, 0.1), (0.92, 0.3), (0.66, 0.5)]) or
    seg(u, v, 0.26, 0.7, 0.9, 0.7, 0.12) or poly(u, v, [(0.34, 0.5), (0.08, 0.7), (0.34, 0.9)])
proc sPlus(u, v: float): bool = rc(u, v, 0.4, 0.14, 0.6, 0.86) or rc(u, v, 0.14, 0.4, 0.86, 0.6)
proc sMinus(u, v: float): bool = rc(u, v, 0.14, 0.4, 0.86, 0.6)
proc sPointer(u, v: float): bool =
  poly(u, v, [(0.22, 0.06), (0.22, 0.84), (0.4, 0.66), (0.54, 0.94), (0.68, 0.88),
              (0.54, 0.6), (0.8, 0.6)])
proc sErrorMark(u, v: float): bool =
  disc(u, v, 0.5, 0.5, 0.44) and not (seg(u, v, 0.32, 0.32, 0.68, 0.68, 0.13) or
                                       seg(u, v, 0.68, 0.32, 0.32, 0.68, 0.13))
proc sWarningMark(u, v: float): bool =
  poly(u, v, [(0.5, 0.06), (0.95, 0.9), (0.05, 0.9)]) and
    not (rc(u, v, 0.45, 0.35, 0.55, 0.65) or disc(u, v, 0.5, 0.77, 0.06))
proc sHintMark(u, v: float): bool =
  disc(u, v, 0.5, 0.5, 0.44) and not (rc(u, v, 0.44, 0.44, 0.56, 0.74) or disc(u, v, 0.5, 0.29, 0.07))
proc sInfoRing(u, v: float): bool =
  ring(u, v, 0.5, 0.5, 0.44, 0.08) or rc(u, v, 0.45, 0.44, 0.55, 0.74) or disc(u, v, 0.5, 0.29, 0.07)
proc sSuccessMark(u, v: float): bool =
  disc(u, v, 0.5, 0.5, 0.44) and not (seg(u, v, 0.26, 0.52, 0.44, 0.7, 0.13) or
                                       seg(u, v, 0.44, 0.7, 0.76, 0.32, 0.13))
proc sClose(u, v: float): bool =
  frame(u, v, 0.1, 0.1, 0.9, 0.9, 0.09) or seg(u, v, 0.32, 0.32, 0.68, 0.68, 0.11) or
    seg(u, v, 0.68, 0.32, 0.32, 0.68, 0.11)
proc sExit(u, v: float): bool =
  rc(u, v, 0.1, 0.12, 0.2, 0.88) or rc(u, v, 0.1, 0.12, 0.5, 0.22) or rc(u, v, 0.1, 0.78, 0.5, 0.88) or
    rc(u, v, 0.3, 0.45, 0.68, 0.55) or poly(u, v, [(0.62, 0.28), (0.94, 0.5), (0.62, 0.72)])
proc sHelp(u, v: float): bool =
  ring(u, v, 0.5, 0.5, 0.44, 0.08) or ring(u, v, 0.5, 0.36, 0.17, 0.09) or
    rc(u, v, 0.46, 0.5, 0.56, 0.64) or disc(u, v, 0.5, 0.78, 0.07)
proc sSaveAll(u, v: float): bool = sFloppy(u * 1.18 - 0.02, v * 1.18 - 0.02) or
  (u > 0.3 and v > 0.3 and sFloppy(u * 1.18 - 0.16, v * 1.18 - 0.16))

proc makeIdeIcons*(size = 16): ImageList =
  ## Icons in the order of the `ic*` constants.
  result = newImageList(size.float32, size.float32)
  let shapes: array[icCount, tuple[s: Shape, c: Color]] = [
    (Shape(sWindow), green),            # icNewApp
    (Shape(sWindow), blue),             # icNewForm
    (Shape(sFolder), amber),            # icOpen
    (Shape(sFloppy), blue),             # icSave
    (Shape(sSaveAll), blue),            # icSaveAll
    (Shape(sUndo), slate),              # icUndo
    (Shape(sRedo), slate),              # icRedo
    (Shape(sCut), slate),               # icCut
    (Shape(sCopy), slate),              # icCopy
    (Shape(sPaste), slate),             # icPaste
    (Shape(sDelete), red),              # icDelete
    (Shape(sFind), blue),               # icFind
    (Shape(sGear), blue),               # icCompile
    (Shape(sRun), green),               # icRun
    (Shape(sSquare), red),              # icReset
    (Shape(sToggle), violet),           # icToggle
    (Shape(sTree), blue),               # icProjectMgr
    (Shape(sSliders), blue),            # icInspectorIc
    (Shape(sBubble), blue),             # icMessagesIc
    (Shape(sErrorMark), red),           # icError
    (Shape(sWarningMark), amber),       # icWarning
    (Shape(sHintMark), blue),           # icHint
    (Shape(sInfoRing), slate),          # icInfo
    (Shape(sSuccessMark), green),       # icSuccess
    (Shape(sPointer), slate),           # icPointer
    (Shape(sPlus), green),              # icAdd
    (Shape(sMinus), red),               # icRemove
    (Shape(sSliders), slate),           # icOptions
    (Shape(sFile), slate),              # icUnit
    (Shape(sWindow), blue),             # icFormUnit
    (Shape(sFolder), amber),            # icProject
    (Shape(sTree), violet),             # icTreeIc
    (Shape(sClose), slate),             # icClose
    (Shape(sExit), slate),              # icExit
    (Shape(sHelp), blue)]               # icHelp
  for (s, c) in shapes: result.add makeIcon(size, c, s)

# ------------------------------------------------------------------ palette

proc pLabel(u, v: float): bool =
  seg(u, v, 0.14, 0.88, 0.5, 0.1, 0.14) or seg(u, v, 0.5, 0.1, 0.86, 0.88, 0.14) or rc(u, v, 0.3, 0.58, 0.7, 0.68)
proc pEdit(u, v: float): bool = frame(u, v, 0.06, 0.28, 0.94, 0.72, 0.08) or rc(u, v, 0.3, 0.4, 0.35, 0.6)
proc pMemo(u, v: float): bool =
  frame(u, v, 0.08, 0.08, 0.92, 0.92, 0.08) or rc(u, v, 0.2, 0.24, 0.8, 0.31) or
    rc(u, v, 0.2, 0.44, 0.8, 0.51) or rc(u, v, 0.2, 0.64, 0.56, 0.71)
proc pButton(u, v: float): bool =
  frame(u, v, 0.06, 0.26, 0.94, 0.74, 0.08) or rc(u, v, 0.3, 0.46, 0.7, 0.54)
proc pCheck(u, v: float): bool =
  frame(u, v, 0.14, 0.14, 0.86, 0.86, 0.1) or seg(u, v, 0.3, 0.52, 0.45, 0.68, 0.12) or
    seg(u, v, 0.45, 0.68, 0.74, 0.32, 0.12)
proc pRadio(u, v: float): bool = ring(u, v, 0.5, 0.5, 0.42, 0.1) or disc(u, v, 0.5, 0.5, 0.18)
proc pListBox(u, v: float): bool =
  frame(u, v, 0.1, 0.08, 0.9, 0.92, 0.08) or rc(u, v, 0.2, 0.22, 0.8, 0.32) or
    (rc(u, v, 0.2, 0.42, 0.8, 0.54)) or rc(u, v, 0.2, 0.66, 0.8, 0.76)
proc pCombo(u, v: float): bool =
  frame(u, v, 0.06, 0.26, 0.94, 0.74, 0.08) or poly(u, v, [(0.62, 0.42), (0.86, 0.42), (0.74, 0.62)])
proc pScrollBar(u, v: float): bool =
  frame(u, v, 0.32, 0.06, 0.68, 0.94, 0.08) or rc(u, v, 0.32, 0.3, 0.68, 0.62)
proc pGroupBox(u, v: float): bool =
  frame(u, v, 0.08, 0.22, 0.92, 0.9, 0.08) and not rc(u, v, 0.14, 0.18, 0.5, 0.3) or
    rc(u, v, 0.18, 0.1, 0.46, 0.3)
proc pPanel(u, v: float): bool = frame(u, v, 0.08, 0.2, 0.92, 0.8, 0.09) or rc(u, v, 0.26, 0.38, 0.5, 0.62)
proc pMainMenu(u, v: float): bool =
  frame(u, v, 0.06, 0.12, 0.94, 0.88, 0.08) or rc(u, v, 0.06, 0.12, 0.94, 0.34) or
    rc(u, v, 0.2, 0.5, 0.5, 0.58) or rc(u, v, 0.2, 0.68, 0.7, 0.76)
proc pPopup(u, v: float): bool =
  frame(u, v, 0.2, 0.08, 0.8, 0.92, 0.08) or rc(u, v, 0.32, 0.24, 0.68, 0.32) or
    rc(u, v, 0.32, 0.46, 0.68, 0.54) or rc(u, v, 0.32, 0.68, 0.68, 0.76)
proc pBevel(u, v: float): bool = rc(u, v, 0.06, 0.34, 0.94, 0.42) or rc(u, v, 0.06, 0.56, 0.94, 0.64)
proc pImage(u, v: float): bool =
  frame(u, v, 0.08, 0.16, 0.92, 0.84, 0.08) or disc(u, v, 0.68, 0.4, 0.09) or
    (v >= 0.5 and v <= 0.77 and abs(u - 0.38) <= (v - 0.45) * 0.9)
proc pPaintBox(u, v: float): bool =
  seg(u, v, 0.26, 0.74, 0.84, 0.16, 0.2) or disc(u, v, 0.2, 0.8, 0.13)
proc pSpin(u, v: float): bool =
  frame(u, v, 0.06, 0.24, 0.94, 0.76, 0.08) or poly(u, v, [(0.72, 0.46), (0.88, 0.46), (0.8, 0.34)]) or
    poly(u, v, [(0.72, 0.54), (0.88, 0.54), (0.8, 0.66)])
proc pTrack(u, v: float): bool =
  (rc(u, v, 0.06, 0.44, 0.94, 0.56) and not disc(u, v, 0.62, 0.5, 0.25)) or disc(u, v, 0.62, 0.5, 0.2)
proc pProgress(u, v: float): bool =
  frame(u, v, 0.06, 0.34, 0.94, 0.66, 0.08) or rc(u, v, 0.14, 0.42, 0.56, 0.58)
proc pScrollBox(u, v: float): bool =
  frame(u, v, 0.08, 0.08, 0.92, 0.92, 0.08) or rc(u, v, 0.74, 0.18, 0.82, 0.52)
proc pSplitter(u, v: float): bool =
  rc(u, v, 0.45, 0.06, 0.55, 0.94) or poly(u, v, [(0.08, 0.5), (0.34, 0.34), (0.34, 0.66)]) or
    poly(u, v, [(0.92, 0.5), (0.66, 0.34), (0.66, 0.66)])
proc pStatus(u, v: float): bool =
  frame(u, v, 0.06, 0.5, 0.94, 0.9, 0.08) or rc(u, v, 0.4, 0.5, 0.46, 0.9) or rc(u, v, 0.06, 0.14, 0.7, 0.22)
proc pToolBar(u, v: float): bool =
  frame(u, v, 0.06, 0.3, 0.94, 0.7, 0.08) or rc(u, v, 0.18, 0.42, 0.32, 0.58) or
    rc(u, v, 0.42, 0.42, 0.56, 0.58) or rc(u, v, 0.66, 0.42, 0.8, 0.58)
proc pPages(u, v: float): bool =
  rc(u, v, 0.08, 0.1, 0.42, 0.3) or rc(u, v, 0.48, 0.14, 0.72, 0.3) or
    frame(u, v, 0.08, 0.3, 0.92, 0.9, 0.08)
proc pGrid(u, v: float): bool =
  frame(u, v, 0.08, 0.1, 0.92, 0.9, 0.08) or rc(u, v, 0.08, 0.38, 0.92, 0.44) or
    rc(u, v, 0.08, 0.62, 0.92, 0.68) or rc(u, v, 0.36, 0.1, 0.42, 0.9) or rc(u, v, 0.62, 0.1, 0.68, 0.9)
proc pDrawGrid(u, v: float): bool = pGrid(u, v) or rc(u, v, 0.42, 0.44, 0.62, 0.62)
proc pListView(u, v: float): bool =
  for i in 0 .. 2:
    let y = 0.14 + i.float * 0.28
    if rc(u, v, 0.1, y, 0.24, y + 0.16) or rc(u, v, 0.32, y + 0.03, 0.9, y + 0.13): return true
proc pCode(u, v: float): bool =
  seg(u, v, 0.34, 0.24, 0.1, 0.5, 0.12) or seg(u, v, 0.1, 0.5, 0.34, 0.76, 0.12) or
    seg(u, v, 0.66, 0.24, 0.9, 0.5, 0.12) or seg(u, v, 0.9, 0.5, 0.66, 0.76, 0.12) or
    seg(u, v, 0.57, 0.18, 0.43, 0.82, 0.1)
proc pTimer(u, v: float): bool =
  ring(u, v, 0.5, 0.52, 0.4, 0.1) or seg(u, v, 0.5, 0.52, 0.5, 0.26, 0.1) or
    seg(u, v, 0.5, 0.52, 0.7, 0.6, 0.1) or rc(u, v, 0.42, 0.04, 0.58, 0.12)
proc pImageList(u, v: float): bool =
  frame(u, v, 0.06, 0.06, 0.62, 0.62, 0.08) or frame(u, v, 0.38, 0.38, 0.94, 0.94, 0.08) or
    disc(u, v, 0.66, 0.66, 0.08)
proc pActionList(u, v: float): bool =
  poly(u, v, [(0.62, 0.04), (0.2, 0.56), (0.46, 0.56), (0.36, 0.96), (0.8, 0.4), (0.54, 0.4)])
proc pForm(u, v: float): bool = sWindow(u, v)

proc makePaletteIcons*(size = 16): tuple[images: ImageList, index: Table[string, int]] =
  ## One icon per palette class, plus "Form" (the form itself); `index` maps a
  ## class name to its image index (-1 is returned by `iconOf` for unknown names).
  result.images = newImageList(size.float32, size.float32)
  let defs: seq[(string, Shape, Color)] = @[
    ("Label", pLabel, blue), ("Edit", pEdit, blue), ("Memo", pMemo, blue),
    ("Button", pButton, blue), ("CheckBox", pCheck, green), ("RadioButton", pRadio, green),
    ("ListBox", pListBox, blue), ("ComboBox", pCombo, blue), ("ScrollBar", pScrollBar, slate),
    ("GroupBox", pGroupBox, amber), ("Panel", pPanel, amber), ("MainMenu", pMainMenu, violet),
    ("PopupMenu", pPopup, violet), ("Bevel", pBevel, slate), ("Image", pImage, green),
    ("PaintBox", pPaintBox, red), ("SpinEdit", pSpin, blue), ("TrackBar", pTrack, slate),
    ("ProgressBar", pProgress, green), ("ScrollBox", pScrollBox, amber), ("Splitter", pSplitter, slate),
    ("StatusBar", pStatus, blue), ("ToolBar", pToolBar, blue), ("PageControl", pPages, amber),
    ("StringGrid", pGrid, blue), ("DrawGrid", pDrawGrid, blue), ("TreeView", sTree, violet),
    ("ListView", pListView, violet), ("CodeEdit", pCode, violet), ("Timer", pTimer, amber),
    ("ImageList", pImageList, green), ("ActionList", pActionList, amber), ("Form", pForm, blue)]
  for (name, s, c) in defs:
    result.index[name] = result.images.count
    result.images.add makeIcon(size, c, s)

proc iconOf*(index: Table[string, int], className: string): int =
  index.getOrDefault(className, -1)
