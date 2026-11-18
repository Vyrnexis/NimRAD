# Package

version       = "0.1.1"
author        = "Vyrnexis"
description   = "A Delphi 7-style IDE for building nimvcl applications"
license       = "MIT"
srcDir        = "src"
bin           = @["nimvcl_ide"]

# Dependencies

requires "nim >= 2.2.0"
# nimvcl brings in the SDL3 binding itself. Pinned to a release tag (bump it
# when nimvcl is released). During development a sibling
# checkout (../nimvcl) is preferred, see config.nims.
requires "https://github.com/Vyrnexis/nimvcl#v0.1.2"

task test, "Run the test suite headless":
  exec "bash scripts/test.sh"
