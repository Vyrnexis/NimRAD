## Command line text as the IDE shows it (compiler flags, run parameters): words
## separated by blanks, a word may hold quoted parts, as in a shell.
##
## * `"a b"` and `'a b'` keep their blanks and may start inside a word:
##   `--passL:"-L/my path"` is one argument, `--passL:-L/my path`.
## * inside double quotes `\"` is a quote and `\\` a backslash; any other
##   backslash is itself (so `"C:\my path\x"` is what it looks like). Outside
##   quotes and inside single quotes a backslash is itself.
## * `quoteArg` is the inverse: `splitArgs(quoteArg(a)) == @[a]` for every `a`.

import std/sequtils

proc splitArgs*(text: string): seq[string] =
  var cur = ""
  var started = false          # a word is under way (`""` is an empty word)
  var i = 0
  while i < text.len:
    let c = text[i]
    case c
    of ' ', '\t', '\n', '\r':
      if started:
        result.add cur
        cur = ""
        started = false
    of '"':
      started = true
      inc i
      while i < text.len and text[i] != '"':
        if text[i] == '\\' and i + 1 < text.len and text[i + 1] in {'"', '\\'}:
          inc i
        cur.add text[i]
        inc i
    of '\'':
      started = true
      inc i
      while i < text.len and text[i] != '\'':
        cur.add text[i]
        inc i
    else:
      started = true
      cur.add c
    inc i
  if started: result.add cur

proc quoteArg*(a: string): string =
  ## `a` as one word of the text `splitArgs` reads.
  if a.len > 0 and not a.anyIt(it in {' ', '\t', '\n', '\r', '"', '\''}): return a
  result = "\""
  for i, c in a:
    if c == '"': result.add "\\\""
    elif c == '\\' and (i + 1 == a.len or a[i + 1] in {'"', '\\'}): result.add "\\\\"
    else: result.add c
  result.add '"'
