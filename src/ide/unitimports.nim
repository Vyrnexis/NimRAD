## The control imports of a form unit. A generated unit imports only the
## modules of the controls its form uses, between marker comments:
##
## ```nim
## {.push warning[UnusedImport]: off.}
## import nimvcl/prelude
## import nimvcl/dsl/formload
## # nimrad: imports begin
## import nimvcl/controls/button
## import nimvcl/controls/edit
## # nimrad: imports end
## {.pop.}
## ```
##
## The IDE rewrites the lines of the block when it saves the unit, from the
## classes in the designed form: a new class adds its module, the last object
## of a class removes it. Only lines of the form `import nimvcl/<dir>/<module>`
## inside the block are the IDE's; any other line in the block, and everything
## outside it, is left alone. A unit without the block (an older project that
## says `import nimvcl`) is never changed.
##
## **Classes of your own.** A form can use a component class that is not
## nimvcl's: one a unit of the project declares or registers
## (`Project.userClassImports`), or one the `.nimproj` names in `classImports`.
## `importsFor` takes those as a (class, module) list next to the nimvcl table, so
## the unit gets `import gauge` (the path from the unit's own folder) between
## the markers as well, and loses it when the last object of the class goes. The
## IDE only manages the lines of modules that are in that list; any other line
## in the block is the user's.
##
## Pure string functions plus the class table; no UI.

import std/[strutils, algorithm, sets, sequtils, os, options]
import nimvcl/dsl/nfmsyntax
import ./[mainfile, nimsource]

const
  UnitImportsBlock* = "imports"
  ImportAllTag* = MarkerPrefix & "all"
  LegacyImportAllTag* = LegacyMarkerPrefix & "all"
  PreludeLine* = "import nimvcl/prelude"

  classModules* = [
    # (class, module path); the base classes (Form, Control, ...) are imported
    # by the unit template itself
    ("Frame", "nimvcl/controls/frame"),
    ("Label", "nimvcl/controls/label"),
    ("Button", "nimvcl/controls/button"),
    ("CheckBox", "nimvcl/controls/checkbox"),
    ("RadioButton", "nimvcl/controls/radiobutton"),
    ("Panel", "nimvcl/controls/panel"),
    ("GroupBox", "nimvcl/controls/panel"),
    ("Bevel", "nimvcl/controls/bevel"),
    ("PaintBox", "nimvcl/controls/paintbox"),
    ("Image", "nimvcl/controls/imagectl"),
    ("ImageControl", "nimvcl/controls/imagectl"),
    ("ScrollBox", "nimvcl/controls/scrollbox"),
    ("Splitter", "nimvcl/controls/splitter"),
    ("FlowPanel", "nimvcl/controls/flowpanel"),
    ("GridPanel", "nimvcl/controls/flowpanel"),
    ("StatusBar", "nimvcl/controls/statusbar"),
    ("StatusPanel", "nimvcl/controls/statusbar"),
    ("ToolBar", "nimvcl/controls/toolbar"),
    ("ToolButton", "nimvcl/controls/toolbar"),
    ("TabControl", "nimvcl/controls/pagecontrol"),
    ("PageControl", "nimvcl/controls/pagecontrol"),
    ("TabSheet", "nimvcl/controls/pagecontrol"),
    ("Edit", "nimvcl/controls/edit"),
    ("Memo", "nimvcl/controls/memo"),
    ("SpinEdit", "nimvcl/controls/spinedit"),
    ("ComboBox", "nimvcl/controls/combobox"),
    ("ListBox", "nimvcl/controls/listbox"),
    ("TrackBar", "nimvcl/controls/trackbar"),
    ("ProgressBar", "nimvcl/controls/progressbar"),
    ("ScrollBar", "nimvcl/controls/scrollbar"),
    ("TreeView", "nimvcl/controls/treeview"),
    ("ListView", "nimvcl/controls/listview"),
    ("ListColumn", "nimvcl/controls/listview"),
    ("DrawGrid", "nimvcl/controls/grids"),
    ("StringGrid", "nimvcl/controls/grids"),
    ("CodeEdit", "nimvcl/controls/codeedit"),
    ("Timer", "nimvcl/core/timer"),
    ("ImageList", "nimvcl/controls/imagelist"),
    ("MainMenu", "nimvcl/controls/menus"),
    ("PopupMenu", "nimvcl/controls/menus"),
    ("MenuItem", "nimvcl/controls/menus"),
    ("ActionList", "nimvcl/controls/actions"),
    ("Action", "nimvcl/controls/actions")]

type UserClasses* = openArray[(string, string)]
  ## (class, import path) of classes that are not nimvcl's.

proc moduleOf*(className: string): string =
  ## The module that declares a nimvcl class, "" for the base classes and for
  ## classes the table does not know (the user's own, see `UserClasses`).
  for (c, m) in classModules:
    if c == className: return m

proc moduleOf*(className: string, user: UserClasses): string =
  ## Like `moduleOf`, a class of the user's list first.
  for (c, m) in user:
    if c == className: return m
  moduleOf(className)

proc collectClasses(root: NfmNode, baseDir: string, classes: var HashSet[string],
                    depth = 0) =
  for n in walk(root): classes.incl n.className
  if root.inherited and baseDir.len > 0 and depth < 16:
    # an inherited form also uses the classes of its ancestors
    let apath = if root.ancestor.isAbsolute: root.ancestor else: baseDir / root.ancestor
    try:
      collectClasses(parseNfm(readFile(apath)), apath.parentDir, classes, depth + 1)
    except CatchableError: discard

proc tryImportsFor*(nfmText: string, baseDir = "", user: UserClasses = []): Option[seq[string]] =
  ## The module paths (sorted, no duplicates) of the classes a form file uses;
  ## `none` when the form file does not parse. `baseDir` (the folder of the
  ## file) lets an inherited form count the classes of its ancestors' files too.
  ## `user` names the modules of classes that are not nimvcl's.
  var root: NfmNode
  try: root = parseNfm(nfmText)
  except NfmError: return none(seq[string])
  var modules: seq[string]
  var classes = initHashSet[string]()
  collectClasses(root, baseDir, classes)
  var seen = initHashSet[string]()
  for c in classes:
    let m = moduleOf(c, user)
    if m.len > 0 and m notin seen:
      seen.incl m
      modules.add m
  modules.sort
  some(modules)

proc importsFor*(nfmText: string, baseDir = "", user: UserClasses = []): seq[string] =
  ## `tryImportsFor`, where a form file that does not parse needs none.
  tryImportsFor(nfmText, baseDir, user).get(@[])

func managedPath(line: string, owned: openArray[string]): string =
  ## `nimvcl/controls/button` for the line `import nimvcl/controls/button`, the
  ## module for the line that imports one of `owned` (a project unit that
  ## provides a class); "" for anything else.
  let t = line.strip
  if t.startsWith("import "):
    let p = t["import ".len .. ^1].strip
    if p.len > 0 and not p.anyIt(it in {' ', ',', '[', ']', '#', '{'}) and
       (p.startsWith("nimvcl/") or p in owned): return p

proc syncImports*(src: string, wanted: seq[string], owned: openArray[string] = []): string =
  ## Makes the managed lines of the `imports` block match `wanted`. A module
  ## the file already imports elsewhere is not added again. Returns `src`
  ## unchanged when the block is missing. The lines the IDE manages are the
  ## `nimvcl/...` imports and those of the modules in `owned`.
  var lines = src.split('\n')
  let r = findBlock(lines, UnitImportsBlock)
  if r.b < 0: return src
  var present = initHashSet[string]()
  var i = r.e - 1
  while i > r.b:                       # drop the lines that are no longer needed
    let p = managedPath(lines[i], owned)
    if p.len > 0:
      if p in wanted and p notin present: present.incl p
      else: lines.delete i             # stale (or a duplicate)
    dec i
  let r2 = findBlock(lines, UnitImportsBlock)
  let outside = lines[0 ..< r2.b] & lines[r2.e + 1 .. ^1]
  var elsewhere = initHashSet[string]()
  for m in importedModules(outside.join("\n")): elsewhere.incl m
  let indent = lines.blockIndent r2
  var at = r2.e
  for m in wanted:
    if m notin present and m notin elsewhere:
      lines.insertBefore(at, "import " & m, indent)
      inc at
  lines.join("\n")

proc syncFromNfm*(src, nfmText: string, baseDir = "", importAll = false,
                  user: UserClasses = []): string =
  ## `syncImports` for the classes of a form file; with `importAll` the block
  ## holds only the modules of the user's classes (the unit imports all of
  ## nimvcl). Returns `src` unchanged when the form file does not parse.
  var owned: seq[string]
  for (_, m) in user: owned.add m
  let found = tryImportsFor(nfmText, baseDir, user)
  if found.isNone: return src
  let wanted = found.get
  syncImports(src, if importAll: wanted.filterIt(it in owned) else: wanted, owned)

proc collectNames(root: NfmNode, dir: string, seen: var HashSet[string],
                  names: var seq[string], depth = 0) =
  for n in walk(root):
    if n.name.len > 0 and n.name notin seen:
      seen.incl n.name
      names.add n.name
  if root.inherited and dir.len > 0 and depth < 16:
    let apath = if root.ancestor.isAbsolute: root.ancestor else: dir / root.ancestor
    try: collectNames(parseNfm(readFile(apath)), apath.parentDir, seen, names, depth + 1)
    except CatchableError: discard

proc componentNames*(nfmText: string, baseDir = ""): seq[string] =
  ## The names of the objects in a form file, those of an inherited form's
  ## ancestors included.
  var root: NfmNode
  try: root = parseNfm(nfmText)
  except NfmError: return
  var seen = initHashSet[string]()
  collectNames(root, baseDir, seen, result)

# ------------------------------------------------------------ user imports

proc importsModule*(src, module: string): bool =
  ## Whether the source imports `module` (`nimvcl/controls/edit`), by its own
  ## line, in a `[a, b]` group, or through `import nimvcl` (everything).
  for p in importedModules(src):
    if p == module or p == "nimvcl": return true

proc addUserImport*(src, module: string): string =
  ## `import <module>` in the unit's own import area: right above the IDE's
  ## `imports begin` marker (never inside the block), or after the last import
  ## of the file when it has no block. Unchanged when the module is imported
  ## already.
  if src.importsModule(module): return src
  var lines = src.split('\n')
  let r = findBlock(lines, UnitImportsBlock)
  var at = -1
  var indent = ""
  if r.b >= 0:
    at = r.b
    indent = lines.blockIndent r
  else:
    var k = 0
    var cont = false
    while k < lines.len:
      let t = lines[k].strip
      let code = if t.find('#') >= 0: t[0 ..< t.find('#')].strip else: t
      if cont:
        at = k + 1
        cont = code.endsWith(",")
      elif t.len == 0 or t.startsWith("#") or code.startsWith("{.p") or
           code.startsWith("export "):
        discard
      elif code.startsWith("import ") or code.startsWith("from "):
        at = k + 1
        indent = lines[k][0 ..< lines[k].len - lines[k].strip(trailing = false).len]
        cont = code.endsWith(",")
      else: break
      inc k
    if at < 0:
      # no import yet: below the leading comment (the unit's doc comment)
      at = 0
      while at < lines.len and (lines[at].strip.startsWith("##") or lines[at].strip.len == 0):
        inc at
  lines.insertBefore(at, "import " & module, indent)
  lines.join("\n")

# --------------------------------------------------------------- import all

proc setImportAll*(src: string, on: bool): string =
  ## Turns the prelude line into `import nimvcl   # nimrad: all` (`on`),
  ## empties the managed block, or the reverse. Only the prelude line and the
  ## tagged line are touched; the block is refilled by `syncFromNfm`.
  var lines = src.split('\n')
  let tail = if lines.crlf: "\r" else: ""
  for i, l in lines:
    let t = l.strip
    let indent = l[0 ..< l.len - l.strip(trailing = false).len]
    if on and t == PreludeLine:
      lines[i] = indent & "import nimvcl   " & ImportAllTag & tail
    elif not on and t.startsWith("import nimvcl ") and (t.endsWith(ImportAllTag) or t.endsWith(LegacyImportAllTag)) and
         t["import nimvcl".len .. ^1].strip.startsWith("#"):
      lines[i] = indent & PreludeLine & tail
  result = lines.join("\n")
  if on: result = syncImports(result, @[])
