## Design-time property editors in the IDE: pictures, image lists, string
## lists, collections and component references, through the Object Inspector
## and the unit editor (headless; the dialogs are driven through their procs).

import std/[unittest, os, osproc, strutils, sequtils]
import headless
import nimvcl
import nimvcl/dsl/[props, props_std]
import nimvcl/controls/[inspector, propeditors]
import ide/[project, builder, uniteditor]

let root = getTempDir() / ("nvide-designprops-" & $getCurrentProcessId())
removeDir root
createDir root
const fixtures = currentSourcePath().parentDir / "fixtures"

Application.init()

proc newHost(): Form =
  result = newForm(nil, 1100, 700)
  result.show()
  result.syncMetrics()

proc click(f: Form, p: PointF, clicks = 1) =
  discard f.paintIfDirty()
  for k in [ekMouseDown, ekMouseUp]:
    Application.dispatch(PlatformEvent(kind: k, windowId: f.win.id, x: p.x, y: p.y,
                                       button: mbLeft, clicks: clicks))

proc find(e: UnitEditor, name: string): Component =
  for (c, _) in e.componentTree:
    if c.name == name: return c

type Rig = object
  host: Form
  proj: Project
  ed: UnitEditor
  insp: ObjectInspector

proc rig(name: string): Rig =
  result.proj = newApplicationProject(root / name, name)
  result.host = newHost()
  result.ed = newUnitEditor(result.proj, "unit1", result.host)
  result.insp = newObjectInspector(result.host)
  result.insp.align = alRight
  result.insp.width = 300
  result.ed.bindInspector(result.insp)
  discard result.host.paintIfDirty()

proc drop(r: Rig, cls: string, dx = 40'f32, dy = 40'f32) =
  let body = r.ed.designedForm
  r.ed.beginCreate cls
  r.host.click(pointF(body.formOrigin.x + dx, body.formOrigin.y + dy))

proc pick(r: Rig, run: proc(d: Form): ModalResult) =
  r.ed.propHost.runModal = run

suite "pictures in the designer":
  test "Image: pick a file, it is copied to images/, shown, saved relative":
    let r = rig("pic1")
    r.drop "Image"
    let im = ImageControl(r.ed.find("Image1"))
    check im != nil and im.picture == nil
    check r.insp.valueTextOf("picture") == "(none)"
    r.pick proc(d: Form): ModalResult =
      check PictureDlgForm(d).loadFile(fixtures / "red.png")
      mrOk
    r.insp.beginEdit("picture")
    check im.picture != nil
    check im.picture.width == 4 and im.picture.height == 3
    check im.picture.source == "images/red.png"
    check fileExists(r.proj.dir / "images" / "red.png")
    check r.insp.valueTextOf("picture") == "images/red.png"
    check r.insp.isBold("picture")
    check r.ed.modified
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nfm").contains("picture = 'images/red.png'")
    # reopening the files shows it again
    r.ed.reloadFromDisk()
    let again = ImageControl(r.ed.find("Image1"))
    check again.picture != nil and again.picture.width == 4

  test "a picture already inside the project is not copied twice":
    let r = rig("pic2")
    createDir r.proj.dir / "art"
    copyFile(fixtures / "blue.png", r.proj.dir / "art" / "b.png")
    r.drop "Image"
    r.pick proc(d: Form): ModalResult =
      PictureDlgForm(d).loadFile(r.proj.dir / "art" / "b.png")
      mrOk
    r.insp.beginEdit("picture")
    check ImageControl(r.ed.find("Image1")).picture.source == "art/b.png"
    check not dirExists(r.proj.dir / "images")

  test "Clear removes the picture and the line in the file":
    let r = rig("pic3")
    r.drop "Image"
    r.pick proc(d: Form): ModalResult =
      PictureDlgForm(d).loadFile(fixtures / "green.png")
      mrOk
    r.insp.beginEdit("picture")
    r.pick proc(d: Form): ModalResult =
      PictureDlgForm(d).clearPicture()
      mrOk
    r.insp.beginEdit("picture")
    check ImageControl(r.ed.find("Image1")).picture == nil
    r.ed.save()
    check not readFile(r.proj.dir / "unit1.nfm").contains("picture")

  test "a missing picture file is reported, the path survives a save":
    let r = rig("pic4")
    r.drop "Image"
    r.pick proc(d: Form): ModalResult =
      PictureDlgForm(d).loadFile(fixtures / "red.png")
      mrOk
    r.insp.beginEdit("picture")
    r.ed.save()
    removeDir r.proj.dir / "images"
    var msgs: seq[string]
    r.ed.onMessage = proc(e: UnitEditor, m: string) = msgs.add m
    r.ed.reloadFromDisk()
    check msgs.anyIt("red.png" in it)
    r.ed.designer.select(Control(r.ed.find("Image1")))
    check r.insp.setValue("stretch", pvBool(true))
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nfm").contains("picture = 'images/red.png'")

  test "the built program has the picture without the files":
    let r = rig("pic5")
    r.drop "Image"
    r.pick proc(d: Form): ModalResult =
      PictureDlgForm(d).loadFile(fixtures / "red.png")
      mrOk
    r.insp.beginEdit("picture")
    # the code checks the picture when the form is shown
    r.ed.designer.select(Control(r.ed.designedForm))
    r.insp.tab = itEvents
    r.insp.selectProp("onShow")
    r.insp.dispatchDouble(r.insp.indexOfProp("onShow"))
    r.ed.save()
    writeFile(r.proj.dir / "unit1.nim", readFile(r.proj.dir / "unit1.nim").replace(
      "sender: Control) =",
      "sender: Control) =\n  doAssert self.Image1.picture != nil and self.Image1.picture.width == 4\n  echo \"picture ok\""))
    let res = r.proj.compileProjectSync()
    if not res.ok: echo res.lines.join("\n")
    check res.ok
    removeDir r.proj.dir / "images"
    let (o, c) = headlessCmd(quoteShell(r.proj.exePath) & " --smoke")
    check c == 0
    check "picture ok" in o

suite "image lists in the designer":
  test "ImageList: images property, ToolBar link, saved and built":
    let r = rig("il1")
    r.ed.beginCreate "ImageList"
    let il = ImageList(r.ed.find("ImageList1"))
    r.drop "ToolBar", 10, 10
    r.ed.designer.select(Control(r.ed.find("ToolBar1")))
    check r.insp.setValue("images", pvObject(Obj(il), "ImageList1"))
    r.ed.selectComponent(il)
    r.pick proc(d: Form): ModalResult =
      let dd = ImageListDlgForm(d)
      dd.addFiles([fixtures / "red.png", fixtures / "blue.png"])
      mrOk
    r.insp.beginEdit("images")
    check il.count == 2
    check il.image(1).source == "images/blue.png"
    r.ed.save()
    let nfm = readFile(r.proj.dir / "unit1.nfm")
    check nfm.contains("object ImageList1: ImageList")
    check nfm.contains("'images/red.png'")
    check nfm.contains("images = ImageList1")
    let res = r.proj.compileProjectSync()
    if not res.ok: echo res.lines.join("\n")
    check res.ok
    r.ed.reloadFromDisk()
    check ImageList(r.ed.find("ImageList1")).count == 2
    check ToolBar(r.ed.find("ToolBar1")).images == ImageList(r.ed.find("ImageList1"))

suite "lists and collections in the designer":
  test "ListBox items through the string list editor":
    let r = rig("sl1")
    r.drop "ListBox"
    r.pick proc(d: Form): ModalResult =
      StringListDlgForm(d).memo.text = "alpha\nbeta\ngamma"
      mrOk
    r.insp.beginEdit("items")
    check ListBox(r.ed.find("ListBox1")).items.len == 3
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nfm").contains("'beta'")
    check r.proj.compiles()

  test "StatusBar panels, PageControl pages, menu items from the collection editor":
    let r = rig("col1")
    r.drop "StatusBar", 10, 10
    r.pick proc(d: Form): ModalResult =
      let c = CollectionDlgForm(d)
      c.addItem()
      c.insp.setValue("text", pvString("Ready"))
      c.addItem()
      mrOk
    r.insp.beginEdit("panels")
    check StatusBar(r.ed.find("StatusBar1")).panels.len == 2
    r.drop "PageControl", 10, 120
    r.ed.designer.select(Control(r.ed.find("PageControl1")))
    r.pick proc(d: Form): ModalResult =
      let c = CollectionDlgForm(d)
      c.addItem()
      c.addItem()
      mrOk
    r.insp.beginEdit("pages")
    let pc = PageControl(r.ed.find("PageControl1"))
    check pc.sheets.len == 2
    check pc.sheets[0].name == "TabSheet1" and pc.sheets[0].caption == "TabSheet1"
    check r.ed.find("TabSheet2") != nil              # named, part of the tree
    r.ed.beginCreate "MainMenu"
    r.pick proc(d: Form): ModalResult =
      let c = CollectionDlgForm(d)
      c.addItem()
      c.insp.setValue("caption", pvString("File"))
      mrOk
    r.insp.beginEdit("items")
    check MainMenu(r.ed.find("MainMenu1")).items.count == 1
    check r.ed.find("MenuItem1") != nil
    r.ed.save()
    let nfm = readFile(r.proj.dir / "unit1.nfm")
    check nfm.contains("object: StatusPanel") and nfm.contains("text = 'Ready'")
    check nfm.contains("object TabSheet2: TabSheet")
    check nfm.contains("object MenuItem1: MenuItem") and nfm.contains("caption = 'File'")
    check r.proj.compiles()
    r.ed.reloadFromDisk()
    check PageControl(r.ed.find("PageControl1")).sheets.len == 2
    check MainMenu(r.ed.find("MainMenu1")).items[0].caption == "File"

  test "ListView columns and items":
    let r = rig("col2")
    r.drop "ListView", 10, 10
    r.pick proc(d: Form): ModalResult =
      let c = CollectionDlgForm(d)
      c.addItem()
      c.insp.setValue("caption", pvString("Name"))
      c.addItem()
      c.insp.setValue("caption", pvString("Size"))
      mrOk
    r.insp.beginEdit("columns")
    r.pick proc(d: Form): ModalResult =          # the ListView Items Editor
      let dd = ItemsDlgForm(d)
      dd.addItem()
      dd.capEdit.text = "a.txt"
      dd.subMemo.text = "10"
      dd.addItem()
      dd.capEdit.text = "b.txt"
      dd.subMemo.text = "20"
      mrOk
    r.insp.beginEdit("items")
    let lv = ListView(r.ed.find("ListView1"))
    check lv.columns.len == 2 and lv.items.count == 2
    check lv.itemLines == @["a.txt\t10", "b.txt\t20"]
    r.ed.save()
    check r.proj.compiles()

  test "popupMenu and action links are chosen from the form's components":
    let r = rig("ref1")
    r.ed.beginCreate "PopupMenu"
    r.drop "Button"
    let b = Button(r.ed.find("Button1"))
    r.ed.designer.select(Control(b))
    check r.insp.beginEdit("popupMenu")
    let cb = r.insp.editCombo
    check cb.items.len == 2 and cb.items[1] == "PopupMenu1"
    cb.itemIndex = 1
    check r.insp.commitEdit()
    check b.popupMenu == PopupMenu(r.ed.find("PopupMenu1"))
    r.ed.save()
    check readFile(r.proj.dir / "unit1.nfm").contains("popupMenu = PopupMenu1")
    check r.proj.compiles()

suite "colours in the designer":
  test "color and font.color set in the inspector are saved to the .nfm and compile":
    let r = rig("fc1")
    r.drop "Panel"
    r.drop "Label", 60, 200
    let p = Panel(r.ed.find("Panel1"))
    let l = Label(r.ed.find("Label1"))
    r.ed.designer.select(Control(p))
    check r.insp.setValue("color", pvColor(hex"#336699"))
    check p.color == hex"#336699" and not p.parentColor
    check r.insp.isBold("color")
    r.ed.designer.select(Control(l))
    r.insp.setExpanded("font", true)
    check r.insp.setValue("font.color", pvColor(hex"#aa0000"))
    check l.fontColor == hex"#aa0000"
    check r.insp.valueTextOf("font.color").toLowerAscii.contains("aa0000")
    check r.insp.indexOfProp("textColor") < 0
    check r.ed.modified
    r.ed.save()
    let nfm = readFile(r.proj.dir / "unit1.nfm")
    check nfm.contains("color = #336699")
    check nfm.contains("font.color = #aa0000")
    check nfm.count("font.color") == 1          # nothing else gets a font colour
    check not nfm.contains("textColor")
    check r.proj.compiles()
    # reopening the files shows both again
    r.ed.reloadFromDisk()
    check Panel(r.ed.find("Panel1")).color == hex"#336699"
    check Label(r.ed.find("Label1")).fontColor == hex"#aa0000"
