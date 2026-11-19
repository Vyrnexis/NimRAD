import std/[unittest, os]
import ide/nimvclpath

let root = getTempDir() / ("nimrad-path-" & $getCurrentProcessId())
removeDir root

proc mk(name: string): string =
  result = root / name / "src"
  createDir result
  writeFile(result / "nimvcl.nim", "")

let a = mk("a")
let b = mk("b")
let c = mk("c")
let empty = root / "empty"
createDir empty

suite "nimvcl source resolution":
  test "env wins over the baked path and nimble":
    check resolveNimvclSrc(a, b, proc(): string = c.parentDir) == a
  test "baked path is next":
    check resolveNimvclSrc("", b, proc(): string = c.parentDir) == b
    check resolveNimvclSrc(empty, b, nil) == b
  test "nimble path: package folder or src folder":
    check resolveNimvclSrc("", empty, proc(): string = c.parentDir) == c
    check resolveNimvclSrc("", "", proc(): string = c) == c
  test "nothing found":
    check resolveNimvclSrc("", "", nil) == ""
    check resolveNimvclSrc("", empty, proc(): string = empty) == ""
  test "this build knows where nimvcl was":
    check isNimvclSrc(compiledAgainst)
    check detectNimvclSrc().len > 0

removeDir root
