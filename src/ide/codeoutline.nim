## The Code Explorer's data: what a unit declares at its top level, without UI.
##
## `outlineOf(src)` returns the declarations in source order: `import`s (one
## per module), the names of `type` sections, `proc`/`func`/`method`/
## `iterator`/`template`/`macro`/`converter` definitions, and the names of
## `const`, `var` and `let` (a section or a single line). Only column 0 starts
## a declaration; the lines of a section are the ones at the indent of its first
## line. Comments and the inside of multi-line strings come from nimvcl's lexer
## (`classifyLines`), so they never count.

import std/strutils
import ./nimsource

type
  OutlineKind* = enum okImport, okType, okProc, okConst, okVar

  OutlineItem* = object
    kind*: OutlineKind
    name*: string
    detail*: string        ## `proc`, `func`...; for a type what it is (`ref object of Panel`); for a variable `let`/`var`
    line*: int             ## 1-based
    exported*: bool

const ProcWords = ["proc", "func", "method", "iterator", "template", "macro", "converter"]

func isIdentCh(c: char): bool = c in IdentChars or ord(c) >= 0x80

func nameAt(s: string, i: int): (string, int) =
  ## The identifier (or backticked operator name) at `i` and the index after it.
  var j = i
  if j < s.len and s[j] == '`':
    inc j
    while j < s.len and s[j] != '`': inc j
    if j < s.len: inc j
    return (s[i ..< j].strip(chars = {'`'}), j)
  while j < s.len and isIdentCh(s[j]): inc j
  (s[i ..< j], j)

func wordAt(s: string, w: string): bool =
  s.startsWith(w) and (s.len == w.len or s[w.len] in {' ', '\t'})

func shorten(s: string, n = 40): string =
  var t = s.strip
  let c = t.find(" #")
  if c >= 0: t = t[0 ..< c].strip
  if t.len > n: t = t[0 ..< n - 3] & "..."
  t

func declNames(s: string, kind: OutlineKind, detail: string, line: int): seq[OutlineItem] =
  ## `a*, b: int = 3` -> a, b. A line that does not start with a name gives nothing.
  var i = 0
  while i < s.len:
    while i < s.len and s[i] in {' ', '\t'}: inc i
    if i >= s.len or not (isIdentCh(s[i]) or s[i] == '`'): return
    let (name, e) = nameAt(s, i)
    if name.len == 0: return
    var j = e
    var exp = false
    if j < s.len and s[j] == '*':
      exp = true
      inc j
    result.add OutlineItem(kind: kind, name: name, detail: detail, line: line, exported: exp)
    while j < s.len and s[j] in {' ', '\t'}: inc j
    if j < s.len and s[j] == ',':
      i = j + 1
    else:
      return

proc outlineOf*(src: string): seq[OutlineItem] =
  let lines = src.split('\n')
  var ls: seq[string]
  for l in lines: ls.add l.strip(chars = {'\r'}, leading = false)
  let cls = classifyLines(ls)
  var section = ""          ## "type", "const", "var", "let" while its lines go on
  var indent = -1           ## indent of the entries of the section (-1: not known yet)
  var i = 0
  while i < ls.len:
    let l = ls[i]
    if cls[i] != lcCode:
      inc i
      continue
    let ind = l.len - l.strip(trailing = false).len
    if ind == 0:
      section = ""
      indent = -1
      var handled = false
      for w in ProcWords:
        if l.wordAt(w):
          var p = w.len
          while p < l.len and l[p] in {' ', '\t'}: inc p
          let (name, e) = nameAt(l, p)
          if name.len > 0:
            result.add OutlineItem(kind: okProc, name: name, detail: w, line: i + 1,
                                   exported: e < l.len and l[e] == '*')
          handled = true
          break
      if handled:
        inc i
        continue
      for w in ["type", "const", "var", "let"]:
        if l.wordAt(w):
          section = w
          let rest = l[w.len .. ^1].strip
          if rest.len > 0:
            # `const X = 1`: the entries share the line with the keyword
            let k = if w == "type": okType elif w == "const": okConst else: okVar
            for it in declNames(rest, k, (if k == okVar: w else: ""), i + 1): result.add it
            if k == okType and result.len > 0 and result[^1].line == i + 1:
              let eq = rest.find('=')
              if eq >= 0: result[^1].detail = shorten(rest[eq + 1 .. ^1])
          handled = true
          break
      if handled:
        inc i
        continue
      if l.wordAt("import") or l.wordAt("include") or l.wordAt("export") or l.wordAt("from"):
        # the statement may go on in the next lines (a comma, or an open bracket)
        var stmt = l
        var j = i
        while j + 1 < ls.len and (stmt.strip.endsWith(",") or stmt.count('[') > stmt.count(']')) and
              ls[j + 1].len > 0 and ls[j + 1][0] in {' ', '\t'}:
          inc j
          stmt.add " " & ls[j].strip
        if l.wordAt("import"):
          for m in importedModules(stmt): result.add OutlineItem(kind: okImport, name: m, detail: "import", line: i + 1)
        elif l.wordAt("from"):
          let imp = stmt.find(" import")
          if imp > 5:
            let m = stmt[5 ..< imp].strip.replace(" ", "")
            if m.len > 0: result.add OutlineItem(kind: okImport, name: m, detail: "from", line: i + 1)
        elif l.wordAt("include"):
          for m in importedModules("import" & stmt["include".len .. ^1]):
            result.add OutlineItem(kind: okImport, name: m, detail: "include", line: i + 1)
        i = j + 1
        continue
      inc i
      continue
    # an indented code line: an entry of the open section?
    if section.len > 0:
      if indent < 0: indent = ind
      if ind == indent:
        let body = l.strip
        let k = case section
          of "type": okType
          of "const": okConst
          else: okVar
        let items = declNames(body, k, (if k == okVar: section else: ""), i + 1)
        for it in items: result.add it
        if k == okType and items.len > 0:
          var depth = 0
          var eq = -1
          for c, ch in body:       # the `=` of the declaration, not one in a pragma
            case ch
            of '[', '(', '{': inc depth
            of ']', ')', '}': dec depth
            of '=':
              if depth == 0:
                eq = c
                break
            else: discard
          if eq >= 0: result[^1].detail = shorten(body[eq + 1 .. ^1])
    inc i
