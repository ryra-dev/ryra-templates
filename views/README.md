# Views

Property views a new `.base` file can start from. Ryra lists them under
**New view** and in `ryra catalog --views`, and
`ryra files --create NAME --view ryra/tasks` makes one from the command line.

Each folder is one template:

- `view.base`: the view itself, an Obsidian Bases file.
- `view.json`: its `title` and one-line `summary`.
- `preview.png`: the picture on its card, about 720 pixels wide.
- `sample/`: the notes the preview is drawn from. A sample writes a date as
  `{{today}}` for the day the preview is taken, or `{{today+3}}` and
  `{{today-2}}` for days after and before it.

`view.json` may also give an `order`: Ryra lists those with one first, lowest
first, and the rest by name.

Each template lists the notes in the folder its view is in,
`file.inFolder(this.file.folder)`, so a note made by quick add, by an agent or
in another app is on it without anything written in it. Inside an Obsidian
vault a view would otherwise read the whole vault.

Templates use Ryra's own properties for what Ryra reads, as `ryra files
--property-help` lists them: `due` for a date somebody has to act on, whatever
its column is called, `done`, `priority`, `assignee` and `tags`. A note reminds
while it is on its view's first view, so a template with `due` leaves what is
finished out of its first view.

`bash scripts/catalog.sh` publishes the folders into `catalog.json`. A preview
is a screenshot of Ryra drawing `view.base` over `sample/`, cropped to the view.
