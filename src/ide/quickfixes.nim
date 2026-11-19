## Quick fixes of compiler messages (Ctrl+.) and Search > Find Unit: the edits
## go to the unit's editor when it is open (one undo step), else to its file.

import nimvcl
import std/[os, strutils, sequtils]
import ./[project, messages, messagespanel, uniteditor, unitimports,
          symbols, quickfix, ideform]

type FixOutcome* = enum
  foNone                 ## nothing was changed
  foApplied              ## changed in place
  foAddedImport          ## an import was added: the build that failed should run again

proc editUnitFile*(ide: IdeForm, file: string, change: proc(src: string): string): bool =
  ## Applies `change` to the unit's text: in its editor when it is open (the
  ## edit is then unsaved, one undo step), else in the file. True when it changed.
  let name = ide.unitOfFile(file)
  if name.len == 0: return false
  let ed = ide.editorOf(name)
  if ed != nil: return ed.editCode(change)
  try:
    let src = readFile(file)
    let res = change(src)
    if res == src: return false
    writeFile(file, res)
    result = true
  except CatchableError: discard

proc addImportTo*(ide: IdeForm, file, module: string): bool =
  ide.editUnitFile(file, proc(src: string): string = addUserImport(src, module))

proc componentsOf(ide: IdeForm, file: string): seq[string] =
  ## The names of the components of the form of the unit `file` (empty for the
  ## program file and for plain units).
  if ide.project == nil: return
  let k = ide.project.findUnit(ide.unitOfFile(file))
  if k < 0: return
  let u = ide.project.units[k]
  if u.nfmPath.len == 0: return
  let nfm = ide.project.nfmPathOf(u)
  if fileExists(nfm):
    try: return componentNames(readFile(nfm), nfm.parentDir)
    except CatchableError: discard

proc fixesOfMessage*(ide: IdeForm, m: Message): seq[QuickFix] =
  if ide.project == nil: return
  result = fixesFor(m, proc(): seq[string] = ide.componentsOf(m.file))
  if ide.project.importAll:             # everything is imported already
    result = result.filterIt(it.kind != fkAddImport)

proc applyFix*(ide: IdeForm, msgIndex: int, fixIndex = 0): FixOutcome =
  ## Applies a fix of message `msgIndex`: an import (the module is chosen from a
  ## list when several declare the name) is added above the IDE's block; a
  ## rename replaces the name in place.
  let fixes = ide.messages.fixesOf(msgIndex)
  if fixIndex >= fixes.len or ide.busy: return foNone
  let fix = fixes[fixIndex]
  let m = ide.messages.msgs[msgIndex]
  case fix.kind
  of fkAddImport:
    var module = fix.modules[0]
    if fix.modules.len > 1:
      let i = ide.pickItem("Add import for " & fix.ident, fix.modules, 0)
      if i < 0 or i >= fix.modules.len: return foNone
      module = fix.modules[i]
    if not ide.addImportTo(m.file, module):
      ide.say module & " is already imported"
      return foNone
    ide.say "Added import " & module & " to " & ide.unitOfFile(m.file)
    foAddedImport
  of fkRename:
    let done = ide.editUnitFile(m.file, proc(src: string): string =
      renameAt(src, m.line, m.col, fix.ident, fix.replacement))
    if done: ide.say "Replaced " & fix.ident & " with " & fix.replacement
    else: ide.say "Could not find " & fix.ident & " at that place"
    if done:
      ide.messages.fixes[msgIndex] = @[]    # the position is stale; the next build lists it again
      foApplied
    else: foNone

proc fixTarget*(ide: IdeForm): int =
  ## The message Ctrl+. works on: the selected one, else the error at the caret,
  ## else the first that has a fix; -1 (and a note) when there is none.
  if ide.project == nil: return -1
  var k = ide.messages.selectedMessage
  if ide.messages.fixesOf(k).len == 0:
    k = -1
    let ed = ide.activeEditor
    if ed != nil and not (ed.isForm and ed.designerVisible):
      let line = ed.code.caretPos.line + 1
      for i, m in ide.messages.msgs:
        if m.hasLocation and m.line == line and ide.unitOfFile(m.file) == ed.unitName and
           ide.messages.fixesOf(i).len > 0:
          k = i
          break
    if k < 0: k = ide.messages.firstWithFix()
  if k < 0: ide.say "No quick fix available"
  k

proc wordAtCaret*(ed: UnitEditor): string =
  let c = ed.code
  let sel = c.selectedText
  if sel.len > 0:
    return if sel.allIt(it in IdentChars) and sel[0] in IdentStartChars: sel else: ""
  let line = c.lineAt(c.caretPos.line)
  var a = min(c.caretPos.col, line.len)
  var b = a
  while a > 0 and line[a - 1] in IdentChars: dec a
  while b < line.len and line[b] in IdentChars: inc b
  if b > a and line[a] in IdentStartChars: line[a ..< b] else: ""

proc findUnitImport*(ide: IdeForm): bool {.discardable.} =
  ## Search > Find Unit (Ctrl+Shift+A): offers the import of the nimvcl module
  ## that declares the identifier at the caret (the selection, if any).
  let ed = ide.activeEditor
  if ide.project == nil or ed == nil: return false
  if ed.isForm and ed.designerVisible: ed.showCode()
  let word = ed.wordAtCaret
  if word.len == 0:
    ide.say "Put the caret on an identifier first"
    return false
  let mods = modulesFor(word)
  if mods.len == 0:
    ide.say "No nimvcl module declares " & word
    return false
  let i =
    ide.pickItem("Add import for " & word, mods, 0)
  if i < 0 or i >= mods.len: return false
  let target =
    if ide.isMainEditor(ed): ide.project.mainPath
    else:
      let k = ide.project.findUnit(ed.unitName)
      if k < 0: return false
      ide.project.nimPathOf(ide.project.units[k])
  result = ide.addImportTo(target, mods[i])
  ide.say(if result: "Added import " & mods[i] else: mods[i] & " is already imported")

proc autoAddImports*(ide: IdeForm): seq[string] =
  ## Project option "Add missing nimvcl imports automatically": adds every import
  ## of the failed build that has exactly one candidate; the notes for Messages
  ## say what was added (empty when nothing was).
  if not ide.project.autoImports: return
  for k in 0 ..< ide.messages.msgs.len:
    let fx = ide.messages.fixesOf(k)
    if fx.len == 0 or fx[0].kind != fkAddImport or fx[0].modules.len != 1: continue
    let m = ide.messages.msgs[k]
    let module = fx[0].modules[0]
    let unit = ide.unitOfFile(m.file)
    if ide.addImportTo(m.file, module):
      result.add "Added import " & module & " to " & unit & " (for " & fx[0].ident & ")"
