# micro-zettlr

A plugin for [micro](https://micro-editor.github.io/) adding wiki features
([Zettelkasten](https://en.wikipedia.org/wiki/Zettelkasten)).

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
