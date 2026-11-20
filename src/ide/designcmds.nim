## The form designer commands behind Edit > Align..., Size... and Tab Order...:
## each is a dialog hook of `IdeForm` (`askAlign`, `askSize`, `askOrder`) and a
## proc that does the work on the designer, so tests drive both.
##
## Size and Tab Order use the designer's `sizeSelection` and `setTabOrder`:
## each is one undo step.

import std/sequtils
import nimvcl
import ./[ideform, uniteditor]

proc freeControls(d: FormDesigner): seq[Control] =
  ## The selected controls that can be resized: not tiles, not aligned ones.
  d.selection.filterIt(not (it of NonVisualTile) and it.parent != nil and it.align == alNone)

proc applyAlign*(d: FormDesigner, o: AlignOptions) =
  case o.horizontal
  of haNoChange: discard
  of haLeftSides: d.alignSelection(aeLefts)
  of haCenters: d.alignSelection(aeHCenters)
  of haRightSides: d.alignSelection(aeRights)
  of haSpaceEqually: d.spaceEvenly(true)
  of haCenterInWindow: d.centerInParent(true, false)
  case o.vertical
  of vaNoChange: discard
  of vaTops: d.alignSelection(aeTops)
  of vaCenters: d.alignSelection(aeVCenters)
  of vaBottoms: d.alignSelection(aeBottoms)
  of vaSpaceEqually: d.spaceEvenly(false)
  of vaCenterInWindow: d.centerInParent(false, true)

proc applySize*(d: FormDesigner, o: SizeOptions) =
  ## The free controls of the selection get the smallest or largest extent, or
  ## the exact size, as one undo step (`sizeSelection`).
  let before = d.selection
  let free = d.freeControls
  if free.len == 0: return
  proc extent(width, grow: bool): float32 =
    result = if width: free[0].width else: free[0].height
    for c in free:
      let v = if width: c.width else: c.height
      if (grow and v > result) or (not grow and v < result): result = v
  proc pick(mode: SizeMode, exact: int, width: bool): float32 =
    case mode
    of smNoChange: -1'f32
    of smShrinkToSmallest: (if free.len < 2: -1'f32 else: extent(width, false))
    of smGrowToLargest: (if free.len < 2: -1'f32 else: extent(width, true))
    of smExact: exact.float32
  let w = pick(o.widthMode, o.width, true)
  let h = pick(o.heightMode, o.height, false)
  if w < 0 and h < 0: return
  d.select(free)
  d.sizeSelection(w, h)
  d.select(before)

proc hasDesignSelection*(ide: IdeForm): bool =
  let ed = ide.activeEditor
  ed != nil and ed.isForm and ed.designerVisible and ed.designer.selection.len > 0

proc alignDialog*(ide: IdeForm): bool {.discardable.} =
  ## Edit > Align...: asks, then aligns the selection. False when cancelled.
  if not ide.hasDesignSelection or ide.askAlign == nil: return false
  var o = AlignOptions()
  if not ide.askAlign(o): return false
  ide.activeEditor.designer.applyAlign(o)
  true

proc sizeDialog*(ide: IdeForm): bool {.discardable.} =
  ## Edit > Size...: asks, then resizes the selection. False when cancelled.
  if not ide.hasDesignSelection or ide.askSize == nil: return false
  let ed = ide.activeEditor
  var o = SizeOptions()
  let c = ed.designer.primary
  if c != nil and not (c of NonVisualTile):
    o.width = c.width.int
    o.height = c.height.int
  if not ide.askSize(o): return false
  ed.designer.applySize(o)
  true

proc tabOrderDialog*(ide: IdeForm): bool {.discardable.} =
  ## Edit > Tab Order...: the controls of the selected control's parent in tab
  ## order; the new order is applied through the editor. False when cancelled
  ## or when there is nothing to order.
  if not ide.hasDesignSelection or ide.askOrder == nil: return false
  let ed = ide.activeEditor
  let comps = ed.tabControls
  if comps.len < 2:
    ide.say "Fewer than two controls to put in order here"
    return false
  let order = ide.askOrder("Tab Order", comps.mapIt(it.name))
  if order.len != comps.len: return false
  ed.designer.setTabOrder(order.mapIt(comps[it]).filterIt(it of Control).mapIt(Control(it)))
  true
