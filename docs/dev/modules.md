# Module layout

Developer notes: where things live under `src/`. The comment at the top of each
module is the detailed reference; this page is the map.

`src/nimrad.nim` is the program (`nimrad`, `nimrad --project FILE`,
`nimrad --nimvcl-path`). Everything else is in `src/ide/`. The scripted session
that makes the documentation pictures (`src/ide/session.nim`, used by
`scripts/docshots.nim` and `tests/tide.nim`) is not part of the program.

## The window

`mainform` builds the window and re-exports the parts. Everything the user can
do is a proc on `IdeForm`, so the menu, the scripted session and the tests drive
the same code. The few modal dialogs are hooks (`askSave`, `showError`,
`askText`, `pickFile`, `pickItem`, `askAlign`, `askSize`, `askOrder`, `askEditorOptions`, `askFindInFiles`) that tests replace.

| Module | Holds |
|---|---|
| `ideform` | The `IdeForm` object and the helpers every part shares |
| `ideeditors` | Editor tabs, the Object TreeView, the state of the actions, `sync`, the Edit and Search commands that go to the active editor, Revert to Inherited |
| `designcmds` | Edit > Align..., Size... and Tab Order...: the dialog hooks (`askAlign`, `askSize`, `askOrder`) and the work on the designer |
| `projectcommands` | Opening, creating and changing projects and units; fonts; options; rename |
| `buildcontroller` | Compile, Run and Stop as one state machine (`BuildPhase`: idle, compiling, compiling for run, retrying after an automatic import, checking, running; Build is a compile with `buildForce`) |
| `bookmarks` | The numbered bookmarks of a code editor: slot to line, follow nimvcl's markers (they carry no number): moved with the edits, dropped with a deleted line, carried by Alt+Up/Down, back with an undo |
| `findcmds`, `findinfiles` | Search > Find in Files: the command (dialog hook, results into Messages) and the search itself (files to read, nimvcl's `Searcher`, limits) |
| `codeinsight`, `codepicker`, `codecmds` | Edit > Complete Code, Insert Template and Parameter Hints: the candidates and their ranking (pure: word before the caret, unit identifiers, components, nimvcl names, keywords; members from the class registry), the signatures of the unit's procs, the pick list popup and the one line hint (a menu popup that takes the form's keys while the editor keeps the focus) and the commands that feed them from the active editor, the form and the settings (`codeTemplates`); templates expand with the line's indent |
| `todoscan`, `todopanel`, `outlinecmds` | View > To-Do List (and the idle hook `flushOutline` of both windows): the marked comments of a unit (lexer based, pure), the docked list (a tab of Messages, closed in the default layout) and the commands that scan the units (editors' unsaved text first) and refresh the list on its button, when shown and after a save (idle hook `flushOutline`) |
| `codeoutline`, `codeexplorer` | View > Code Explorer: the top-level declarations of a unit (lexer based, pure) and the docked tree; `outlinecmds` also feeds it from the active editor, debounced by `IdeForm.outlineDelay` through the model's version counter |
| `quickfixes` | Quick Fix and Find Unit applied to the editors or the files |
| `ideui` | Menus, toolbars, docking and the wiring of the actions |
| `idedialogs` | The real dialogs behind the hooks |
| `actions` | The action table: captions, hints, shortcuts, icons |
| `uniteditor` | The editor of one unit: form designer and code view, inheritance, rebuild of descendants |
| `palette`, `projecttree`, `messagespanel`, `icons` | component palette with search, Project Manager, Messages and Output windows, procedurally drawn icons |
| `session` | The scripted session |

## Building and running

| Module | Holds |
|---|---|
| `builder` | `nim c` on a worker thread and the child process of the program; output and the end of a build reach the UI thread through `runOnUi`. The compiler is asked for `-d:nimBetterRun` and uses `<output folder>/nimcache` |
| `proctree` | A child process that leads a process group (posix) or a job object (Windows), so `killTree` also ends the C compiler and anything the program started. The read end of the output pipe then ends too. Stdin is `/dev/null` or closed |
| `buildcheck` | The up-to-date check behind Run: a snapshot of the project folder before the compiler starts, a stamp (`nimrad-build.json`) after a successful build, and `isUpToDate`. Any doubt builds. Limits: 4000 files, 4 MB per hashed file, 64 MB hashed per check |
| `sdllink` | The SDL link flags for macOS, one definition shared by `config.nims` (the IDE), `builder` (the projects) and the `nim.cfg` of new projects |
| `nimvclpath` | Finding nimvcl's `src` folder: `$NIMVCL_SRC`, the folder the IDE was compiled against, `nimble path nimvcl` |
| `messages` | Parsing compiler output (`MessageParser`) and the tracebacks of the running program (`RuntimeParser`) into messages |
| `cmdargs` | Splitting and quoting command line text (compiler flags, run parameters) |

## The project and its sources

| Module | Holds |
|---|---|
| `project` | The model: the `.nimproj` file (format in the module comment, `formatVersion`, `classImports`), units, fonts, rename, add and remove |
| `mainfile` | Edits of the program file between the `# nimrad:` markers (the old `# nimvcl-ide:` markers are still recognised) |
| `unitimports` | The managed import block of a form unit, custom class imports, the "import all" tag |
| `codegen` | Edits of a unit's source text: handler stubs, renames, imports. Line based, uses nimvcl's lexer to skip strings and comments |
| `nimsource` | What the IDE needs to know about Nim source text in one place: valid identifiers, keywords, the modules a file imports (comments recognised with the lexer) |
| `fileio` | Atomic writes (a temporary file, then a rename) |
| `ideconfig` | `settings.json` in the user config folder, including the open units per project (`sessions`) and the one-time move from `nimvcl-ide` |
| `quickfix`, `symbols`, `symbolindex`, `symbolscan` | Quick fix rules (pure), the symbol to module lookup, and the generated table of nimvcl symbols (`nimble genindex`; the test `tsymbolindex` fails when it is stale) |

The designer and the Object Inspector are nimvcl's (`FormDesigner`,
`ObjectInspector`, the property editor dialogs); see the nimvcl
[documentation](https://github.com/Vyrnexis/nimvcl/blob/main/docs/README.md).
