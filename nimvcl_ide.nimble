# Package

version       = "0.0.1"
author        = "Vyrnexis"
description   = "A Delphi 7-style IDE for building nimvcl applications"
license       = "MIT"
srcDir        = "src"
bin           = @["nimvcl_ide"]

# Dependencies

requires "nim >= 2.2.0"
# nimvcl is used from ../nimvcl/src during development (see nim.cfg).
