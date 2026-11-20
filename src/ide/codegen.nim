## Edits to the source text of a form unit (`unit1.nim`): handler stubs,
## renames and import updates. Everything works on plain text, line by line,
## and keeps what the user wrote: the file's line ending and trailing newline
## are preserved, and nothing outside the touched lines changes.
##
## Strings and comments are skipped with nimvcl's `NimHighlighter` lexer, so a
## `"self.button1"` in a string or a `# button1` comment is never renamed.
##
## **Handler signatures** come from the property registry: an event's
## `PropInfo` carries its `params` and `returnType`.
##
## Line and column numbers are 0-based (as in `CodeEdit`).

import std/[strutils, algorithm, sequtils]
import nimvcl/controls/nimlexer
import nimvcl/dsl/[props, props_std]
import nimvcl
import ./nimsource

type
  StubResult* = object
    text*: string       ## the whole new source
    line*, col*: int    ## caret position inside the handler (its first body line)
    inserted*: bool     ## false when the proc already existed

  EventSig* = tuple[params, ret: string]   ## "sender: Control, key: var Key", ""

# --------------------------------------------------------------- signatures

proc eventSig*(p: PropInfo): EventSig =
  ## Parameters (after the form) and result type of an event property.
  var ps: seq[string]
  for x in p.params: ps.add x.name & ": " & x.typeName
  (ps.join(", "), p.returnType)

proc registrySig(className, eventName: string): EventSig =
  let ci = classByName(className)
  let p = if ci != nil: ci.findProp(eventName) else: nil
  if p != nil and p.kind == pkEvent: eventSig(p)
  else: ("sender: Control", "")

proc handlerParams*(className, eventName: string): string =
  ## The event's parameter list for a handler of `className.eventName`
  ## (`"sender: Control"` for `Button.onClick`), through the registry.
  registrySig(className, eventName).params

# ------------------------------------------------------------------- lines

type
  Src = object
    lines: seq[string]   ## without line ends; a trailing newline is a final ""
    eol: string

proc split(src: string): Src =
  result.lines = src.split('\n')
  # CRLF only when every line has it; in a file with mixed endings the `\r` of
  # the lines that have one stays part of the line, so it is written back as is
  let n = result.lines.len - 1                 # the piece after the last `\n` has no end
  if n > 0 and result.lines[0 ..< n].allIt(it.endsWith('\r')):
    result.eol = "\r\n"
    for l in result.lines.mitems:
      if l.endsWith('\r'): l.setLen l.len - 1
  else: result.eol = "\n"

proc join(s: Src): string = s.lines.join(s.eol)

proc isBlank(l: string): bool = l.strip().len == 0

proc codeLines(s: Src): int =
  ## Number of lines excluding the empty piece after a final newline.
  if s.lines.len > 0 and s.lines[^1].len == 0: s.lines.len - 1 else: s.lines.len

type Tok = object
  line, start, len: int
  kind: TokenKind

proc tokenize(s: Src): seq[Tok] =
  ## Tokens of every line (comments and strings are single tokens).
  let h = newNimHighlighter()
  var state = 0
  var toks: seq[Token]
  for i, l in s.lines:
    toks.setLen 0
    state = h.lexLine(l, state, toks)
    for t in toks: result.add Tok(line: i, start: t.start, len: t.len, kind: t.kind)

proc text(s: Src, t: Tok): string = s.lines[t.line][t.start ..< t.start + t.len]

proc isIdentChar(c: char): bool = c in IdentChars or ord(c) >= 0x80

# ------------------------------------------------------------------ procs

type ProcInfo = object
  name: string
  firstParam, firstType: string   ## "self", "Form1"
  first, last: int                ## line range; `last` excludes trailing blanks
  bodyLine: int                   ## first line after the header (== last+1 when none)

proc parseProcs(s: Src): seq[ProcInfo] =
  ## Top-level `proc`/`func`/`method` definitions (column 0). A definition goes on
  ## while the lines are indented, blank, comments, or inside a multi-line
  ## string; comments and strings come from the lexer (see `classifyLines`).
  let n = s.codeLines
  let cls = classifyLines(s.lines[0 ..< n])
  var i = 0
  while i < n:
    let l = s.lines[i]
    var kw = 0
    if cls[i] != lcCode:
      inc i
      continue
    for k in ["proc ", "func ", "method "]:
      if l.startsWith(k): kw = k.len
    if kw == 0:
      inc i
      continue
    var p = kw
    while p < l.len and l[p] == ' ': inc p
    var name = identAt(l, p)
    p += name.len
    if p < l.len and l[p] == '*': inc p
    var info = ProcInfo(name: name, first: i)
    # first parameter: look at the header text (joined while the paren is open)
    var hdr = l[p .. ^1]
    var j = i
    while hdr.find(')') < 0 and hdr.find(':') < 0 and j + 1 < n and j < i + 3:
      inc j
      hdr.add " " & s.lines[j].strip()
    let lp = hdr.find('(')
    if lp >= 0:
      # the first parameter's colon must lie inside the parameter list: before
      # the matching `)`, outside nested brackets (`proc f(): T` has none)
      var depth = 0
      var colon = -1
      for c in lp ..< hdr.len:
        case hdr[c]
        of '(', '[', '{': inc depth
        of ')', ']', '}':
          dec depth
          if depth <= 0: break
        of ':':
          if depth == 1:
            colon = c
            break
        else: discard
      if colon > lp:
        let nm = hdr[lp + 1 ..< colon].strip()
        if nm.len > 0 and '=' notin nm:
          info.firstParam = nm
          var ty = hdr[colon + 1 .. ^1].strip()
          var e = 0
          while e < ty.len and (isIdentChar(ty[e]) or ty[e] == '.'): inc e
          info.firstType = ty[0 ..< e]
    # extent: following lines that are blank, indented, a comment, or inside a literal
    var last = i
    var k = i + 1
    while k < n:
      let m = s.lines[k]
      if cls[k] == lcBlank: inc k
      elif cls[k] == lcInside or m[0] in {' ', '\t'}:
        last = k
        inc k
      elif cls[k] == lcComment: inc k        # a comment at column 0 does not end the body
      else: break
    info.last = last
    # a one-line proc `proc f() = body` has its body on the header line
    info.bodyLine = i + 1
    result.add info
    i = max(last, i) + 1

proc findProc(procs: seq[ProcInfo], name: string): int =
  for i, p in procs:
    if sameIdent(p.name, name): return i
  -1

var
  procsText: string                ## the text `procsCache` was parsed from
  procsCache: seq[ProcInfo]
  procsValid = false

proc parseProcsCached(src: string, s: Src): seq[ProcInfo] =
  ## `parseProcs(s)` for `s = split(src)`, remembered for the last text: one property
  ## change asks `hasProc` and `ensureHandler` about the same text, and lexing is the
  ## cost. (The IDE runs this on the UI thread only.)
  if not (procsValid and procsText == src):
    procsCache = parseProcs(s)
    procsText = src
    procsValid = true
  procsCache

proc handlerNames*(src, formType: string): seq[string] =
  ## Names of the top-level procs whose first parameter has type `formType`,
  ## in source order.
  for p in parseProcs(split(src)):
    if sameIdent(p.firstType, formType): result.add p.name

proc hasProc*(src, name: string): bool =
  parseProcsCached(src, split(src)).findProc(name) >= 0

proc firstBodyCol(s: Src, p: ProcInfo): int =
  if p.bodyLine <= p.last:
    let l = s.lines[p.bodyLine]
    result = l.len - l.strip(trailing = false).len
  else: result = 2

proc ensureHandler*(src, formType, handlerName, eventParams: string,
                    retType = "", hint = ""): StubResult =
  ## Makes sure a proc `handlerName` exists:
  ## `proc handlerName(self: formType, eventParams) =` + `  discard`.
  ## An existing proc of that name (any signature) is left alone. The stub goes
  ## after the last proc whose first parameter is `formType`, else after the
  ## `loadForm` line, else after the imports, else at the end. The caret is on
  ## the first body line (column of the indentation).
  var s = split(src)
  let procs = parseProcsCached(src, s)
  let ex = procs.findProc(handlerName)
  if ex >= 0:
    return StubResult(text: src, line: min(procs[ex].bodyLine, procs[ex].last),
                      col: firstBodyCol(s, procs[ex]), inserted: false)
  var at = -1                       # insert after this line
  for p in procs:
    if sameIdent(p.firstType, formType): at = p.last
  if at < 0:
    for i in 0 ..< s.codeLines:
      if s.lines[i].startsWith("loadForm"): at = i
  if at < 0:
    for i in 0 ..< s.codeLines:
      let l = s.lines[i]
      if l.startsWith("import ") or l.startsWith("from ") or l.startsWith("export "):
        at = i
        # a list that goes on in the next lines (`import a,\n  b`, `[a,\n b]`)
        while at + 1 < s.codeLines:
          let code = s.lines[at].split('#')[0].strip
          if not (code.endsWith(",") or code.count('[') > code.count(']')): break
          inc at
    # inside a `{.push ...}` region (the managed import block): go past its `{.pop.}`
    var pushed = false
    for i in 0 .. min(at, s.codeLines - 1):
      let l = s.lines[i].strip
      if l.startsWith("{.push"): pushed = true
      elif l.startsWith("{.pop"): pushed = false
    if at >= 0 and pushed:
      for i in at + 1 ..< s.codeLines:
        if s.lines[i].strip.startsWith("{.pop"):
          at = i
          break
  if at < 0: at = s.codeLines - 1
  let params = if eventParams.strip().len > 0: ", " & eventParams.strip() else: ""
  let header = "proc " & handlerName & "(self: " & formType & params & ")" &
               (if retType.len > 0: ": " & retType else: "") & " ="
  var add = @["", header]
  if hint.len > 0: add.add "  # " & hint
  add.add "  discard"
  if at + 1 < s.codeLines and not isBlank(s.lines[at + 1]): add.add ""
  if at < 0:                       # empty file: no blank line before
    add.delete 0
    at = -1
  for k, l in add: s.lines.insert(l, at + 1 + k)
  if s.lines[^1].len > 0: s.lines.add ""    # keep a final newline
  # the caret goes on the `discard`, after the hint comment
  result = StubResult(text: s.join,
                      line: at + 1 + (if add[0].len == 0: 1 else: 0) + 1 + (if hint.len > 0: 1 else: 0),
                      col: 2, inserted: true)

proc ensureHandlerFor*(src, formType, className, eventName, handlerName: string,
                       ancestorType = ""): StubResult =
  ## `ensureHandler` with the parameters taken from the registry. With
  ## `ancestorType` (a form that inherits from that type) the stub carries a
  ## comment on how to call the ancestor's handler of the same name.
  let sig = registrySig(className, eventName)
  var hint = ""
  if ancestorType.len > 0:
    var args: seq[string]
    for seg in sig.params.split(','):
      let a = seg.split(':')[0].strip
      if a.len > 0: args.add a
    hint = "replaces " & ancestorType & "'s " & handlerName & "; its version (exported with `*`): " &
           handlerName & "(" & ancestorType & "(self)" &
           (if args.len > 0: ", " & args.join(", ") else: "") & ")"
  ensureHandler(src, formType, handlerName, sig.params, sig.ret, hint)

proc isEmptyBody(s: Src, p: ProcInfo): bool =
  for i in p.first + 1 .. p.last:
    let t = s.lines[i].strip()
    if t.len > 0 and t != "discard": return false
  # one-line procs (`proc f(...) = discard`) have the body in the header
  p.last > p.first or s.lines[p.first].strip().endsWith("= discard")

proc emptyHandlers*(src, formType: string): seq[string] =
  ## Handlers whose body is only `discard`. The caller must also clear the
  ## event in the .nfm before `removeEmptyHandler`, or the form no longer compiles.
  let s = split(src)
  for p in parseProcs(s):
    if sameIdent(p.firstType, formType) and isEmptyBody(s, p): result.add p.name

proc removeEmptyHandler*(src, handlerName: string): string =
  ## Deletes the proc when its body is empty (only `discard` or blank lines),
  ## with one of the blank lines around it. Returns `src` unchanged otherwise.
  var s = split(src)
  let procs = parseProcs(s)
  let i = procs.findProc(handlerName)
  if i < 0 or not isEmptyBody(s, procs[i]): return src
  let p = procs[i]
  var first = p.first
  var last = p.last
  if last + 1 < s.lines.len and isBlank(s.lines[last + 1]) and
     (last + 1 < s.codeLines): inc last
  elif first > 0 and isBlank(s.lines[first - 1]): dec first
  s.lines = s.lines[0 ..< first] & s.lines[last + 1 .. ^1]
  s.join

# ---------------------------------------------------------------- renames

proc applyEdits(s: var Src, edits: seq[tuple[line, start, len: int, repl: string]]) =
  ## Applies replacements, last first so positions stay valid.
  var e = edits
  e.sort(proc(a, b: tuple[line, start, len: int, repl: string]): int =
    if a.line != b.line: cmp(b.line, a.line) else: cmp(b.start, a.start))
  for x in e:
    s.lines[x.line] = s.lines[x.line][0 ..< x.start] & x.repl & s.lines[x.line][x.start + x.len .. ^1]

proc renameHandler*(src, oldName, newName: string): string =
  ## Renames the proc and every identifier use of it (calls, other references).
  ## Member accesses (`x.oldName`) are left alone. This works on tokens, not on
  ## scopes: a local variable or a parameter with the same name is renamed too.
  ## Spellings that differ only in style (`oldname`) match, as in Nim. That is
  ## right for the generated handler names it is meant for; it is not a general
  ## rename.
  var s = split(src)
  var edits: seq[tuple[line, start, len: int, repl: string]]
  for t in tokenize(s):
    if t.kind == tkIdent and sameIdent(s.text(t), oldName) and
       not (t.start > 0 and s.lines[t.line][t.start - 1] == '.'):
      edits.add (t.line, t.start, t.len, newName)
  s.applyEdits edits
  s.join

proc receivers(s: Src, formType: string): seq[string] =
  result.add "self"
  for p in parseProcs(s):
    if sameIdent(p.firstType, formType) and p.firstParam.len > 0 and not result.anyIt(sameIdent(it, p.firstParam)):
      result.add p.firstParam

proc renameComponentRefs*(src, oldName, newName: string, formType = ""): string =
  ## Renames `self.oldName` / `f.oldName`. With `formType` the receiver must be
  ## `self` or the name of the first parameter of a proc of that form type;
  ## without it any `x.oldName` is renamed. Strings and comments are skipped,
  ## and only whole identifiers match. Token level: a receiver that is not a plain
  ## name (`Form1(x).oldName`) or an alias (`let f = self; f.oldName`) is not found.
  var s = split(src)
  let recv = if formType.len > 0: receivers(s, formType) else: @[]
  var edits: seq[tuple[line, start, len: int, repl: string]]
  for t in tokenize(s):
    if t.kind != tkIdent or not sameIdent(s.text(t), oldName) or t.start == 0: continue
    let l = s.lines[t.line]
    if l[t.start - 1] != '.': continue
    var e = t.start - 1                       # end of the receiver
    var b = e
    while b > 0 and isIdentChar(l[b - 1]): dec b
    if b == e or (b > 0 and l[b - 1] == '.'): continue   # chained: a.b.old is not ours
    if formType.len > 0 and not recv.anyIt(sameIdent(it, l[b ..< e])): continue
    edits.add (t.line, t.start, t.len, newName)
  s.applyEdits edits
  s.join

# ---------------------------------------------------------------- imports

proc renameImport*(src, oldUnit, newUnit: string, dir = ""): string =
  ## Updates `import oldUnit`, `import a, oldUnit`, `import dir/[oldUnit, b]`
  ## (as the last path part) and `from oldUnit import x` to the new name.
  ## Longer paths such as `oldUnit/sub` and other identifiers are not touched.
  ## `dir` is the folder the unit is imported from when it is not the folder of
  ## the file (`sub`, `../x`): `import sub/oldUnit` is then the import of the unit.
  var s = split(src)
  var edits: seq[tuple[line, start, len: int, repl: string]]
  var inImport = false
  var depth = 0
  var afterFrom = false          # in `from <module>`, before its `import`
  var fromNames = false          # after that `import`: the names are not modules
  var lastText = ""
  var prevLine = -1
  let toks = tokenize(s)
  for t in toks:
    if t.line != prevLine:
      # a new line: an import statement goes on after a trailing comma or an open bracket
      if prevLine >= 0 and not (inImport and (lastText == "," or depth > 0)):
        inImport = false
      prevLine = t.line
    let txt = s.text(t)
    if t.kind == tkKeyword and t.start == (s.lines[t.line].len - s.lines[t.line].strip(trailing = false).len) and
       txt in ["import", "export", "from", "include"]:
      inImport = true
      depth = 0
      afterFrom = txt == "from"
      fromNames = false
      lastText = txt
      continue
    if not inImport:
      continue
    if t.kind in {tkComment, tkDocComment}: continue
    lastText = txt
    if t.kind == tkPunct or t.kind == tkOperator:
      for c in txt:
        if c == '[': inc depth
        elif c == ']': dec depth
    if t.kind == tkIdent and txt == oldUnit and not fromNames:
      let l = s.lines[t.line]
      let after = t.start + t.len
      let nextCh = if after < l.len: l[after] else: ' '
      let prevCh = if t.start > 0: l[t.start - 1] else: ' '
      let prev2 = if t.start > 1: l[t.start - 2] else: ' '
      let before = l[0 ..< t.start]
      let startsPath =
        if dir.len > 0:
          before.endsWith(dir & "/") and
            (before.len == dir.len + 1 or before[before.len - dir.len - 2] in {' ', ',', '[', '\t'})
        else: prevCh in {' ', ',', '[', '\t'} or (prevCh == '/' and prev2 == '.')
      if startsPath and nextCh != '/':
        edits.add (t.line, t.start, t.len, newUnit)
    if afterFrom and txt == "import":
      afterFrom = false
      fromNames = true
  s.applyEdits edits
  s.join

proc renameLoadFormPath*(src, oldNfm, newNfm: string): string =
  ## Updates the file name in `loadForm Type, "old.nfm"`.
  var s = split(src)
  for i in 0 ..< s.lines.len:
    if s.lines[i].startsWith("loadForm"):
      s.lines[i] = s.lines[i].replace("\"" & oldNfm & "\"", "\"" & newNfm & "\"")
  s.join
