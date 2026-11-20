## Parsing of Nim compiler and runtime output into `Message`s for the
## Messages panel. Pure Nim, no UI.
##
## Recognised lines (compiler run with `--colors:off --listFullPaths:on`):
##
## * `file(line, col) Error: text`, `Warning:`, `Hint:` (also `Fatal:`);
## * `file(line, col) template/generic instantiation of `x` from here`: kept as
##   a note on the error (or warning) that follows it;
## * lines that continue an error or warning (the `Expression:` block of a type
##   mismatch, candidate lists, ...), blank lines inside included: appended to
##   its text until the next recognised line;
## * runtime traceback lines `file(line) proc` (and `file proc`, which Nim
##   prints when the line is unknown): `isTrace` messages, kind `mkInfo`;
## * anything else (`CC: x.nim`, `Hint: used config file ...`, program output):
##   `mkInfo` for lines without a kind, `mkHint`/`mkError`/`mkWarning` for
##   location-less `Hint:`/`Error:`/`Warning:` lines.
##
## Use `MessageParser` for a stream of lines, `parseMessages` for a whole text.

import std/[strutils, parseutils]

type
  MessageKind* = enum mkError, mkWarning, mkHint, mkInfo

  Message* = object
    kind*: MessageKind
    file*: string          ## "" when the line has no location
    line*, col*: int       ## 1-based as printed by Nim; 0 when unknown
    text*: string          ## the text after `Error:` etc.; may span lines
    notes*: seq[Message]   ## instantiation stack, innermost call last
    isTrace*: bool         ## a runtime traceback entry (`text` is the proc)

  MessageParser* = object
    done: seq[Message]
    pending: seq[Message]  ## instantiation notes waiting for their error
    open: bool             ## the last message accepts continuation lines
    blanks: int            ## blank lines seen since the last continuation line

func hasLocation*(m: Message): bool = m.file.len > 0 and m.line > 0

func isKnownPrefix(s: string): bool =
  s.startsWith("Error: ") or s.startsWith("Warning: ") or s.startsWith("Hint: ") or
  s.startsWith("Fatal: ") or s.startsWith("template/generic instantiation")

func kindOf(word: string): (bool, MessageKind) =
  case word
  of "Error", "Fatal": (true, mkError)
  of "Warning": (true, mkWarning)
  of "Hint": (true, mkHint)
  else: (false, mkInfo)

proc splitKind(s: string, kind: var MessageKind, text: var string): bool =
  ## "Error: text" -> kind, text
  let c = s.find(':')
  if c <= 0 or c + 1 > s.high or s[c + 1] != ' ': return false
  let (ok, k) = kindOf(s[0 ..< c])
  if not ok: return false
  kind = k
  text = s[c + 2 .. ^1]
  true

proc parseLocation(line: string, file: var string, ln, col: var int,
                   rest: var string): bool =
  ## `file(l, c) rest` or `file(l) rest`, where `rest` is a known message start
  ## (compiler form) or any text (trace form, col = 0).
  var i = line.find('(')
  while i > 0:
    var p = i + 1
    var l, c = 0
    let n1 = parseInt(line, l, p)
    if n1 > 0:
      p += n1
      var hasCol = false
      if p < line.len and line[p] == ',':
        inc p
        while p < line.len and line[p] == ' ': inc p
        let n2 = parseInt(line, c, p)
        if n2 > 0:
          p += n2
          hasCol = true
        else: p = -1
      if p > 0 and p < line.len and line[p] == ')' and p + 1 < line.len and
         line[p + 1] == ' ':
        let r = line[p + 2 .. ^1]
        if (hasCol and isKnownPrefix(r)) or (not hasCol and line[0 ..< i].endsWith(".nim")):
          file = line[0 ..< i]
          ln = l
          col = c
          rest = r
          return true
    i = line.find('(', i + 1)
  false

proc parseLine*(line: string): Message =
  ## Parses one line on its own (no continuation or note handling).
  var file, rest, text: string
  var ln, col: int
  var k: MessageKind
  if parseLocation(line, file, ln, col, rest):
    result = Message(file: file, line: ln, col: col)
    if col == 0:
      result.kind = mkInfo
      result.isTrace = true
      result.text = rest
    elif rest.startsWith("template/generic instantiation"):
      result.kind = mkInfo
      result.text = rest
    elif splitKind(rest, k, text):
      result.kind = k
      result.text = text
    else:
      result.kind = mkInfo
      result.text = rest
  elif splitKind(line, k, text):
    result = Message(kind: k, text: text)
  elif (let sp = line.find(' '); sp > 4 and line.find(' ', sp + 1) < 0 and
        line[0 ..< sp].endsWith(".nim")):
    # "file.nim proc": a traceback entry without a line number
    result = Message(kind: mkInfo, file: line[0 ..< sp], text: line[sp + 1 .. ^1], isTrace: true)
  else:
    result = Message(kind: mkInfo, text: line)

func isInstantiation(m: Message): bool =
  m.hasLocation and m.kind == mkInfo and not m.isTrace and
    m.text.startsWith("template/generic instantiation")

proc feed*(p: var MessageParser, line: string) =
  ## Adds one output line (without its newline).
  let line = line.strip(leading = false, chars = {'\r', '\n'})
  if line.len == 0:
    if p.open: inc p.blanks      # a blank line may sit inside a long error text
    return
  var m = parseLine(line)
  if p.open and p.done.len > 0 and m.kind == mkInfo and not m.isTrace and
     not line.startsWith("CC: ") and not line.allCharsInSet({'.'}):
    p.done[^1].text.add "\n".repeat(p.blanks + 1) & line
    p.blanks = 0
    return
  p.open = false
  p.blanks = 0
  if m.isInstantiation:
    p.pending.add m
    return
  if m.kind in {mkError, mkWarning} and m.hasLocation:
    m.notes = p.pending
    p.pending = @[]
    p.open = true
  elif p.pending.len > 0:
    # notes without a following error: keep them visible as plain messages
    p.done.add p.pending
    p.pending = @[]
  elif m.kind == mkError and m.file.len == 0:
    p.open = true      # `execution of an external compiler program failed`: the C compiler's lines follow
  p.done.add m

proc take*(p: var MessageParser): seq[Message] =
  ## Messages completed so far. The last one is held back while it may still
  ## receive continuation lines; `flush` returns everything at the end.
  if p.open and p.done.len > 0:
    result = p.done[0 ..< p.done.high]
    p.done = @[p.done[^1]]
  else:
    result = p.done
    p.done = @[]

proc flush*(p: var MessageParser): seq[Message] =
  if p.pending.len > 0:
    p.done.add p.pending
    p.pending = @[]
  p.open = false
  result = p.done
  p.done = @[]

proc parseMessages*(text: string): seq[Message] =
  var p: MessageParser
  for l in text.splitLines: p.feed l
  p.flush()

func `$`*(m: Message): string =
  let loc = if m.file.len > 0: m.file & (if m.line > 0: "(" & $m.line & (if m.col > 0: ", " & $m.col else: "") & ")" else: "") & " " else: ""
  loc & (if m.isTrace: "" else: $m.kind & ": ") & m.text
