## The Project Manager: a TreeView with the project as the root and its units
## below it (form units carry a window icon). Double click or Enter on a unit
## calls `onOpenUnit(unitName)`, on the project node `onOpenMain()` (the
## program file).

import nimvcl
import ./[project, icons]

type
  ProjectTree* = ref object
    tree*: TreeView
    onOpenUnit*: proc(unitName: string)
    onOpenMain*: proc()
    unitNames: seq[string]        ## node.tag = index into this

proc newProjectTree*(parent: Container, images: ImageList): ProjectTree =
  result = ProjectTree()
  let t = result
  t.tree = newTreeView(parent)
  t.tree.align = alClient
  t.tree.images = images
  t.tree.readOnly = true
  t.tree.showLines = false
  let open = proc() =
    let n = t.tree.selected
    if n != nil and n.tag >= 0 and n.tag < t.unitNames.len and t.onOpenUnit != nil:
      t.onOpenUnit(t.unitNames[n.tag])
    elif n != nil and n.tag == -1 and n.parent == nil and t.onOpenMain != nil:
      t.onOpenMain()
  t.tree.onDblClick = proc(sender: Control) = open()
  t.tree.onKeyDown = proc(sender: Control, key: var Key, shift: ShiftState) =
    if key == keyEnter and shift == {}:
      open()
      key = Key(0)

proc refresh*(t: ProjectTree, p: Project) =
  ## Rebuilds the tree (keeps the selected unit selected when it still exists).
  let keep = t.tree.selected
  var keepName = ""
  if keep != nil and keep.tag >= 0 and keep.tag < t.unitNames.len: keepName = t.unitNames[keep.tag]
  t.tree.beginUpdate()
  t.tree.items.clear()
  t.unitNames.setLen 0
  if p != nil:
    let root = t.tree.items.addChild(nil, p.name & " (" & p.mainFile & ")")
    root.imageIndex = icProject
    root.selectedIndex = icProject
    root.tag = -1
    for u in p.units:
      let label = if u.isForm: u.name & " (" & u.formType & ")" else: u.name
      let n = root.addChild(label)
      n.tag = t.unitNames.len
      n.imageIndex = if u.isForm: icFormUnit else: icUnit
      n.selectedIndex = n.imageIndex
      if u.name == keepName: t.tree.selected = n
      t.unitNames.add u.name
    root.expand()
  t.tree.endUpdate()

proc unitOfNode(t: ProjectTree, n: TreeNode): string =
  if n != nil and n.tag >= 0 and n.tag < t.unitNames.len: t.unitNames[n.tag] else: ""

proc nodeOf*(t: ProjectTree, name: string): TreeNode =
  ## The node of unit `name` (nil when there is none).
  let root = t.tree.items.top(0)
  if root == nil: return nil
  for n in root.children:
    if t.unitOfNode(n) == name: return n

proc selectedUnit*(t: ProjectTree): string = t.unitOfNode(t.tree.selected)

proc selectUnit*(t: ProjectTree, name: string) =
  ## Selects the node of `name` (no `onOpenUnit`).
  let n = t.nodeOf(name)
  if n != nil: t.tree.selected = n

proc unitCount*(t: ProjectTree): int = t.unitNames.len

