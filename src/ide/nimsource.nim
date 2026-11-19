## What the IDE needs to know about Nim source text, in one place: which
## identifiers are valid names, and which modules a file imports. Comments are
## recognised with nimvcl's lexer, so they never count.

import std/[strutils, sequtils]
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
