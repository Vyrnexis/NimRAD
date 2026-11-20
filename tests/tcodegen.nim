import std/[unittest, strutils, sets]
import nimvcl/dsl/[props, props_std]
import ide/codegen

const unit = """import nimvcl, nimvcl/dsl/nfm

loadForm Form1, "unit1.nfm"

proc okButtonClick(self: Form1, sender: Control) =
  self.label1.caption = "self.label1 # not a comment"

proc helper(x: int): int = x + 1

proc cancelClick(f: Form1, sender: Control) =
  # f.label1 in a comment
  f.label1.caption = "x"
  discard helper(1)
"""

suite "ensureHandler":
  test "inserts a stub after the last handler":
    let r = ensureHandler(unit, "Form1", "exitClick", "sender: Control")
    check r.inserted
    let lines = r.text.splitLines
    check lines[r.line - 1] == "proc exitClick(self: Form1, sender: Control) ="
    check lines[r.line] == "  discard"
    check r.col == 2
    # after cancelClick, which is the last handler (helper is not one)
    check r.text.find("proc cancelClick") < r.text.find("proc exitClick")
    check r.text.endsWith("  discard\n")

  test "idempotent":
    let a = ensureHandler(unit, "Form1", "exitClick", "sender: Control")
    let b = ensureHandler(a.text, "Form1", "exitClick", "sender: Control")
    check not b.inserted
    check b.text == a.text
    check b.line == a.line

  test "existing proc: caret on its body":
    let r = ensureHandler(unit, "Form1", "okButtonClick", "sender: Control")
    check not r.inserted
    check r.text == unit
    check unit.splitLines[r.line].startsWith("  self.label1")

  test "after loadForm when there is no handler":
    let src = "import nimvcl\n\nloadForm Form1, \"unit1.nfm\"\n\nproc helper() = discard\n"
    let r = ensureHandler(src, "Form1", "aClick", "sender: Control")
    let lines = r.text.splitLines
    check lines[2].startsWith("loadForm")
    check lines[4] == "proc aClick(self: Form1, sender: Control) ="
    check r.line == 5
    check lines[6] == ""            # separated from helper
    check lines[7].startsWith("proc helper")

  test "empty file and missing trailing newline":
    let r = ensureHandler("", "Form1", "aClick", "sender: Control")
    check r.text == "proc aClick(self: Form1, sender: Control) =\n  discard\n"
    check r.line == 1
    let r2 = ensureHandler("import nimvcl", "Form1", "aClick", "sender: Control")
    check r2.text.endsWith("  discard\n")
    check r2.text.splitLines[r2.line] == "  discard"

  test "CRLF files keep their line endings":
    let src = unit.replace("\n", "\r\n")
    let r = ensureHandler(src, "Form1", "exitClick", "sender: Control")
    check r.text.count("\r\n") == r.text.count("\n")
    check r.text.startsWith(src[0 ..< src.len - 1])

  test "event parameters from the registry":
    check handlerParams("Button", "onClick") == "sender: Control"
    check handlerParams("MenuItem", "onClick") == "sender: MenuItem"
    check handlerParams("Form", "onClose") == "sender: Form, action: var CloseAction"
    check handlerParams("Edit", "onKeyDown") == "sender: Control, key: var Key, shift: ShiftState"
    let r = ensureHandlerFor(unit, "Form1", "Form", "onClose", "formClose")
    check "proc formClose(self: Form1, sender: Form, action: var CloseAction) =" in r.text

  test "every event of the registry has parameters":
    var missing: seq[string]
    for ci in allClasses():
      for p in ci.propsOf:
        if p.kind == pkEvent and p.params.len == 0: missing.add ci.name & "." & p.name
    check missing.len == 0
    if missing.len > 0: echo "missing: ", missing

  test "no loadForm line: the stub goes after the push/pop region of the imports":
    let src = "{.push warning[UnusedImport]: off.}\nimport nimvcl/core/[control, form]\n" &
              "# nimrad: imports begin\nimport nimvcl/controls/button\n" &
              "# nimrad: imports end\n{.pop.}\n"
    let r = ensureHandler(src, "Form1", "aClick", "sender: Control")
    let lines = r.text.splitLines
    check lines[5] == "{.pop.}"
    check lines[7] == "proc aClick(self: Form1, sender: Control) ="
    check r.text.find("imports end") < r.text.find("{.pop.}")
    check r.text.find("{.pop.}") < r.text.find("proc aClick")

suite "handlers":
  test "handlerNames":
    check handlerNames(unit, "Form1") == @["okButtonClick", "cancelClick"]
    check handlerNames(unit, "Form2").len == 0

  test "renameHandler renames the proc and its references":
    let src = unit & "\nproc other(self: Form1) =\n  okButtonClick(self, nil)\n  self.okButtonClick = 1\n"
    let r = renameHandler(src, "okButtonClick", "saveClick")
    check "proc saveClick(self: Form1" in r
    check "  saveClick(self, nil)" in r
    check "self.okButtonClick = 1" in r          # member access untouched
    check "okButtonClick" notin r.replace("self.okButtonClick", "")

  test "empty handlers":
    let src = ensureHandler(unit, "Form1", "exitClick", "sender: Control").text
    check emptyHandlers(src, "Form1") == @["exitClick"]
    let r = removeEmptyHandler(src, "exitClick")
    check r == unit
    check removeEmptyHandler(src, "okButtonClick") == src     # not empty
    check removeEmptyHandler(src, "nope") == src

suite "renameComponentRefs":
  test "skips strings, comments and longer identifiers":
    let src = "proc a(self: Form1, sender: Control) =\n" &
              "  self.label1.caption = \"self.label1\"\n" &
              "  # self.label1 here\n" &
              "  f.label1.left = 3\n" &
              "  self.label10.left = 1\n" &
              "  self.mylabel1.left = 1\n" &
              "  other.label1.left = 2\n" &
              "  let s = \"\"\"\nself.label1\n\"\"\"\n" &
              "  self.label1.top = 0 # self.label1\n"
    let r = renameComponentRefs(src, "label1", "title")
    check "  self.title.caption = \"self.label1\"" in r
    check "  # self.label1 here" in r
    check "  f.title.left = 3" in r
    check "self.label10.left" in r
    check "self.mylabel1.left" in r
    check "  other.title.left = 2" in r          # no form type given: any receiver
    check "\nself.label1\n\"\"\"" in r
    check "  self.title.top = 0 # self.label1" in r

  test "with a form type only the form's receivers":
    let src = "proc a(f: Form1, sender: Control) =\n  f.label1.left = 3\n  self.label1.top = 1\n  other.label1.left = 2\n"
    let r = renameComponentRefs(src, "label1", "title", "Form1")
    check "  f.title.left = 3" in r
    check "  self.title.top = 1" in r
    check "  other.label1.left = 2" in r

suite "imports":
  test "renameImport":
    check renameImport("import unit1\n", "unit1", "main_form") == "import main_form\n"
    check renameImport("import std/os, unit1, nimvcl\n", "unit1", "u") == "import std/os, u, nimvcl\n"
    check renameImport("import ./unit1\n", "unit1", "u") == "import ./u\n"
    check renameImport("import foo/[unit1, bar]\n", "unit1", "u") == "import foo/[u, bar]\n"
    check renameImport("import std/os,\n  unit1,\n  nimvcl\n", "unit1", "u") == "import std/os,\n  u,\n  nimvcl\n"
    check renameImport("from unit1 import newForm1\n", "unit1", "u") == "from u import newForm1\n"
    check renameImport("import unit1 as uu\n", "unit1", "u") == "import u as uu\n"

  test "renameImport leaves other things alone":
    let src = "import unit10, unit1/sub, other/unit1\nlet unit1 = 3\necho \"import unit1\"\n# import unit1\n"
    check renameImport(src, "unit1", "u") == src

  test "renameLoadFormPath":
    check renameLoadFormPath("loadForm Form1, \"unit1.nfm\"\n", "unit1.nfm", "main.nfm") ==
      "loadForm Form1, \"main.nfm\"\n"

suite "procs the way the lexer sees them":
  const tricky = "loadForm Form1, \"unit1.nfm\"\n\n" &
    "proc emptyOne(self: Form1, sender: Control) =\n" &
    "  discard\n" &
    "# a comment at column 0 inside the body\n" &
    "  discard\n\n" &
    "proc withText(self: Form1, sender: Control) =\n" &
    "  let s = \"\"\"\n" &
    "proc fake(self: Form1) =\n" &
    "not code either\n" &
    "\"\"\"\n" &
    "  echo s\n\n" &
    "proc last(self: Form1, sender: Control) =\n" &
    "  discard\n"

  test "a comment at column 0 does not cut a body, and a string line is no proc":
    check handlerNames(tricky, "Form1") == @["emptyOne", "withText", "last"]
    check not hasProc(tricky, "fake")
    check hasProc(tricky, "withText")

  test "a column-0 comment in a body is part of it: the proc is not empty and stays":
    check emptyHandlers(tricky, "Form1") == @["last"]
    check removeEmptyHandler(tricky, "emptyOne") == tricky     # the comment is the user's
    check removeEmptyHandler(tricky, "withText") == tricky

  test "an empty proc after the multi-line string goes, the rest stays whole":
    let r = removeEmptyHandler(tricky, "last")
    check "proc last" notin r
    check "proc withText" in r and "echo s" in r and "not code either" in r
    check r.count("discard") == 2                              # emptyOne's two

  test "a stub goes after the last proc even when a string has column-0 text":
    let r = ensureHandler(tricky, "Form1", "newOne", "sender: Control")
    check r.text.find("proc last") < r.text.find("proc newOne")
    check r.text.find("echo s") < r.text.find("proc newOne")

suite "from imports":
  test "names after `from x import` are not modules":
    check renameImport("from strutils import unit1\nimport unit1\n", "unit1", "base") ==
          "from strutils import unit1\nimport base\n"
    check renameImport("from unit1 import x\n", "unit1", "base") == "from base import x\n"
    check renameImport("from a/unit1 import x, unit1\n", "unit1", "base", "a") ==
          "from a/base import x, unit1\n"

suite "proc header parse":
  test "a colon outside the parameter list is not a first parameter":
    let src = "proc makeForm(): Form1 =\n  discard\n\nproc f(a = 1): Form1 =\n  discard\n\n" &
              "proc g(a: seq[int], b: Form1) =\n  discard\n\nproc h(self: Form1) =\n  discard\n"
    check handlerNames(src, "Form1") == @["h"]

suite "style-insensitive names":
  const src = "proc button1click(self: Form_1, sender: Control) =\n  self.label_1.caption = \"x\"\n"
  test "an existing proc is found under another style":
    check hasProc(src, "button1Click")
    check not ensureHandler(src, "Form1", "button1Click", "sender: Control").inserted
    check not hasProc(src, "Button1click")          # the first letter counts
  test "handlers of a form type spelled in another style":
    check handlerNames(src, "Form1") == @["button1click"]
  test "component references match by style":
    check renameComponentRefs(src, "label1", "caption1", "Form1").contains("self.caption1.caption")

suite "stub placement and line endings":
  test "the caret of a stub with a hint is on its discard":
    let r = ensureHandlerFor(unit, "Form1", "Button", "onClick", "exitClick", "Base")
    check r.text.splitLines[r.line] == "  discard"
  test "the import fallback goes after a multi-line import":
    let src = "import a,\n  b\n\nvar x = 1\n"
    let r = ensureHandler(src, "Form1", "f", "")
    check r.text.startsWith("import a,\n  b\n\nproc f(")
    let r2 = ensureHandler("import std/[os,\n  strutils]\nvar x = 1\n", "Form1", "f", "")
    check r2.text.startsWith("import std/[os,\n  strutils]\n\nproc f(")
  test "mixed line endings stay as they are; all-CRLF stays CRLF":
    let mixed = "import a\r\nvar x = 1\nvar y = 2\r\n"
    let r = ensureHandler(mixed, "Form1", "f", "")
    check r.text.count("\r\n") == 2
    let crlf = unit.replace("\n", "\r\n")
    let c = ensureHandler(crlf, "Form1", "f", "").text
    check c.count("\n") == c.count("\r\n")
