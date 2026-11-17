## The marker blocks of the main program file: adding and removing units and
## forms, and leaving everything else (also a damaged file) alone.
import std/[unittest, strutils]
import ide/mainfile

const base = """## demo
import std/os
import nimvcl
# nimvcl-ide: imports begin
{.push warning[UnusedImport]: off.}
import unit1
{.pop.}
# nimvcl-ide: imports end

proc main() =
  Application.init()
  # nimvcl-ide: forms begin
  let mainForm = newForm1()
  # nimvcl-ide: forms end
  Application.run(mainForm)

main()
"""

suite "main file blocks":
  test "a form adds its import and a hidden create line":
    let s = base.addUnit("unit2", "Form2")
    check "\n{.pop.}\n" in s
    let lines = s.splitLines
    let i1 = lines.find("import unit1")
    check lines[i1 + 1] == "import unit2"            # before the {.pop.}
    check lines[i1 + 2] == "{.pop.}"
    check "  let form2 {.used.} = newForm2()" in lines
    check s.count("let mainForm = newForm1()") == 1
    check s.count("newForm2()") == 1
    check s.removeUnit("unit2", "Form2") == base

  test "a plain unit only adds the import":
    let s = base.addUnit("helpers", "")
    check "import helpers" in s
    check "new" notin s.replace("newForm1", "").replace("import nimvcl", "").replace("nimvcl-ide", "")
    check s.removeUnit("helpers", "") == base

  test "adding twice changes nothing more":
    let s = base.addUnit("unit2", "Form2")
    check s.addUnit("unit2", "Form2") == s
    check base.addUnit("unit1", "Form1") == base        # already there

  test "the first form of an empty block becomes the main form":
    let s = base.removeUnit("unit1", "Form1")
    check "newForm1" notin s and "import unit1" notin s
    check s.addUnit("unit1", "Form1") == base

  test "only the blocks are edited":
    var s = base.replace("import std/os", "import std/os  # mine")
    s = s.replace("main()\n", "main()\n# import unit2 stays\nlet x = newForm2()\n")
    let t = s.addUnit("unit2", "Form2")
    check "# import unit2 stays\nlet x = newForm2()\n" in t       # outside the blocks: untouched
    check t.removeUnit("unit2", "Form2") == s                      # outside copy of newForm2 survives
    check "import std/os  # mine" in t

  test "user lines inside a block are kept":
    let s = base.replace("  let mainForm = newForm1()\n",
                         "  let mainForm = newForm1()\n  mainForm.caption = \"hi\"\n")
    let t = s.addUnit("unit2", "Form2")
    check "  mainForm.caption = \"hi\"\n" in t
    check t.removeUnit("unit2", "Form2") == s

  test "a form type is matched as a whole word":
    let s = base.addUnit("unit10", "Form10").addUnit("unit1b", "Form1b")
    check s.removeUnit("unit10", "Form10").count("newForm10") == 0
    check s.removeUnit("unit10", "Form10").contains("newForm1b()")
    check "let mainForm = newForm1()" in base.removeUnit("unitX", "Form")   # not a prefix match

  test "a missing marker leaves the file alone":
    let noImports = base.replace("# nimvcl-ide: imports end\n", "")
    check noImports.addUnit("unit2", "Form2") == noImports.addForm("Form2")   # the forms block still works
    check "import unit2" notin noImports.addUnit("unit2", "Form2")
    let noForms = base.replace("# nimvcl-ide: forms begin\n", "")
    check noForms.addForm("Form2") == noForms
    check noForms.removeUnit("unit1", "Form1").contains("let mainForm")  # create line stays
    check not hasBlock(noForms, FormsBlock) and hasBlock(noForms, ImportsBlock)
    check "plain text".addUnit("a", "B") == "plain text"
    check "".addUnit("a", "B") == ""

  test "an end marker before its begin does not count":
    let s = "# nimvcl-ide: forms end\n# nimvcl-ide: forms begin\n"
    check s.addForm("Form2") == s

  test "an existing import elsewhere is not repeated":
    let s = base.replace("import nimvcl\n", "import nimvcl, unit2\nimport unit2\n")
    check s.addImport("unit2") == s

  test "CRLF files keep their line ending":
    let crlf = base.replace("\n", "\r\n")
    let s = crlf.addUnit("unit2", "Form2")
    check s.count("\r\n") == crlf.count("\r\n") + 2
    check s.count("\n") == s.count("\r\n")                          # no bare \n
    check s.removeUnit("unit2", "Form2") == crlf

  test "indent of the forms block, and tabs":
    let s = base.replace("  # nimvcl-ide: forms begin", "\t# nimvcl-ide: forms begin")
    check "\n\tlet form2 {.used.} = newForm2()\n" in s.addForm("Form2")

  test "the main form is the one on the mainForm line":
    check base.isMainForm("Form1")
    let s = base.addUnit("unit2", "Form2")
    check not s.isMainForm("Form2")
    check s.isMainForm("Form1")
    check not base.isMainForm("Form")

  test "a form named like the main form variable does not clash":
    check formVar("MainForm") == "mainFormCreated"
    check formVar("Form2") == "form2"
    let s = base.addUnit("mainform2", "MainForm")
    check "let mainFormCreated {.used.} = newMainForm()" in s
