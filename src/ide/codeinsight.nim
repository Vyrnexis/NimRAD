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

  Signature* = object
    text*: string            ## `proc foo(a: int, b: string): bool`
    params*: seq[string]

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

func looseKey(s: string): string =
  ## `s` without case and underscores: what completion matches by, so `button`
  ## also offers `Button` (Delphi's completion ignores case too).
  for ch in s:
    if ch != '_': result.add ch.toLowerAscii

func startsWithStyle*(text, prefix: string): bool =
  ## `prefix` is the start of `text`, ignoring case and underscores.
  prefix.len == 0 or text.looseKey.startsWith(prefix.looseKey)

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
    if result == 0:                    # the prefix as typed (case included) first
      result = cmp(not a.text.startsWith(prefix), not b.text.startsWith(prefix))
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

# --------------------------------------------------------- parameter hints

func callAt*(line: string, col: int): tuple[name: string, argIndex: int] =
  ## The call the caret is inside, on this line: the name before the
  ## innermost unclosed `(` and the number of commas before the caret in it.
  ## The name is "" when there is none.
  var depth = 0
  var commas: seq[int] = @[0]
  var i = min(col, line.len) - 1
  var inStr = false
  # walk back; quotes are not tracked precisely, an odd number before the caret
  # means the caret is inside a string
  var quotes = 0
  for j in 0 ..< min(col, line.len):
    if line[j] == '"': inc quotes
  inStr = quotes mod 2 == 1
  if inStr: return
  while i >= 0:
    let c = line[i]
    case c
    of ')', ']', '}':
      inc depth
      commas.add 0
    of '(', '[', '{':
      if depth == 0:
        if c != '(': return
        var e = i
        while e > 0 and line[e - 1] == ' ': dec e
        var a = e
        while a > 0 and isIdentByte(line[a - 1]): dec a
        let name = line[a ..< e]
        if name.len == 0 or name[0] notin IdentStartChars or name in NimKeywords: return
        return (name, commas[0])
      dec depth
      discard commas.pop
    of ',':
      if depth == 0: inc commas[0]
    else: discard
    dec i

proc signaturesOf*(src, name: string): seq[Signature] =
  ## The declarations of `name` in `src` (proc, func, method, template,
  ## iterator, macro, converter), as `kind name(params): result`.
  if name.len == 0: return
  let lines = src.split('\n')
  let classes = classifyLines(lines)
  const Kinds = ["proc", "func", "method", "template", "iterator", "macro", "converter"]
  for ln in 0 ..< lines.len:
    if classes[ln] != lcCode: continue
    let s = lines[ln].strip(chars = {'\r'}, leading = false).strip(trailing = false)
    var kind = ""
    for k in Kinds:
      if s.startsWith(k & " "): kind = k
    if kind.len == 0: continue
    var p = kind.len
    while p < s.len and s[p] == ' ': inc p
    let a = p
    while p < s.len and isIdentByte(s[p]): inc p
    if not s[a ..< p].sameIdent(name): continue
    if p < s.len and s[p] == '*': inc p
    # the rest of the declaration up to the end of the parameter list, over a few lines
    var rest = s[p .. ^1]
    var extra = 1
    while rest.count('(') > rest.count(')') and ln + extra < lines.len and extra < 6:
      rest.add " " & lines[ln + extra].strip
      inc extra
    var open = rest.find('(')
    if open < 0 or rest[0 ..< open].strip.len > 0 and not rest[0 ..< open].strip.startsWith("["):
      continue
    open = rest.find('(')
    var depth = 0
    var close = -1
    var params: seq[string]
    var cur = ""
    for i in open ..< rest.len:
      let c = rest[i]
      if c in {'(', '[', '{'}:
        inc depth
        if depth == 1: continue
      elif c in {')', ']', '}'}:
        dec depth
        if depth == 0:
          close = i
          break
      if depth == 1 and c == ',':
        params.add cur.strip
        cur = ""
      else: cur.add c
    if close < 0: continue
    if cur.strip.len > 0: params.add cur.strip
    var res = ""
    let tail = rest[close + 1 .. ^1].strip
    if tail.startsWith(":"):
      var e = tail.find(" =")
      if e < 0: e = tail.find("{.")
      if e < 0: e = tail.len
      res = ": " & tail[1 ..< e].strip
    result.add Signature(text: kind & " " & s[a ..< p].strip(chars = {'*'}) & "(" & params.join(", ") & ")" & res,
                         params: params)
