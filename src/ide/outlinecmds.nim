## View > To-Do List and View > Code Explorer.
##
## To-Do List: the scan of the project's units for marked comments (`todoscan`)
## into the To-Do List window (`todopanel`). The text of a unit with unsaved
## edits is what is scanned, not the file. The list is refreshed by its button,
## when the window is shown, and at the next idle moment after a save, a close
## or a project change.
##
## Code Explorer: the declarations of the active unit (`codeoutline`) in the
## Code Explorer window (`codeexplorer`). It follows the active editor at once
## and the text after `IdeForm.outlineDelay` seconds without edits, and only
## when the text changed (the model's version counts). Both are done by
## `flushOutline`, the idle hook.

import std/[os, times]
import nimvcl
import ./[findinfiles, todoscan, todopanel, codeoutline, codeexplorer,
          uniteditor, ideform, ideeditors]

proc collectTodos*(ide: IdeForm): seq[TodoEntry] =
  ## The marked comments of the main file and the units, in that order.
  if ide.project == nil: return
  for file in ide.project.projectFiles(fsUnits):
    var text = ""
    let name = ide.unitOfFile(file)
    let ed = if name.len > 0: ide.editorOf(name) else: nil
    if ed != nil and ed.modified:
      text = ed.code.text
    else:
      try:
        if getFileSize(file) > MaxFileSize: continue
        text = readFile(file)
      except CatchableError: continue
    for it in scanTodos(text):
      result.add TodoEntry(item: it, unitName: name, file: file)

proc refreshTodos*(ide: IdeForm) =
  ide.todoDirty = false
  ide.todo.setEntries ide.collectTodos()

proc toggleTodo*(ide: IdeForm) =
  ## View > To-Do List: shows the window with a fresh list, or hides it.
  if ide.pnlTodo.state == dpHidden:
    ide.refreshTodos()
    ide.pnlTodo.show()
  else:
    ide.pnlTodo.hide()

proc refreshExplorer*(ide: IdeForm) =
  ## Makes the Code Explorer show the active unit as it is now.
  let ed = ide.activeEditor
  ide.outlineEd = ed
  if ed == nil:
    ide.outlineVersion = -1
    ide.outlineSeen = -1
    ide.explorer.setItems @[]
    return
  ide.outlineVersion = ed.code.model.version
  ide.outlineSeen = ide.outlineVersion
  ide.explorer.setItems outlineOf(ed.code.text)

proc toggleExplorer*(ide: IdeForm) =
  ## View > Code Explorer: shows the window with the active unit, or hides it.
  if ide.pnlExplorer.state == dpHidden:
    ide.refreshExplorer()
    ide.pnlExplorer.show()
  else:
    ide.pnlExplorer.hide()

proc explorerJump*(ide: IdeForm, line: int) =
  ## Double click on a declaration: the caret goes to its line in the code of
  ## the unit the Code Explorer shows.
  let ed = ide.outlineEd
  if ed == nil or ide.editors.find(ed) < 0: return
  ide.openUnit(ed.unitName).gotoLine(line, 1)
  ide.activeControl = ed.code

proc flushOutline*(ide: IdeForm) =
  ## The idle hook: brings the To-Do List and the Code Explorer up to date when
  ## they are shown and something changed.
  if ide.todoDirty and ide.pnlTodo.state != dpHidden: ide.refreshTodos()
  if ide.pnlExplorer.state == dpHidden: return
  let ed = ide.activeEditor
  if ed != ide.outlineEd:
    ide.refreshExplorer()
  elif ed != nil:
    let v = ed.code.model.version
    if v != ide.outlineSeen:
      ide.outlineSeen = v                  # edits restart the delay
      ide.outlineChanged = epochTime()
    if v != ide.outlineVersion and epochTime() - ide.outlineChanged >= ide.outlineDelay:
      ide.refreshExplorer()
