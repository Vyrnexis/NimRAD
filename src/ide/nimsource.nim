## What the IDE needs to know about Nim source text, in one place: which
## identifiers are valid names, and which modules a file imports. Comments are
## recognised with nimvcl's lexer, so they never count.

import std/[strutils, sequtils, sets]
import nimvcl/controls/nimlexer

const NimKeywords* = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
  "concept", "const", "continue", "converter", "defer", "discard", "distinct", "div",
  "do", "elif", "else", "end", "enum", "except", "export", "finally", "for", "from",
  "func", "if", "import", "in", "include", "interface", "is", "isnot", "iterator",
  "let", "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of",
  "or", "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
  "template", "try", "tuple", "type", "using", "var", "when", "while", "xor", "yield"]

func isValidIdent*(s: string): bool =
  ## A name the IDE accepts for units, projects and components: a letter, then
  ## letters, digits and single underscores (none at the end), not a keyword.
  s.len > 0 and s[0] in {'a'..'z', 'A'..'Z'} and
    s.allIt(it in {'a'..'z', 'A'..'Z', '0'..'9', '_'}) and
    not s.contains("__") and not s.endsWith("_") and s notin NimKeywords

func styleKey*(s: string): string =
  ## Nim identifier equality as a key: the first letter counts, the rest ignores
  ## case and underscores.
  if s.len == 0: return ""
  result = $s[0]
  for ch in s[1 .. ^1]:
    if ch != '_': result.add ch.toLowerAscii

func sameIdent*(a, b: string): bool =
  ## Whether two spellings name the same Nim identifier.
  a == b or a.styleKey == b.styleKey

# ------------------------------------------------------------------ imports

proc codeOfLine(h: NimHighlighter, line: string, state: var int): string =
  ## The line without its comment; "" for a line inside a multi-line string or comment.
  var toks: seq[Token]
  let inside = state != 0
  state = h.lexLine(line, state, toks)
  if inside: return ""
  for t in toks:
    if t.kind in {tkComment, tkDocComment}: return line[0 ..< t.start]
  line

func splitTop(s: string): seq[string] =
  ## Splits at the commas outside brackets.
  var depth = 0
  var cur = ""
  for ch in s:
    if ch == '[': inc depth
    elif ch == ']': dec depth
    if ch == ',' and depth == 0:
      result.add cur
      cur = ""
    else: cur.add ch
  result.add cur

func moduleOf(item: string): string =
  ## `a/b as c` -> `a/b` (no spaces left inside).
  var t = item.strip
  for kw in [" as ", " except "]:
    let i = t.find(kw)
    if i >= 0: t = t[0 ..< i]
  t.strip.replace(" ", "")

func modulesOfList(list: string): seq[string] =
  ## `a/b, c/[d, e as f]` -> `a/b`, `c/d`, `c/e`.
  for item in list.splitTop:
    let q = item.strip
    let b = q.find('[')
    if b >= 0 and q.endsWith("]"):
      let prefix = q[0 ..< b].strip.strip(chars = {'/'}, leading = false)
      for m in q[b + 1 ..< q.high].splitTop:
        let n = moduleOf(m)
        if n.len > 0: result.add(if prefix.len > 0: prefix & "/" & n else: n)
    else:
      let n = moduleOf(q)
      if n.len > 0: result.add n

proc importedModules*(src: string): seq[string] =
  ## The module paths of every `import` statement of the file, in order:
  ## `import a/b, c/[d, e]  # x` gives `a/b`, `c/d`, `c/e`. A list that goes on
  ## in the next line (after a comma or inside the brackets) is followed, and
  ## `as` / `except` parts are left out.
  let h = newNimHighlighter()
  var state = 0
  var collecting = false
  var text = ""
  template finish() =
    if text.len > 0: result.add modulesOfList(text)
    text = ""
    collecting = false
  for raw in src.split('\n'):
    let code = h.codeOfLine(raw.strip(chars = {'\r'}, leading = false), state).strip
    if collecting:
      text.add " " & code
    elif code.startsWith("import ") or code == "import":
      collecting = true
      text = code["import".len .. ^1]
    else: continue
    let open = text.count('[') - text.count(']')
    if open <= 0 and not code.endsWith(","): finish()
  finish()

proc codeIdentKeys*(src: string): HashSet[string] =
  ## The identifiers the code uses, as `styleKey`s; comments and strings (also
  ## multi-line ones) never count.
  let h = newNimHighlighter()
  var state = 0
  var toks: seq[Token]
  for raw in src.split('\n'):
    let line = raw.strip(chars = {'\r'}, leading = false)
    toks.setLen 0
    state = h.lexLine(line, state, toks)
    for t in toks:
      if t.kind == tkIdent: result.incl line[t.start ..< min(t.start + t.len, line.len)].styleKey

# ------------------------------------------------------------------- lines

type LineClass* = enum
  lcBlank       ## nothing on the line
  lcComment     ## only a comment (a doc comment too)
  lcCode        ## code starts on this line (it may continue a multi-line string)
  lcInside      ## the line is inside a multi-line string or comment that began above

proc classifyLines*(lines: openArray[string]): seq[LineClass] =
  ## One class per line, from nimvcl's lexer, so a `proc` at the start of a line
  ## of a triple-quoted string, or a comment at column 0 inside a body, is not
  ## mistaken for code.
  let h = newNimHighlighter()
  var state = 0
  var toks: seq[Token]
  for raw in lines:
    let line = raw.strip(chars = {'\r'}, leading = false)
    toks.setLen 0
    let inside = state != 0
    state = h.lexLine(line, state, toks)
    if inside:
      result.add lcInside
    elif line.strip.len == 0:
      result.add lcBlank
    else:
      var code = false
      for t in toks:
        if t.kind notin {tkComment, tkDocComment} and
           line[t.start ..< min(t.start + t.len, line.len)].strip.len > 0: code = true
      result.add(if code: lcCode else: lcComment)

# ------------------------------------------------------------------ classes

proc identAt*(code: string, i: int): string =
  var j = i
  while j < code.len and (code[j] in IdentChars or ord(code[j]) >= 0x80): inc j
  code[i ..< j]

proc declaredClasses*(src: string): seq[string] =
  ## The classes a unit provides for forms: the ones it registers
  ## (`registerClass(Badge, parent = Panel): ...`) and the `ref object` types it
  ## declares (`Badge* = ref object of Panel`), in order, without duplicates.
  ## Comments and strings never count.
  let h = newNimHighlighter()
  var state = 0
  proc addName(r: var seq[string], name: string) =
    if name.len > 0 and name[0] in IdentStartChars and name notin r: r.add name
  var toks: seq[Token]
  for raw in src.split('\n'):
    var code = raw.strip(chars = {'\r'}, leading = false)
    toks.setLen 0
    let inside = state != 0
    state = h.lexLine(code, state, toks)
    if inside: continue
    for t in toks:                      # comments and strings do not count
      if t.kind in {tkComment, tkDocComment, tkString, tkChar}:
        for k in t.start ..< min(t.start + t.len, code.len): code[k] = ' '
    if code.strip.len == 0: continue
    var at = code.find("registerClass(")
    while at >= 0:
      if at == 0 or code[at - 1] notin IdentChars:
        var k = at + "registerClass(".len
        while k < code.len and code[k] == ' ': inc k
        result.addName code.identAt(k)
      at = code.find("registerClass(", at + 1)
    # `Name* = ref object of Base`, also as `type Name* = ...`
    var t = code.strip
    if t.startsWith("type "): t = t["type ".len .. ^1].strip
    let name = t.identAt(0)
    if name.len == 0: continue
    var k = name.len
    if k < t.len and t[k] == '*': inc k
    while k < t.len and t[k] == ' ': inc k
    if k < t.len and t[k] == '[':                  # generic parameters
      let close = t.find(']', k)
      if close < 0: continue
      k = close + 1
      while k < t.len and t[k] == ' ': inc k
    if k < t.len and t[k] == '=':
      let rest = t[k + 1 .. ^1].strip
      if rest.startsWith("ref object") and name notin ["object", "ref"]: result.addName name
