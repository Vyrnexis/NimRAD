# Development convenience: a nimvcl checkout next to this one wins over the
# nimble package. Without it, the package installed by nimble is used.
import std/os

switch("path", "src")
let sibling = thisDir() / ".." / "nimvcl" / "src"
if fileExists(sibling / "nimvcl.nim"):
  switch("path", sibling)
