import std/unittest
import ide/cmdargs

suite "splitArgs":
  test "words, quotes in the middle of a word, empty words":
    check splitArgs("") == newSeq[string]()
    check splitArgs("  a   b\tc ") == @["a", "b", "c"]
    check splitArgs("--fast \"a b\" plain") == @["--fast", "a b", "plain"]
    check splitArgs("--passL:\"-L/my path\" -d:x") == @["--passL:-L/my path", "-d:x"]
    check splitArgs("'a b' \"\" x") == @["a b", "", "x"]
    check splitArgs("a\"b c\"d") == @["ab cd"]
    check splitArgs("--name='it''s'") == @["--name=its"]

  test "backslashes are only special before a quote or a backslash inside double quotes":
    check splitArgs("C:\\dir\\x") == @["C:\\dir\\x"]
    check splitArgs("\"C:\\my path\\x\"") == @["C:\\my path\\x"]
    check splitArgs("\"say \\\"hi\\\"\"") == @["say \"hi\""]
    check splitArgs("\"a\\\\\"") == @["a\\"]
    check splitArgs("'a\\b'") == @["a\\b"]

  test "an open quote runs to the end":
    check splitArgs("a \"b c") == @["a", "b c"]

suite "quoteArg":
  test "plain words stay, others are quoted":
    check quoteArg("--hints:off") == "--hints:off"
    check quoteArg("a b") == "\"a b\""
    check quoteArg("") == "\"\""
    check quoteArg("it's") == "\"it's\""

  test "splitArgs undoes quoteArg":
    for a in ["", "x", "a b", "a\"b", "a\\", "a\\\\", "a\\\"b", "C:\\my dir\\", "tab\there",
              "'single'", "\\", "\"", "--passL:-L/my path", "é ü"]:
      check splitArgs(quoteArg(a)) == @[a]
    check splitArgs(quoteArg("a b") & " " & quoteArg("c")) == @["a b", "c"]
