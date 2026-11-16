# nimvcl-ide

A Delphi 7-style IDE for building windowed applications with
[nimvcl](https://github.com/Vyrnexis/nimvcl): a component palette, a form
designer, an object inspector, code editor tabs, and one-key build and run.

**Status:** in development.

## Building

nimvcl-ide expects a nimvcl checkout next to it (`../nimvcl`).

```sh
nim c -d:release -o:build/nimvcl_ide src/nimvcl_ide.nim
build/nimvcl_ide
```
