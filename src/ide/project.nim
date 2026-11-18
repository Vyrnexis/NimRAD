## The project model: a `.nimproj` file plus the units it lists.
##
## ## File format
##
## JSON (chosen over key=value because units are a list of records and flags
## are lists of strings; it is easy to read, diff and extend):
##
## ```json
## {
##   "version": 1,
##   "name": "hello",
##   "mainFile": "hello.nim",
##   "units": [
##     {"name": "unit1", "nim": "unit1.nim", "nfm": "unit1.nfm",
##      "isForm": true, "formType": "Form1"},
##     {"name": "unit2", "nim": "unit2.nim", "nfm": "unit2.nfm",
##      "isForm": true, "formType": "Form2", "ancestor": "unit1"}
##   ],
##   "fonts": [{"file": "fonts/Foo-Regular.ttf", "family": "Foo", "style": "regular"}],
##   "outputDir": "build",
##   "nimFlags": ["-d:release"],
##   "defines": ["useFoo", "level=2"],
##   "title": "My App",
##   "version": "1.0.0",
##   "runArgs": [],
##   "nimvclPath": "",
##   "autoImports": true,
##   "importAll": true
## }
## ```
##
## * `ancestor` (form units only) is the unit whose form this one inherits
##   from (File > New Inherited Form); the `.nfm` names the ancestor file too
##   (`ancestor = 'unit1.nfm'`), the project keeps the unit name for the IDE.
## * `fonts` lists the font files copied into `<project>/fonts/` (`Project >
##   Add Font File...`); `style` is `regular`, `bold`, `italic` or `bolditalic`.
##   The main file registers them at startup, embedded at compile time.
## * Every path is stored relative to the folder of the `.nimproj`
##   (forward slashes); `resolve` gives the absolute path. Absolute paths that
##   are given to the API are converted on the way in.
## * `outputDir` defaults to `build`.
## * `nimvclPath` is the nimvcl `src` folder; empty means "detect"
##   (`detectNimvclPath`: `$NIMVCL_SRC`, then the folder the IDE was compiled
##   against, then `nimble path nimvcl`).
## * `autoImports` (Project > Options > "Add missing nimvcl imports automatically")
##   and `importAll` ("Import all of nimvcl") are written only when on.
## * Missing fields take their defaults when loading; unknown fields are dropped.
##
## Files of a new project come from `templates/` (read at compile time) with
## `${placeholder}` substitution.

import std/[json, os, strutils, sequtils]
import nimvcl/graphics/[font, context]
import nimvcl/dsl/nfmsyntax
import ./[codegen, mainfile, nimvclpath, unitimports]

const
  ProjectExt* = ".nimproj"
  tmplMain = staticRead("../../templates/main.nim.tmpl")
  tmplUnit = staticRead("../../templates/unit.nim.tmpl")
  tmplNfm = staticRead("../../templates/unit.nfm.tmpl")
  tmplCfg = staticRead("../../templates/nim.cfg.tmpl")
  tmplInhNim = staticRead("../../templates/inherited.nim.tmpl")
  tmplInhNfm = staticRead("../../templates/inherited.nfm.tmpl")

type
  ProjectError* = object of CatchableError

  ProjectUnit* = object
    name*: string        ## module name, `unit1`
    nimPath*: string     ## relative to the project folder
    nfmPath*: string     ## "" for a plain unit
    isForm*: bool
    formType*: string    ## `Form1` for a form unit
    ancestor*: string    ## unit of the ancestor form when this form is inherited, else ""

  ProjectFont* = object
    file*: string        ## relative to the project folder, `fonts/Foo-Regular.ttf`
    family*: string      ## name used in `FontSpec.family`
    style*: string       ## "regular", "bold", "italic" or "bolditalic"

  Project* = ref object
    filePath*: string    ## absolute path of the .nimproj
    name*: string
    mainFile*: string
    units*: seq[ProjectUnit]
    fonts*: seq[ProjectFont]
    outputDir*: string
    nimFlags*: seq[string]
    defines*: seq[string]  ## conditional defines, passed as `-d:<entry>`
    title*: string         ## application title, passed as `-d:appTitle=<title>`
    version*: string       ## version info, passed as `-d:appVersion=<version>`
    runArgs*: seq[string]
    nimvclPath*: string  ## "" = detect
    autoImports*: bool   ## add a missing `import nimvcl/...` by itself when a build fails for it
    importAll*: bool     ## units and the program import `nimvcl` (slower builds), not the prelude and the control imports

# ------------------------------------------------------------------- helpers

proc expand*(tmpl: string, vars: openArray[(string, string)]): string =
  ## Replaces `${key}`; a key that is not in `vars` raises `ProjectError`.
  var i = 0
  while i < tmpl.len:
    if tmpl[i] == '$' and i + 1 < tmpl.len and tmpl[i + 1] == '{':
      let e = tmpl.find('}', i)
      if e < 0: raise newException(ProjectError, "unterminated placeholder")
      let key = tmpl[i + 2 ..< e]
      var found = false
      for (k, v) in vars:
        if k == key:
          result.add v
          found = true
          break
      if not found: raise newException(ProjectError, "unknown placeholder ${" & key & "}")
      i = e + 1
    else:
      result.add tmpl[i]
      inc i

proc validName*(s: string): bool =
  ## Project and unit names: a letter, then letters, digits or `_`.
  s.len > 0 and s[0] in Letters and s.allIt(it in IdentChars)

proc dir*(p: Project): string = parentDir(p.filePath)

proc unixPath(s: string): string = s.replace('\\', '/')

proc resolve*(p: Project, rel: string): string =
  ## Absolute path of a stored path.
  if rel.isAbsolute: normalizedPath(rel) else: normalizedPath(p.dir / rel)

proc relativeTo(p: Project, path: string): string =
  let abs = if path.isAbsolute: normalizedPath(path) else: normalizedPath(p.dir / path)
  unixPath(relativePath(abs, p.dir))

proc detectNimvclPath*(): string =
  ## The nimvcl `src` folder, or "" when none is found (see `nimvclpath`).
  detectNimvclSrc()

proc nimvclSrc*(p: Project): string =
  ## The folder passed to `--path` (resolved from the project, else detected).
  if p.nimvclPath.len > 0: p.resolve(p.nimvclPath) else: detectNimvclPath()

proc mainPath*(p: Project): string = p.resolve(p.mainFile)
proc outputPath*(p: Project): string = p.resolve(p.outputDir)
proc nimPathOf*(p: Project, u: ProjectUnit): string = p.resolve(u.nimPath)
proc nfmPathOf*(p: Project, u: ProjectUnit): string =
  if u.nfmPath.len > 0: p.resolve(u.nfmPath) else: ""

proc findUnit*(p: Project, name: string): int =
  for i, u in p.units:
    if u.name == name: return i
  -1

# --------------------------------------------------------------- load / save

proc str(j: JsonNode, key, default: string): string =
  if j.kind == JObject and j.hasKey(key) and j[key].kind == JString: j[key].getStr else: default

proc strs(j: JsonNode, key: string): seq[string] =
  if j.kind == JObject and j.hasKey(key) and j[key].kind == JArray:
    for e in j[key]:
      if e.kind == JString: result.add e.getStr

proc toJson*(p: Project): JsonNode =
  var us = newJArray()
  for u in p.units:
    us.add %*{"name": u.name, "nim": u.nimPath, "nfm": u.nfmPath,
              "isForm": u.isForm, "formType": u.formType}
    if u.ancestor.len > 0: us[us.len - 1]["ancestor"] = %u.ancestor
  var fs = newJArray()
  for f in p.fonts: fs.add %*{"file": f.file, "family": f.family, "style": f.style}
  result = %*{"version": 1, "name": p.name, "mainFile": p.mainFile, "units": us, "fonts": fs,
     "outputDir": p.outputDir, "nimFlags": p.nimFlags, "defines": p.defines, "title": p.title,
     "version": p.version, "runArgs": p.runArgs, "nimvclPath": p.nimvclPath}
  if p.autoImports: result["autoImports"] = %true
  if p.importAll: result["importAll"] = %true

proc save*(p: Project) =
  writeFile(p.filePath, p.toJson.pretty & "\n")

proc loadProject*(path: string): Project =
  ## Raises `ProjectError` when the file is missing or not a project.
  let abs = absolutePath(path)
  var j: JsonNode
  try:
    j = parseJson(readFile(abs))
  except CatchableError as e:
    raise newException(ProjectError, "cannot read project " & abs & ": " & e.msg)
  if j.kind != JObject:
    raise newException(ProjectError, abs & " is not a project file")
  result = Project(filePath: abs, name: j.str("name", abs.splitFile.name),
                   mainFile: j.str("mainFile", ""), outputDir: j.str("outputDir", "build"),
                   nimFlags: j.strs("nimFlags"), defines: j.strs("defines"),
                   title: j.str("title", ""), version: j.str("version", ""),
                   runArgs: j.strs("runArgs"),
                   nimvclPath: j.str("nimvclPath", ""))
  for (key, field) in [("autoImports", addr result.autoImports), ("importAll", addr result.importAll)]:
    if j.hasKey(key) and j[key].kind == JBool: field[] = j[key].getBool
  if result.mainFile.len == 0: result.mainFile = result.name & ".nim"
  if result.outputDir.len == 0: result.outputDir = "build"
  if j.hasKey("units") and j["units"].kind == JArray:
    for e in j["units"]:
      if e.kind != JObject: continue
      var u = ProjectUnit(name: e.str("name", ""), nimPath: e.str("nim", ""),
                          nfmPath: e.str("nfm", ""), formType: e.str("formType", ""),
                          ancestor: e.str("ancestor", ""))
      u.isForm = e.hasKey("isForm") and e["isForm"].kind == JBool and e["isForm"].getBool
      if u.name.len > 0 and u.nimPath.len > 0: result.units.add u
  if j.hasKey("fonts") and j["fonts"].kind == JArray:
    for e in j["fonts"]:
      if e.kind != JObject: continue
      let f = ProjectFont(file: e.str("file", ""), family: e.str("family", ""),
                          style: e.str("style", "regular"))
      if f.file.len > 0 and f.family.len > 0: result.fonts.add f

# ------------------------------------------------------------------- editing

proc addUnit*(p: Project, name, nimPath: string, nfmPath = "", isForm = false,
              formType = "", ancestor = ""): ProjectUnit =
  ## Registers a unit (paths absolute or relative to the project folder).
  if p.findUnit(name) >= 0:
    raise newException(ProjectError, "unit " & name & " already exists")
  result = ProjectUnit(name: name, nimPath: p.relativeTo(nimPath),
                       nfmPath: (if nfmPath.len > 0: p.relativeTo(nfmPath) else: ""),
                       isForm: isForm or nfmPath.len > 0, formType: formType,
                       ancestor: ancestor)
  p.units.add result

proc ancestorUnitOf*(p: Project, nfmPath: string): string =
  ## For the form file `nfmPath` that starts with `inherited`, the project unit
  ## whose form file it names as `ancestor`; "" otherwise.
  try:
    let root = parseNfm(readFile(nfmPath))
    if not root.inherited: return ""
    let target = normalizedPath(if root.ancestor.isAbsolute: root.ancestor
                                else: nfmPath.parentDir / root.ancestor)
    for u in p.units:
      if u.nfmPath.len > 0 and normalizedPath(p.nfmPathOf(u)) == target: return u.name
  except CatchableError: discard

proc descendantsOf*(p: Project, unitName: string): seq[string] =
  ## Units whose form inherits (directly or through others) from `unitName`'s.
  var todo = @[unitName]
  while todo.len > 0:
    let a = todo.pop()
    for u in p.units:
      if u.ancestor == a and u.name notin result:
        result.add u.name
        todo.add u.name

# --------------------------------------------------------------------- fonts

const FontExts = [".ttf", ".otf"]

func styleName(st: set[FontStyle]): string =
  if fsBold in st and fsItalic in st: "bolditalic"
  elif fsBold in st: "bold"
  elif fsItalic in st: "italic"
  else: "regular"

proc fontFamilies*(p: Project): seq[string] =
  ## The distinct families of the project's fonts, in the order they were added.
  for f in p.fonts:
    if f.family notin result: result.add f.family

proc registerFonts*(p: Project) =
  ## Registers the project's fonts in this process (the designer and the
  ## Object Inspector use them); missing files are skipped.
  var seen: seq[string]
  for f in p.fonts:
    if f.family in seen: continue
    seen.add f.family
    var data: array[4, string]
    for g in p.fonts:
      if g.family != f.family or not fileExists(p.resolve(g.file)): continue
      let i = case g.style
        of "bold": 1
        of "italic": 2
        of "bolditalic": 3
        else: 0
      data[i] = readFile(p.resolve(g.file))
    if data[0].len == 0:
      for d in data:
        if d.len > 0:
          data[0] = d
          break
    if data[0].len > 0:
      registerFontFamilyData(f.family, data[0], data[1], data[2], data[3])

proc fontsBlockLines*(p: Project): seq[string] =
  ## The lines of the main file's `fonts` block: one `registerFontFamilyData`
  ## per family, the files read at compile time into constants (`staticRead`, so
  ## they travel inside the executable).
  if p.fonts.len == 0: return
  result.add "import nimvcl/graphics/font"
  let mainDir = p.mainPath.parentDir
  var seen: seq[string]
  var calls: seq[string]
  for f in p.fonts:
    if f.family in seen: continue
    seen.add f.family
    let n = seen.len
    var args: array[4, string]
    for g in p.fonts:
      if g.family != f.family: continue
      let i = case g.style
        of "bold": 1
        of "italic": 2
        of "bolditalic": 3
        else: 0
      let cn = "projectFont" & $n & ["Regular", "Bold", "Italic", "BoldItalic"][i]
      result.add "const " & cn & " = staticRead(" &
                 escape(unixPath(relativePath(p.resolve(g.file), mainDir))) & ")"
      args[i] = cn
    if args[0].len == 0:
      for a in args:
        if a.len > 0:
          args[0] = a
          break
    var call = "registerFontFamilyData(" & escape(f.family) & ", " & args[0]
    for (nm, a) in [("bold", args[1]), ("italic", args[2]), ("boldItalic", args[3])]:
      if a.len > 0 and a != args[0]: call.add ", " & nm & " = " & a
    calls.add call & ")"
  result.add calls

proc addFontFile*(p: Project, path: string): ProjectFont =
  ## Copies a `.ttf` / `.otf` into `<project>/fonts/` and records it. The family
  ## name and the bold/italic flags come from the font file (the file name when it
  ## names no family). Adding the same file again returns the existing entry.
  ## Saving the project and updating the main file (`syncFontsBlock`) is up to the caller.
  let ext = path.splitFile.ext.toLowerAscii
  if ext notin FontExts: raise newException(ProjectError, "not a .ttf or .otf file: " & path)
  if not fileExists(path): raise newException(ProjectError, "no such file: " & path)
  let info = fontFileInfo(path)
  if info.family.len == 0:
    raise newException(ProjectError, path & " is not a usable font file")
  let dest = p.dir / "fonts" / path.extractFilename
  let rel = p.relativeTo(dest)
  for f in p.fonts:
    if f.file == rel and fileExists(dest) and
       (normalizedPath(path) == normalizedPath(dest) or readFile(path) == readFile(dest)):
      return f
  if fileExists(dest) and normalizedPath(path) != normalizedPath(dest):
    raise newException(ProjectError, rel & " already exists in the project")
  createDir p.dir / "fonts"
  if normalizedPath(path) != normalizedPath(dest): copyFile(path, dest)
  result = ProjectFont(file: rel, family: info.family, style: styleName(info.style))
  p.fonts = p.fonts.filterIt(it.file != rel)
  p.fonts.add result

# ------------------------------------------------------------------ main file

proc editMain(p: Project, change: proc(src: string): string): bool =
  ## Applies `change` to the main file; true when the file changed.
  let f = p.mainPath
  if not fileExists(f): return false
  let src = readFile(f)
  let res = change(src)
  if res == src: return false
  writeFile(f, res)
  true

proc addToMain*(p: Project, u: ProjectUnit): bool {.discardable.} =
  ## Adds `import <unit>` to the main file and, for a form, its create line
  ## (only between the `nimvcl-ide:` markers, see `mainfile`). True when the
  ## file changed; false when it is missing or has no markers.
  let ft = if u.isForm: u.formType else: ""
  p.editMain(proc(src: string): string = mainfile.addUnit(src, u.name, ft))

proc removeFromMain*(p: Project, u: ProjectUnit): bool {.discardable.} =
  ## The reverse of `addToMain`.
  let ft = if u.isForm: u.formType else: ""
  p.editMain(proc(src: string): string = mainfile.removeUnit(src, u.name, ft))

proc syncFontsBlock*(p: Project): bool {.discardable.} =
  ## Rewrites the main file's `fonts` block from `p.fonts` (see `fontsBlockLines`).
  ## True when the file changed; false when it is missing or has no markers.
  let lines = p.fontsBlockLines
  p.editMain(proc(src: string): string = mainfile.setFonts(src, lines))

proc isMainForm*(p: Project, u: ProjectUnit): bool =
  ## Whether the unit's form is the one the main program shows.
  u.isForm and fileExists(p.mainPath) and
    mainfile.isMainForm(readFile(p.mainPath), u.formType)

proc removeUnit*(p: Project, name: string, deleteFiles = false) =
  ## Drops the unit from the project (and its import and create line from the
  ## main file, see `removeFromMain`); with `deleteFiles` its files go too.
  let i = p.findUnit(name)
  if i < 0: raise newException(ProjectError, "no unit " & name)
  let u = p.units[i]
  let kids = p.units.filterIt(it.ancestor == name).mapIt(it.name)
  if kids.len > 0:
    raise newException(ProjectError, "unit " & name & " is the ancestor of " &
                       kids.join(", ") & "; remove those forms first")
  p.units.delete i
  p.removeFromMain(u)
  if deleteFiles:
    for f in [p.nimPathOf(u), p.nfmPathOf(u)]:
      if f.len > 0 and fileExists(f): removeFile f

proc sourceFiles(p: Project): seq[string] =
  result.add p.mainPath
  for u in p.units: result.add p.nimPathOf(u)

proc renameUnit*(p: Project, oldName, newName: string) =
  ## Renames the unit and its files (same folder), then updates the `import` in
  ## the main file and the other units, and the .nfm path of its `loadForm`.
  ## The form type is not renamed.
  if not validName(newName): raise newException(ProjectError, "bad unit name " & newName)
  let i = p.findUnit(oldName)
  if i < 0: raise newException(ProjectError, "no unit " & oldName)
  if p.findUnit(newName) >= 0: raise newException(ProjectError, "unit " & newName & " already exists")
  var u = p.units[i]
  let oldNim = p.nimPathOf(u)
  let oldNfm = p.nfmPathOf(u)
  let newNim = oldNim.parentDir / newName & ".nim"
  let newNfm = if oldNfm.len > 0: oldNfm.parentDir / newName & ".nfm" else: ""
  for f in [newNim, newNfm]:
    if f.len > 0 and fileExists(f): raise newException(ProjectError, f & " already exists")
  if fileExists(oldNim): moveFile(oldNim, newNim)
  if oldNfm.len > 0 and fileExists(oldNfm): moveFile(oldNfm, newNfm)
  u.name = newName
  u.nimPath = p.relativeTo(newNim)
  if newNfm.len > 0: u.nfmPath = p.relativeTo(newNfm)
  p.units[i] = u
  if newNfm.len > 0:
    # forms that inherit from this one name its file: `ancestor = 'unit1.nfm'`
    for k in 0 ..< p.units.len:
      if p.units[k].ancestor != oldName: continue
      p.units[k].ancestor = newName
      let kidNfm = p.nfmPathOf(p.units[k])
      if kidNfm.len > 0 and fileExists(kidNfm):
        let src = readFile(kidNfm)
        let rel = unixPath(relativePath(newNfm, kidNfm.parentDir))
        let lines = src.split('\n')
        var outp: seq[string]
        for l in lines:
          if l.strip.startsWith("ancestor = "):
            outp.add l[0 ..< l.len - l.strip(trailing = false).len] & "ancestor = " & quoteNfm(rel)
          else: outp.add l
        let res = outp.join("\n")
        if res != src: writeFile(kidNfm, res)
  for f in p.sourceFiles:
    if not fileExists(f): continue
    var src = readFile(f)
    var out0 = renameImport(src, oldName, newName)
    if f == newNim and oldNfm.len > 0:
      out0 = renameLoadFormPath(out0, oldNfm.extractFilename, newNfm.extractFilename)
    if out0 != src: writeFile(f, out0)

proc renameProject*(p: Project, newName: string) =
  ## Renames the project: the `.nimproj` and, when it is named after the
  ## project, the main file move to the new name (same folder). Units are not
  ## touched; the program is built under the new name.
  if not validName(newName): raise newException(ProjectError, "bad project name " & newName)
  if newName == p.name: return
  if p.findUnit(newName) >= 0:
    raise newException(ProjectError, "unit " & newName & " already exists")
  let newProj = p.dir / newName & ProjectExt
  let renameMain = p.mainFile == p.name & ".nim"
  let newMain = p.dir / newName & ".nim"
  if fileExists(newProj): raise newException(ProjectError, newProj & " already exists")
  if renameMain and fileExists(newMain):
    raise newException(ProjectError, newMain & " already exists")
  let oldProj = p.filePath
  if renameMain:
    if fileExists(p.mainPath): moveFile(p.mainPath, newMain)
    p.mainFile = newName & ".nim"
  p.name = newName
  p.filePath = newProj
  p.save()
  if fileExists(oldProj): removeFile oldProj

proc nextFormNumber(p: Project): int =
  result = 1
  while true:
    var used = false
    for u in p.units:
      if u.name == "unit" & $result or u.formType == "Form" & $result: used = true
    if not used and not fileExists(p.dir / ("unit" & $result & ".nim")): return
    inc result

proc importModeOf(p: Project, src: string): string =
  ## A freshly generated file in the project's import mode (see `importAll`).
  if p.importAll: setImportAll(src, true) else: src

proc writeUnitFiles(p: Project, unit, form: string) =
  let vars = {"unit": unit, "form": form}
  writeFile(p.dir / unit & ".nim", p.importModeOf expand(tmplUnit, vars))
  writeFile(p.dir / unit & ".nfm", expand(tmplNfm, vars))

proc newFormUnit*(p: Project, name = ""): ProjectUnit =
  ## Adds `unitN.nim` / `unitN.nfm` (form `FormN`) and registers it; `name`
  ## chooses another unit name (the form type is then its capitalised form).
  ## The main file imports it and creates the form (`addToMain`).
  var unit = name
  var form: string
  if unit.len == 0:
    let n = p.nextFormNumber
    unit = "unit" & $n
    form = "Form" & $n
  else:
    if not validName(unit): raise newException(ProjectError, "bad unit name " & unit)
    form = unit.capitalizeAscii
    if form == unit: form &= "Form"
  if p.findUnit(unit) >= 0 or fileExists(p.dir / unit & ".nim") or
     fileExists(p.dir / unit & ".nfm"):
    raise newException(ProjectError, "unit " & unit & " already exists")
  p.writeUnitFiles(unit, form)
  result = p.addUnit(unit, unit & ".nim", unit & ".nfm", true, form)
  p.addToMain(result)

proc formUnits*(p: Project): seq[ProjectUnit] =
  ## The form units (what File > New Inherited Form offers as ancestors).
  for u in p.units:
    if u.isForm and u.formType.len > 0 and u.nfmPath.len > 0: result.add u

proc newInheritedFormUnit*(p: Project, ancestorUnit: string, name = ""): ProjectUnit =
  ## Adds a form unit that inherits from the form of `ancestorUnit`
  ## (`unitN.nim` / `unitN.nfm`, form `FormN`), registers it and puts it in the
  ## main file. The `.nfm` is only `inherited FormN: FormN` and the ancestor's
  ## file name; the `.nim` imports the ancestor unit and runs `loadForm`.
  let ancIdx = p.findUnit(ancestorUnit)
  if ancIdx < 0: raise newException(ProjectError, "no unit " & ancestorUnit)
  let anc = p.units[ancIdx]
  if not anc.isForm or anc.formType.len == 0 or anc.nfmPath.len == 0:
    raise newException(ProjectError, "unit " & ancestorUnit & " is not a form")
  if not fileExists(p.nfmPathOf(anc)):
    raise newException(ProjectError, "the form file of " & ancestorUnit & " is missing")
  var unit = name
  var form: string
  if unit.len == 0:
    let n = p.nextFormNumber
    unit = "unit" & $n
    form = "Form" & $n
  else:
    if not validName(unit): raise newException(ProjectError, "bad unit name " & unit)
    form = unit.capitalizeAscii
    if form == unit: form &= "Form"
  if p.findUnit(unit) >= 0 or fileExists(p.dir / unit & ".nim") or
     fileExists(p.dir / unit & ".nfm"):
    raise newException(ProjectError, "unit " & unit & " already exists")
  let rel = unixPath(relativePath(p.nfmPathOf(anc), p.dir))
  writeFile(p.dir / unit & ".nim",
            p.importModeOf expand(tmplInhNim, {"unit": unit, "form": form, "ancestor": anc.name,
                                               "ancestorForm": anc.formType}))
  writeFile(p.dir / unit & ".nfm",
            expand(tmplInhNfm, {"form": form, "ancestorNfm": rel}))
  result = p.addUnit(unit, unit & ".nim", unit & ".nfm", true, form, anc.name)
  p.addToMain(result)

proc newApplicationProject*(dir, name: string, nimvclPath = ""): Project =
  ## Creates `dir` (if needed) with `<name>.nimproj`, `<name>.nim`, a first
  ## form unit (`unit1.nim` / `unit1.nfm`) and a `nim.cfg`, and saves the project.
  if not validName(name): raise newException(ProjectError, "bad project name " & name)
  if name == "unit1": raise newException(ProjectError, "project name clashes with unit1")
  let d = absolutePath(dir)
  createDir d
  result = Project(filePath: d / name & ProjectExt, name: name, mainFile: name & ".nim",
                   outputDir: "build", nimvclPath: nimvclPath)
  let src = result.nimvclSrc
  let cfgPath = if src.len == 0: "../nimvcl/src" else: unixPath(relativePath(src, d))
  let u = result.newFormUnit()
  writeFile(d / result.mainFile,
            expand(tmplMain, {"name": name, "unit": u.name, "form": u.formType}))
  writeFile(d / "nim.cfg", expand(tmplCfg, {"nimvclPath": cfgPath}))
  result.save()

proc rewriteImports*(p: Project): seq[string] =
  ## Puts the program and every unit in the import mode of the project
  ## (`importAll`): `import nimvcl` or the prelude with the control imports of
  ## the form. Units and programs that never had the IDE's lines are left alone.
  ## Returns the files that changed; save open editors first and reload them after.
  for f in p.sourceFiles:
    if not fileExists(f): continue
    let src = readFile(f)
    var res = setImportAll(src, p.importAll)
    for u in p.units:
      if p.nimPathOf(u) == f and u.isForm and u.nfmPath.len > 0 and fileExists(p.nfmPathOf(u)):
        res = syncFromNfm(res, readFile(p.nfmPathOf(u)), p.nfmPathOf(u).parentDir, p.importAll)
    if res != src:
      writeFile(f, res)
      result.add f
