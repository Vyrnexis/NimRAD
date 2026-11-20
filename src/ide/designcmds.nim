## The form designer commands behind Edit > Align..., Size... and Tab Order...:
## each is a dialog hook of `IdeForm` (`askAlign`, `askSize`, `askOrder`) and a
## proc that does the work on the designer, so tests drive both.
##
## nimvcl's `FormDesigner` has no command for shrinking or growing to the
## smallest or largest control or for an exact size: those reorder the selection
## so the right control is the primary one (`makeSameSize` copies the primary's
## size), or resize one control at a time with `nudge`. Each step is one undo
## step.

import std/[sequtils, strutils]
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

proc sameExtent(d: FormDesigner, free: seq[Control], width: bool, grow: bool) =
  ## Every control of `free` gets the smallest (or largest) width or height.
  if free.len < 2: return
  var pick = free[0]
  for c in free:
    let (v, best) = if width: (c.width, pick.width) else: (c.height, pick.height)
    if (grow and v > best) or (not grow and v < best): pick = c
  d.select(@[pick] & free.filterIt(it != pick))     # the primary one is the model
  d.makeSameSize(width, not width)

proc applySize*(d: FormDesigner, o: SizeOptions) =
  let before = d.selection
  let free = d.freeControls
  if free.len > 0:
    for (width, mode) in [(true, o.widthMode), (false, o.heightMode)]:
      case mode
      of smNoChange: discard
      of smShrinkToSmallest: d.sameExtent(free, width, false)
      of smGrowToLargest: d.sameExtent(free, width, true)
      of smExact: discard
    if smExact in [o.widthMode, o.heightMode]:
      for c in free:
        let dx = if o.widthMode == smExact: o.width.float32 - c.width else: 0'f32
        let dy = if o.heightMode == smExact: o.height.float32 - c.height else: 0'f32
        if dx != 0 or dy != 0:
          d.select(c)
          d.nudge(dx, dy, resize = true)
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
  ed.setTabOrder(order.mapIt(comps[it]))
  true
