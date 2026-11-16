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
##      "isForm": true, "formType": "Form1"}
##   ],
##   "outputDir": "build",
##   "nimFlags": ["-d:release"],
##   "runArgs": [],
##   "nimvclPath": ""
## }
## ```
##
## * Every path is stored relative to the folder of the `.nimproj`
##   (forward slashes); `resolve` gives the absolute path. Absolute paths that
##   are given to the API are converted on the way in.
## * `outputDir` defaults to `build`.
## * `nimvclPath` is the nimvcl `src` folder; empty means "detect"
##   (`detectNimvclPath`: `$NIMVCL_SRC`, then `../nimvcl/src` next to the IDE
##   checkout, next to the IDE binary, and next to the current directory).
## * Missing fields take their defaults when loading; unknown fields are dropped.
##
## Files of a new project come from `templates/` (read at compile time) with
## `${placeholder}` substitution.

import std/[json, os, strutils, sequtils]
import ./codegen

const
  ProjectExt* = ".nimproj"
  tmplMain = staticRead("../../templates/main.nim.tmpl")
  tmplUnit = staticRead("../../templates/unit.nim.tmpl")
  tmplNfm = staticRead("../../templates/unit.nfm.tmpl")
  tmplCfg = staticRead("../../templates/nim.cfg.tmpl")
  ideRoot = currentSourcePath().parentDir.parentDir.parentDir

type
  ProjectError* = object of CatchableError

  ProjectUnit* = object
    name*: string        ## module name, `unit1`
    nimPath*: string     ## relative to the project folder
    nfmPath*: string     ## "" for a plain unit
    isForm*: bool
    formType*: string    ## `Form1` for a form unit

  Project* = ref object
    filePath*: string    ## absolute path of the .nimproj
    name*: string
    mainFile*: string
    units*: seq[ProjectUnit]
    outputDir*: string
    nimFlags*: seq[string]
    runArgs*: seq[string]
    nimvclPath*: string  ## "" = detect

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
  ## The nimvcl `src` folder, or "" when none is found.
  var cands: seq[string]
  let env = getEnv("NIMVCL_SRC")
  if env.len > 0: cands.add env
  cands.add ideRoot.parentDir / "nimvcl" / "src"
  cands.add getAppDir().parentDir / "nimvcl" / "src"
  cands.add getAppDir().parentDir.parentDir / "nimvcl" / "src"
  cands.add getCurrentDir().parentDir / "nimvcl" / "src"
  for c in cands:
    if fileExists(c / "nimvcl.nim"): return normalizedPath(c)

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
  %*{"version": 1, "name": p.name, "mainFile": p.mainFile, "units": us,
     "outputDir": p.outputDir, "nimFlags": p.nimFlags, "runArgs": p.runArgs,
     "nimvclPath": p.nimvclPath}

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
                   nimFlags: j.strs("nimFlags"), runArgs: j.strs("runArgs"),
                   nimvclPath: j.str("nimvclPath", ""))
  if result.mainFile.len == 0: result.mainFile = result.name & ".nim"
  if result.outputDir.len == 0: result.outputDir = "build"
  if j.hasKey("units") and j["units"].kind == JArray:
    for e in j["units"]:
      if e.kind != JObject: continue
      var u = ProjectUnit(name: e.str("name", ""), nimPath: e.str("nim", ""),
                          nfmPath: e.str("nfm", ""), formType: e.str("formType", ""))
      u.isForm = e.hasKey("isForm") and e["isForm"].kind == JBool and e["isForm"].getBool
      if u.name.len > 0 and u.nimPath.len > 0: result.units.add u

# ------------------------------------------------------------------- editing

proc addUnit*(p: Project, name, nimPath: string, nfmPath = "", isForm = false,
              formType = ""): ProjectUnit =
  ## Registers a unit (paths absolute or relative to the project folder).
  if p.findUnit(name) >= 0:
    raise newException(ProjectError, "unit " & name & " already exists")
  result = ProjectUnit(name: name, nimPath: p.relativeTo(nimPath),
                       nfmPath: (if nfmPath.len > 0: p.relativeTo(nfmPath) else: ""),
                       isForm: isForm or nfmPath.len > 0, formType: formType)
  p.units.add result

proc removeUnit*(p: Project, name: string, deleteFiles = false) =
  ## Drops the unit from the project; with `deleteFiles` its files go too.
  let i = p.findUnit(name)
  if i < 0: raise newException(ProjectError, "no unit " & name)
  let u = p.units[i]
  p.units.delete i
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
  for f in p.sourceFiles:
    if not fileExists(f): continue
    var src = readFile(f)
    var out0 = renameImport(src, oldName, newName)
    if f == newNim and oldNfm.len > 0:
      out0 = renameLoadFormPath(out0, oldNfm.extractFilename, newNfm.extractFilename)
    if out0 != src: writeFile(f, out0)

proc nextFormNumber(p: Project): int =
  result = 1
  while true:
    var used = false
    for u in p.units:
      if u.name == "unit" & $result or u.formType == "Form" & $result: used = true
    if not used and not fileExists(p.dir / ("unit" & $result & ".nim")): return
    inc result

proc writeUnitFiles(p: Project, unit, form: string) =
  let vars = {"unit": unit, "form": form}
  writeFile(p.dir / unit & ".nim", expand(tmplUnit, vars))
  writeFile(p.dir / unit & ".nfm", expand(tmplNfm, vars))

proc newFormUnit*(p: Project, name = ""): ProjectUnit =
  ## Adds `unitN.nim` / `unitN.nfm` (form `FormN`) and registers it; `name`
  ## chooses another unit name (the form type is then its capitalised form).
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
