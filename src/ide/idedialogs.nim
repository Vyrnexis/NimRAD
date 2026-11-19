## The real dialogs behind the hooks of `IdeForm` (`askSave`, `showError`,
## `askText`, `pickFile`, `pickItem`); tests replace the hooks.

import nimvcl
import ./[project, ideform]

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
  let r = d.showModal()
  d.freeWindow()
  case r
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
  result = if d.showModal() == mrOk: lb.itemIndex else: -1
  d.freeWindow()

proc askTextDefault*(caption, prompt: string, value: var string): bool =
  inputQuery(caption, prompt, value)

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
