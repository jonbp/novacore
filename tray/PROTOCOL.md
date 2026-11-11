# Tray icon protocol

Novacore has four tray icons: the Linux tray icon (`tray/linux/novacore-tray.py`), the KDE Plasma widget, which takes its place in Plasma's system tray (`tray/plasmoid/`), the macOS menu bar icon (`tray/macos/NovacoreTray.swift`) and the Windows tray icon (`tray/windows/novacore-tray.ps1`). Each one only draws things and carries out actions. The CLI decides what goes in the menu, what each item does, where it goes in a panel and which dialogs to show, so most new features only need a change in `bin/novacore`. Every icon picks it up straight away.

## Adding a feature

1. **A menu item that runs a command:** add it in `tray_menu` in `bin/novacore`, with `act_run` for its action, and pass it to the `add_` or `sub_` function for where it goes (see "Building the menu" below). That's all. Every icon shows it, greys it out while another command runs (`idle`), and notifies you when it finishes.
2. **A dialog that asks for something:** describe it as a form (see below), with an action that runs `tray submit <form>`. Then add a case to `tray_submit` that turns the answers into the real command.
3. **Something an icon can't do yet**, such as a new kind of action, field or block: add it to every icon and document it here. Keep the description generic, so the next feature that needs it can use it too.

To see what the icons get, run `novacore tray menu | python3 -m json.tool`.

## Building the menu

`tray_menu` says once what each item is for, and gets both the menu's `items` and the `panel` from that:

| Function | Menu | Panel |
|---|---|---|
| `add_main ITEM` | The first item. | What clicking the heading does. |
| `add_section LABEL` | A separator with a heading. | A heading. |
| `add_divider` | A separator. | A line. |
| `add_row ITEM` | An item. | A row. |
| `add_button ITEM` | An item. | A button. Ones added one after another share a row. |
| `add_own ITEM` | An item. | A button along the bottom. |
| `sub_start`, then `sub_` functions, then `add_card LABEL` | A submenu. | A row that expands into a card. |
| `sub_start`, then `sub_choice`s, then `add_picker LABEL` | A submenu. | A row that opens the options as a menu. |

Inside a submenu: `sub_main` (a button on the row, such as a site's Open), `sub_link` (a link), `sub_break` (a separator: the next links start a new line), `sub_choices LABEL` and `sub_choice` (a separator, then options to pick one of), and `sub_danger` (a button at the bottom, such as Remove).

## Commands

| Command | Output |
|---|---|
| `tray menu` | The menu, as JSON (see below). It exits 0 even when Docker is unreachable, and says why in `problem`. |
| `tray run LABEL DONE ARGS…` | Runs `novacore ARGS…` detached, so it finishes even if the icon quits. It fails if another command from the tray is still running. |
| `tray poll` | The running command's state, one item per line: the exit code (blank while it runs), `alive` or `dead`, LABEL, DONE, then its output. |
| `tray submit FORM ID=VALUE…` | Runs the command that a form stands for, with the form's answers. |

## The menu

```json
{
  "version": 1,
  "state": "running",
  "status": "Running, 3 sites",
  "problem": "Can't reach the Docker daemon. Is Docker Desktop or OrbStack running?",
  "items": [ … ],
  "panel": { … }
}
```

- `state` is `running`, `stopped` or `error`. It sets the badge colour. The icons also have a `busy` state of their own while a command runs.
- `status` follows "Novacore ·" in the first line of the menu. `problem`, if present, goes on the line below it.
- The icons add that heading and the separator under it. `items` is everything else, for an icon that draws a menu.
- `panel` is the same items laid out for an icon that draws a panel (see "The panel" below).

An item is either a separator, `{"separator": true}`, or an item. A separator with a `label` starts a section with that heading. Icons that draw a menu can leave the heading out and just draw a line.

An item has these keys:

| Key | Meaning |
|---|---|
| `label` | Its text. |
| `action` | What clicking it does (see below). Without one, clicking does nothing. |
| `items` | A submenu of items. |
| `enabled` | `false` greys it out. |
| `idle` | `true` greys it out while a command from the tray runs. Use it for anything that changes something. |
| `checked` | `true` shows a check mark. |
| `bold` | `true` shows it in bold, for the main thing a menu does. |
| `icon` | The name of a picture to show beside it in a panel (see below). |
| `detail` | A second line of text under the label, such as a site's URL and PHP version. |

`icon` and `detail` are for icons that draw a panel: the Plasma widget, and the Windows and macOS ones. The Linux one leaves them out. `mitem` picks an `icon` from the item's action, unless it's given one. The names are `dashboard`, `site`, `open`, `git`, `info`, `folder`, `code`, `terminal`, `log`, `remove`, `add`, `start`, `stop`, `restart`, `bug`, `tools`, `database`, `output`, `refresh` and `quit`. An icon that doesn't know a name shows none.

## The panel

```json
{
  "header": ITEM,
  "blocks": [ … ],
  "footer": [ITEM, …]
}
```

The CLI has already decided where everything goes, so a panel draws these in order and doesn't rearrange them. `header` is what clicking the panel's heading does, if there is one. `footer` is the icon's own commands (`tray`), along the bottom. `blocks` is the rest, each one of these:

| Block | Draw it as |
|---|---|
| `{"heading": LABEL}` | The heading of a section. |
| `{"divider": true}` | A line between sections. |
| `{"buttons": [ITEM, …]}` | A row of buttons sharing the width. An item with `"primary": true` is the one to press, in the accent colour. |
| `{"row": ITEM}` | A row that does ITEM's action. |
| `{"row": ITEM, "menu": [ITEM, …]}` | A row that opens the ITEMs as a menu, such as Xdebug's modes. |
| `{"row": ITEM, "card": CARD, "button": ITEM, "avatar": "MS"}` | A row that expands into CARD, such as a site's. `button`, if present, is a button on the row, and `avatar`, if present, is shown in a coloured circle in place of ITEM's picture. Only one row is expanded at a time. |

A card is:

```json
{
  "links": [[ITEM, …], …],
  "choices": [{"label": "PHP version", "items": [ITEM, …]}],
  "buttons": [ITEM, …]
}
```

`links` are groups of links, two to a line, each group starting a new line. `choices` are boxes to pick one of their items from (a pop-up button on macOS), captioned with `label`. The checked item is the current one. `buttons` go at the bottom, and one with `"danger": true` is in red. Any of the three can be missing.

The items in a panel are menu items like any other, and an item with `items` opens them as a menu. A panel still decides for itself whether to show an item (it leaves out editors that aren't installed, and the Plasma widget leaves out `quit`) and whether it's greyed out (`enabled`, `idle`).

## Actions

An action has one of these keys:

| Action | Does |
|---|---|
| `{"open": URL}` | Opens a URL in the browser. |
| `{"folder": PATH}` | Opens a folder in the file manager, Finder or Explorer. On Windows, the path in WSL is opened as `\\wsl.localhost\<distro>\…`. |
| `{"editor": PATH, "app": A}` | Opens a folder in an editor: A is `vscode` (the default) or `zed`. The item is hidden if that editor isn't installed. On Windows, it opens through the editor's WSL support. |
| `{"terminal": PATH, "title": T}` | Opens a terminal in a folder. |
| `{"console": [ARGS…], "title": T}` | Runs `novacore ARGS…` in a new terminal, for interactive commands such as `shell` or `logs`. |
| `{"run": [ARGS…], "label": L, "done": D, "url": U}` | Runs `novacore ARGS…` through `tray run`. L shows while it runs, and D is the notification when it's done. Clicking that notification opens U, if it's set. If the command fails, the notification shows its error, and clicking it shows the output. |
| `{"dialog": "form", …}` | Shows a form (see below). |
| `{"dialog": "info", …}` | Shows details to copy (see below). |
| `{"tray": "output" \| "refresh" \| "quit"}` | The icon's own commands. `output` is greyed out until there's some output to show. The Plasma widget leaves out `quit`, as it's part of Plasma. |

## Form dialogs

```json
{
  "dialog": "form",
  "title": "Add Site",
  "heading": "Optional bold first line",
  "message": "Optional text under it",
  "submit": "Add",
  "destructive": false,
  "fields": [ … ],
  "action": {"run": ["tray", "submit", "add-site"], "label": "Adding {name}…", "done": "…", "url": "https://{name}.localhost"}
}
```

When you submit the form, its action runs with one `ID=VALUE` argument added for each field. `{id}` in the action's `label`, `done` and `url` is replaced by that field's answer. With `destructive`, Return or Enter cancels the dialog rather than submitting it.

| Field `type` | Keys | Answer |
|---|---|---|
| `text` | `label`, `value`, `lowercase`, `hint`, `rules` | The trimmed text. Submit stays disabled while it's empty or breaks a rule. |
| `choice` | `label`, `options`, `value`, `hints` | The chosen option. `hints` maps an option to a note shown while it's chosen. |
| `combo` | `label`, `options`, `value`, `note` | The typed or chosen text. `note` shows under it. |
| `check` | `label`, `value` | `1` or `0`. |

Any field can have `"enabled": false`. A text field's `hint` shows under it while its value is valid, with `{value}` replaced by what you typed. Its `rules` are checked in order, and the first one that fails shows its `error`, also with `{value}` replaced:

- `{"match": REGEX, "error": …}` fails when the value doesn't match. Keep REGEX to syntax that .NET, ICU and PCRE2 (Qt) share.
- `{"notIn": [STRINGS], "error": …}` fails when the value is one of them.

## Info dialogs

```json
{
  "dialog": "info",
  "title": "blog",
  "sections": [{"heading": "Site", "rows": [["URL", "https://blog.localhost"], …]}],
  "buttons": [{"label": "Open Site", "action": {"open": "https://blog.localhost"}}]
}
```

Each row shows a label and a value, with a button to copy the value. The icons add a Close button after `buttons`. Only one info dialog with a given title is open at a time.
