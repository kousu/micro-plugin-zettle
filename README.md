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

## Pasting media

In a markdown file, pasting an image, video, audio or PDF with `Ctrl-V` saves it next to the note and inserts a link
like `![name.png](./name.png)`. Existing files are never overwritten; a `-1`, `-2`, … suffix is
added instead.

- **Files copied in a file manager**: images, videos, audio and PDFs are copied over with their
  original names and linked, and anything else is pasted as its path.
- **Image, video, audio or PDF data** (e.g. "Copy Image" in a browser, or a screenshot) is saved as
  `pasted_<image|video|audio|document>_<date>-<time>.<ext>`.

Video, audio and PDFs use the same `![name](./file)` link. Some renderers show them inline
(Obsidian does all three); others treat the link as a broken image.

This uses `wl-paste` (Wayland) or `xclip` (X11) to read the clipboard's mimetypes.
Pasting media doesn't work on macOS yet.

## Pasting rich text

In a markdown file, pasting rich text with `Ctrl-V` (from a web page, a word
processor or Google Docs, say) converts it to Markdown, as GitHub and
Obsidian do: headings, emphasis, links, images, lists, tables, quotes and
code become Markdown, other text is kept as text, and styles and layout are
dropped. Images embedded in the copied HTML (as `data:` URLs) are saved
beside the note, like pasted media, and linked from it; other images keep
their URLs. When the browser says which page the text was copied from,
links to that page's own headings point to them in the note, and its
footnotes are kept.

The conversion is done by [markdownify](https://github.com/kousu/lua-markdownify),
vendored in `vendor/markdownify/`. It uses the clipboard's `text/html`,
read with `wl-paste` or `xclip` like pasted media.

To also download the pasted media that are on the web, beside the note:

```
> set zettle.download-media true
```

The paste happens at once, linking to the media's URLs; they download in
the background (with `curl`), and each link switches to the local file when
its download finishes. If a download fails, the link keeps its URL. This is
off by default, and has no effect with `zettle.convert-html` off.

A file identical to one already beside the note is reused rather than saved
again, and pasting the same media into a note in another folder gives it its
own copy. If a link is edited away before its download finishes, the file
is still kept.

Some sites refuse downloads that don't look like a browser's, so each one
presents as a common browser, and tells the site the page the text was
copied from (without its `#fragment`), as a browser would.

To paste rich text as plain text instead:

```
> set zettle.convert-html false
```

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
