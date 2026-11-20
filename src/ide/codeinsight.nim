## Code insight without a window: the candidates of Ctrl+Space completion, the
## code templates of Ctrl+J and the signatures behind Ctrl+Shift+Space. Pure
## functions of text and plain data, so they are tested without the IDE
## (`tcodeinsight`); the popup and the editor glue are `codepicker` and
## `codecmds`.
##
## Completion: the identifier before the caret is the prefix; candidates match
## it by `styleKey` (first letter exact, the rest ignoring case and
## underscores). After `self.` or `<component>.` the candidates are the members
## handed in by the caller (the form's components, the properties and events of
## the class); anywhere else they are, in this order of preference, the
## identifiers of the unit, the form's components, the nimvcl symbols and the
## Nim keywords.
##
## Templates: the code of a template is plain text, `|` marks where the caret
## goes (the first one; none: the end), the lines after the first are indented
## by the indent of the line the template starts on, and every group of two
## leading spaces in the template is one indent unit of the editor.

import std/[strutils, sets, algorithm]
import nimvcl/controls/nimlexer
import ./[nimsource, symbolindex]

const
  MaxCandidates* = 400
  CaretMark* = '|'

type
  CandKind* = enum
    ckMember, ckUnit, ckComponent, ckSymbol, ckKeyword   ## in order of preference

  Candidate* = object
    text*: string
    kind*: CandKind
    detail*: string          ## the type of a member; "" otherwise

  Member* = tuple[name, detail: string]

  ComponentInfo* = object
    ## One named component of the form and what can follow its name.
    name*: string
    isForm*: bool            ## the form itself: `self.`
    members*: seq[Member]    ## its published properties and events

  Word* = object
    start*: int              ## column where the identifier before the caret starts
    prefix*: string
    dotted*: bool            ## a `.` comes right before the identifier
    qualifier*: string       ## the identifier before that dot ("" when none)

  CodeTemplate* = object
    name*, description*, code*: string

  Expansion* = object
    text*: string            ## to insert at the start of the word
    caretLine*: int          ## the caret, relative to the start of `text`
    caretCol*: int           ## (column counted from the line start; for line 0 from the insert point)

func isIdentByte(c: char): bool = c in IdentChars or ord(c) >= 0x80

# ------------------------------------------------------------------ words

func wordBefore*(line: string, col: int): Word =
  ## The identifier that ends at `col`, and what stands before it.
  let c = clamp(col, 0, line.len)
  var a = c
  while a > 0 and isIdentByte(line[a - 1]): dec a
  result.start = a
  result.prefix = line[a ..< c]
  if a > 0 and line[a - 1] == '.':
    result.dotted = true
    var q = a - 1
    let e = q
    while q > 0 and isIdentByte(line[q - 1]): dec q
    result.qualifier = line[q ..< e]

func startsWithStyle*(text, prefix: string): bool =
  ## Nim identifier rules: `prefix` is the start of `text`.
  prefix.len == 0 or text.styleKey.startsWith(prefix.styleKey)

# -------------------------------------------------------------- candidates

proc unitIdents*(src: string): seq[string] =
  ## The identifiers the code uses, by first appearance, spelled as written;
  ## comments, strings and keywords are not among them.
  let h = newNimHighlighter()
  var state = 0
  var toks: seq[Token]
  var seen = initHashSet[string]()
  for raw in src.split('\n'):
    let line = raw.strip(chars = {'\r'}, leading = false)
    toks.setLen 0
    state = h.lexLine(line, state, toks)
    for t in toks:
      if t.kind == tkIdent:
        let w = line[t.start ..< min(t.start + t.len, line.len)]
        if w.len > 0 and w notin seen:
          seen.incl w
          result.add w

var symbolNames: seq[string]

proc nimvclSymbols*(): seq[string] =
  ## The exported names of nimvcl (from the generated index), once.
  if symbolNames.len == 0:
    var seen = initHashSet[string]()
    for (_, names) in symbolIndexData:
      for n in names.split(' '):
        if n.len > 1 and n notin seen and n[0] in IdentStartChars:
          seen.incl n
          symbolNames.add n
  symbolNames

proc rank*(cands: seq[Candidate], prefix: string): seq[Candidate] =
  ## The candidates that match `prefix`, kind first, then the shorter name, then
  ## alphabetical; a name that is the same identifier as an earlier one, or as
  ## the prefix itself, is left out.
  var seen = initHashSet[string]()
  if prefix.len > 0: seen.incl prefix.styleKey
  var keep: seq[Candidate]
  for c in cands:
    if c.text.len == 0 or not c.text.startsWithStyle(prefix): continue
    let k = c.text.styleKey
    if k in seen: continue
    seen.incl k
    keep.add c
  keep.sort(proc(a, b: Candidate): int =
    result = cmp(ord(a.kind), ord(b.kind))
    if result == 0: result = cmp(a.text.len, b.text.len)
    if result == 0: result = cmp(a.text, b.text))
  result = if keep.len > MaxCandidates: keep[0 ..< MaxCandidates] else: keep

proc candidatesFor*(src: string, w: Word, comps: seq[ComponentInfo]): seq[Candidate] =
  ## The ranked candidates for the word at the caret.
  var all: seq[Candidate]
  var member = false
  if w.dotted and w.qualifier.len > 0:
    for c in comps:
      let isSelf = w.qualifier == "self" and c.isForm
      if isSelf or (not c.isForm and c.name.sameIdent(w.qualifier)):
        member = true
        for (n, d) in c.members: all.add Candidate(text: n, kind: ckMember, detail: d)
        if isSelf:
          for o in comps:
            if not o.isForm: all.add Candidate(text: o.name, kind: ckComponent)
        break
  if not member:
    for n in unitIdents(src): all.add Candidate(text: n, kind: ckUnit)
    if not w.dotted:
      for c in comps: all.add Candidate(text: c.name, kind: ckComponent)
    for n in nimvclSymbols(): all.add Candidate(text: n, kind: ckSymbol)
    if not w.dotted:
      for k in NimKeywords: all.add Candidate(text: k, kind: ckKeyword)
  rank(all, w.prefix)

# --------------------------------------------------------------- templates

const BuiltinTemplates* = [
  CodeTemplate(name: "proc", description: "procedure", code: "proc |() =\n  discard"),
  CodeTemplate(name: "func", description: "function without side effects", code: "func |() =\n  discard"),
  CodeTemplate(name: "if", description: "if", code: "if |:\n  discard"),
  CodeTemplate(name: "ife", description: "if ... else", code: "if |:\n  discard\nelse:\n  discard"),
  CodeTemplate(name: "for", description: "for ... in", code: "for | in :\n  discard"),
  CodeTemplate(name: "fori", description: "for i in 0 ..< n", code: "for i in 0 ..< |:\n  discard"),
  CodeTemplate(name: "while", description: "while", code: "while |:\n  discard"),
  CodeTemplate(name: "case", description: "case ... of ... else", code: "case |\nof :\n  discard\nelse:\n  discard"),
  CodeTemplate(name: "try", description: "try ... except", code: "try:\n  |\nexcept CatchableError:\n  discard"),
  CodeTemplate(name: "tryf", description: "try ... finally", code: "try:\n  |\nfinally:\n  discard"),
  CodeTemplate(name: "when", description: "when", code: "when |:\n  discard"),
  CodeTemplate(name: "block", description: "block", code: "block |:\n  discard"),
  CodeTemplate(name: "obj", description: "type ... = ref object", code: "type\n  | = ref object\n    discard"),
  CodeTemplate(name: "echo", description: "echo", code: "echo |"),
  CodeTemplate(name: "discard", description: "discard", code: "discard |")]

proc mergeTemplates*(user: seq[CodeTemplate]): seq[CodeTemplate] =
  ## The built-in templates, a user template of the same name replacing its
  ## built-in; the rest of the user's follow. Sorted by name.
  for t in BuiltinTemplates:
    var replaced = false
    for u in user:
      if u.name.sameIdent(t.name): replaced = true
    if not replaced: result.add t
  var seen = initHashSet[string]()
  for u in user:
    if u.name.len > 0 and u.name.styleKey notin seen:
      seen.incl u.name.styleKey
      result.add u
  result.sort(proc(a, b: CodeTemplate): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii))

proc matching*(templates: seq[CodeTemplate], prefix: string): seq[CodeTemplate] =
  for t in templates:
    if t.name.startsWithStyle(prefix): result.add t

proc exact*(templates: seq[CodeTemplate], name: string): int =
  ## The index of the template called `name` (same identifier), -1 when none.
  if name.len == 0: return -1
  for i, t in templates:
    if t.name.sameIdent(name): return i
  -1

func leadingBlank*(line: string): string =
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  line[0 ..< i]

proc expand*(t: CodeTemplate, baseIndent, unit: string): Expansion =
  ## `t.code` ready to insert where the line has the indent `baseIndent`;
  ## `unit` is one level of indent in the editor (spaces or a tab).
  var out0: seq[string]
  var caretLine = -1
  var caretCol = 0
  let src = t.code.split('\n')
  for i in 0 ..< src.len:
    var line = src[i]
    var n = 0
    while line.len >= 2 * (n + 1) and line[2 * n .. 2 * n + 1] == "  ": inc n
    line = unit.repeat(n) & line[2 * n .. ^1]
    if i > 0: line = baseIndent & line
    if caretLine < 0:
      let p = line.find(CaretMark)
      if p >= 0:
        caretLine = i
        caretCol = p
        line = line[0 ..< p] & line[p + 1 .. ^1]
    out0.add line
  result.text = out0.join("\n")
  if caretLine < 0:
    caretLine = out0.high
    caretCol = out0[^1].len
  result.caretLine = caretLine
  result.caretCol = caretCol
