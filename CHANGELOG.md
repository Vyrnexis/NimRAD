# Changelog

## 0.1.0 - 2026-11-18

First public release.

- Form designer on the nimvcl property registry, Object Inspector, Object
  TreeView, component palette with search (`Ctrl+Alt+C`).
- Code editor with Nim highlighting; events created by double click; `F12`
  switches between form and code.
- Compile and run in the background, with messages, jump to errors, live
  program output.
- Inherited forms (File > New Inherited Form).
- Design-time editors for pictures, image lists, string lists and collections;
  colour and `font.color`; font drop-down; project fonts (Project > Add Font
  File).
- Form units import only the controls they use, so builds are fast.
- Editable program file with managed import and form blocks.
- Docking panels with a saved layout; light and dark themes.
- nimvcl is found without environment variables: `$NIMVCL_SRC`, the folder the
  IDE was compiled against, or `nimble path nimvcl`.
