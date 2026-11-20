## View > To-Do List: the scan of the project's units for marked comments
## (`todoscan`) into the To-Do List window (`todopanel`). The text of a unit
## with unsaved edits is what is scanned, not the file. The list is refreshed
## by its button, when the window is shown, and at the next idle moment after a
## save, a close or a project change (`flushOutline`).

import std/os
import nimvcl
import ./[project, findinfiles, todoscan, todopanel, uniteditor, ideform, ideeditors]

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

proc flushOutline*(ide: IdeForm) =
  ## The idle hook: brings the To-Do List up to date when it is shown and
  ## something changed.
  if ide.todoDirty and ide.pnlTodo.state != dpHidden: ide.refreshTodos()
