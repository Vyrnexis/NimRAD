## The symbol index (`src/ide/symbolindex.nim`, generated from the nimvcl
## sources by `scripts/gen_symbolindex.nim`): it must match a fresh scan of the
## nimvcl the IDE is built against (a stale index fails here, run
## `nimble genindex`), it must know the well-known symbols, and it must cover
## every control class of the unit imports table.

import std/[unittest, os, strutils, sets]
import ide/[symbolscan, symbols, symbolindex, unitimports, nimvclpath]

let srcDir = absolutePath(detectNimvclSrc())
let committed = currentSourcePath().parentDir.parentDir / "src" / "ide" / "symbolindex.nim"

suite "scanner":
  test "declarations of the usual kinds":
    let names = scanSource("""
## doc comment with proc fake*() in it
import std/os

type
  Shape* = object
    width*: int
  Mode* = enum
    mdOne, mdTwo = 2,
    mdThree   # comment
  Hidden = enum hA, hB
  Style* {.pure.} = enum plain, fancy
  Handler* = proc(x: int)

const
  Limit* = 3
  secret = 4
var gCount*: int
let gName* = "x"

proc visible*(a: int): int = a
proc hidden(a: int): int = a
func pure2*[T](a: T): T = a
template tmpl*(x: untyped) = discard
iterator items2*(s: Shape): int = discard
proc `+++`*(a, b: int): int = a + b
when defined(foo):
  proc inWhen*() = discard
let text = @@@
proc inString*() = discard
@@@
""".replace("@@@", "\"\"\""))
    for n in ["Shape", "Mode", "mdOne", "mdTwo", "mdThree", "Style", "Handler", "Limit",
              "gCount", "gName", "visible", "pure2", "tmpl", "items2"]:
      check n in names
    for n in ["fake", "Hidden", "hA", "plain", "fancy", "secret", "hidden", "inWhen",
              "inString", "width", "+++"]:
      check n notin names

suite "index":
  test "the committed index is not stale":
    check srcDir.len > 0
    let fresh = renderIndex(srcDir)
    check fileExists(committed)
    if readFile(committed) != fresh:
      checkpoint "symbolindex.nim is out of date: run `nimble genindex`"
      fail()

  test "well-known symbols and their modules":
    check modulesFor("newButton") == @["nimvcl/controls/button"]
    check modulesFor("Button") == @["nimvcl/controls/button"]
    check "nimvcl/controls/dialogs" in modulesFor("showMessage")
    check "nimvcl/controls/dialogs" in modulesFor("mtInformation")     # enum value
    check modulesFor("newProgressBar") == @["nimvcl/controls/progressbar"]
    check modulesFor("newListView") == @["nimvcl/controls/listview"]
    check modulesFor("rgb") == @["nimvcl/graphics/color"]
    check modulesFor("loadForm") == @["nimvcl/dsl/formload"]
    check modulesFor("noSuchSymbolAnywhere").len == 0
    check symbolCount() > 1000

  test "every control class resolves to the module of the unit imports table":
    var modulesWithEntry = initHashSet[string]()
    for (m, _) in symbolIndexData: modulesWithEntry.incl m
    for (cls, module) in classModules:
      check module in modulesWithEntry
      # the registry's `Image` is `ImageControl` in the code
      if cls != "Image": check module in modulesFor(cls)

  test "modules for apps first; the designer and registry modules only add what is missing":
    # props / inspector symbols that other modules declare are not listed there
    var seen = initHashSet[string]()
    for (m, names) in symbolIndexData:
      if m in SecondaryModules: continue
      for n in names.split(' '): seen.incl n
    for (m, names) in symbolIndexData:
      if m notin SecondaryModules: continue
      for n in names.split(' '): check n notin seen
    for (m, _) in symbolIndexData:
      check fileExists(srcDir / m & ".nim")
      check m notin SkippedModules
