## What the user does to the project: open, create, close, add and remove
## units and fonts, options, run parameters, rename. The procs work on the
## model and tell the window to refresh; the dialogs come from the hooks.

import nimvcl
import std/[os, strutils, sequtils]
import ./[cmdargs, project, ideconfig, messagespanel, uniteditor, mainfile,
          ideform, ideeditors]

proc refuseWhileBusy(ide: IdeForm, what: string): bool =
  ## True (after saying so) while the compiler or the program runs: the build
  ## belongs to the current project, so it must end first (Run > Program Reset).
  result = ide.busy
  if result:
    ide.fail "Cannot " & what & " while a build or program is running; use Program Reset first."

proc closeProject*(ide: IdeForm): bool =
  ## Closes the project and its editors (false: cancelled at the save prompt,
  ## or refused while a build or program is running).
  if ide.refuseWhileBusy("close the project"): return false
  if not ide.trySaveProject(): return false
  if not ide.closeAllEditors(): return false
  if ide.project != nil:
    ide.project.unregisterFonts()
  ide.project = nil
  ide.messages.clear()
  ide.refreshProject()
  true

proc rememberProject*(ide: IdeForm) =
  ide.settings.addRecent(ide.project.filePath)
  ide.saveSettings()
proc openProject*(ide: IdeForm, path: string): bool

proc openHandler(ide: IdeForm, path: string): MenuItemEvent =
  result = proc(s: MenuItem) = discard ide.openProject(path)

proc rebuildRecentMenu*(ide: IdeForm) =
  ## File > Reopen: the recent projects (at most `MaxRecent`), newest first.
  ide.recentMenu.clear()
  if ide.settings.recentProjects.len == 0:
    let none = ide.recentMenu.addItem("(none)")
    none.enabled = false
    return
  for i, path in ide.settings.recentProjects:
    let num = if i < 9: "&" & $(i + 1) else: "1&0"
    ide.recentMenu.addItem(num & "  " & path.extractFilename.changeFileExt("") & "   " & path.parentDir,
                           openHandler(ide, path))

proc openProject*(ide: IdeForm, path: string): bool =
  ## Opens a `.nimproj` (the current project is closed first). Refused while a
  ## build or program is running.
  if ide.refuseWhileBusy("open a project"): return false
  var p: Project
  try:
    p = loadProject(path)
  except CatchableError as e:
    let gone = not fileExists(path)
    ide.settings.removeRecent(path)
    ide.saveSettings()
    ide.rebuildRecentMenu()
    ide.fail(if gone: "The project " & path & " no longer exists; it was removed from the Reopen list."
             else: "Cannot open " & path & ": " & e.msg)
    return false
  if not ide.closeProject(): return false
  ide.project = p
  p.registerFonts()
  ide.messages.clear()
  ide.refreshProject()
  ide.rememberProject()
  ide.rebuildRecentMenu()
  if p.units.len > 0: discard ide.openUnit(p.units[0].name)
  ide.say "Opened project " & p.name
  true

proc nextProjectName(dir: string): string =
  var n = 1
  while dirExists(dir / ("Project" & $n)) or fileExists(dir / ("Project" & $n & ProjectExt)): inc n
  "Project" & $n

proc newApplication*(ide: IdeForm, dir = "", name = ""): bool =
  ## File > New Application: a project with one form. Without `dir` it goes to
  ## `~/nimvcl-projects/ProjectN`. Refused while a build or program is running.
  if ide.refuseWhileBusy("create a project"): return false
  if not ide.closeProject(): return false
  var d = dir
  var n = name
  if d.len == 0:
    n = nextProjectName(defaultProjectsDir())
    d = defaultProjectsDir() / n
  elif n.len == 0:
    n = d.extractFilename
  try:
    ide.project = newApplicationProject(d, n)
  except CatchableError as e:
    ide.fail "Cannot create the project: " & e.msg
    return false
  ide.messages.clear()
  ide.refreshProject()
  ide.rememberProject()
  ide.rebuildRecentMenu()
  if ide.project.units.len > 0: discard ide.openUnit(ide.project.units[0].name)
  ide.say "Created project " & ide.project.name & " in " & ide.project.dir
  true

proc newForm*(ide: IdeForm): UnitEditor =
  ## File > New Form: adds a form unit to the project and opens it.
  if ide.project == nil: return nil
  let mainEd = ide.beforeMainEdit()
  try:
    let u = ide.project.newFormUnit()       # also imports and creates it in the main file
    ide.project.save()
    ide.afterMainEdit(mainEd)
    ide.refreshProject()
    result = ide.openUnit(u.name)
  except CatchableError as e:
    ide.fail "Cannot create the form: " & e.msg

proc addToProject*(ide: IdeForm, path: string): bool =
  ## Adds an existing `.nim` unit (a form unit when a `.nfm` of the same name
  ## sits next to it).
  if ide.project == nil: return false
  let name = path.splitFile.name
  let nfm = path.changeFileExt(".nfm")
  let mainEd = ide.beforeMainEdit()
  try:
    if not validName(name): raise newException(ProjectError, "bad unit name " & name)
    if name == ide.project.name: raise newException(ProjectError, name & " is the program file")
    var u: ProjectUnit
    if fileExists(nfm):
      u = ide.project.addUnit(name, path, nfm, true, formTypeOfNfm(nfm),
                              ide.project.ancestorUnitOf(nfm))
    else:
      u = ide.project.addUnit(name, path)
    ide.project.save()
    if not ide.project.addToMain(u) and fileExists(ide.project.mainPath) and
       not readFile(ide.project.mainPath).hasBlock(ImportsBlock):
      ide.say "The main file has no nimrad markers: import " & name & " there yourself"
    ide.afterMainEdit(mainEd)
    ide.refreshProject()
    discard ide.openUnit(name)
    result = true
  except CatchableError as e:
    ide.fail "Cannot add " & path & ": " & e.msg

proc addFontFile*(ide: IdeForm, path: string): bool =
  ## Project > Add Font File: copies the font into `<project>/fonts/`, records it
  ## in the project and makes the main file register it at startup.
  if ide.project == nil: return false
  let mainEd = ide.beforeMainEdit()
  try:
    let f = ide.project.addFontFile(path)
    ide.project.save()
    ide.project.registerFonts()
    if not ide.project.syncFontsBlock() and fileExists(ide.project.mainPath) and
       not readFile(ide.project.mainPath).hasBlock(ImportsBlock):
      ide.say "The main file has no nimrad markers: register " & f.file & " there yourself"
    ide.afterMainEdit(mainEd)
    ide.say "Added font " & f.family & " (" & f.style & ")"
    result = true
  except CatchableError as e:
    ide.fail "Cannot add " & path & ": " & e.msg

proc removeFont*(ide: IdeForm, file = ""): bool =
  ## Project > Remove Font: takes a font out of the project, out of the main
  ## file's `fonts` block and out of the project's `fonts` folder (the file is
  ## deleted). Without `file` (as in `Project.fonts`) the font is chosen from a
  ## list, which is also the confirmation. The family is unregistered from
  ## this IDE session (faces still in the project are registered again), so it
  ## leaves the Object Inspector's list; it is gone from the next build too.
  if ide.project == nil: return false
  if ide.project.fonts.len == 0:
    ide.say "The project has no fonts"
    return false
  var target = file
  if target.len == 0:
    var labels: seq[string]
    for f in ide.project.fonts: labels.add f.family & " (" & f.style & ")  " & f.file
    let i = ide.pickItem("Remove Font: deletes the file from the project", labels, 0)
    if i < 0 or i >= ide.project.fonts.len: return false
    target = ide.project.fonts[i].file
  let mainEd = ide.beforeMainEdit()
  try:
    let f = ide.project.removeFont(target)
    ide.project.save()
    ide.project.syncFontsBlock()
    unregisterFontFamily(f.family)
    ide.project.registerFonts()      # other faces of the family stay
    ide.afterMainEdit(mainEd)
    ide.refreshProject()
    ide.say "Removed font " & f.family & " (" & f.style & ")"
    result = true
  except CatchableError as e:
    ide.fail "Cannot remove " & target & ": " & e.msg

proc removeFromProject*(ide: IdeForm, unitName: string): bool =
  ## Takes a unit out of the project (its files stay on disk). The unit that
  ## makes the main form cannot be removed.
  if ide.project == nil: return false
  let i = ide.project.findUnit(unitName)
  if i < 0: return false
  let u = ide.project.units[i]
  if ide.project.isMainForm(u):
    ide.fail "The main form (" & u.formType & ") cannot be removed from the project."
    return false
  let kids = ide.project.inheritorsOf(unitName)
  if kids.len > 0:                         # checked first: the editor stays open
    ide.fail "Cannot remove " & unitName & ": it is the ancestor of " & kids.join(", ") &
             "; remove those forms first."
    return false
  let ed = ide.editorOf(unitName)
  if ed != nil and not ide.closeEditor(ed): return false
  let mainEd = ide.beforeMainEdit()
  try:
    ide.project.removeUnit(unitName)       # also drops its import and create line from the main file
    ide.project.save()
    result = true
  except CatchableError as e:
    ide.fail "Cannot remove " & unitName & ": " & e.msg
  ide.afterMainEdit(mainEd)
  ide.refreshProject()

# options ---------------------------------------------------------------

proc cleanDefine(d: string): string =
  ## `-d:foo`, `--define:foo` and `foo` all name the define `foo`.
  result = d.strip
  for pre in ["--define:", "-d:", "--define=", "-d="]:
    if result.startsWith(pre):
      result = result[pre.len .. ^1]
      break

proc splitDefines*(text: string): seq[string] =
  ## "a b,c=1 -d:d" -> `@["a", "b", "c=1", "d"]`.
  for w in text.replace(',', ' ').splitWhitespace:
    let d = w.cleanDefine
    if d.len > 0 and d notin result: result.add d

proc currentOptions*(ide: IdeForm): ProjectOptions =
  let p = ide.project
  ProjectOptions(outputDir: p.outputDir, flags: p.nimFlags.map(quoteArg).join(" "),
                 defines: p.defines.join(" "), title: p.title, version: p.version,
                 autoImports: p.autoImports, importAll: p.importAll)

proc applyOptions*(ide: IdeForm, o: ProjectOptions) =
  ## Project > Options, after OK: stores the options and saves the project.
  if ide.project == nil: return
  let p = ide.project
  p.outputDir = if o.outputDir.strip.len > 0: o.outputDir.strip else: "build"
  p.nimFlags = splitArgs(o.flags)       # a quoted flag keeps its spaces
  p.defines = splitDefines(o.defines)
  p.title = o.title.strip
  p.version = o.version.strip
  p.autoImports = o.autoImports
  let modeChanged = p.importAll != o.importAll
  if modeChanged:
    if not ide.saveAll(): return       # unsaved edits go to disk before the files are rewritten
    p.importAll = o.importAll
    let changed = p.rewriteImports()
    for e in ide.editors: e.reloadFromDisk()
    ide.say(if p.importAll: "All units import nimvcl (" & $changed.len & " files changed)"
            else: "Units import the prelude and their controls (" & $changed.len & " files changed)")
  if not ide.trySaveProject(): return
  if not modeChanged: ide.say "Project options saved"

proc runParameters*(ide: IdeForm): string =
  ## The program arguments as one line (as shown by Run > Parameters).
  if ide.project != nil: ide.project.runArgs.map(quoteArg).join(" ") else: ""

proc setRunParameters*(ide: IdeForm, text: string) =
  if ide.project == nil: return
  ide.project.runArgs = splitArgs(text)
  if ide.trySaveProject(): ide.say "Run parameters saved"

proc showRunParameters*(ide: IdeForm) =
  ## Run > Parameters: the command line arguments of the program.
  if ide.project == nil: return
  var v = ide.runParameters
  let ok = ide.askText("Run Parameters", "Parameters:", v)
  if ok: ide.setRunParameters v

# units and forms -------------------------------------------------------

proc chooseUnit(ide: IdeForm, title: string, formsOnly: bool): string =
  ## Asks which unit to open from the list; "" when cancelled. The program
  ## file comes first in the Units list and is returned as the project name.
  var names, labels: seq[string]
  if not formsOnly:
    names.add ide.project.name
    labels.add ide.project.name & " (program)"
  for u in ide.project.units:
    if formsOnly and not u.isForm: continue
    names.add u.name
    labels.add(if u.isForm: u.name & " (" & u.formType & ")" else: u.name)
  if names.len == 0: return ""
  var cur = 0
  let ed = ide.activeEditor
  if ed != nil: cur = max(names.find(ed.unitName), 0)
  let i =
    ide.pickItem(title, labels, cur)
  if i >= 0 and i < names.len: names[i] else: ""

proc viewUnits*(ide: IdeForm, formsOnly = false): UnitEditor =
  ## View > Units... (Ctrl+F12) and View > Forms... (Shift+F12): choose, open.
  if ide.project == nil: return nil
  let n = ide.chooseUnit(if formsOnly: "View Form" else: "View Unit", formsOnly)
  if n.len > 0: result = ide.openUnit(n)

proc newInheritedForm*(ide: IdeForm, ancestor = ""): UnitEditor =
  ## File > New Inherited Form...: asks which form of the project to inherit
  ## from (`ancestor`, a unit name, skips the question), adds the descendant
  ## unit and opens it.
  if ide.project == nil: return nil
  var anc = ancestor
  if anc.len == 0:
    var names, labels: seq[string]
    for u in ide.project.formUnits:
      names.add u.name
      labels.add u.name & " (" & u.formType & ")"
    if names.len == 0:
      ide.fail "The project has no form to inherit from."
      return nil
    let ed = ide.activeEditor
    let cur = if ed != nil: max(names.find(ed.unitName), 0) else: 0
    let i =
      ide.pickItem("New Inherited Form", labels, cur)
    if i < 0 or i >= names.len: return nil
    anc = names[i]
  let mainEd = ide.beforeMainEdit()
  try:
    let u = ide.project.newInheritedFormUnit(anc)
    ide.project.save()
    ide.afterMainEdit(mainEd)
    ide.refreshProject()
    result = ide.openUnit(u.name)
  except CatchableError as e:
    ide.fail "Cannot create the form: " & e.msg

# save as ---------------------------------------------------------------

proc reloadOthers(ide: IdeForm) =
  ## Re-reads every open unit (their files may have been rewritten on disk).
  for e in ide.editors: e.reloadFromDisk()

proc renameUnit*(ide: IdeForm, oldName, newName: string): bool =
  ## File > Save As: saves everything, then renames the unit through
  ## `Project.renameUnit` (its files, the imports and the `loadForm` path);
  ## the unit stays open under its new name. The form type keeps its name.
  if ide.project == nil: return false
  let name = newName.strip
  if ide.project.findUnit(oldName) < 0:
    ide.fail oldName & " is not a unit of the project"
    return false
  if name == oldName: return true
  ide.saveAll()
  let ed = ide.editorOf(oldName)
  let wasOpen = ed != nil
  let wasDesigner = ed != nil and ed.designerVisible
  if wasOpen and not ide.closeEditor(ed): return false
  try:
    ide.project.renameUnit(oldName, name)
    ide.project.save()
  except CatchableError as e:
    ide.fail "Cannot rename " & oldName & ": " & e.msg
    if wasOpen: discard ide.openUnit(oldName)
    return false
  ide.reloadOthers()
  ide.refreshProject()
  if wasOpen:
    let ne = ide.openUnit(name)
    if ne != nil and ne.isForm and not wasDesigner: ne.showCode()
  ide.say "Saved as " & name
  true

proc renameProject*(ide: IdeForm, newName: string): bool =
  ## File > Save Project As: renames the project (the `.nimproj` and the main
  ## file), the units stay.
  if ide.project == nil: return false
  let name = newName.strip
  if name == ide.project.name: return true
  ide.saveAll()
  let oldPath = ide.project.filePath
  let mainEd = ide.mainEditor
  if mainEd != nil and not ide.closeEditor(mainEd): return false
  try:
    ide.project.renameProject(name)
  except CatchableError as e:
    ide.fail "Cannot rename the project: " & e.msg
    if mainEd != nil: discard ide.openMain()
    return false
  ide.settings.removeRecent(oldPath)
  ide.rememberProject()
  ide.rebuildRecentMenu()
  ide.refreshProject()
  if mainEd != nil: discard ide.openMain()
  ide.say "Project saved as " & name
  true

proc saveAs*(ide: IdeForm, newName = ""): bool =
  ## File > Save As: the active unit gets a new name (asked for when `newName`
  ## is empty); for the program file it is the same as Save Project As.
  let ed = ide.activeEditor
  if ed == nil: return false
  var v = newName
  let isMain = ide.isMainEditor(ed)
  if v.len == 0:
    v = if isMain: ide.project.name else: ed.unitName
    if not ide.askText("Save As", if isMain: "Project name:" else: "Unit name:", v): return false
  if isMain: ide.renameProject(v) else: ide.renameUnit(ed.unitName, v)

proc saveProjectAs*(ide: IdeForm, newName = ""): bool =
  if ide.project == nil: return false
  var v = newName
  if v.len == 0:
    v = ide.project.name
    if not ide.askText("Save Project As", "Project name:", v): return false
  ide.renameProject(v)
