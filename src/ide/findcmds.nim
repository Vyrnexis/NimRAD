## Search > Find in Files...: the dialog is the hook `askFindInFiles`, the search
## is `findinfiles`, the result goes to the Messages window (one row per line
## found: file, line, text; a double click or F8 opens the place).

import std/[os, strutils]
import nimvcl
import ./[project, findinfiles, messagespanel, uniteditor, icons, ideform, ideeditors]

proc wordAt(line: string, col: int): string =
  proc isIdent(c: char): bool = c in IdentChars
  var a = min(col, line.len)
  var b = a
  while a > 0 and isIdent(line[a - 1]): dec a
  while b < line.len and isIdent(line[b]): inc b
  line[a ..< b]

proc suggestedText(ide: IdeForm): string =
  ## What the dialog starts with: the selection, else the word at the caret,
  ## else what was searched last.
  let ed = ide.activeEditor
  if ed != nil and not (ed.isForm and ed.designerVisible):
    let c = ed.code
    if c.hasSelection:
      let s = c.selectedText
      if s.len > 0 and '\n' notin s and '\r' notin s: return s
    else:
      let p = c.caretPos
      let w = wordAt(c.lineAt(p.line), p.col)
      if w.len > 0: return w
  ide.findOptions.text

proc editedText(ide: IdeForm): TextOf =
  ## The text of a unit that has unsaved edits is what is searched, not the file.
  result = proc(file: string, text: var string): bool =
    let name = ide.unitOfFile(file)
    let ed = if name.len > 0: ide.editorOf(name) else: nil
    if ed != nil and ed.modified:
      text = ed.code.text
      return true

proc findInFilesRun*(ide: IdeForm, o: FindOptions): FindResult =
  ## Searches and lists the lines found in Messages.
  if ide.project == nil: return
  let files = ide.project.projectFiles(o.scope)
  result = findInFiles(files, o, ide.editedText)
  let m = ide.messages
  m.clear()
  m.showMessages()
  let what = "'" & o.text & "'"
  if result.error.len > 0:
    m.addNote("Find in Files: bad regular expression: " & result.error, icError)
    ide.say "Find in Files: bad regular expression"
    return
  m.addNote("Find in Files: " & what & " in " & (if o.scope == fsUnits: "the units of " else: "the folder of ") &
            ide.project.name & " (" & $result.scanned & " files)", icInfo)
  m.bulk:
    for h in result.hits: m.addMatch(h.file, h.line, h.col, h.text)
  var summary = $result.hits.len & " lines in " & $result.files & " files"
  if result.truncated: summary = "The first " & $MaxHits & " lines (there are more); narrow the search"
  if result.skipped > 0: summary.add "; " & $result.skipped & " files skipped (too big or unreadable)"
  if result.hits.len == 0: summary = "Nothing found for " & what
  m.addNote(summary, if result.hits.len > 0: icSuccess else: icInfo)
  ide.say "Find in Files: " & summary
  if result.hits.len > 0: m.select 0

proc findInFilesCommand*(ide: IdeForm): bool {.discardable.} =
  ## Search > Find in Files...: asks, then searches. False when cancelled.
  if ide.project == nil or ide.askFindInFiles == nil: return false
  var o = ide.findOptions
  o.text = ide.suggestedText
  if not ide.askFindInFiles(o) or o.text.len == 0: return false
  ide.findOptions = o
  discard ide.findInFilesRun(o)
  true
