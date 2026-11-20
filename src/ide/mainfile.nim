## Edits of the project's main program file. The IDE touches the file only
## between marker comments:
##
## ```nim
## # nimrad: imports begin
## {.push warning[UnusedImport]: off.}
## import unit1
## {.pop.}
## # nimrad: imports end
## ...
##   # nimrad: forms begin
##   let mainForm = newForm1()
##   let form2 {.used.} = newForm2()
##   # nimrad: forms end
## ```
##
## A top-level `fonts` block (after the imports) registers the project's fonts:
##
## ```nim
## # nimrad: fonts begin
## import nimvcl/graphics/font
## const projectFont1Regular = staticRead("fonts/Foo-Regular.ttf")
## registerFontFamilyData("Foo", projectFont1Regular)
## # nimrad: fonts end
## ```
##
## `imports` holds one `import unitN` per unit (inside a `push`/`pop` pair that
## silences "imported and not used", which a unit without a form would cause;
## new imports go before the `{.pop.}`); `forms` is the IDE's
## `Application.CreateForm` list: the first form is the main form (the one
## `Application.run` shows), the others are only created, so they stay hidden
## until the program shows them. Calling each constructor also means the import
## of a form unit is used.
##
## Everything outside the blocks is never changed. When a block (or its
## marker) is missing, the matching edit is skipped and the procs return the
## source unchanged. Line endings (`\n` or `\r\n`) and the indent of the
## `forms` block are kept. Pure string functions, no UI.

import std/[strutils, sequtils]
import ./nimsource

const
  ImportsBlock* = "imports"
  FormsBlock* = "forms"
  FontsBlock* = "fonts"
  MainFormVar* = "mainForm"

type BlockRange* = tuple[b, e: int]   ## line index of the begin and end marker; -1 = none

const
  MarkerPrefix* = "# nimrad: "
  LegacyMarkerPrefix* = "# nimvcl-ide: "   ## written by the IDE before it was renamed
  ## Marker prefixes the IDE reads, the current one first. Projects keep the
  ## prefix they already have (a block is only ever rewritten between its
  ## markers); every block the IDE creates uses `MarkerPrefix`.

func beginMarker*(name: string): string = MarkerPrefix & name & " begin"
func endMarker*(name: string): string = MarkerPrefix & name & " end"

func isMarker*(t, name, suffix: string): bool =
  ## `t` (stripped) is the `suffix` ("begin" / "end") marker of block `name`,
  ## written with either the current or the legacy prefix.
  t == MarkerPrefix & name & " " & suffix or t == LegacyMarkerPrefix & name & " " & suffix

proc findBlock*(lines: seq[string], name: string): BlockRange =
  result = (-1, -1)
  for i, l in lines:
    let t = l.strip
    if result.b < 0:
      if t.isMarker(name, "begin"): result.b = i
    elif t.isMarker(name, "end"):
      result.e = i
      return
  result = (-1, -1)

proc hasBlock*(src, name: string): bool =
  findBlock(src.split('\n'), name).b >= 0

func isIdentCh(c: char): bool = c in IdentChars

func callsCtor(line, formType: string): bool =
  ## `new<formType>(` as a whole word, outside a comment.
  let hash = line.find('#')
  let code = if hash >= 0: line[0 ..< hash] else: line
  let key = "new" & formType & "("
  var i = code.find(key)
  while i >= 0:
    if i == 0 or not code[i - 1].isIdentCh: return true
    i = code.find(key, i + 1)

func formVar*(formType: string): string =
  ## The variable of a secondary form: `Form2` -> `form2`.
  result = formType
  if result.len > 0: result[0] = result[0].toLowerAscii
  if cmpIgnoreStyle(result, MainFormVar) == 0: result.add "Created"

func crlf*(lines: seq[string]): bool =
  lines.len > 1 and lines.anyIt(it.endsWith('\r'))

proc insertBefore*(lines: var seq[string], at: int, text: string, indent: string) =
  let tail = if lines.crlf: "\r" else: ""
  lines.insert(indent & text & tail, at)

proc blockHas(lines: seq[string], r: BlockRange, pred: proc(l: string): bool): bool =
  for i in r.b + 1 ..< r.e:
    if pred(lines[i]): return true

proc blockIndent*(lines: seq[string], r: BlockRange): string =
  let l = lines[r.b]
  l[0 ..< l.len - l.strip(trailing = false).len]

proc addImport*(src, unit: string): string =
  ## `import unit` at the end of the `imports` block (unless already imported).
  var lines = src.split('\n')
  let r = findBlock(lines, ImportsBlock)
  if r.b < 0: return src
  let want = "import " & unit
  if unit in importedModules(src): return src       # also when the user imported it elsewhere
  var at = r.e
  while at - 1 > r.b and lines[at - 1].strip == "{.pop.}": dec at   # stay inside push/pop
  lines.insertBefore(at, want, lines.blockIndent r)
  lines.join("\n")

proc removeImport*(src, unit: string): string =
  ## Drops `import unit` from the `imports` block.
  var lines = src.split('\n')
  let r = findBlock(lines, ImportsBlock)
  if r.b < 0: return src
  let want = "import " & unit
  var i = r.e - 1
  while i > r.b:
    if lines[i].strip == want: lines.delete i
    dec i
  lines.join("\n")

proc addForm*(src, formType: string): string =
  ## `let formN {.used.} = newFormN()` at the end of the `forms` block, or
  ## `let mainForm = newFormN()` when the block holds no form yet.
  var lines = src.split('\n')
  let r = findBlock(lines, FormsBlock)
  if r.b < 0: return src
  if lines.blockHas(r, proc(l: string): bool = l.callsCtor(formType)): return src
  let hasMain = lines.blockHas(r, proc(l: string): bool = l.strip.startsWith("let " & MainFormVar))
  let line =
    if hasMain: "let " & formVar(formType) & " {.used.} = new" & formType & "()"
    else: "let " & MainFormVar & " = new" & formType & "()"
  lines.insertBefore(r.e, line, lines.blockIndent r)
  lines.join("\n")

proc removeForm*(src, formType: string): string =
  ## Drops the line that creates the form from the `forms` block.
  var lines = src.split('\n')
  let r = findBlock(lines, FormsBlock)
  if r.b < 0: return src
  var i = r.e - 1
  while i > r.b:
    if lines[i].callsCtor(formType): lines.delete i
    dec i
  lines.join("\n")

proc isMainForm*(src, formType: string): bool =
  ## Whether `formType` is the form `Application.run` shows (the `mainForm`
  ## line), wherever in the file that line is.
  for l in src.split('\n'):
    if l.callsCtor(formType) and l.strip.startsWith("let " & MainFormVar): return true

proc addUnit*(src, unit, formType: string): string =
  ## The import, and for a form (`formType` not empty) its create line.
  result = src.addImport(unit)
  if formType.len > 0: result = result.addForm(formType)

proc removeUnit*(src, unit, formType: string): string =
  result = src.removeImport(unit)
  if formType.len > 0: result = result.removeForm(formType)

proc setFonts*(src: string, content: seq[string]): string =
  ## Replaces the lines of the `fonts` block with `content` (no indent, no line
  ## ends). A file without the block gets one right after the imports block
  ## (only when `content` is not empty); without an imports block it is left alone.
  var lines = src.split('\n')
  let tail = if lines.crlf: "\r" else: ""
  var r = findBlock(lines, FontsBlock)
  if r.b < 0:
    if content.len == 0: return src
    let imp = findBlock(lines, ImportsBlock)
    if imp.b < 0: return src
    lines.insert(beginMarker(FontsBlock) & tail, imp.e + 1)
    lines.insert(endMarker(FontsBlock) & tail, imp.e + 2)
    r = (imp.e + 1, imp.e + 2)
  for _ in r.b + 1 ..< r.e: lines.delete(r.b + 1)
  for i, l in content: lines.insert(l & tail, r.b + 1 + i)
  lines.join("\n")
