## Atomic writes: content, permissions, symbolic links, no temporary file left.
import std/[unittest, os, strutils, tempfiles]
import ide/fileio

suite "writeFileAtomic":
  let dir = createTempDir("nimrad-fileio", "")
  defer: removeDir dir

  test "writes and replaces the content, leaving no temporary file":
    let f = dir / "a.txt"
    writeFileAtomic(f, "one")
    writeFileAtomic(f, "two")
    check readFile(f) == "two"
    for k, p in walkDir(dir):
      check not p.endsWith(".tmp")

  when defined(posix):
    test "the permissions of the existing file are kept":
      let f = dir / "script.sh"
      writeFile(f, "old")
      setFilePermissions(f, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead})
      writeFileAtomic(f, "new")
      check readFile(f) == "new"
      check getFilePermissions(f) == {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead}

    test "a symbolic link is written through and stays a link":
      let real = dir / "real.txt"
      let link = dir / "link.txt"
      writeFile(real, "old")
      createSymlink("real.txt", link)
      writeFileAtomic(link, "new")
      check symlinkExists(link)
      check readFile(real) == "new"
      check readFile(link) == "new"

    test "a dangling link is replaced by a file":
      let link = dir / "dangling.txt"
      createSymlink("nowhere.txt", link)
      writeFileAtomic(link, "x")
      check readFile(link) == "x"

  test "relPosix uses slashes":
    check relPosix(dir / "sub" / "x.nim", dir) == "sub/x.nim"
