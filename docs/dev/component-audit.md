# Design-time component audit

What a Delphi 7 user expects to set at design time for each class on the
palette, and what was not possible. "Status" is the state as of NimRAD 0.2.0
with nimvcl 0.2.0 (rows marked 0.2.0 were closed in that release). Where a class is not listed, its registered properties
cover the usual set (position, size, align, anchors, font, color, caption or
text, enabled, visible, hint, tab order, events).

Problem kinds: *not registered* (no property in the registry), *no editor* (the
Inspector shows it but nothing edits it in the IDE), *not saved* (the `.nfm`
writer skips it), *not restored* (`loadNfm` / `loadForm` cannot read it),
*not painted* (set but not drawn by the control).

| Component | Property | Problem | Status |
|---|---|---|---|
| Image | picture | registered, but no editor in the IDE, not saved to the `.nfm`, `loadNfm` raised "cannot be set from a form file", `loadForm` could not build it | Fixed: picture dialog (Load..., Clear), saved as `picture = 'images/x.png'`, files copied into the project `images/`, `loadNfm` reads from disk, `loadForm` embeds the bytes; shown in the designer |
| ImageList | images | not registered: no way to add images | Fixed: image list dialog (thumbnails, Add of several files, Delete, Up, Down); saved as a list of relative paths; embedded by `loadForm` |
| ImageList | width, height | registered, drawn at that size | Works (every image is stretched into the logical size) |
| ToolBar | images | the drop-down listed the objects of the IDE window instead of the form's ImageLists (the design surface sits inside the IDE) | Fixed: the IDE supplies the form's components (`onGetChoices`); saved by name, resolved by both loaders |
| TreeView | images | same drop-down problem | Fixed |
| ListView | smallImages, largeImages | same drop-down problem | Fixed |
| MainMenu, PopupMenu, ActionList | images | same drop-down problem | Fixed |
| ToolButton | image | same as Image.picture | Fixed (same dialog and storage) |
| ToolButton | imageIndex | registered; needs the ToolBar's `images` link | Works once `images` is linked |
| ToolButton | glyph | code only (a draw proc) | Later |
| ToolBar | buttons | no way to create ToolButtons in the IDE (not on the palette) | Fixed: `buttons` collection editor (Add, Delete, Up, Down, inspector) |
| All controls | popupMenu | not a property (only `attachPopupMenu` in code) | Fixed: `popupMenu` property (drop-down of PopupMenus), saved as `popupMenu = name` |
| All controls | action | not registered | Fixed: drop-down of Actions, saved by name |
| MenuItem | action | not registered | Fixed |
| ListBox | items | registered, but "..." did nothing in the IDE | Fixed: string list dialog |
| ComboBox | items | same | Fixed |
| Memo | lines | same | Fixed |
| TabControl | tabs | same (class is not on the palette; PageControl is) | Fixed |
| PageControl | pages (TabSheet) | no way to add a page in the IDE; TabSheet is not on the palette | Fixed: `pages` collection editor; new sheets are named and captioned |
| StatusBar | panels | no way to add panels | Fixed: `panels` collection editor (also `deletePanel`, `movePanel` in the library) |
| ListView | columns | no way to add columns | Fixed: `columns` collection editor (also `columns.move`) |
| ListView | items | no property, no text form | Fixed as text: one row per line, cells separated by a tab; saved and restored by both loaders. Edited in the Items Editor |
| ListView | per-item imageIndex, checked | not stored | Fixed (0.2.0): `itemImages` and `checkedItems` string lists, edited in the Items Editor (image index, check state) |
| TreeView | items (nodes) | no property, no text form | Fixed as an outline, two spaces per level; saved and restored by both loaders. Edited in the Items Editor (Add, Add child, Indent, Outdent, Up, Down) |
| TreeView | node imageIndex, selectedIndex, checked | not stored | Fixed (0.2.0): `itemImages`, `itemSelectedImages`, `checkedItems` |
| TreeView | node expanded | not stored | Later (by design: expansion is a run-time state) |
| MainMenu | items | no menu editor in the IDE: items could not be added | Fixed: `items` collection editor (sub-items open another editor); items are named and captioned |
| MainMenu | (palette drop) | dropping it created a bar inside the form that only became a tile after a reload | Fixed: it is a tile at once, like the other non-visual components |
| PopupMenu | items | no editor | Fixed (same collection editor) |
| ActionList | actions | no way to add Actions | Fixed: `actions` collection editor (no reordering) |
| Action | caption, hint, imageIndex, shortcut, category, ... | registered | Works; `imageIndex` needs the ActionList's `images` link |
| All controls | font.color | the text colour could not be set (`Label.textColor` only) | Fixed: `font.color` is a part of `font` (shown under it in the inspector, written only when set); `textColor` is a deprecated alias and an old `textColor` line still loads |
| All controls | color | only some controls painted their own `color` | Fixed: every control with a background fills with it |
| Label | textRole | not registered (theme colour role) | Later |
| Panel, GroupBox | caption colour | `textColor` was not registered | Fixed: `font.color` (Panel caption; GroupBox caption too) |
| Edit | passwordChar | not registered (`password` is) | Fixed (0.2.0): a one-character string property; `password = true` stays the bullet |
| Edit | textHint | alias of `placeholder`, which is registered | Works |
| Button | images, imageIndex, imageAlignment | the control had no image support | Fixed (0.2.0): `images` (drop-down of the form's ImageLists), `imageIndex`, `imageAlignment` |
| Button, CheckBox, RadioButton | action | see All controls | Fixed |
| StringGrid | cells | no property, not stored | Fixed (0.2.0): `cells` string list (one row per entry, cells separated by a tab, fixed row and column titles included), cell editor dialog; OK also sets `colCount` and `rowCount` |
| StringGrid, DrawGrid | per-column widths, per-row heights | not stored | Fixed (0.2.0): `colWidths` and `rowHeights` as comma separated lists |
| CodeEdit | highlighter | code only; `language` / `autoHighlighter` are registered | Later |
| Form | menu, icon | no such properties (a MainMenu is a child of the form) | Fixed (0.2.0): `menu` (drop-down of MainMenus; a MainMenu that is a child of the form is its menu already and is not written), `icon` (picture dialog, becomes the window icon) |
| Form | keyPreview | not registered | Later |
| ScrollBar, TrackBar, ProgressBar, SpinEdit, CheckBox, RadioButton, GroupBox, Bevel, PaintBox, ScrollBox, Splitter, Timer | | all usual properties and events are registered, saved and restored | No gap found |

## What "Fixed" means for the files

* `.nfm`: pictures are paths relative to the `.nfm` (forward slashes); lists of
  images are lists of such paths. An image made in memory has no path and is
  not written.
* `loadNfm` / `loadNfmFile` read pictures from disk next to the `.nfm`; a
  missing file gives a warning and a blank stand-in that keeps the path.
* `loadForm` embeds the picture files in the program when it is compiled.
* The designer shows the pictures at once (the Image control paints its
  picture; an ImageList's icons show in the controls that use it).

## Left for later

Expansion of TreeView nodes (a run-time state); `Label.textRole`;
`ToolButton.glyph`; `CodeEdit.highlighter`; `Form.keyPreview`.
