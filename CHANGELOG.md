# Changelog

## Unreleased

- Opening a project brings back the units that were open when it was closed (or the IDE was
  left) and the active one; units that are gone are skipped. Kept in `settings.json`
  (`sessions`, last 20 projects), not in the `.nimproj`.
- Clickable runtime tracebacks: a Nim traceback in the output of the running program (frames and
  the `unhandled exception` line) is listed in Messages; double click or `F8` opens the file and
  line of a project unit. Messages is shown when the program ended with one.
- Edit > Parameter Hints (`Shift+Ctrl+Space`): inside `name(` on the current line, a hint over
  the line shows the parameters of the proc, func, method, template, iterator or macro called
  `name` that the unit declares. It closes when the caret leaves the call.
- Edit > Insert Template (`Ctrl+J`): code templates (`proc`, `func`, `if`, `ife`, `for`, `fori`,
  `while`, `case`, `try`, `tryf`, `when`, `block`, `obj`, `echo`, `discard`). When the word before
  the caret is a template's name it is expanded, indented like the line, with the caret at the
  right place; otherwise the templates are listed like completions. Your own go into
  `settings.json` as `"codeTemplates": [{"name", "description", "code"}]` (`|` marks the caret).
- Edit > Complete Code (`Ctrl+Space`): the names that fit the word before the caret, listed under
  it (`Up`, `Down`, `PageUp`, `PageDown` choose, `Enter` or `Tab` insert, `Esc` closes; typing
  narrows the list, `Backspace` widens it). After `self.` they are the form's components and its
  properties and events, after `Button1.` the properties and events of that component's class;
  elsewhere the identifiers of the unit, the components, nimvcl names and keywords. One match
  is inserted at once.
- Search > Find in Files... (`Shift+Ctrl+F`): text (the selection or the word at the caret to
  start with), case sensitive, whole words, regular expression, in all units of the project
  or in the project folder (`.nim` and `.nfm`; not hidden folders, `nimcache` or the output
  folder). The lines found are listed in Messages (file, line, text); a double click or `F8`
  opens the place, a form file opens the form. Units with unsaved edits are searched as
  edited. At most 1000 lines are listed, files over 2 MB are skipped.
- Numbered bookmarks as in Delphi: `Shift+Ctrl+0` .. `9` set bookmark N on the caret line (or
  remove it when it is on that line), `Ctrl+0` .. `9` go to it, also in another unit. The
  gutter shows a bookmark icon, bookmarks follow their line while you edit, and a number is
  used once in the whole project. Search > Toggle Bookmarks and Go to Bookmark list them.
  They are not saved with the project.
- Tools > Editor Options... is a dialog now: font family, font size, tab width, insert spaces for
  Tab and line numbers. It applies to every open and new editor and is kept in `settings.json`
  (`editorFontFamily`, `editorTabWidth`, `editorInsertSpaces`, `editorLineNumbers`; files
  without them keep working). The default tab width stays 2.
- Project > Build (`Shift+F9`) compiles everything again with `-f`, ignoring the up-to-date
  check; Project > Syntax Check runs `nim check` and lists the messages like a compile,
  without making a program or writing the build record. Program Reset stops either.
- Edit > Align... and Edit > Size... (Delphi's dialogs): left sides, centers, right sides, space
  equally or center in window, horizontally and vertically; shrink to smallest, grow to
  largest or an exact width and height. Edit > Tab Order... lists the controls of the selected
  control's parent in tab order with Move Up and Move Down and saves it as `tabOrder` in the form.
- Save removes an event handler that is still the generated stub (its body is only `discard`)
  and clears the events bound to it, as Delphi does. A handler with any code of yours, one
  that other code calls, one an inherited component uses, or one a descendant form uses stays.
- A double click in the designer creates the default event of the class, as in Delphi:
  `onChange` for Edit, Memo, ComboBox, TrackBar, ScrollBar, SpinEdit, CheckBox, ListBox
  and RadioButton, `onTimer` for Timer, `onShow` for the form, `onClick` otherwise.
- Stop (Program Reset) asks the program and the processes it started to end first
  (SIGTERM on Linux and macOS) and kills what is still running after 0.3 s.
- Saving keeps the permissions of the file (an executable script stays executable) and
  writes through a symbolic link instead of replacing it.
- The window comes back where it was (position, size, maximized). A saved docking layout
  that cannot be used no longer fails silently: the default layout is shown and the
  status bar says so. Component search also finds a class by other words (`tabs` finds
  PageControl, `multiline` Memo, `interval` Timer); a class without an icon shows its
  name on its palette button.
- Save no longer silently overwrites a `.nim` or `.nfm` that another program changed
  since the unit was opened or last saved: it asks "... changed on disk. Overwrite?",
  and Cancel leaves the file alone (the save counts as failed, so closing stays open).
- The Object TreeView is no longer looked at again after every property change or drag
  step, and when it is rebuilt (a component added, removed, renamed or moved) the nodes
  you collapsed stay collapsed and the scroll position is kept.
- Edit > Revert to Inherited is enabled only while the designer shows and the selected
  property (or component) really differs from the ancestor form's.
- Help > About shows the version from `nimrad.nimble` (it said 0.0.1).
- Closing a tab that is not the active one keeps the active tab.
- Smaller fixes: a main file that cannot be saved before the IDE edits it is reported and
  its text kept; Save As / Save Project As stop when a file cannot be saved first;
  a path from `$NIMVCL_SRC` is made absolute and `nimble path` giving nothing no longer
  yields a relative `src`; a project listing the same unit twice is refused; `&` in a
  project name no longer becomes a mnemonic in File > Reopen; `nimrad FILE.nimproj`
  opens the project, and unknown options or `--project` without a file are reported on
  stderr; a settings file that cannot be written is reported once in the status bar.
- Opening a project that cannot be read (corrupt, made by a newer version, no permission)
  no longer removes it from File > Reopen; only a project whose file is gone is dropped.
- Add to Project checks first that the file exists and is a `.nim` file, takes a relative
  path from the project's folder, and refuses a form whose `.nfm` cannot be read (it used
  to add a form unit without a form type).
- File > New Application that fails half way removes the files it made (so trying again
  works) and reopens the project that was open; changing the import mode in Project >
  Options puts the files back when one cannot be written; Remove Font deletes the font
  file only after the project and the main file were saved.
- New Form refuses a unit name whose form type would hide a nimvcl class (`button`
  gives `Button`).
- Add Font File refuses a second file with the same family and style (the program would
  not compile).
- Saving a project keeps the keys this version does not know inside unit and font
  records (as it already did at the top level).
- Output: a partial line (a prompt without a newline) shows after 0.2 s instead of
  waiting for the rest; Program Reset after the program ended on its own no longer
  reports "cancelled".
- Quick fixes: "Did you mean ...?" is refused ("compile again") when its line has changed
  since the build instead of editing the wrong place; an import for a file outside
  the project says so instead of "already imported"; the automatic import option
  only adds types and `newXxx` constructors, not noise names like `caption` or `add`.
- Stopping a build or program can no longer hit an unrelated process (a reaped pid or
  a reused job handle), and a program started elsewhere at the same moment cannot
  keep a build's output open (the pipe is close-on-exec from the start).
- Run and Compile no longer walk `.git`, nimcache or the output folder when checking
  whether the program is up to date, and files unchanged since the last build are
  not hashed again, so the pause on large project folders is gone.
- Run no longer skips the build wrongly: an output folder that is (or contains) the
  project folder, or `-o`/`--out`/`--outdir` among the project's flags, always
  builds, and a module replaced during the build (even keeping an older time)
  is noticed by the next check.
- A build lists up to 100 errors in Messages (`--errorMax:100`), not just the first;
  a project's own `--errorMax` flag still wins.
- Messages: the gcc/ld lines that follow `Error: execution of an external compiler
  program ... failed` are kept in that message instead of being dropped.
- A new handler stub of an inherited event puts the caret on its `discard`, not on
  the hint comment; the fallback placement after the imports skips the lines of
  a multi-line `import a,\n  b`; a unit with mixed line endings is no longer
  rewritten as all-CRLF; reloading a unit from disk keeps the selected control.
- A control import stays in a unit's managed import block while the unit's code
  still names the class (`Timer(...)`, `cast[Label](x)`), also after the last
  object of the class left the form.
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
