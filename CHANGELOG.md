# Changelog

## Unreleased

- The program file: a commented-out `# let x = newForm1()` is not taken for the
  form's create line, and a file whose first line has no CRLF but others do keeps
  its CRLF endings when units are added.
- Handler and component names are compared the way Nim does (case after the first
  letter and underscores ignored): `button1click` is the handler `button1Click`
  and no second stub is added.
- A proc such as `proc makeForm(): Form1` or `proc f(a = 1): Form1` is no longer
  taken for an event handler of Form1.
- A file that cannot be written (read-only, disk full) is reported when saving,
  closing a tab or project, or closing the window, instead of raising; a failed
  save counts as Cancel, so nothing is lost.
- Closing the window saves the units like Save All does (forms inheriting from
  another are written before it), and asks about all of them first.
- Remove from Project on a form that others inherit from says so and keeps its
  tab open; a failure while removing is reported instead of raising.
- New Application, Open Project and closing the project are refused (and
  disabled) while the compiler or the program runs, so the build's messages
  and fixes no longer reach another project. Use Program Reset first.
- An unexpected error while running the compiler or the program no longer
  leaves the IDE busy for good: the job always ends, the error is listed as
  output and the child process is always waited for.
- A form file that does not parse no longer makes the unit lose its control
  imports.
- A unit that cannot be written stays marked as modified.
- Deleting a control that has children no longer breaks forms inheriting from
  this one: the check covers every control below the selected ones.

## 0.2.1 - 2026-11-20

- Editor tabs leave room for the close button again (nimvcl 0.2.1).

## 0.2.0 - 2026-11-20

- The Object Inspector's popup (Revert to Inherited) acts on the row that was
  right-clicked, and properties that differ from the ancestor form show their
  name in bold. The ancestor form is read once per version of its file.
- Remove Font unregisters the family in the IDE; closing or switching projects
  unregisters the project's fonts.
- Inherited forms stay current while open: saving an ancestor rebuilds the open
  descendants on top of its new file, keeping their selection, their unsaved
  code and their unsaved form changes (laid over the new ancestor as
  differences). Save All writes descendants before ancestors.
- **Project > Remove Font...** removes a font from the project, the program
  file's font block and the `fonts/` folder.
- A form that uses a component class of the project (declared with
  `ref object of` or registered with `registerClass` in one of its units, or
  named in `classImports` of the `.nimproj`) gets the import in its managed
  import block, also when the designer cannot show the form. Quick Fix and
  Find Unit offer those units too.
- Renaming an event handler in the Object Inspector renames its proc (when no
  other event uses it) instead of leaving it behind with a second stub.
- Code review leftovers: a unit file is saved through a temporary file;
  `codegen` finds procs with the lexer (a column-0 comment or a string line no
  longer cuts a body); `from x import name` is not taken for an import of unit
  `name` when a unit is renamed; compiler flags with a quoted space survive
  Project > Options; New Form skips a number whose `.nfm` exists and refuses a
  form type another unit has; New Application refuses a folder that holds its
  files; the main form's unit cannot be removed through the model; an open
  descendant follows the rename of its ancestor; the Object TreeView follows
  edits through the editor's own notification; the nimvcl folder is looked up
  once, not for every compile; `--shots` is gone from the program (use
  `scripts/docshots.nim`).
- Inherited forms: **Edit > Revert to Inherited** (also in the Object
  Inspector's context menu) puts the selected property back to the ancestor's
  value, **Revert Component to Inherited** every property of the component;
  the value then leaves the descendant's `.nfm`.
- A right click in the Messages window selects the row under the mouse before
  the context menu opens, so Quick Fix acts on that message.
- Run skips the compiler when nothing changed: it compares the files the
  compiler read (from the list it leaves in the nimcache), the project
  folder, the compiler arguments and the program, and builds at any doubt.
  The nimcache of a project is now `<output folder>/nimcache`.
- The IDE is now called NimRAD (Rapid Application Development). The package,
  the program and the main module are `nimrad` (was `nimvcl_ide`), and the
  repository is https://github.com/Vyrnexis/NimRAD.
- Settings move from `nimvcl-ide/` to `nimrad/` in the user config folder the
  first time NimRAD starts (only when `nimrad/` does not exist yet).
- New projects get `# nimrad: ...` marker comments. Projects with the old
  `# nimvcl-ide: ...` markers (and the `# nimvcl-ide: all` import tag) are
  still recognised and are edited in place, keeping their markers.

## 0.1.6 - 2026-11-19

- Unit paths are stored canonical like the project's own path, so a unit
  named through a symlink (macOS: /var is /private/var) gets a working
  relative import.

## 0.1.5 - 2026-11-19

- macOS: the IDE builds again (the process-tree code took `environ` from
  `_NSGetEnviron`).
- Windows: a program started by Run or a build sees the end of its input
  instead of waiting forever; Stop ends the program even when it could not
  be put into a job object.

## 0.1.4 - 2026-11-19

Fixes from a full code review; requires nimvcl 0.1.4.

- Run always builds first (nim c is incremental), so it can no longer start a
  stale program.
- Stop ends the whole process tree (process group on Linux/macOS, job object
  on Windows).
- Renaming or deleting a component that a descendant form inherits or uses is
  refused; renaming a unit or project rolls back if a step fails.
- Timers of a designed form stop when its editor closes.
- `.nimproj`: the format version is `formatVersion` (no longer clashing with
  the application `version`); files from a newer IDE are refused; unknown
  fields survive a save; project files are written atomically.
- Units outside the program folder are imported by relative path.
- Compiler and program output arrive in batches; the Output tab keeps the
  last 5000 lines.
- Quick fixes read form files only when an error could need them; panels
  refresh only when something changed.
- Internals: project paths are canonical from load; one module for Nim source
  facts; the main form is split into focused modules with a single build
  state.

## 0.1.3 - 2026-11-19

- Windows and macOS support (experimental), with CI jobs for both; requires
  nimvcl 0.1.3.
- Windows: the built program's path gets the `.exe` suffix; `nim` is found
  on `PATH` as `nim.exe`.
- macOS: the IDE and the projects it builds link SDL at build time, and new
  projects get the same flags in their `nim.cfg` so `nim c` works outside
  the IDE. Compiler messages match units by real path (`/private/var`).
- Project files are read with `/` or `\` path separators.

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
