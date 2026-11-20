## The To-Do list: the comments of a unit that carry a marker, found with
## nimvcl's lexer (so a `TODO` inside a string never counts). Pure Nim, no UI.
##
## A comment counts when, after the `#` (or `##`, or inside `#[ ... ]#`), it
## starts with one of `TodoMarkers` in capitals:
##
## ```nim
## # TODO: write the tests
## # TODO 1: important (a priority, 1 is the highest, 0 = none)
## # FIXME(me): owner in brackets
## #[ TODO -oMe -cUI : Delphi's own syntax, owner and category ]#
## ```
##
## The text follows a `:` or `-` (or just a space). The marker must be a whole
## word, so `TODOS` or `NOTEBOOK` are no markers.

import std/[strutils, parseutils]
import nimvcl/controls/nimlexer

const TodoMarkers* = ["TODO", "FIXME", "NOTE", "HACK", "XXX"]

type
  TodoItem* = object
    marker*: string        ## `TODO`, `FIXME`, ...
    priority*: int         ## 0 = none, 1 = highest
    text*: string
    owner*, category*: string
    line*: int             ## 1-based

func parseComment(c: string): (bool, TodoItem) =
  ## `c` is the comment text without its `#` signs and brackets.
  var s = c.strip
  var item: TodoItem
  for m in TodoMarkers:
    if s.startsWith(m) and (s.len == m.len or s[m.len] notin IdentChars):
      item.marker = m
      s = s[m.len .. ^1].strip(trailing = false)
      break
  if item.marker.len == 0: return
  # a priority number
  var n = 0
  let digits = parseInt(s, n)
  if digits > 0 and (digits == s.len or s[digits] notin IdentChars):
    item.priority = n
    s = s[digits .. ^1].strip(trailing = false)
  # (owner)
  if s.startsWith("("):
    let close = s.find(')')
    if close > 0:
      item.owner = s[1 ..< close].strip
      s = s[close + 1 .. ^1].strip(trailing = false)
  # Delphi's -oOwner -cCategory
  while s.len > 2 and s[0] == '-' and s[1] in {'o', 'c'}:
    var e = 2
    while e < s.len and s[e] notin Whitespace: inc e
    if s[1] == 'o': item.owner = s[2 ..< e] else: item.category = s[2 ..< e]
    s = s[e .. ^1].strip(trailing = false)
  if s.len > 0 and s[0] in {':', '-'}: s = s[1 .. ^1]
  item.text = s.strip
  (true, item)

proc scanTodos*(src: string): seq[TodoItem] =
  ## The marked comments of `src`, in source order.
  let h = newNimHighlighter()
  var state = 0
  var toks: seq[Token]
  var ln = 0
  for raw in src.split('\n'):
    inc ln
    let line = raw.strip(chars = {'\r'}, leading = false)
    toks.setLen 0
    state = h.lexLine(line, state, toks)
    for t in toks:
      if t.kind notin {tkComment, tkDocComment}: continue
      var c = line[t.start ..< min(t.start + t.len, line.len)]
      c = c.strip(trailing = false, chars = {'#', '[', ' ', '\t'})
      if c.endsWith("]#"): c.setLen c.len - 2
      let (ok, item) = parseComment(c)
      if ok:
        var it = item
        it.line = ln
        result.add it
