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
  test "an empty nimble answer is not `src`, a relative env path becomes absolute":
    let old = getCurrentDir()
    setCurrentDir root / "a"                 # has src/nimvcl.nim
    defer: setCurrentDir old
    check resolveNimvclSrc("", "", proc(): string = "") == ""
    # the current folder comes back resolved (macOS: /var is /private/var)
    check resolveNimvclSrc("src", "", nil).expandFilename == a.expandFilename
  test "this build knows where nimvcl was":
    check isNimvclSrc(compiledAgainst)
    check detectNimvclSrc().len > 0

suite "detectNimvclSrc is remembered":
  test "an environment change or a vanished folder is noticed":
    let keep = getEnv("NIMVCL_SRC")
    defer:
      if keep.len > 0: putEnv("NIMVCL_SRC", keep) else: delEnv("NIMVCL_SRC")
      forgetNimvclSrc()
    putEnv("NIMVCL_SRC", a)
    forgetNimvclSrc()
    check detectNimvclSrc() == a
    putEnv("NIMVCL_SRC", b)                    # another setting: not the cached answer
    check detectNimvclSrc() == b
    check detectNimvclSrc() == b
    removeFile b / "nimvcl.nim"                # the folder is not nimvcl any more
    check detectNimvclSrc() != b               # looked up again
    writeFile(b / "nimvcl.nim", "")

removeDir root
