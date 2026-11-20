## Edit > Complete Code (Ctrl+Space), Insert Template (Ctrl+J) and Parameter
## Hints (Shift+Ctrl+Space) of the code view. What the candidates, templates and
## signatures are is `codeinsight` (pure); the popup is `codepicker`; this module
## feeds them from the active editor, the form's components and the settings.
##
## Without a form (or in a plain unit) the component names are simply missing.

import std/[strutils, sequtils]
import nimvcl
import nimvcl/dsl/props
import ./[ideconfig, nimsource, uniteditor, ideform, ideeditors, codeinsight, codepicker]

proc activeCode(ide: IdeForm): UnitEditor =
  ## The active editor when its code view is showing.
  let ed = ide.activeEditor
  if ed != nil and not (ed.isForm and ed.designerVisible): ed else: nil

proc componentInfos(ed: UnitEditor, qualifier: string): seq[ComponentInfo] =
  ## The components of the form; the properties and events of the one that
  ## `qualifier` names (`self`: the form) are filled in.
  for (c, depth) in ed.componentTree:
    var info = ComponentInfo(name: c.name, isForm: depth == 0)
    let wanted = if info.isForm: qualifier == "self" or qualifier.sameIdent(c.name)
                 else: qualifier.len > 0 and qualifier.sameIdent(c.name)
    if wanted:
      let ci = classOf(Obj(c))
      if ci != nil:
        for p in ci.propsOf:
          if not p.hidden and '.' notin p.name:
            info.members.add (p.name, (if p.kind == pkEvent: "event" else: p.typeName))
    result.add info

func withoutRange(code: CodeEdit, a, b: CodePos): string =
  ## The text without what is between `a` and `b` (same line).
  var lines: seq[string]
  for i in 0 ..< code.lineCount:
    var l = code.lineAt(i)
    if i == a.line: l = l[0 ..< min(a.col, l.len)] & l[min(b.col, l.len) .. ^1]
    lines.add l
  lines.join("\n")

proc rowOf(c: Candidate): string =
  if c.detail.len > 0: c.text & "   " & c.detail else: c.text

proc completeCode*(ide: IdeForm): bool {.discardable.} =
  ## Ctrl+Space: the candidates for the word before the caret. One candidate is
  ## inserted at once, several are listed (narrowed while typing; Enter or Tab
  ## picks). False when there is nothing to offer.
  let ed = ide.activeCode
  if ed == nil: return false
  let c = ed.code
  let pos = c.caretPos
  let w = wordBefore(c.lineAt(pos.line), pos.col)
  let start: CodePos = (pos.line, w.start)
  let src = withoutRange(c, start, pos)        # the word being typed is not a name of the unit
  let infos = componentInfos(ed, w.qualifier)
  var cands = candidatesFor(src, w, infos)
  if cands.len == 0:
    ide.say "No code completion for '" & w.prefix & "'"
    return false
  if cands.len == 1:
    c.replaceRange(start, pos, cands[0].text)
    return true
  discard showPicker(ide, c, start, cands.map(rowOf),
    refilter = proc(prefix: string): seq[string] =
      var w2 = w
      w2.prefix = prefix
      cands = candidatesFor(src, w2, infos)
      cands.map(rowOf),
    accept = proc(row: int, a, b: CodePos) =
      if row in 0 ..< cands.len: c.replaceRange(a, b, cands[row].text))
  true

proc userTemplates(ide: IdeForm): seq[CodeTemplate] =
  mergeTemplates(ide.settings.codeTemplates.mapIt(
    CodeTemplate(name: it.name, description: it.description, code: it.code)))

proc expandTemplate*(c: CodeEdit, t: CodeTemplate, a, b: CodePos) =
  ## Puts the template where the word from `a` to `b` is, indented like its
  ## line, the caret at the template's mark. One undo step.
  let unit = if c.insertSpaces: ' '.repeat(c.tabWidth) else: "\t"
  let e = t.expand(leadingBlank(c.lineAt(a.line)), unit)
  c.beginUndoGroup()
  c.replaceRange(a, b, e.text)
  c.caretPos = (a.line + e.caretLine, if e.caretLine == 0: a.col + e.caretCol else: e.caretCol)
  c.endUndoGroup()

proc insertTemplate*(ide: IdeForm): bool {.discardable.} =
  ## Ctrl+J: the word before the caret is a template's name: expand it. Else the
  ## templates that start with the word are listed (all of them when none does).
  let ed = ide.activeCode
  if ed == nil: return false
  let c = ed.code
  let pos = c.caretPos
  let all = ide.userTemplates
  let w = wordBefore(c.lineAt(pos.line), pos.col)
  var start: CodePos = (pos.line, w.start)
  var prefix = w.prefix
  let i = all.exact(prefix)
  if i >= 0:
    expandTemplate(c, all[i], start, pos)
    return true
  var shown = all.matching(prefix)
  if shown.len == 0:
    start = pos
    prefix = ""
    shown = all
  if shown.len == 1:
    expandTemplate(c, shown[0], start, pos)
    return true
  proc row(t: CodeTemplate): string = t.name & "   " & t.description
  discard showPicker(ide, c, start, shown.map(row),
    refilter = proc(p: string): seq[string] =
      shown = all.matching(p)
      shown.map(row),
    accept = proc(r: int, a, b: CodePos) =
      if r in 0 ..< shown.len: expandTemplate(c, shown[r], a, b))
  true
