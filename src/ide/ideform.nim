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
          messagespanel, uniteditor, editortabs]

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

  WatchedState* = tuple[msgs, panels, units: int, state: BuildState, prop: string]

  BuildPhase* = enum
    ## One state instead of a handful of flags. The `...ForRun` phases start the
    ## program when the build succeeds; the `Retry` ones are the second build
    ## after the automatic import fix (it never runs a third time).
    bpIdle, bpCompiling, bpCompilingForRun, bpRetrying, bpRetryingForRun, bpRunning

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
    pnlTree*, pnlInspector*, pnlProject*, pnlMessages*, pnlEditors*: DockPanel
    objTree*: TreeView
    inspector*: ObjectInspector
    projectTree*: ProjectTree
    messages*: MessagesPanel
    pages*: EditorPages
    status*: StatusBar
    editors*: seq[UnitEditor]
    sheets*: seq[TabSheet]
    bound*: UnitEditor
    defaultLayout*: string
    treeSig*: string
    treeDirty*: bool            ## the components of the bound form changed
    actionsDirty*: bool         ## something the action states depend on changed
    watched*: WatchedState
      ## what changes without an event of ours (messages, dock panels, project)
    treeComps*: seq[Component]
    treeNodes*: seq[TreeNode]
    syncingTree*: bool
    buildPhase*: BuildPhase     ## what the build controller is doing (see `buildcontroller`)
    failedPhase*: BuildPhase    ## the phase of the last build that failed (what a fix repeats)
    buildStart*: float
    lastExitCode*: int          ## exit code of the program that ran last
    lastBuildOk*: bool
    lastBuildInfo*: string
    buildCount*: int
    # modal dialogs (replaced by tests)
    askSave*: proc(unitName: string): SaveChoice
    showError*: proc(text: string)
    askText*: proc(caption, prompt: string, value: var string): bool
    pickFile*: proc(title: string, filters: seq[(string, string)]): string
    pickItem*: proc(title: string, items: seq[string], selected: int): int
      ## A list to choose from; the index, or -1 when cancelled.

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
  result.size = ide.settings.editorFontSize.float32

proc applyEditorFont*(ide: IdeForm) =
  for e in ide.editors: e.code.font = ide.editorFont
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
