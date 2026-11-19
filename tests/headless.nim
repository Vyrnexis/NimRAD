## Shared by the tests that run a built program: sets the headless SDL drivers
## in this process (inherited by the child) instead of using a `VAR=x cmd`
## shell prefix, which cmd.exe does not understand.
import std/[os, osproc]

proc headlessCmd*(cmd: string): tuple[output: string, exitCode: int] =
  if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
  putEnv("SDL_RENDER_DRIVER", "software")
  execCmdEx(cmd)   # stderr is merged into the output by default
