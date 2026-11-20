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
