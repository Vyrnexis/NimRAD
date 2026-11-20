## Search > Find in Files: the search itself, without any UI.
##
## `projectFiles` lists what is searched (the units of the project, or every
## `.nim` and `.nfm` under the project folder), `findInFiles` reads them one
## after the other on the calling thread and returns the lines that match, at
## most `MaxHits` of them. The matching is nimvcl's `Searcher` (plain text,
## case, whole word, regular expression with nimvcl's own engine), run over a
## `CodeModel` that is loaded with each file. A line is listed once however
## often it matches.
##
## Limits: `MaxHits` hits, `MaxFileSize` bytes per file (a bigger one is
## skipped and counted), `MaxFiles` files in the folder scope, no hidden
## folders, no `nimcache`, not the output folder.

import std/[os, algorithm, strutils]
import nimvcl/controls/[codemodel, search]
import ./project

const
  MaxHits* = 1000
  MaxFileSize* = 2_000_000
  MaxFiles* = 5000
  MaxHitText = 300

type
  FindScope* = enum fsUnits, fsFolder

  FindOptions* = object
    text*: string
    caseSensitive*, wholeWord*, regex*: bool
    scope*: FindScope

  FindHit* = object
    file*: string
    line*, col*: int         ## 1-based (col counts bytes)
    text*: string            ## the line, stripped and cut

  FindResult* = object
    hits*: seq[FindHit]
    files*: int              ## files that have a hit
    scanned*: int            ## files read
    skipped*: int            ## files left out: too big, binary or unreadable
    truncated*: bool         ## more than `MaxHits` lines match
    error*: string           ## a bad regular expression ("" when fine)

  TextOf* = proc(file: string, text: var string): bool
    ## Gives the text of a file that is not the one on disk (an edited unit);
    ## false = read the file.

proc projectFiles*(p: Project, scope: FindScope): seq[string] =
  ## The files `findInFiles` reads, in a stable order.
  case scope
  of fsUnits:
    var l = @[p.mainPath]
    for u in p.units: l.add p.nimPathOf(u)
    for f in l:
      if f notin result and fileExists(f): result.add f
  of fsFolder:
    let skipDir = normalizedPath(p.outputPath)
    proc walk(dir: string, acc: var seq[string]) =
      var entries: seq[(PathComponent, string)]
      for kind, path in walkDir(dir): entries.add (kind, path)
      entries.sort(proc(a, b: (PathComponent, string)): int = cmp(a[1], b[1]))
      for (kind, path) in entries:
        if acc.len >= MaxFiles: return
        let name = path.extractFilename
        case kind
        of pcDir:
          if name.startsWith(".") or name == "nimcache" or normalizedPath(path) == skipDir: continue
          walk(path, acc)
        of pcFile:
          let ext = name.splitFile.ext.toLowerAscii
          if ext in [".nim", ".nfm"]: acc.add path
        else: discard
    walk(p.dir, result)

proc cut(line: string): string =
  result = line.strip
  if result.len > MaxHitText:
    var n = MaxHitText
    while n > 0 and (result[n].ord and 0xC0) == 0x80: dec n     # not inside a UTF-8 sequence
    result = result[0 ..< n] & "..."

proc findInFiles*(files: seq[string], o: FindOptions, textOf: TextOf = nil): FindResult =
  if o.text.len == 0: return
  var searcher: Searcher
  try:
    searcher = newSearcher(o.text, SearchOptions(ignoreCase: not o.caseSensitive,
                                                 wholeWord: o.wholeWord, regex: o.regex))
  except RegexError as e:
    result.error = e.msg
    return
  let model = newCodeModel()
  for f in files:
    var text = ""
    let edited = textOf != nil and textOf(f, text)
    if not edited:
      try:
        if getFileSize(f) > MaxFileSize:
          inc result.skipped
          continue
        text = readFile(f)
      except CatchableError:
        inc result.skipped
        continue
    if text.len > MaxFileSize or '\0' in text[0 ..< min(text.len, 4096)]:
      inc result.skipped
      continue
    inc result.scanned
    discard model.loadText(text)
    var lastLine = -1
    var any = false
    for mt in searcher.findAll(model):
      if mt.a.line == lastLine: continue
      lastLine = mt.a.line
      if result.hits.len >= MaxHits:
        result.truncated = true
        break
      any = true
      result.hits.add FindHit(file: f, line: mt.a.line + 1, col: mt.a.col + 1,
                              text: cut(model.line(mt.a.line)))
    if any: inc result.files
    if result.truncated: break
