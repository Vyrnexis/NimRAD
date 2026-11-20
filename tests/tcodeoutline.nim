import std/unittest
import ide/codeoutline

proc names(r: seq[OutlineItem], k: OutlineKind): seq[string] =
  for x in r:
    if x.kind == k: result.add x.name

suite "outline":
  test "procs of every kind, exported, operators":
    let r = outlineOf("proc a*() = discard\nfunc b(x: int): int = x\nmethod c(s: Foo) = discard\n" &
                      "iterator d(): int =\n  yield 1\ntemplate e() = discard\nmacro f() = discard\n" &
                      "proc `+`*(a, b: V): V = a\n  # proc inner\n")
    check r.names(okProc) == @["a", "b", "c", "d", "e", "f", "+"]
    check r[0].exported and not r[1].exported and r[1].detail == "func" and r[6].exported
    check r[3].line == 4
  test "type sections and one-line types":
    let r = outlineOf("type\n  Foo* = ref object of Panel\n    x: int\n  Bar = enum\n    a, b\n\ntype Baz = int\n")
    check r.names(okType) == @["Foo", "Bar", "Baz"]
    check r[0].detail == "ref object of Panel" and r[0].exported and r[0].line == 2
    check r[1].detail == "enum" and r[2].detail == "int" and r[2].line == 7
  test "const, var and let: sections, lines, several names":
    let r = outlineOf("const\n  A* = 1\n  B = \"x\"\nlet c, d = 2\nvar\n  e: int\n    # f: int\nvar g* = 3\n")
    check r.names(okConst) == @["A", "B"]
    check r.names(okVar) == @["c", "d", "e", "g"]
    check r[2].detail == "let" and r[4].detail == "var"
  test "imports":
    let r = outlineOf("import std/[os, strutils], nimvcl\nfrom std/tables import Table\nimport a,\n  b\n")
    check r.names(okImport) == @["std/os", "std/strutils", "nimvcl", "std/tables", "a", "b"]
  test "comments, strings and indented code do not declare":
    let r = outlineOf("# proc no()\nlet s = \"\"\"\nproc no2() = discard\n\"\"\"\nwhen true:\n  proc inner() = discard\nproc yes() =\n  let x = 1\n")
    check r.names(okProc) == @["yes"]
    check r.names(okVar) == @["s"]
  test "crlf and empty text":
    check outlineOf("").len == 0
    check outlineOf("proc a() = discard\r\nproc b() = discard\r\n").names(okProc) == @["a", "b"]
