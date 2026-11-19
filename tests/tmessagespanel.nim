## The Messages window: a right click selects the row under the mouse before
## the context menu opens, so Quick Fix acts on that message.
import std/[unittest, os]
import nimvcl
import ide/[messagespanel, messages, icons, quickfix]

if not existsEnv("SDL_VIDEO_DRIVER"): putEnv("SDL_VIDEO_DRIVER", "offscreen")
putEnv("SDL_RENDER_DRIVER", "software")

Application.init()
let host = newForm(nil, 900, 400)
host.show()
let panel = newMessagesPanel(host, makeIdeIcons())
panel.root.align = alClient
host.syncMetrics()

proc fire(kind: EventKind, p: PointF, button: MouseButton) =
  Application.dispatch(PlatformEvent(kind: kind, windowId: host.win.id, x: p.x, y: p.y,
                                     button: button, clicks: 1))

proc rightClick(p: PointF) =
  discard host.paintIfDirty()
  fire(ekMouseDown, p, mbRight)
  fire(ekMouseUp, p, mbRight)
  Application.processMessages(0)
  # close the context menu again
  Application.dispatch(PlatformEvent(kind: ekKeyDown, windowId: host.win.id, key: keyEscape))
  Application.processMessages(0)

proc rowCentre(i: int): PointF =
  let r = panel.list.itemRect(i)
  panel.list.clientToForm(pointF(r.x + 40, r.y + r.h / 2))

suite "Messages context menu":
  test "a right click selects the row under the mouse":
    panel.feedLines(@["/p/unit1.nim(3, 5) Error: undeclared identifier: 'a'",
                      "/p/unit1.nim(4, 5) Error: undeclared identifier: 'b'",
                      "/p/unit1.nim(5, 5) Error: undeclared identifier: 'c'"])
    panel.finish()
    check panel.msgs.len == 3
    check panel.selectedMessage == -1
    discard host.paintIfDirty()
    rightClick(rowCentre(1))
    check panel.selectedMessage == 1
    rightClick(rowCentre(2))
    check panel.selectedMessage == 2
    rightClick(rowCentre(0))
    check panel.selectedMessage == 0

  test "a right click below the rows clears the selection":
    panel.list.itemIndex = 1
    let r = panel.list.itemRect(2)
    rightClick(panel.list.clientToForm(pointF(r.x + 40, r.bottom + 60)))
    check panel.selectedMessage == -1

  test "the fixes offered are those of the right-clicked row":
    panel.fixes[1] = @[QuickFix(kind: fkAddImport, title: "Add import x", ident: "b", modules: @["x"])]
    rightClick(rowCentre(1))
    check panel.selectedMessage == 1
    check panel.fixesOf(panel.selectedMessage).len == 1
