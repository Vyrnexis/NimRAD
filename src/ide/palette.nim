## The component palette: a tabbed strip (Standard, Additional, Views, System)
## with one tool button per component class, like Delphi's.
##
## A click on a class selects it (`onPick(className)`: the main form calls the
## active unit editor's `beginCreate`); a click on the arrow or on the selected
## class again, or `reset`, goes back to the pointer (`onCancel`). Only classes
## that the property registry knows are offered.
##
## A filter edit above the tabs searches every tab at once: while it holds
## text a flat "Search results" group replaces the tabs (the tabs and the
## selected one stay as they were and come back when the filter is cleared).
## Down / Up move the highlight, Enter calls `onDrop(className)`, Esc clears
## the filter and calls `onLeave`.

import std/[tables, strutils, sequtils]
import nimvcl
import nimvcl/dsl/[props, props_std]
import ./icons

type
  PaletteTab* = tuple[name: string, classes: seq[string]]

  ComponentPalette* = ref object
    holder*: Panel                       ## the filter edit and the tabs / results
    filter*: Edit
    root*: PageControl                   ## the tabs
    results*: Panel                      ## "Search results", shown instead of the tabs
    onDrop*: proc(className: string)     ## Enter on the highlighted result
    onLeave*: proc()                     ## Esc: the filter was cleared, focus goes back
    highlighted*: string                 ## the result Enter acts on
    onPick*: proc(className: string)
    onCancel*: proc()
    picked*: string                      ## the selected class, "" for the pointer
    buttons: seq[(string, ToolButton)]   ## ("" for the pointers)
    found: seq[(string, ToolButton)]     ## the buttons of the results group
    resBar: ToolBar

const paletteTabs*: array[4, PaletteTab] = [
  ("Standard", @["Label", "Edit", "Memo", "Button", "CheckBox", "RadioButton", "ListBox",
                 "ComboBox", "ScrollBar", "GroupBox", "Panel", "MainMenu", "PopupMenu"]),
  ("Additional", @["Bevel", "Image", "PaintBox", "SpinEdit", "TrackBar", "ProgressBar",
                   "ScrollBox", "Splitter", "StatusBar", "ToolBar", "PageControl",
                   "StringGrid", "DrawGrid"]),
  ("Views", @["TreeView", "ListView", "CodeEdit"]),
  ("System", @["Timer", "ImageList", "ActionList"])]

# Words that find a class in the filter besides its name (the hint is the name).
const classKeywords* = [
  ("Label", "text caption static"), ("Edit", "text box input field single line"),
  ("Memo", "multiline text box multi line"), ("Button", "push click command"),
  ("CheckBox", "check tick toggle option"), ("RadioButton", "radio option choice"),
  ("ListBox", "list items choices"), ("ComboBox", "combo dropdown drop down list choice"),
  ("ScrollBar", "scroll slider"), ("GroupBox", "group frame container caption"),
  ("Panel", "container group box"), ("MainMenu", "menu bar"),
  ("PopupMenu", "context menu right click"), ("Bevel", "line border frame"),
  ("Image", "picture bitmap graphic png"), ("PaintBox", "draw canvas custom paint"),
  ("SpinEdit", "number spin updown integer"), ("TrackBar", "slider range"),
  ("ProgressBar", "progress bar percent"), ("ScrollBox", "scroll container"),
  ("Splitter", "resize divider"), ("StatusBar", "status panels bottom"),
  ("ToolBar", "tool strip icons"), ("PageControl", "tabs pages notebook tab sheet"),
  ("StringGrid", "table grid cells rows columns"), ("DrawGrid", "table grid custom cells"),
  ("TreeView", "tree nodes hierarchy"), ("ListView", "list report icons columns")]

proc keywordsOf*(className: string): string =
  ## The extra search words of a class ("" when it has none).
  for (n, k) in classKeywords:
    if n == className: return k
  case className
  of "CodeEdit": "code editor source syntax"
  of "Timer": "interval tick"
  of "ImageList": "images icons pictures"
  of "ActionList": "actions commands"
  else: ""

proc known*(className: string): bool = classByName(className) != nil

proc classes*(p: ComponentPalette): seq[string] =
  ## Every class that has a button (the pointers excluded).
  for (n, b) in p.buttons:
    if n.len > 0: result.add n

const filterHeight* = 24'f32          ## the filter edit above the tabs

proc sync(p: ComponentPalette) =
  for (n, b) in p.buttons:
    b.down = n == p.picked
  for (n, b) in p.found:
    b.down = n == p.picked or n == p.highlighted

func filtering*(p: ComponentPalette): bool = p.results != nil and p.results.visible

proc matches*(p: ComponentPalette): seq[string] =
  ## The classes the filter shows, in tab order.
  for (n, b) in p.found:
    if b.visible: result.add n

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
  for (n, b) in (if p.filtering: p.found else: p.buttons):
    if n == className and b.visible:
      let o = b.clientToForm(pointF(0, 0))
      return rectF(o.x, o.y, b.width, b.height)

proc highlight(p: ComponentPalette, className: string) =
  p.highlighted = className
  p.sync()

proc applyFilter*(p: ComponentPalette) =
  ## Shows the classes that contain the filter text (case-insensitive, in the
  ## class name or its search words, see `classKeywords`), or the tabs again when the text is empty.
  let q = p.filter.text.strip.toLowerAscii
  if q.len == 0:
    p.results.visible = false
    p.root.visible = true
    p.highlighted = ""
    p.sync()
    return
  var first = ""
  for (n, b) in p.found:
    let hit = q in n.toLowerAscii or q in n.keywordsOf
    b.visible = hit
    if hit and first.len == 0: first = n
  p.root.visible = false
  p.results.visible = true
  p.highlight(if p.highlighted.len > 0 and
                  p.found.anyIt(it[0] == p.highlighted and it[1].visible): p.highlighted
              else: first)

proc moveHighlight*(p: ComponentPalette, delta: int) =
  let m = p.matches
  if m.len == 0: return
  var i = m.find(p.highlighted)
  i = if i < 0: 0 else: (i + delta + m.len) mod m.len
  p.highlight(m[i])

proc clearFilter*(p: ComponentPalette) =
  p.filter.text = ""
  p.applyFilter()

proc focusFilter*(p: ComponentPalette) =
  p.filter.setFocus()
  p.filter.selectAll()

proc pickHandler(p: ComponentPalette, className: string): proc(sender: Control) =
  ## A separate proc so that every button captures its own class name.
  result = proc(sender: Control) = p.pick(className)

proc newComponentPalette*(parent: Container, ide: ImageList, paletteImages: ImageList,
                          index: Table[string, int]): ComponentPalette =
  ## `ide` supplies the pointer icon (`icPointer` of `makeIdeIcons`), the
  ## class icons come from `makePaletteIcons`.
  result = ComponentPalette()
  let p = result
  p.holder = newPanel(parent)
  p.holder.align = alClient
  p.holder.borderStyle = pbNone
  p.filter = newEdit(p.holder)
  p.filter.align = alTop
  p.filter.height = filterHeight
  p.filter.placeholder = "Search components"
  p.root = newPageControl(p.holder)
  p.root.align = alClient
  p.results = newPanel(p.holder)
  p.results.align = alClient
  p.results.borderStyle = pbNone
  p.results.visible = false
  let cap = newLabel(p.results, "Search results")
  cap.align = alLeft
  cap.width = 96
  p.resBar = newToolBar(p.results)
  p.resBar.align = alClient
  p.resBar.images = paletteImages
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
      b.imageIndex = index.iconOf(cls)
      b.showCaption = b.imageIndex < 0       # no icon: the name instead of a blank button
      b.hint = cls
      b.onClick = pickHandler(p, cls)
      p.buttons.add (cls, b)

  # the results group: one button per class, shown or hidden by the filter
  for cls in p.classes:
    let b = newToolButton(p.resBar, cls, tbsCheck)
    b.imageIndex = index.iconOf(cls)
    b.showCaption = b.imageIndex < 0
    b.hint = cls
    b.visible = false
    b.onClick = pickHandler(p, cls)
    p.found.add (cls, b)
  p.filter.onChange = proc(sender: Control) = p.applyFilter()
  p.filter.onKeyDown = proc(sender: Control, key: var Key, shift: ShiftState) =
    if shift != {}: return
    if key == keyDown and p.filtering: p.moveHighlight(1)
    elif key == keyUp and p.filtering: p.moveHighlight(-1)
    elif key == keyEnter:
      if p.filtering and p.highlighted.len > 0 and p.onDrop != nil:
        p.onDrop(p.highlighted)
    elif key == keyEscape:
      p.clearFilter()
      if p.onLeave != nil: p.onLeave()
    else: return
    key = Key(0)
