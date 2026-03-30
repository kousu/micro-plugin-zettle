# micro-zettlr

A plugin for [micro](https://micro-editor.github.io/) adding wiki features
([Zettelkasten](https://en.wikipedia.org/wiki/Zettelkasten)).

## Development

Clone the repo and symlink it into micro's plugin directory under the plugin's name:

```sh
git clone https://github.com/kousu/micro-plugin-zettlr
ln -s "$PWD/micro-plugin-zettlr" ~/.config/micro/plug/zettlr
```

micro loads plugins from `~/.config/micro/plug/` at startup, so changes to the
working copy take effect the next time micro is launched (or after `> reload` in
an existing session).

## Installation

This plugin depends on [a fork of filemanager](https://github.com/kousu/micro-plugin-filemanager)
(version ≥ 3.5.0), which is not in the official plugin channel. Register it first,
then install both plugins:

```sh
micro -options pluginrepos=https://raw.githubusercontent.com/kousu/micro-plugin-filemanager/master/repo.json
micro -plugin install filemanager
micro -plugin install zettlr
```

The version constraint in `repo.json` (`"filemanager": ">=3.5.0"`) ensures the
fork is used — the upstream plugin only reaches 3.4.0.

## Keybindings

| Action | Default key | Description |
|---|---|---|
| `Activate` | `Ctrl-Space` | Toggle the `- [ ]` item on the current line, or follow the link under the cursor |
| `ToggleTodo` | — | Toggle the `- [ ]` item only (not bound by default) |
| `OpenLink` | — | Follow the link under the cursor only (not bound by default) |
| `NavigateBack` | `Alt-Left` | Go back to the previously opened file |

Clicking the `[ ]` or `[x]` checkbox on a TODO line with the mouse also toggles it.
Clicking a `[text](./path)` link opens the linked file (or external app for non-text files).

`Activate` tries `ToggleTodo` first; if the cursor is not on a checkbox it falls through to
`OpenLink`. `ToggleTodo` and `OpenLink` are exposed separately so they can be bound
independently if preferred.

### Changing keybindings

To override a default, add an entry to `~/.config/micro/bindings.json`. For example,
to rebind `NavigateBack` to `Ctrl-Backspace`:

```json
{
    "Ctrl-Backspace": "lua:zettlr.NavigateBack"
}
```

The plugin uses `TryBindKey` with `overwrite = false`, so any binding already present in
`bindings.json` takes precedence over the plugin defaults automatically.

## Per-project config

Drop a `.zettlr.json` file in your notes folder to enable project-specific behaviour.
Currently the only effect of the file's presence is enabling **autosave** for that session —
useful for Obsidian-style journalling where you want edits saved automatically:

```sh
echo '{}' > ~/notes/.zettlr.json
micro ~/notes/
```

micro will detect `.zettlr.json` in its working directory on startup and call
`set autosave 1` automatically. If the file exists but cannot be parsed as JSON the
plugin treats it as `{}` and still enables autosave.
