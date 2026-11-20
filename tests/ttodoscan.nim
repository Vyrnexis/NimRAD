import std/unittest
import ide/todoscan

suite "todo comments":
  test "markers, priority, text":
    let r = scanTodos("let a = 1  # TODO: write tests\n# FIXME 2: crash\n#NOTE plain\nx # TODO\n")
    check r.len == 4
    check r[0].marker == "TODO" and r[0].text == "write tests" and r[0].line == 1 and r[0].priority == 0
    check r[1].marker == "FIXME" and r[1].priority == 2 and r[1].text == "crash" and r[1].line == 2
    check r[2].marker == "NOTE" and r[2].text == "plain"
    check r[3].text == "" and r[3].line == 4
  test "owner and Delphi syntax":
    let r = scanTodos("# TODO(me): a\n#[ TODO -oBob -cUI : b ]#\n## HACK - c\n")
    check r[0].owner == "me" and r[0].text == "a"
    check r[1].owner == "Bob" and r[1].category == "UI" and r[1].text == "b"
    check r[2].marker == "HACK" and r[2].text == "c"
  test "strings, other words and lower case are no markers":
    check scanTodos("let s = \"# TODO: no\"\n# TODOS later\n# NOTEBOOK\n# todo: lower\n# see TODO\n").len == 0
    check scanTodos("let s = \"\"\"\n# TODO: inside\n\"\"\"\n").len == 0
  test "multi-line block comments":
    let r = scanTodos("#[\nTODO: one\nplain\n]#\nproc f() = discard\n")
    check r.len == 1 and r[0].line == 2 and r[0].text == "one"
