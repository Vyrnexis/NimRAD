import std/[unittest, strutils, sequtils, algorithm]
import ide/codeinsight

proc texts(c: seq[Candidate]): seq[string] = c.mapIt(it.text)

let comps = @[
  ComponentInfo(name: "Form1", isForm: true, members: @[("caption", "string"), ("onShow", "NotifyEvent")]),
  ComponentInfo(name: "Button1", members: @[("caption", "string"), ("onClick", "NotifyEvent"), ("width", "float32")]),
  ComponentInfo(name: "Label1", members: @[("caption", "string")])]

suite "words":
  test "prefix, dot and qualifier":
    let w = wordBefore("  self.cap", 10)
    check (w.start, w.prefix, w.dotted, w.qualifier) == (7, "cap", true, "self")
    let e = wordBefore("x = Button1.", 12)
    check (e.prefix, e.dotted, e.qualifier) == ("", true, "Button1")
    let p = wordBefore("foo(ab", 6)
    check (p.start, p.prefix, p.dotted) == (4, "ab", false)
    check wordBefore("", 0).prefix == ""
    check wordBefore("abc", 99).prefix == "abc"

  test "matching ignores case and underscores":
    check "fooBar".startsWithStyle("foo_b")
    check "fooBar".startsWithStyle("FOOB")
    check "Foo".startsWithStyle("fo")
    check "Foo".startsWithStyle("fx") == false

suite "candidates":
  test "members of self and of a component":
    let s = candidatesFor("", wordBefore("self.", 5), comps)
    check "Button1" in s.texts and "Label1" in s.texts and "caption" in s.texts
    check "Form1" notin s.texts
    let b = candidatesFor("", wordBefore("Button1.on", 10), comps)
    check b.texts == @["onClick"]
    check b[0].detail == "NotifyEvent"
    check candidatesFor("", wordBefore("Button_1.cap", 12), comps).texts == @["caption"]

  test "plain word: unit identifiers, components, symbols, keywords; best kind first":
    let src = "proc doWork() =\n  discard\n# dowork in a comment\nlet doneFlag = \"dosomething\"\n"
    let c = candidatesFor(src, wordBefore("do", 2), comps)
    check c.texts[0 .. 1] == @["doWork", "doneFlag"] or c.texts[0 .. 1] == @["doneFlag", "doWork"]
    check "dosomething" notin c.texts
    check "do" notin c.texts                # the prefix itself
    check c.allIt(it.text.toLowerAscii.startsWith("do"))
    check c.mapIt(ord(it.kind)).isSorted(system.cmp[int])
    let k = candidatesFor("", wordBefore("whi", 3), comps)
    check "while" in k.texts and k[0].kind in {ckSymbol, ckKeyword}

  test "a lower-case prefix finds a capitalised name, the same case first":
    let c = candidatesFor("let button = 1\n", wordBefore("butt", 4), comps)
    check "Button1" in c.texts
    let l = candidatesFor("", wordBefore("Lab", 3), comps)
    check l[0].text == "Label1" and l[0].kind == ckComponent
    check "Label" in l.texts                # nimvcl symbol, behind the component

  test "an identifier is offered once, the shorter first":
    let src = "let foo_bar = 1\nlet fooBar = 2\nlet foobarbaz = 3\n"
    check candidatesFor(src, wordBefore("foo", 3), @[]).texts[0 .. 1] == @["foo_bar", "foobarbaz"]

  test "nothing matches":
    check candidatesFor("let a = 1", wordBefore("zzqx", 4), comps).len == 0

  test "unit identifiers skip comments, strings and keywords":
    check unitIdents("let a = \"b\" # c\nproc d() = discard\n") == @["a", "d"]

suite "templates":
  let all = mergeTemplates(@[])

  test "built-ins are found by name and prefix":
    check all.exact("tryf") >= 0 and all.exact("nosuch") == -1 and all.exact("") == -1
    check all.matching("tr").mapIt(it.name) == @["try", "tryf"]
    check all.matching("fo").mapIt(it.name) == @["for", "fori"]

  test "user templates add and replace":
    let m = mergeTemplates(@[CodeTemplate(name: "proc", description: "mine", code: "proc x|"),
                             CodeTemplate(name: "log", description: "", code: "echo \"|\"")])
    check m[m.exact("proc")].description == "mine"
    check m.exact("log") >= 0
    check m.len == all.len + 1

  test "expansion: caret, indent of the line, indent unit":
    let t = all[all.exact("ife")]
    let e = t.expand("    ", "  ")
    check e.text == "if :\n      discard\n    else:\n      discard"
    check (e.caretLine, e.caretCol) == (0, 3)
    let tab = all[all.exact("try")].expand("\t", "\t")
    check tab.text == "try:\n\t\t\n\texcept CatchableError:\n\t\tdiscard"
    check (tab.caretLine, tab.caretCol) == (1, 2)
    let four = all[all.exact("proc")].expand("", "    ")
    check four.text == "proc () =\n    discard"
    check (four.caretLine, four.caretCol) == (0, 5)

  test "no marker: the caret goes to the end":
    let e = CodeTemplate(name: "x", code: "a\nb").expand("  ", "  ")
    check e.text == "a\n  b" and (e.caretLine, e.caretCol) == (1, 3)

  test "every built-in expands with exactly one caret mark":
    for t in all:
      check t.code.count(CaretMark) == 1
      check CaretMark notin t.expand("", "  ").text

suite "parameter hints":
  test "the call at the caret":
    check callAt("foo(a, b", 8) == ("foo", 1)
    check callAt("foo(", 4) == ("foo", 0)
    check callAt("x.foo(bar(1, 2), ", 17) == ("foo", 1)
    check callAt("foo(bar(1, ", 11) == ("bar", 1)
    check callAt("foo(a) + 1", 10).name == ""
    check callAt("echo \"foo(a", 11).name == ""
    check callAt("if (a", 5).name == ""        # a keyword is not a call
    check callAt("a[1, 2", 6).name == ""

  test "signatures of the unit":
    let src = "proc add*(a, b: int): int =\n  a + b\nproc add(s: string; t: string) =\n  discard\n" &
              "proc long(\n    x: int,\n    y: seq[int]\n): bool =\n  true\n# proc add(z: int)\n"
    let a = signaturesOf(src, "add")
    check a.mapIt(it.text) == @["proc add(a, b: int): int", "proc add(s: string; t: string)"]
    check a[0].params == @["a", "b: int"]
    check signaturesOf(src, "long")[0].text == "proc long(x: int, y: seq[int]): bool"
    check signaturesOf(src, "nosuch").len == 0
    check signaturesOf("proc foo[T](x: T): T =\n  x\n", "foo")[0].text == "proc foo(x: T): T"
