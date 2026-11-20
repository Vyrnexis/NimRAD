## The IDE's main window object and the small helpers every part shares. The
## parts live in their own modules (`mainform` ties them together):
##
## * `idedialogs`: the real dialogs behind the hooks below;
## * `ideeditors`: editor tabs, Object TreeView, actions state, `sync`;
## * `projectcommands`: opening, creating and changing projects and units;
## * `buildcontroller`: compile, run, stop (one `BuildPhase` state);
## * `quickfixes`: fixes of compiler messages and Find Unit;
## * `ideui`: menus, toolbars, docking, the action wiring.

import nimvcl
import nimvcl/controls/inspector
import std/[os, tables, strutils]
import ./[project, builder, ideconfig, actions, palette, projecttree,
          messagespanel, uniteditor, editortabs, findinfiles, todopanel, codeexplorer, codeoutline]

proc versionOf(nimble: string): string {.compileTime.} =
  ## The `version = "..."` line of nimrad.nimble.
  for line in nimble.splitLines:
    let l = line.strip
    if l.startsWith("version"):
      let q1 = l.find('"')
      let q2 = l.rfind('"')
      if q1 >= 0 and q2 > q1: return l[q1 + 1 ..< q2]

const
  AppName* = "NimRAD"
  AppVersion* = versionOf(staticRead("../../nimrad.nimble"))
    ## From nimrad.nimble at compile time.

static: doAssert AppVersion.len > 0, "no version found in nimrad.nimble"

type
  SaveChoice* = enum scSave, scDiscard, scCancel

  HorzAlign* = enum
    haNoChange, haLeftSides, haCenters, haRightSides, haSpaceEqually, haCenterInWindow
  VertAlign* = enum
    vaNoChange, vaTops, vaCenters, vaBottoms, vaSpaceEqually, vaCenterInWindow
  AlignOptions* = object
    ## The Edit > Align dialog (Delphi's Alignment dialog).
    horizontal*: HorzAlign
    vertical*: VertAlign

  SizeMode* = enum smNoChange, smShrinkToSmallest, smGrowToLargest, smExact
  SizeOptions* = object
    ## The Edit > Size dialog; `width` and `height` count with `smExact`.
    widthMode*, heightMode*: SizeMode
    width*, height*: int

  EditorOptions* = object
    ## The Tools > Editor Options dialog (what `Settings` keeps for the editors).
    fontFamily*: string        ## "" = the theme's monospace font
    fontSize*, tabWidth*: int
    insertSpaces*, lineNumbers*: bool

  WatchedState* = tuple[msgs, panels, units: int, state: BuildState, prop: string]

  BuildPhase* = enum
    ## One state instead of a handful of flags. The `...ForRun` phases start the
    ## program when the build succeeds; the `Retry` ones are the second build
    ## after the automatic import fix (it never runs a third time).
    bpIdle, bpCompiling, bpCompilingForRun, bpRetrying, bpRetryingForRun, bpChecking, bpRunning

  IdeForm* = ref object of Form
    settings*: Settings
    settingsFile*: string
    project*: Project
    acts*: IdeActions
    ideIcons*: ImageList
    palIcons*: ImageList
    palIndex*: Table[string, int]
    menu*: MainMenu
    recentMenu*: MenuItem
    settingsFailed: bool       ## the last write of the settings file failed (said once)
    palette*: ComponentPalette
    site*: DockSite
    pnlTree*, pnlInspector*, pnlProject*, pnlMessages*, pnlEditors*, pnlTodo*, pnlExplorer*: DockPanel
    objTree*: TreeView
    inspector*: ObjectInspector
    projectTree*: ProjectTree
    messages*: MessagesPanel
    todo*: TodoPanel
    explorer*: CodeExplorer
    outlineEd*: UnitEditor      ## whose declarations the Code Explorer shows
    outlineVersion*: int        ## the text version it was made from
    outlineSeen*: int           ## the last version noticed (a change restarts the delay)
    outlineChanged*: float      ## when `outlineSeen` was noticed (`epochTime`)
    outlineDelay*: float        ## seconds without edits before the Code Explorer follows (0.3)
    todoDirty*: bool            ## the To-Do List is out of date (shown again at the next idle)
    pages*: EditorPages
    status*: StatusBar
    editors*: seq[UnitEditor]
    sheets*: seq[TabSheet]
    bound*: UnitEditor
    defaultLayout*: string
    treeSig*: string
    treeOwner*: UnitEditor      ## whose components the Object TreeView shows
    treeDirty*: bool            ## the components of the bound form changed
    actionsDirty*: bool         ## something the action states depend on changed
    watched*: WatchedState
      ## what changes without an event of ours (messages, dock panels, project)
    treeComps*: seq[Component]
    treeNodes*: seq[TreeNode]
    syncingTree*: bool
    buildPhase*: BuildPhase     ## what the build controller is doing (see `buildcontroller`)
    failedPhase*: BuildPhase    ## the phase of the last build that failed (what a fix repeats)
    buildForce*: bool           ## the build in progress ignores the up-to-date state (`-f`)
    buildStart*: float
    lastExitCode*: int          ## exit code of the program that ran last
    lastBuildOk*: bool
    lastBuildInfo*: string
    buildCount*: int
    # modal dialogs (replaced by tests)
    askSave*: proc(unitName: string): SaveChoice
    askOverwrite*: proc(text: string): bool
      ## "X changed on disk. Overwrite?"; false = leave the file alone (the save fails)
    showError*: proc(text: string)
    askText*: proc(caption, prompt: string, value: var string): bool
    pickFile*: proc(title: string, filters: seq[(string, string)]): string
    pickItem*: proc(title: string, items: seq[string], selected: int): int
      ## A list to choose from; the index, or -1 when cancelled.
    askAlign*: proc(o: var AlignOptions): bool
      ## The Align dialog; false when cancelled.
    askSize*: proc(o: var SizeOptions): bool
      ## The Size dialog; false when cancelled.
    askEditorOptions*: proc(o: var EditorOptions): bool
      ## The Editor Options dialog; false when cancelled.
    askFindInFiles*: proc(o: var FindOptions): bool
      ## The Find in Files dialog (starts with the options in `o`); false when cancelled.
    findOptions*: FindOptions    ## what Find in Files was asked last
    askOrder*: proc(title: string, items: seq[string]): seq[int]
      ## A list the user puts in order (Move Up, Move Down): the indexes of
      ## `items` in the new order, or empty when cancelled.

  ProjectOptions* = object
    ## The fields of the Project Options dialog (text as typed).
    outputDir*, flags*, defines*, title*, version*: string
    autoImports*, importAll*: bool

  StatusPart* = enum spState, spBuild, spCaret, spModified, spMessage

# ------------------------------------------------------------------ helpers

proc defaultProjectsDir*(): string = getHomeDir() / "nimvcl-projects"

proc say*(ide: IdeForm, text: string) =
  ide.status.panels[ord spMessage].text = text

proc setPart*(ide: IdeForm, part: StatusPart, text: string) =
  if ide.status.panels[ord part].text != text: ide.status.panels[ord part].text = text

proc fail*(ide: IdeForm, text: string) =
  ide.say text
  ide.showError text

template modal*(d: Form, r, body: untyped) =
  ## Runs `d` modally: `r` is the modal result inside `body` (which can still read
  ## the dialog's controls). The window is freed afterwards even when `body` or the
  ## dialog's own handlers raise.
  try:
    let r = d.showModal()
    body
  finally:
    d.freeWindow()

proc trySaveProject*(ide: IdeForm): bool =
  ## Saves the project file; a failure is reported and gives false.
  if ide.project == nil: return true
  try:
    ide.project.save()
    result = true
  except CatchableError as e:
    ide.fail "Cannot save the project " & ide.project.name & ": " & e.msg

proc activeIndex*(ide: IdeForm): int =
  if ide.editors.len == 0: -1 else: ide.pages.activePageIndex

proc activeEditor*(ide: IdeForm): UnitEditor =
  let i = ide.activeIndex
  if i >= 0 and i < ide.editors.len: ide.editors[i] else: nil

proc editorIndex*(ide: IdeForm, unitName: string): int =
  for i, e in ide.editors:
    if e.unitName == unitName: return i
  -1

proc editorOf*(ide: IdeForm, unitName: string): UnitEditor =
  let i = ide.editorIndex(unitName)
  if i >= 0: ide.editors[i] else: nil

proc busy*(ide: IdeForm): bool = buildState() != bsIdle

proc saveSettings*(ide: IdeForm) =
  ## Writes the settings file. A failure is said once in the status bar (and on
  ## stderr), not in a dialog: settings are written all the time.
  if ideconfig.saveSettings(ide.settings, ide.settingsFile):
    ide.settingsFailed = false
  elif not ide.settingsFailed:
    ide.settingsFailed = true
    let text = "Cannot save the settings file " & ide.settingsFile
    ide.say text
    stderr.writeLine "nimrad: " & text

proc isDark*(ide: IdeForm): bool = ide.settings.theme == "dark"

proc editorFont*(ide: IdeForm): FontSpec =
  result = currentTheme().monoFont
  if ide.settings.editorFontFamily.len > 0: result.family = ide.settings.editorFontFamily
  result.size = ide.settings.editorFontSize.float32

proc applyEditorOptions*(ide: IdeForm, ed: UnitEditor) =
  ## The font, tab width, tab key and gutter of the settings for one code editor.
  let s = ide.settings
  ed.code.font = ide.editorFont
  ed.code.tabWidth = s.editorTabWidth
  ed.code.insertSpaces = s.editorInsertSpaces
  ed.code.showLineNumbers = s.editorLineNumbers

proc applyEditorFont*(ide: IdeForm) =
  ## Applies the editor settings to every open editor and to the program Output.
  for e in ide.editors: ide.applyEditorOptions e
  ide.messages.output.font = ide.editorFont

proc updateCaption*(ide: IdeForm) =
  ide.caption = AppName & (if ide.project != nil: " - " & ide.project.name else: "") &
                (if ide.buildPhase == bpRunning: " [Running]" else: "")

proc isMainEditor*(ide: IdeForm, ed: UnitEditor): bool =
  ## The editor of the program file (it is not a unit of the project).
  ide.project != nil and ed != nil and ed.unitName == ide.project.name and
    ide.project.findUnit(ed.unitName) < 0

proc tabCaption*(ide: IdeForm, ed: UnitEditor): string =
  (if ide.isMainEditor(ed): ed.unitName & ".nim" else: ed.unitName) &
    (if ed.modified: "*" else: "")

proc modifiedUnits*(ide: IdeForm): seq[string] =
  for e in ide.editors:
    if e.modified: result.add e.unitName

proc updateTabs*(ide: IdeForm) =
  for i, e in ide.editors:
    let cap = ide.tabCaption(e)
    if ide.sheets[i].caption != cap: ide.sheets[i].caption = cap

proc updateStatus*(ide: IdeForm) =
  let ed = ide.activeEditor
  if ed != nil and not (ed.isForm and ed.designerVisible):
    let p = ed.code.caretPos
    ide.setPart(spCaret, $(p.line + 1) & ": " & $(p.col + 1))
  else:
    ide.setPart(spCaret, "")
  ide.setPart(spModified, if ed != nil and ed.modified: "Modified" else: "")

proc unitOfFile*(ide: IdeForm, file: string): string =
  ## The unit whose `.nim` is `file` ("" when it is not a unit of the project);
  ## the program file gives the project's name (what `openUnit` accepts for it).
  if ide.project == nil: "" else: ide.project.unitOfFile(file)
