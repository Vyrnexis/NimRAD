## How programs are linked against SDL on macOS. The SDL binding dlopens
## "libSDL3.dylib" (and the TTF/image libraries) by bare name, which dyld does
## not find in Homebrew's prefix, so SDL is linked at build time instead.
## Shared by config.nims (building the IDE) and builder.nim (building the
## user's projects), so the three flag sets cannot drift apart.

const
  SdlLibs* = ["SDL3", "SDL3_ttf", "SDL3_image"]
    ## canonical names of the binding's libraries (file name without "lib"
    ## prefix and everything from the first '.')
  SdlLibDirs* = ["/opt/homebrew/lib", "/usr/local/lib"]

proc sdlPassL*(): string =
  for d in SdlLibDirs: result.add "-L" & d & " "
  for i, l in SdlLibs:
    if i > 0: result.add ' '
    result.add "-l" & l

proc sdlCfgBlock*(): string =
  ## The same flags as a nim.cfg section, for the `nim.cfg` of new projects (a
  ## project built outside the IDE, for example `nim c app.nim`, needs them too).
  result = "@if macosx:\n"
  for l in SdlLibs: result.add "  --dynlibOverride:" & l & "\n"
  result.add "  --passL:\"" & sdlPassL() & "\"\n@end\n"
