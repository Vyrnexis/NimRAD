## The Code Explorer window: a TreeView of what the active unit declares
## (`codeoutline`): the groups Types, Procs, Constants, Variables and Imports,
## each with its entries in source order. Double click or Enter on an entry
## calls `onJump(line)` (1-based). A group the user collapsed stays collapsed
## when the tree is rebuilt.

import std/[strutils, sets]
import nimvcl
import ./[codeoutline, icons]

type
  CodeExplorer* = ref object
    tree*: TreeView
    onJump*: proc(line: int)
    items*: seq[OutlineItem]      ## what the tree shows (node.tag = index, -1 for a group)
    collapsed: HashSet[string]    ## group names the user closed

const GroupNames: array[OutlineKind, string] =
  ["Imports", "Types", "Procs", "Constants", "Variables"]
const GroupOrder = [okType, okProc, okConst, okVar, okImport]

proc labelOf(it: OutlineItem): string =
  result = it.name & (if it.exported: "*" else: "")
  if it.detail.len > 0 and it.kind != okImport: result.add "  " & it.detail

proc groupName(n: TreeNode): string =
  ## "Types" for the node "Types (3)".
  let c = n.text.rfind(" (")
  if c > 0: n.text[0 ..< c] else: n.text

proc newCodeExplorer*(parent: Container, images: ImageList): CodeExplorer =
  result = CodeExplorer()
  let x = result
  x.tree = newTreeView(parent)
  x.tree.align = alClient
  x.tree.images = images
  x.tree.readOnly = true
  x.tree.showLines = false
  let open = proc() =
    let n = x.tree.selected
    if n != nil and n.tag >= 0 and n.tag < x.items.len and x.onJump != nil:
      x.onJump(x.items[n.tag].line)
  x.tree.onDblClick = proc(sender: Control) = open()
  x.tree.onKeyDown = proc(sender: Control, key: var Key, shift: ShiftState) =
    if key == keyEnter and shift == {}:
      open()
      key = Key(0)

proc setItems*(x: CodeExplorer, items: seq[OutlineItem]) =
  ## Rebuilds the tree.
  # remember which groups are closed
  x.collapsed.clear()
  for n in x.tree.items.topNodes:
    if n.tag == -1 and not n.expanded: x.collapsed.incl n.groupName
  x.items = items
  x.tree.beginUpdate()
  x.tree.items.clear()
  for g in GroupOrder:
    var idx: seq[int]
    for i, it in items:
      if it.kind == g: idx.add i
    if idx.len == 0: continue
    let root = x.tree.items.addChild(nil, GroupNames[g] & " (" & $idx.len & ")")
    root.tag = -1
    root.imageIndex = icProject
    root.selectedIndex = icProject
    for i in idx:
      let n = root.addChild(labelOf(items[i]))
      n.tag = i
      n.imageIndex = (case g
                      of okProc: icCompile
                      of okType: icFormUnit
                      of okImport: icAdd
                      else: icUnit)
      n.selectedIndex = n.imageIndex
    if GroupNames[g] notin x.collapsed: root.expand()
  x.tree.endUpdate()
