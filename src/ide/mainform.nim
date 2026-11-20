## The IDE's main window: menu, toolbars, component palette and a docking
## layout (Object TreeView and Object Inspector on the left, the unit editors
## in the middle, the Project Manager on the right, Messages at the bottom).
##
## Everything the user can do is a proc on `IdeForm` (`openProject`,
## `openUnit`, `compile`, `run`, ...), so the scripted session and the tests
## drive the same code as the menu. The few modal dialogs (save changes,
## errors, text input, file choice) are hooks (`askSave`, `showError`,
## `askText`, `pickFile`, `pickItem`) that tests replace.
##
## Where things live: `ideform` (the object and shared helpers), `ideeditors`
## (editors, tree, actions state, `sync`), `projectcommands`, `buildcontroller`,
## `quickfixes`, `ideui` (menus, toolbars, docking, action wiring) and
## `idedialogs`; this module builds the window and re-exports them all.
##
## `refreshTree`, `refreshActions`, ... are called from an idle hook after
## every batch of events (`flush`), and by hand in headless scripts (`sync`).

import std/[os, strutils]
import nimvcl
from sdl3 import getWindowFlags, maximizeWindow, WINDOW_MAXIMIZED, Rect,
  getDisplayForRect, getDisplayUsableBounds
import ./[project, ideconfig, icons, actions, palette, uniteditor]
import ./[ideform, idedialogs, ideeditors, designcmds, projectcommands, buildcontroller, quickfixes, findcmds, codecmds, outlinecmds, ideui]
export ideform, idedialogs, ideeditors, designcmds, projectcommands, buildcontroller, quickfixes, findcmds, outlinecmds, ideui

proc rememberWindow*(ide: IdeForm) =
  ## Puts the window's position and size (and whether it is maximized) into the
  ## settings. A maximized window keeps the size it had before.
  let w = ide.win
  if w == nil: return
  if (getWindowFlags(w.window) and WINDOW_MAXIMIZED) != 0:
    ide.settings.window.maximized = true
  else:
    let size = w.logicalSize
    let pos = w.position
    ide.settings.window = (pos.x, pos.y, int(size.w), int(size.h), false)

proc onSomeDisplay(x, y, w, h: int): bool =
  ## Whether a good part of the rectangle (the title bar at least) lies on a
  ## display, so a window put there can be reached; a display that has gone
  ## (a monitor unplugged) must not hide the IDE.
  var r = Rect(x: cint(x), y: cint(y), w: cint(w), h: cint(h))
  let d = getDisplayForRect(addr r)
  var u: Rect
  if d == 0 or not getDisplayUsableBounds(d, u): return false
  let ix = min(x + w, int(u.x + u.w)) - max(x, int(u.x))
  let iy = min(y + 40, int(u.y + u.h)) - max(y, int(u.y))
  ix >= 100 and iy >= 20

proc newIdeForm*(settingsFile = settingsPath(), width = 1360, height = 860): IdeForm =
  ## Builds the window (no project yet; see `startup`). `Application.init()`
  ## must have run. The settings are read from (and saved to) `settingsFile`.
  let ide = IdeForm()
  ide.initForm()
  ide.settingsFile = settingsFile
  ide.settings = loadSettings(settingsFile)
  ide.setBounds(0, 0, width.float32, height.float32)
  ide.position = poScreenCenter
  let ws = ide.settings.window
  if ws.w >= MinWindowW and ws.h >= MinWindowH and onSomeDisplay(ws.x, ws.y, ws.w, ws.h):
    # where the window was last time, when that is still on a display
    ide.setBounds(ws.x.float32, ws.y.float32, ws.w.float32, ws.h.float32)
    ide.position = poDesigned
  if ws.maximized:
    ide.onShow = proc(sender: Control) =
      discard maximizeWindow(ide.win.window)
  ide.askSave = askSaveDefault
  ide.askOverwrite = askOverwriteDefault
  ide.showError = showErrorDefault
  ide.askText = askTextDefault
  ide.pickItem = pickItemDefault
  ide.askAlign = askAlignDefault
  ide.askSize = askSizeDefault
  ide.askOrder = askOrderDefault
  ide.askFindInFiles = askFindInFilesDefault
  ide.askEditorOptions = askEditorOptionsDefault
  ide.pickFile = pickFileDefault(ide)
  Application.theme = if ide.isDark: themeDark() else: themeLight()

  ide.ideIcons = makeIdeIcons(16)
  let pal = makePaletteIcons(20)
  ide.palIcons = pal.images
  ide.palIndex = pal.index
  ide.acts = newIdeActions(ide, ide.ideIcons)

  ide.buildMenu()

  # top: toolbars at the left, the component palette filling the rest
  let top = newPanel(ide)
  top.align = alTop
  top.borderStyle = pbNone
  top.height = 72 + filterHeight       # the palette's filter edit sits above its tabs
  let bars = newPanel(top)
  bars.align = alLeft
  bars.borderStyle = pbNone
  bars.width = 380
  ide.buildToolbars(bars)
  ide.palette = newComponentPalette(top, ide.ideIcons, ide.palIcons, ide.palIndex)
  ide.palette.root.align = alClient
  ide.palette.onPick = proc(cls: string) =
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.beginCreate(cls)
    else:
      ide.palette.reset()
      ide.say "Open a form to place components"
  ide.palette.onDrop = proc(cls: string) =
    if ide.dropComponent(cls): ide.palette.clearFilter()
    ide.activeControl = nil
  ide.palette.onLeave = proc() = ide.activeControl = nil
  ide.palette.onCancel = proc() =
    let ed = ide.activeEditor
    if ed != nil and ed.isForm: ed.designer.cancelCreate()

  ide.status = newStatusBar(ide)
  discard ide.status.addPanel("Ready", 130)
  discard ide.status.addPanel("", 190)
  discard ide.status.addPanel("", 96, taCenter)
  discard ide.status.addPanel("", 80, taCenter)
  discard ide.status.addPanel("", 100)
  ide.status.sizeGrip = true

  ide.buildDocking()
  ide.connectActions()
  ide.refreshActions()
  ide.updateCaption()

  if ide.settings.layout.len > 0 and not ide.site.loadLayout(ide.settings.layout):
    ide.resetLayout()
    ide.say "The saved window layout could not be used; the default layout is shown (Reset Layout)"
  elif ide.settings.layout.len > 0 and "\"todo\"" notin ide.settings.layout:
    ide.pnlTodo.hide()                   # a layout saved before the To-Do List existed

  ide.onCloseQuery = proc(sender: Form, canClose: var bool) =
    # ask for every modified unit first (Cancel keeps the window open), then
    # save the chosen ones the way Save All does
    var chosen: seq[UnitEditor]
    for e in ide.editors:
      if e.modified:
        case ide.askSave(e.unitName)
        of scCancel:
          canClose = false
          return
        of scSave: chosen.add e
        of scDiscard: discard
    if not (ide.saveEditors(chosen) and ide.trySaveProject()):
      canClose = false                   # a failed save counts as Cancel
      return
    ide.programReset()
    ide.rememberOpenUnits()
    ide.rememberWindow()
    ide.saveLayout()
  Application.addIdleHook("ide-sync", proc() = ide.flush())
  Application.addIdleHook("ide-outline", proc() = ide.flushOutline())
  ide

proc projectArg*(args: openArray[string]): string =
  ## The project on the command line: the path after `--project` (or of
  ## `--project=path`), else the first plain argument ending in `.nimproj` (what
  ## a file association passes). "" when there is none.
  var positional = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--project":
      if i + 1 < args.len: return args[i + 1]
    elif a.startsWith("--project="):
      return a["--project=".len .. ^1]
    elif positional.len == 0 and not a.startsWith("-") and a.toLowerAscii.endsWith(ProjectExt):
      positional = a
    inc i
  positional

proc commandLineProblems*(args: openArray[string]): seq[string] =
  ## What is wrong with the command line: unknown options, a `--project` without
  ## a file, arguments that are not a `.nimproj`. One line each, for stderr.
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--project":
      if i + 1 < args.len: inc i
      else: result.add "--project needs a project file"
    elif a.startsWith("--project="):
      if a.len == "--project=".len: result.add "--project needs a project file"
    elif a in ["-h", "--help", "--nimvcl-path"]: discard
    elif a.startsWith("-"): result.add "unknown option " & a
    elif not a.toLowerAscii.endsWith(ProjectExt): result.add "ignored argument " & a & " (not a " & ProjectExt & " file)"
    inc i

proc startup*(ide: IdeForm, defaultDir = "", project = "") =
  ## Opens `project` when given (`--project path`), else the last project,
  ## else a fresh `Project1` in `defaultDir` (`~/nimvcl-projects/Project1`; an
  ## existing one is reopened). A `project` that cannot be opened is reported
  ## and the usual choice follows.
  if project.len > 0 and ide.openProject(absolutePath(project)): return
  for path in ide.settings.recentProjects:
    if fileExists(path) and ide.openProject(path): return
  let dir = if defaultDir.len > 0: defaultDir else: defaultProjectsDir() / "Project1"
  let existing = dir / "Project1" & ProjectExt
  if fileExists(existing) and ide.openProject(existing): return
  discard ide.newApplication(dir, "Project1")
