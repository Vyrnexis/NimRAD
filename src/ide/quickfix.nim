## Quick fixes for compiler messages (pure, no UI):
##
## * `undeclared identifier: 'X'` where nimvcl declares `X` in some module:
##   "Add import nimvcl/<module>" (`fkAddImport`, one module or a few to choose from);
## * `undeclared field: 'edit1'`, `attempting to call undeclared routine: 'edit1'`
##   or `undeclared identifier: 'edit1'` where the form has a component `Edit1`
##   (it differs only in the case of the first letter): "Did you mean Edit1?"
##   (`fkRename`, replaces that occurrence).
##
## `fixesFor` gives the fixes of one message; the edits themselves are
## `unitimports.addUserImport` and `renameAt`.

import std/strutils
import ./[messages, symbols]

type
  FixKind* = enum fkAddImport, fkRename

  QuickFix* = object
    kind*: FixKind
    title*: string
    ident*: string              ## the name the compiler did not know
    modules*: seq[string]       ## fkAddImport: the candidates
    replacement*: string        ## fkRename: the component's name

func quoted(text, key: string): string =
  ## `'name'` after `key` in the first line of the message.
  let first = text.splitLines[0]
  let i = first.find(key)
  if i < 0: return
  let a = first.find('\'', i + key.len)
  if a < 0: return
  let b = first.find('\'', a + 1)
  if b > a + 1: first[a + 1 ..< b] else: ""

func unknownName*(text: string): string =
  ## The name in "undeclared identifier: 'x'", "undeclared field: 'x' ..." or
  ## "attempting to call undeclared routine: 'x'"; "" for other messages.
  for key in ["undeclared identifier: ", "undeclared field: ", "undeclared routine: "]:
    let q = quoted(text, key)
    if q.len > 0: return q

func caseSibling*(name: string, components: openArray[string]): string =
  ## The component whose name is `name` with another case of the first letter.
  if name.len < 2 or name in components: return
  for c in components:
    if c.len == name.len and c[1 .. ^1] == name[1 .. ^1] and c[0] != name[0] and
       c[0].toLowerAscii == name[0].toLowerAscii:
      return c

proc fixesFor*(m: Message, components: openArray[string]): seq[QuickFix] =
  ## The fixes of an error message (none for other kinds). `components` are
  ## the names of the objects of the form of the unit the error is in.
  if m.kind != MessageKind.mkError or not m.hasLocation: return
  let name = unknownName(m.text)
  if name.len == 0: return
  let sib = caseSibling(name, components)
  if sib.len > 0:
    return @[QuickFix(kind: fkRename, ident: name, replacement: sib,
                      title: "Did you mean " & sib & "?")]
  if m.text.startsWith("undeclared identifier"):
    let mods = modulesFor(name)
    if mods.len == 1:
      result.add QuickFix(kind: fkAddImport, ident: name, modules: mods,
                          title: "Add import " & mods[0])
    elif mods.len > 1:
      result.add QuickFix(kind: fkAddImport, ident: name, modules: mods,
                          title: "Add import of " & name & " (" & $mods.len & " modules)")

func isWord(s: string, i, n: int): bool =
  (i == 0 or s[i - 1] notin IdentChars) and (i + n >= s.len or s[i + n] notin IdentChars)

proc renameAt*(src: string, line, col: int, ident, replacement: string): string =
  ## Replaces the occurrence of `ident` on the 1-based `line` that is nearest
  ## to `col` (the compiler's column may point at the dot before it).
  var lines = src.split('\n')
  if line < 1 or line > lines.len: return src
  let l = lines[line - 1]
  var best = -1
  var i = l.find(ident)
  while i >= 0:
    if l.isWord(i, ident.len) and (best < 0 or abs(i - (col - 1)) < abs(best - (col - 1))):
      best = i
    i = l.find(ident, i + 1)
  if best < 0: return src
  lines[line - 1] = l[0 ..< best] & replacement & l[best + ident.len .. ^1]
  lines.join("\n")
