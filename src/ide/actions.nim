## The IDE's commands: one `ActionList` holds every action; the menu items and
## the toolbar buttons are all linked to these actions, so a caption, icon,
## shortcut or enabled state is defined (and changed) in one place.
##
## `IdeActions` only creates the actions (caption, hint, shortcut, icon); the
## main form assigns `onExecute` and `onUpdate`.

import nimvcl
import ./icons

type
  ActId* = enum
    aNewApp, aNewForm, aNewInheritedForm, aOpenProject, aSave, aSaveAs, aSaveProjectAs, aSaveAll, aClose, aExit,
    aUndo, aRedo, aCut, aCopy, aPaste, aDelete, aSelectAll, aRevertProp, aRevertComponent,
    aFind, aReplace, aFindNext, aGotoLine, aFindUnit, aQuickFix,
    aViewProjectMgr, aViewInspector, aViewTree, aViewMessages, aToggleView, aTheme,
    aViewUnits, aViewForms,
    aAddToProject, aAddFont, aRemoveFromProject, aViewSource, aProjectOptions,
    aCompile, aRun, aReset, aRunParameters, aShowHints, aNextMessage, aNextMessageAlt,
    aPointer, aFindComponent, aBringToFront, aSendToBack, aAlignLefts, aAlignTops, aCenterH, aCenterV,
    aEditorOptions, aAbout

  IdeActions* = ref object
    list*: ActionList
    icons*: ImageList          ## the `ic*` icons (`ActionList.images`)
    acts: array[ActId, Action]

  ActDef = tuple[id: ActId, caption, hint, key: string, icon: int]

const defs: array[ActId, ActDef] = [
  (aNewApp, "New &Application", "Create a new application", "", icNewApp),
  (aNewForm, "New &Form", "Add a new form to the project", "", icNewForm),
  (aNewInheritedForm, "New &Inherited Form...", "Add a form that inherits from another form of the project", "", icFormUnit),
  (aOpenProject, "&Open Project...", "Open a project", "Ctrl+F11", icOpen),
  (aSave, "&Save", "Save the current unit", "Ctrl+S", icSave),
  (aSaveAs, "Save &As...", "Save the current unit under another name", "", icSave),
  (aSaveProjectAs, "Save Project As&...", "Rename the project", "", -1),
  (aSaveAll, "Save &All", "Save every unit and the project", "Shift+Ctrl+S", icSaveAll),
  (aClose, "&Close", "Close the current unit", "Ctrl+W", icClose),
  (aExit, "E&xit", "Quit the IDE", "Alt+F4", icExit),
  (aUndo, "&Undo", "Undo", "Ctrl+Z", icUndo),
  (aRedo, "&Redo", "Redo", "Shift+Ctrl+Z", icRedo),
  (aCut, "Cu&t", "Cut", "Ctrl+X", icCut),
  (aCopy, "&Copy", "Copy", "Ctrl+C", icCopy),
  (aPaste, "&Paste", "Paste", "Ctrl+V", icPaste),
  (aDelete, "&Delete", "Delete the selection", "Ctrl+Del", icDelete),
  (aSelectAll, "Select &All", "Select all", "Ctrl+A", -1),
  (aRevertProp, "Revert to &Inherited", "Put the selected property of an inherited component back to the ancestor form's value", "", -1),
  (aRevertComponent, "Revert Component to Inherited", "Put every property of the selected inherited component back to the ancestor form's values", "", -1),
  (aFind, "&Find...", "Find text", "Ctrl+F", icFind),
  (aReplace, "&Replace...", "Find and replace text", "Ctrl+H", -1),
  (aFindNext, "Find &Next", "Find the next match", "F3", -1),
  (aGotoLine, "&Go to Line Number...", "Jump to a line", "Alt+G", -1),
  (aFindUnit, "Find &Unit...", "Add the import of the nimvcl module that declares the identifier at the caret", "Shift+Ctrl+A", -1),
  (aQuickFix, "&Quick Fix", "Apply the fix of the selected compiler message (add a missing import, correct a name)", "Ctrl+.", -1),
  (aViewProjectMgr, "&Project Manager", "Show or hide the Project Manager", "Ctrl+Alt+P", icProjectMgr),
  (aViewInspector, "&Object Inspector", "Show or hide the Object Inspector", "F11", icInspectorIc),
  (aViewTree, "Object Tree&View", "Show or hide the Object TreeView", "Shift+Alt+F11", icTreeIc),
  (aViewMessages, "&Messages", "Show or hide the Messages window", "Alt+0", icMessagesIc),
  (aToggleView, "Toggle &Form/Unit", "Switch between the form and its code", "F12", icToggle),
  (aTheme, "&Dark Theme", "Switch between the light and dark theme", "", -1),
  (aViewUnits, "&Units...", "Open a unit of the project", "Ctrl+F12", icUnit),
  (aViewForms, "Fo&rms...", "Open a form of the project", "Shift+F12", icFormUnit),
  (aAddToProject, "&Add to Project...", "Add an existing unit to the project", "Shift+F11", icAdd),
  (aAddFont, "Add &Font File...", "Copy a .ttf or .otf into the project's fonts folder and embed it in the program", "", -1),
  (aRemoveFromProject, "&Remove from Project", "Remove the current unit from the project", "", icRemove),
  (aViewSource, "&View Source", "Show the main program file", "", icProject),
  (aProjectOptions, "&Options...", "Compiler flags and output folder", "Shift+Ctrl+F11", icOptions),
  (aCompile, "&Compile", "Compile the project", "Ctrl+F9", icCompile),
  (aRun, "&Run", "Compile (if needed) and run", "F9", icRun),
  (aReset, "Program Re&set", "Stop the running program", "Ctrl+F2", icReset),
  (aRunParameters, "&Parameters...", "Command line arguments of the program", "", icOptions),
  (aShowHints, "Show &Hints", "Show compiler hints in Messages", "", icHint),
  (aNextMessage, "&Next Message", "Go to the next compiler message", "F8", -1),
  (aNextMessageAlt, "Next Message", "Go to the next compiler message", "Ctrl+Alt+Down", -1),
  (aPointer, "&Pointer", "Stop placing components", "", icPointer),
  (aFindComponent, "Find &Component", "Search the component palette", "Ctrl+Alt+C", -1),
  (aBringToFront, "Bring to &Front", "Bring the selection to the front", "", -1),
  (aSendToBack, "&Send to Back", "Send the selection to the back", "", -1),
  (aAlignLefts, "Align &Left Edges", "Align the selection to the left edge", "", -1),
  (aAlignTops, "Align &Top Edges", "Align the selection to the top edge", "", -1),
  (aCenterH, "Center &Horizontally", "Center the selection horizontally", "", -1),
  (aCenterV, "Center &Vertically", "Center the selection vertically", "", -1),
  (aEditorOptions, "&Editor Options...", "Editor font size", "", -1),
  (aAbout, "&About NimRAD", "About", "", icHelp)]

proc `[]`*(a: IdeActions, id: ActId): Action = a.acts[id]

proc newIdeActions*(owner: Form, icons: ImageList): IdeActions =
  ## Creates the list (owned by `owner`, so the shortcuts work anywhere in the
  ## window) and every action.
  result = IdeActions(icons: icons)
  result.list = newActionList(owner)
  result.list.images = icons
  for d in defs:
    let a = newAction(result.list, d.caption, nil,
                      (if d.key.len > 0: shortcut(d.key) else: noShortcut))
    a.hint = d.hint
    a.imageIndex = d.icon
    result.acts[d.id] = a

iterator pairs*(a: IdeActions): (ActId, Action) =
  for id in ActId: yield (id, a.acts[id])
