# Views

Property views a new `.base` file can start from. Ryra lists them under
**New view** and in `ryra catalog --views`, and
`ryra files --create NAME --view ryra/tasks` makes one from the command line.

Each folder is one template:

- `view.base`: the view itself, an Obsidian Bases file.
- `view.json`: its `title` and one-line `summary`.
- `preview.png`: the picture on its card, about 720 pixels wide.
- `sample/`: the notes the preview is drawn from. A sample may write `{{month}}`
  for the month the preview is taken in, so a calendar shows them, and
  `{{today}}` for its day, or `{{today+3}}` for three days after it.

`view.json` may also give an `order`: Ryra lists those with one first, lowest
first, and the rest by name.

Inside an Obsidian vault a view reads the whole vault, so each template filters
on a `type` property, which a note added from the view is given, or, as Todo
does, on `file.inFolder(this.file.folder)`, the folder the view is in.

`bash scripts/catalog.sh` publishes the folders into `catalog.json`. A preview
is a screenshot of Ryra drawing `view.base` over `sample/`, cropped to the view.
