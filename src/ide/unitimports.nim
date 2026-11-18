## The control imports of a form unit. A generated unit imports only the
## modules of the controls its form uses, between marker comments:
##
## ```nim
## {.push warning[UnusedImport]: off.}
## import nimvcl/core/[control, form, application]
## import nimvcl/dsl/formload
## # nimvcl-ide: imports begin
## import nimvcl/controls/button
## import nimvcl/controls/edit
## # nimvcl-ide: imports end
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
## Pure string functions plus the class table; no UI.

import std/[strutils, algorithm, sets, sequtils, os]
import nimvcl/dsl/nfmsyntax
import ./mainfile

const
  UnitImportsBlock* = "imports"

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

proc moduleOf*(className: string): string =
  ## The module that declares a class, "" for the base classes and for classes
  ## the IDE does not know (the user's own).
  for (c, m) in classModules:
    if c == className: return m

proc collectClasses(root: NfmNode, baseDir: string, classes: var HashSet[string],
                    depth = 0) =
  for n in walk(root): classes.incl n.className
  if root.inherited and baseDir.len > 0 and depth < 16:
    # an inherited form also uses the classes of its ancestors
    let apath = if root.ancestor.isAbsolute: root.ancestor else: baseDir / root.ancestor
    try:
      collectClasses(parseNfm(readFile(apath)), apath.parentDir, classes, depth + 1)
    except CatchableError: discard

proc importsFor*(nfmText: string, baseDir = ""): seq[string] =
  ## The module paths (sorted, no duplicates) of the classes a form file uses.
  ## A form file that does not parse needs none. `baseDir` (the folder of the
  ## file) lets an inherited form count the classes of its ancestors' files too.
  var root: NfmNode
  try: root = parseNfm(nfmText)
  except NfmError: return
  var classes = initHashSet[string]()
  collectClasses(root, baseDir, classes)
  var seen = initHashSet[string]()
  for c in classes:
    let m = moduleOf(c)
    if m.len > 0 and m notin seen:
      seen.incl m
      result.add m
  result.sort

func managedPath(line: string): string =
  ## `nimvcl/controls/button` for the line `import nimvcl/controls/button`,
  ## "" for anything else.
  let t = line.strip
  if t.startsWith("import nimvcl/"):
    let p = t["import ".len .. ^1].strip
    if p.len > 0 and not p.anyIt(it in {' ', ',', '[', ']', '#', '{'}): return p

proc syncImports*(src: string, wanted: seq[string]): string =
  ## Makes the managed lines of the `imports` block match `wanted`. A module
  ## the file already imports elsewhere is not added again. Returns `src`
  ## unchanged when the block is missing.
  var lines = src.split('\n')
  let r = findBlock(lines, UnitImportsBlock)
  if r.b < 0: return src
  var present = initHashSet[string]()
  var i = r.e - 1
  while i > r.b:                       # drop the lines that are no longer needed
    let p = managedPath(lines[i])
    if p.len > 0:
      if p in wanted and p notin present: present.incl p
      else: lines.delete i             # stale (or a duplicate)
    dec i
  let r2 = findBlock(lines, UnitImportsBlock)
  var elsewhere = initHashSet[string]()
  for k, l in lines:
    let t = l.strip
    if (k < r2.b or k > r2.e) and t.startsWith("import "):
      elsewhere.incl t["import ".len .. ^1].strip
  let indent = lines.blockIndent r2
  var at = r2.e
  for m in wanted:
    if m notin present and m notin elsewhere:
      lines.insertBefore(at, "import " & m, indent)
      inc at
  lines.join("\n")

proc syncFromNfm*(src, nfmText: string, baseDir = ""): string =
  ## `syncImports` for the classes of a form file.
  syncImports(src, importsFor(nfmText, baseDir))
