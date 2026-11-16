## The component palette: a tabbed strip (Standard, Additional, Views, System)
## with one tool button per component class, like Delphi's.
##
## A click on a class selects it (`onPick(className)`: the main form calls the
## active unit editor's `beginCreate`); a click on the arrow or on the selected
## class again, or `reset`, goes back to the pointer (`onCancel`). Only classes
## that the property registry knows are offered.

import std/tables
import nimvcl
import nimvcl/dsl/[props, props_std]
import ./icons

type
  PaletteTab* = tuple[name: string, classes: seq[string]]

  ComponentPalette* = ref object
    root*: PageControl
    onPick*: proc(className: string)
    onCancel*: proc()
    picked*: string                      ## the selected class, "" for the pointer
    buttons: seq[(string, ToolButton)]   ## ("" for the pointers)

const paletteTabs*: array[4, PaletteTab] = [
  ("Standard", @["Label", "Edit", "Memo", "Button", "CheckBox", "RadioButton", "ListBox",
                 "ComboBox", "ScrollBar", "GroupBox", "Panel", "MainMenu", "PopupMenu"]),
  ("Additional", @["Bevel", "Image", "PaintBox", "SpinEdit", "TrackBar", "ProgressBar",
                   "ScrollBox", "Splitter", "StatusBar", "ToolBar", "PageControl",
                   "StringGrid", "DrawGrid"]),
  ("Views", @["TreeView", "ListView", "CodeEdit"]),
  ("System", @["Timer", "ImageList", "ActionList"])]

proc known*(className: string): bool = classByName(className) != nil

proc classes*(p: ComponentPalette): seq[string] =
  ## Every class that has a button (the pointers excluded).
  for (n, b) in p.buttons:
    if n.len > 0: result.add n

proc sync(p: ComponentPalette) =
  for (n, b) in p.buttons:
    b.down = n == p.picked

proc reset*(p: ComponentPalette) =
  ## Back to the pointer (does not call `onCancel`).
  p.picked = ""
  p.sync()

proc pick*(p: ComponentPalette, className: string) =
  ## What a click on the button of `className` does ("" = the pointer).
  if className.len == 0 or className == p.picked:
    let wasPicking = p.picked.len > 0
    p.reset()
    if wasPicking and p.onCancel != nil: p.onCancel()
  elif className.known:
    p.picked = className
    p.sync()
    if p.onPick != nil: p.onPick(className)

proc buttonRect*(p: ComponentPalette, className: string): RectF =
  ## Where the button is, in form coordinates (tests and screenshots).
  for (n, b) in p.buttons:
    if n == className and b.visible:
      let o = b.clientToForm(pointF(0, 0))
      return rectF(o.x, o.y, b.width, b.height)

proc pickHandler(p: ComponentPalette, className: string): proc(sender: Control) =
  ## A separate proc so that every button captures its own class name.
  result = proc(sender: Control) = p.pick(className)

proc newComponentPalette*(parent: Container, ide: ImageList, paletteImages: ImageList,
                          index: Table[string, int]): ComponentPalette =
  ## `ide` supplies the pointer icon (`icPointer` of `makeIdeIcons`), the
  ## class icons come from `makePaletteIcons`.
  result = ComponentPalette()
  let p = result
  p.root = newPageControl(parent)
  p.root.align = alClient
  for tab in paletteTabs:
    let sheet = newTabSheet(p.root, tab.name)
    let bar = newToolBar(sheet)
    bar.images = paletteImages
    # the pointer first, as a button of the same list (its icon is the
    # last one of the palette list: see below)
    let ptr0 = newToolButton(bar, "", tbsCheck)
    ptr0.hint = "Pointer"
    ptr0.glyph = proc(c: Canvas, r: RectF, color: Color) =
      let s = min(r.w, r.h) * 0.8
      let x = r.x + (r.w - s) / 2
      let y = r.y + (r.h - s) / 2
      c.drawImage(ide.image(icPointer), rectF(x, y, s, s))
    ptr0.down = true
    ptr0.onClick = proc(sender: Control) = p.pick("")
    p.buttons.add ("", ptr0)
    newToolButton(bar, kind = tbsSeparator)
    for cls in tab.classes:
      if not cls.known: continue
      let b = newToolButton(bar, cls, tbsCheck)
      b.showCaption = false
      b.imageIndex = index.iconOf(cls)
      b.hint = cls
      b.onClick = pickHandler(p, cls)
      p.buttons.add (cls, b)
