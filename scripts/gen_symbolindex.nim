## Writes `src/ide/symbolindex.nim` from the nimvcl sources.
## Usage: nim r scripts/gen_symbolindex.nim [<nimvcl src folder>] > src/ide/symbolindex.nim
## (without an argument the folder the IDE is built against is used)
import std/os
import ../src/ide/[symbolscan, nimvclpath]

let src = if paramCount() >= 1: paramStr(1) else: detectNimvclSrc()
if src.len == 0 or not dirExists(src / "nimvcl"):
  quit "nimvcl sources not found; pass the src folder", 1
stdout.write renderIndex(absolutePath(src))
