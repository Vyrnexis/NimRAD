# Changelog

## 0.1.2 - 2026-11-19

- Quick fix for missing imports: when a build fails on an undeclared nimvcl
  name, Messages offers "Add import ..." (Ctrl+.), adds it above the
  IDE-managed block and rebuilds. Several candidate modules give a chooser.
- "Did you mean Edit1?" for a component name written with the wrong case of
  its first letter (Nim is case-sensitive there).
- Search > Find Unit (Shift+Ctrl+A) adds the import for the name at the caret.
- Project options: "Add missing nimvcl imports automatically" (off by
  default) and "Import all of nimvcl" (simpler, slower builds).

## 0.1.1 - 2026-11-19

- New units and the program file import `nimvcl/prelude`, so handler code can
  call `showMessage`, `messageDlg`, `inputBox`, timers, colours and fonts
  without extra imports. Requires nimvcl 0.1.2.
- Projects created with 0.1.0 keep working; to get the same in them, add
  `import nimvcl/prelude` to each unit, above the `nimvcl-ide: imports` block.

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
