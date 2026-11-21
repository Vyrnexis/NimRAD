# Package

version       = "0.3.1"
author        = "Vyrnexis"
description   = "A Delphi 7-style IDE for building nimvcl applications"
license       = "MIT"
srcDir        = "src"
bin           = @["nimrad"]

# Dependencies

requires "nim >= 2.2.0"
# nimvcl brings in the SDL3 binding itself. A version range, not a #tag:
# nimble 0.22 leaves a #tag dependency off the compiler path when it is already installed. During development a sibling
# checkout (../nimvcl) is preferred, see config.nims.
requires "https://github.com/Vyrnexis/nimvcl >= 0.4.1"

task test, "Run the test suite headless":
  exec "bash scripts/test.sh"

task genindex, "Regenerate src/ide/symbolindex.nim from the nimvcl sources":
  exec "nim r --hints:off scripts/gen_symbolindex.nim > src/ide/symbolindex.nim.tmp"
  exec "mv src/ide/symbolindex.nim.tmp src/ide/symbolindex.nim"
