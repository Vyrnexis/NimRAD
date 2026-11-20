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

  test "Nim style matching: first letter exact, the rest free":
    check "fooBar".startsWithStyle("foo_b")
    check "fooBar".startsWithStyle("FOOB") == false
    check "Foo".startsWithStyle("fo") == false

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
    check c.allIt(it.text.startsWith("do"))
    check c.mapIt(ord(it.kind)).isSorted(system.cmp[int])
    let k = candidatesFor("", wordBefore("whi", 3), comps)
    check "while" in k.texts and k[0].kind in {ckSymbol, ckKeyword}
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
