## The real dialogs behind the hooks of `IdeForm` (`askSave`, `showError`,
## `askText`, `pickFile`, `pickItem`); tests replace the hooks.

import std/[sequtils, strutils]
import nimvcl
import ./[project, ideform, findinfiles]

proc askSaveDefault*(unitName: string): SaveChoice =
  let d = newForm(nil, 440, 150)
  d.caption = "Save changes"
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  newLabel(d, "Save changes to " & unitName & "?", 24, 28, 390)
  let save = newButton(d, "&Save", 96, 90, 96, 32)
  save.modalResult = mrYes
  save.isDefault = true
  let discardBtn = newButton(d, "Do&n't Save", 200, 90, 112, 32)
  discardBtn.modalResult = mrNo
  let cancel = newButton(d, "Cancel", 320, 90, 96, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  withModal(d):
    result = case dlgResult
             of mrYes: scSave
             of mrNo: scDiscard
             else: scCancel

proc pickItemDefault*(title: string, items: seq[string], selected: int): int =
  let d = newForm(nil, 380, 380)
  d.caption = title
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  let lb = newListBox(d, 16, 16, 348, 270)
  for it in items: lb.items.add it
  lb.itemIndex = clamp(selected, 0, max(items.len - 1, 0))
  lb.onDblClick = proc(sender: Control) = d.modalResult = mrOk
  let ok = newButton(d, "OK", 188, 306, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 280, 306, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  d.activeControl = lb
  withModal(d):
    result = if dlgResult == mrOk: lb.itemIndex else: -1

proc askTextDefault*(caption, prompt: string, value: var string): bool =
  inputQuery(caption, prompt, value)

proc askOverwriteDefault*(text: string): bool =
  messageDlg(text, mtWarning, {mbYes, mbCancel}, mbCancel, "Save") == mrYes

proc showErrorDefault*(text: string) = messageDlg(text, mtError)

proc pickFileDefault*(ide: IdeForm): proc(title: string, filters: seq[(string, string)]): string =
  ## A file open dialog; it starts in the project's folder (the projects
  ## folder when there is none, and for "Open Project").
  result = proc(title: string, filters: seq[(string, string)]): string =
    let dlg = newOpenDialog(ide)
    dlg.title = title
    dlg.initialDir = if ide.project != nil and title != "Open Project": ide.project.dir
                     else: defaultProjectsDir()
    dlg.filters = filters & @[("All files", "*")]
    if dlg.executeModal(): dlg.fileName else: ""

proc radioColumn(d: Form, title: string, items: openArray[string], left, top, width: float32,
                 selected: int): seq[RadioButton] =
  let box = newGroupBox(d, title, left, top, width, 24 + 28 * items.len.float32 + 8)
  for i, it in items:
    result.add newRadioButton(box, it, i == selected, 12, 8 + 28 * i.float32, width - 24)

proc askAlignDefault*(o: var AlignOptions): bool =
  let d = newForm(nil, 440, 300)
  d.caption = "Alignment"
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  let hs = radioColumn(d, "Horizontal", ["No change", "Left sides", "Centers", "Right sides",
                                         "Space equally", "Center in window"],
                       16, 12, 200, ord o.horizontal)
  let vs = radioColumn(d, "Vertical", ["No change", "Tops", "Centers", "Bottoms",
                                       "Space equally", "Center in window"],
                       224, 12, 200, ord o.vertical)
  let ok = newButton(d, "OK", 244, 252, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 336, 252, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  withModal(d):
    if dlgResult == mrOk:
      for i, b in hs:
        if b.checked: o.horizontal = HorzAlign(i)
      for i, b in vs:
        if b.checked: o.vertical = VertAlign(i)
      result = true

proc askSizeDefault*(o: var SizeOptions): bool =
  let d = newForm(nil, 440, 250)
  d.caption = "Size"
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  let names = ["No change", "Shrink to smallest", "Grow to largest", "Width:"]
  let hnames = ["No change", "Shrink to smallest", "Grow to largest", "Height:"]
  let ws = radioColumn(d, "Width", names, 16, 12, 200, ord o.widthMode)
  let hs = radioColumn(d, "Height", hnames, 224, 12, 200, ord o.heightMode)
  let wv = newSpinEdit(d, o.width, 120, 120 - 28 + 4 + 12, 84, 24)
  wv.minValue = 1
  wv.maxValue = 10000
  let hv = newSpinEdit(d, o.height, 328, 120 - 28 + 4 + 12, 84, 24)
  hv.minValue = 1
  hv.maxValue = 10000
  let ok = newButton(d, "OK", 244, 200, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 336, 200, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  withModal(d):
    if dlgResult == mrOk:
      for i, b in ws:
        if b.checked: o.widthMode = SizeMode(i)
      for i, b in hs:
        if b.checked: o.heightMode = SizeMode(i)
      o.width = wv.value
      o.height = hv.value
      result = true

proc askOrderDefault*(title: string, items: seq[string]): seq[int] =
  ## A list with Move Up and Move Down; OK gives the indexes in the new order.
  let d = newForm(nil, 380, 380)
  d.caption = title
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  var order = toSeq(0 ..< items.len)
  let lb = newListBox(d, 16, 16, 250, 270)
  for i in order: lb.items.add items[i]
  lb.itemIndex = 0
  proc move(by: int) =
    let i = lb.itemIndex
    let j = i + by
    if i < 0 or j < 0 or j >= order.len: return
    swap(order[i], order[j])
    lb.items[i] = items[order[i]]
    lb.items[j] = items[order[j]]
    lb.itemIndex = j
  let up = newButton(d, "Move &Up", 276, 16, 90, 32)
  up.onClick = proc(sender: Control) = move(-1)
  let down = newButton(d, "Move &Down", 276, 56, 90, 32)
  down.onClick = proc(sender: Control) = move(1)
  let ok = newButton(d, "OK", 188, 306, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 280, 306, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  d.activeControl = lb
  withModal(d):
    if dlgResult == mrOk: result = order

proc askEditorOptionsDefault*(o: var EditorOptions): bool =
  let d = newForm(nil, 440, 290)
  d.caption = "Editor Options"
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  newLabel(d, "Font:", 20, 24, 100)
  let family = newComboBox(d, csDropDown, 130, 20, 290)
  family.items.add "(default monospace)"
  var seen: seq[string]
  for f in systemFontFamilies() & registeredFontFamilies():
    if f notin seen:
      seen.add f
      family.items.add f
  family.text = if o.fontFamily.len > 0: o.fontFamily else: family.items[0]
  newLabel(d, "Font size (6 - 40):", 20, 66, 110)
  let size = newSpinEdit(d, o.fontSize, 130, 62, 84, 24)
  size.minValue = 6
  size.maxValue = 40
  newLabel(d, "Tab width (1 - 16):", 20, 106, 110)
  let tab = newSpinEdit(d, o.tabWidth, 130, 102, 84, 24)
  tab.minValue = 1
  tab.maxValue = 16
  let spaces = newCheckBox(d, "Insert spaces for Tab", o.insertSpaces, 20, 144, 380)
  let nums = newCheckBox(d, "Show line numbers", o.lineNumbers, 20, 176, 380)
  let ok = newButton(d, "OK", 244, 230, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 336, 230, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  withModal(d):
    if dlgResult == mrOk:
      let t = family.text.strip
      o.fontFamily = if t == family.items[0] or t.len == 0: "" else: t
      o.fontSize = size.value
      o.tabWidth = tab.value
      o.insertSpaces = spaces.checked
      o.lineNumbers = nums.checked
      result = true

proc askFindInFilesDefault*(o: var FindOptions): bool =
  let d = newForm(nil, 460, 290)
  d.caption = "Find in Files"
  d.borderStyle = bsSingle
  d.position = poScreenCenter
  newLabel(d, "Text to find:", 20, 24, 100)
  let text = newEdit(d, o.text, 130, 20, 310)
  let cs = newCheckBox(d, "Case sensitive", o.caseSensitive, 20, 62, 200)
  let ww = newCheckBox(d, "Whole words only", o.wholeWord, 20, 92, 200)
  let rx = newCheckBox(d, "Regular expression", o.regex, 20, 122, 200)
  let scope = radioColumn(d, "Where", ["All units of the project", "The project folder"],
                          236, 56, 204, ord o.scope)
  let ok = newButton(d, "OK", 264, 232, 84, 32)
  ok.modalResult = mrOk
  ok.isDefault = true
  let cancel = newButton(d, "Cancel", 356, 232, 84, 32)
  cancel.modalResult = mrCancel
  cancel.isCancel = true
  d.activeControl = text
  withModal(d):
    if dlgResult == mrOk:
      o.text = text.text
      o.caseSensitive = cs.checked
      o.wholeWord = ww.checked
      o.regex = rx.checked
      o.scope = if scope[1].checked: fsFolder else: fsUnits
      result = o.text.len > 0
