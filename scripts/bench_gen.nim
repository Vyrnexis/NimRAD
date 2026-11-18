## Helper of bench_build.sh: generates a small project the way the IDE does
## (a new application project, then a form with a Label, an Edit, a Button and
## an ImageList with one picture) into the folder given as the first argument.
import std/[os, strutils]
import ide/[project, unitimports]

const nfm = """object Form1: Form
  width = 640
  height = 480
  caption = 'Form1'
  object label1: Label
    left = 16
    top = 16
    caption = 'Name:'
  end
  object edit1: Edit
    left = 16
    top = 40
    width = 200
    text = 'hello'
  end
  object button1: Button
    left = 16
    top = 80
    caption = 'OK'
    onClick = button1Click
  end
  object imageList1: ImageList
    width = 16
    height = 16
    images = (
      'red.png'
    )
  end
end
"""

proc main() =
  let dir = paramStr(1)
  removeDir dir
  discard newApplicationProject(dir, "benchapp")
  writeFile(dir / "unit1.nfm", nfm)
  copyFile(currentSourcePath.parentDir.parentDir / "tests" / "fixtures" / "red.png",
           dir / "red.png")
  let u = dir / "unit1.nim"
  var src = readFile(u)
  src.add "\nproc button1Click(self: Form1, sender: Control) = discard\n"
  # the IDE keeps the control imports in sync when it saves a unit
  writeFile(u, syncFromNfm(src, nfm))

main()
