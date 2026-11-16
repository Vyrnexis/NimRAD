# nimvcl-ide

A Delphi 7-style IDE for building windowed applications with
[nimvcl](https://github.com/Vyrnexis/nimvcl): a component palette, a form
designer, an object inspector, code editor tabs, and one-key build and run.

![nimvcl IDE: the form designer](docs/images/ide-designer.png)

<p>
<img src="docs/images/ide-code-build.png" width="32%" alt="The handler code and a successful build">
<img src="docs/images/ide-compile-error.png" width="32%" alt="A compile error and the jump to it">
<img src="docs/images/ide-dark.png" width="32%" alt="The dark theme">
</p>

**Status:** in development.

## Features

- Form designer on top of the nimvcl property registry: drop components from
  the palette, move and size them, edit them in the Object Inspector and the
  Object TreeView. Forms are saved as `.nfm` files.
- Double click a component to create its event handler in the unit's code.
- Code editor with Nim highlighting; F12 switches between form and code.
- Compile (Ctrl+F9) and Run (F9) in the background; errors are listed in
  Messages and the first one is opened for you.
- Docking panels (saved layout), project manager, recent projects, light and
  dark theme. One action list drives the menu, the toolbars and the shortcuts.

## Building

nimvcl-ide expects a nimvcl checkout next to it (`../nimvcl`).

```sh
nim c -d:release -o:build/nimvcl_ide src/nimvcl_ide.nim
build/nimvcl_ide
```

The first start creates `~/nimvcl-projects/Project1`. See the
[user guide](docs/user-guide.md) for a walk-through.

## Keyboard shortcuts

| Keys | Command | Keys | Command |
|---|---|---|---|
| `Ctrl+F11` | Open Project | `Ctrl+F9` | Compile |
| `Ctrl+S` | Save | `F9` | Run |
| `Shift+Ctrl+S` | Save All | `Ctrl+F2` | Program Reset |
| `Ctrl+W` | Close unit | `F12` | Toggle Form / Unit |
| `Ctrl+Z` / `Shift+Ctrl+Z` | Undo / Redo | `F11` | Object Inspector |
| `Ctrl+X` `Ctrl+C` `Ctrl+V` | Cut, Copy, Paste | `Ctrl+Alt+P` | Project Manager |
| `Ctrl+A` | Select All | `Shift+Alt+F11` | Object TreeView |
| `Ctrl+F` / `Ctrl+H` | Find / Replace | `Alt+0` | Messages |
| `F3` | Find Next | `Shift+F11` | Add to Project |
| `Alt+G` | Go to Line | `Shift+Ctrl+F11` | Project Options |

## Screenshots and tests

```sh
export SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software
build/nimvcl_ide --shots build/shots     # a scripted session, one PNG per step
scripts/test.sh                          # the test suite (add -d:release for a release run)
```
