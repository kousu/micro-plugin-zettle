# micro-zettle

A plugin for [micro](https://micro-editor.github.io/) adding wiki features
([Zettelkasten](https://en.wikipedia.org/wiki/Zettelkasten)).


## Installation

This plugin depends on [a fork of filemanager](https://github.com/kousu/micro-plugin-filemanager) which is not in the official plugin channel. Register it first, then install both plugins:

```sh
micro -options pluginrepos=https://raw.githubusercontent.com/kousu/micro-plugin-filemanager/master/repo.json
micro -plugin install filemanager
micro -plugin install zettle
```

## Vaults

Mark a project folder as a wiki with

```
touch .zettle
```

This will

- initialize `micro`'s working directory to that folder
- root the file manager (`Ctrl-e tree`) at that folder
- enable **autosave**
- ... {not yet defined} ...

Even without this this plugin adds the Markdown-friendly features.

## Keybindings

| Action | Default key | Description |
|---|---|---|
| `Activate` | `Enter`, mouse click | Follow links; Toggle `- [ ]` checkboxes |
| `ToggleTodo` | (none) | Toggle `- [ ]` checkboxes  |
| `OpenLink` | (none) | Follow links |
| `NavigateBack` | `Alt-Left` | Go back to the previously opened file |
| `ToggleBlockquote` | `>` | Add or remove "> " to every selected line |
| `PreviewMarkdown` | `Ctrl-P` | Render the current document with `glow`; press `q` to return [^wysiwyg] |

[^wysiwyg]: I would actually like to do mixed-mode WYSIWYG rendering like Zettlr, where everything is pretty except when you're editing it, and then you see the code.

### Changing keybindings

To override a default, add an entry to `~/.config/micro/bindings.json`. For example,
to rebind `NavigateBack` to `Ctrl-Backspace`:

```json
{
    "Ctrl-Backspace": "lua:zettle.NavigateBack"
}
```

The plugin uses `TryBindKey` with `overwrite = false`, so any binding already present in
`bindings.json` takes precedence over the plugin defaults automatically.

If you prefer to trigger `Activate` with `Ctrl-Space` instead of (or in addition to) `Enter`,
add it to `bindings.json`:

```json
{
    "Ctrl-Space": "lua:zettle.Activate",
    "Enter": "InsertNewline"
}
```

Restoring `Enter` to plain `InsertNewline` is recommended when using `Ctrl-Space`,
since the default `Enter` binding routes through `Activate` first.

## Development

Clone the repo and symlink it into micro's plugin directory under the plugin's name:

```sh
git clone https://github.com/kousu/micro-plugin-zettle
ln -s "$PWD/micro-plugin-zettle" ~/.config/micro/plug/zettle
```

There's a good chance, at this stage, that you will need to edit the filemanager plugin too:

```sh
git clone https://github.com/kousu/micro-plugin-filemananger
ln -s "$PWD/micro-plugin-filemanager" ~/.config/micro/plug/filemanager
```

micro loads plugins from `~/.config/micro/plug/` at startup, so changes to the
working copy take effect on next launch (or after `> reload` in an existing session).

To debug, use `micro:Log("...")` and run micro as `micro -debug` and `tail -f log.txt`. (without -debug the log lines go nowhere)

We use `stylua` to lint the code. Make sure your editor is set up for it.
