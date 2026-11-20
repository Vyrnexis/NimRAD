## Scans the nimvcl sources for the symbols an application can use (exported
## procs, funcs, templates, macros, iterators, types, consts, lets, vars and the
## values of exported enums) and renders them as `symbolindex.nim`, the table the
## quick fixes and "Find unit" use to map a symbol to its module.
##
## The scan is textual, on the declarations of the files (the sources are
## written in a regular style: declarations at column 0, `type`/`const`
## sections indented by two). It is not a Nim parser; the test
## `tsymbolindex` compares the committed `symbolindex.nim` with a fresh scan and
## checks well-known symbols, so a source that the scan misreads shows up there.
##
## `scripts/gen_symbolindex.nim` writes the file:
## `nim r scripts/gen_symbolindex.nim <nimvcl src folder> > src/ide/symbolindex.nim`.
##
## Modules that are not meant for applications (the property registry, the
## inspector, the designer surface, the raw platform wrappers) only contribute
## symbols that no other module declares.

import std/[strutils, algorithm, os, sets, sequtils]
import ./fileio

const
  SecondaryModules* = ["nimvcl/dsl/props", "nimvcl/dsl/props_std",
                       "nimvcl/controls/inspector", "nimvcl/controls/propeditors",
                       "nimvcl/controls/designsurface", "nimvcl/platform/dialogs"]
  SkippedModules* = ["nimvcl", "nimvcl/prelude"]    ## only re-export

  routineKeywords = ["proc", "func", "template", "macro", "iterator", "method", "converter"]

type Section = enum secNone, secType, secValue

func isIdentCh(c: char): bool = c in IdentChars

func identAt(s: string, i: int): string =
  var j = i
  while j < s.len and s[j].isIdentCh: inc j
  s[i ..< j]

func leadingSpaces(s: string): int =
  while result < s.len and s[result] == ' ': inc result

func declName(rest: string, exported: var bool): string =
  ## `name* ...` -> "name", exported; backticked (operator) names give "".
  exported = false
  if rest.len == 0 or rest[0] notin IdentStartChars: return ""
  result = rest.identAt(0)
  exported = rest.len > result.len and rest[result.len] == '*'

func enumValues(text: string, values: var seq[string]) =
  for part in text.split(','):
    var p = part.strip
    let c = p.find('#')
    if c >= 0: p = p[0 ..< c].strip
    if p.len > 0 and p[0] in IdentStartChars:
      values.add p.identAt(0)

proc scanDef(lines: seq[string], at: int, rest: string, indent: int, isType: bool,
             res: var seq[string]) =
  ## One entry of a type/const/let/var section (the line `at`, text `rest`).
  var exported = false
  let name = declName(rest, exported)
  if name.len == 0 or not exported: return
  res.add name
  if not isType: return
  let eq = rest.find('=', name.len)
  if eq < 0: return
  let pragma = rest[name.len ..< eq]
  var after = rest[eq + 1 .. ^1].strip
  if not after.startsWith("enum") or "pure" in pragma: return
  after = after[4 .. ^1]
  var values: seq[string]
  enumValues(after, values)
  # the values may continue on the following, deeper indented lines
  var k = at + 1
  while k < lines.len:
    let l = lines[k]
    let t = l.strip
    if t.len == 0 or t.startsWith("#"):
      inc k
      continue
    if l.leadingSpaces <= indent: break
    enumValues(t, values)
    inc k
  res.add values

proc scanSource*(text: string): seq[string] =
  ## The usable symbols declared in one source file (duplicates possible).
  let lines = text.splitLines
  var section = secNone
  var sectionIndent = -1
  var inBlockComment = 0
  var inString = false
  var i = 0

  while i < lines.len:
    let l = lines[i]
    let t = l.strip
    # multi-line strings and block comments hide their lines
    if inString:
      if l.count("\"\"\"") mod 2 == 1: inString = false
      inc i
      continue
    if inBlockComment > 0:
      if "]#" in l or "]##" in l: dec inBlockComment
      inc i
      continue
    if t.startsWith("#[") or t.startsWith("##["):
      if not ("]#" in t[2 .. ^1]): inc inBlockComment
      inc i
      continue
    if l.count("\"\"\"") mod 2 == 1:
      inString = true
      inc i
      continue
    if t.len == 0 or t.startsWith("#"):
      inc i
      continue
    let indent = l.leadingSpaces
    if indent == 0:
      section = secNone
      sectionIndent = -1
      var handled = false
      for kw in routineKeywords:
        if l.startsWith(kw & " "):
          var exported = false
          let name = declName(l[kw.len + 1 .. ^1].strip(trailing = false), exported)
          if exported: result.add name
          handled = true
          break
      if not handled:
        for (kw, sec) in [("type", secType), ("const", secValue), ("let", secValue), ("var", secValue)]:
          if l == kw or l.startsWith(kw & " "):
            section = sec
            if l.len > kw.len + 1:
              scanDef(lines, i, l[kw.len + 1 .. ^1].strip, 0, sec == secType, result)
            break
    elif section != secNone:
      if sectionIndent < 0: sectionIndent = indent
      if indent == sectionIndent: scanDef(lines, i, t, indent, section == secType, result)
    inc i

proc moduleName(srcDir, file: string): string =
  "nimvcl/" & relPosix(file, srcDir / "nimvcl").changeFileExt("")

proc scanTree*(srcDir: string): seq[(string, seq[string])] =
  ## (module, sorted unique names) for every module of `srcDir/nimvcl`, sorted
  ## by module. Secondary modules keep only the names nothing else declares.
  var files: seq[string]
  for f in walkDirRec(srcDir / "nimvcl"):
    if f.endsWith(".nim"): files.add f
  files.sort
  var primary = initHashSet[string]()
  var mods: seq[(string, seq[string])]
  var secondary: seq[(string, seq[string])]
  for f in files:
    let m = moduleName(srcDir, f)
    if m in SkippedModules: continue
    var names = scanSource(readFile(f))
    names.sort
    names = names.deduplicate(isSorted = true)
    if m in SecondaryModules: secondary.add (m, names)
    else:
      mods.add (m, names)
      for n in names: primary.incl n
  for (m, names) in secondary:
    var keep: seq[string]
    for n in names:
      if n notin primary: keep.add n
    if keep.len > 0: mods.add (m, keep)
  for (m, names) in mods:
    if names.len > 0: result.add (m, names)
  result.sort(proc(a, b: (string, seq[string])): int = cmp(a[0], b[0]))

proc renderIndex*(srcDir: string): string =
  ## The text of `symbolindex.nim` for the nimvcl sources in `srcDir`.
  let tree = scanTree(srcDir)
  result = "## The symbols of the nimvcl modules an application can use, by module.\n" &
    "## GENERATED by scripts/gen_symbolindex.nim from the nimvcl sources; do not edit\n" &
    "## (`nimble genindex` rewrites it, the test `tsymbolindex` fails when it is stale).\n\n" &
    "const symbolIndexData*: array[" & $tree.len & ", tuple[module, names: string]] = [\n"
  for k, (m, names) in tree:
    result.add "  (\"" & m & "\", \"" & names.join(" ") & "\")" & (if k < tree.high: ",\n" else: "]\n")
