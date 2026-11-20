# Package

version       = "0.3.0"
author        = "Vyrnexis"
description   = "A Delphi 7-style IDE for building nimvcl applications"
license       = "MIT"
srcDir        = "src"
bin           = @["nimrad"]

# Dependencies

requires "nim >= 2.2.0"
# nimvcl brings in the SDL3 binding itself. Pinned to a release tag (bump it
# when nimvcl is released). During development a sibling
# checkout (../nimvcl) is preferred, see config.nims.
requires "https://github.com/Vyrnexis/nimvcl#v0.4.0"

task test, "Run the test suite headless":
  exec "bash scripts/test.sh"

task genindex, "Regenerate src/ide/symbolindex.nim from the nimvcl sources":
  exec "nim r --hints:off scripts/gen_symbolindex.nim > src/ide/symbolindex.nim.tmp"
  exec "mv src/ide/symbolindex.nim.tmp src/ide/symbolindex.nim"
