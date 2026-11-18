## Which nimvcl module declares a symbol: the lookup over the generated
## `symbolindex` (see `symbolscan`).

import std/[strutils, tables]
import ./symbolindex

var table: Table[string, seq[string]]

proc buildTable() =
  for (m, names) in symbolIndexData:
    for n in names.split(' '):
      if n.len > 0:
        table.mgetOrPut(n, @[]).add m

proc modulesFor*(name: string): seq[string] =
  ## The modules (`nimvcl/controls/edit`, sorted) that declare `name`; empty
  ## when none does.
  if table.len == 0: buildTable()
  table.getOrDefault(name)

proc symbolCount*(): int =
  if table.len == 0: buildTable()
  table.len
