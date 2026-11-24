-- Pasting into a note: media are saved beside it, and rich text becomes Markdown.

local micro = import("micro")
local buffer = import("micro/buffer")
local shell = import("micro/shell")
local config = import("micro/config")
local time = import("time")
local os = import("os")
local filepath = import("filepath")

local util = require("zettle.util")
local base64 = require("zettle.base64")
local media = require("zettle.media")
local clipboard = require("zettle.clipboard")
local downloads = require("zettle.downloads")

-- Build a markdown media link to `filename` in the note's own folder.
local function mediaLink(filename)
	-- file names can hold newlines and brackets, which would break the link's text
	local alt = filename:gsub("%c", " "):gsub("([\\%[%]])", "\\%1")
	return "![" .. alt .. "](./" .. util.urlEncode(filename) .. ")"
end

-- Never paste binary data into a note: shows an error and returns true if `text` is binary.
local function refuseBinary(text)
	if text ~= nil and text:find("\0", 1, true) then
		micro.InfoBar():Error("zettle: refusing to paste binary clipboard contents")
		return true
	end
	return false
end

-- With smartpaste, give the lines of `text`, pasted at `loc`, the
-- indentation of the line pasted into.
local function smartIndent(buf, loc, text)
	if buf.Settings["smartpaste"] and loc.X > 0 then
		local pasteIndent = text:match("^[ \t]*")
		if pasteIndent ~= " " and text:find("\n" .. pasteIndent, 1, true) then
			local lineIndent = buf:Line(loc.Y):match("^[ \t]*")
			-- the line pasted into already has the first line's indentation
			text = text:sub(#pasteIndent + 1)
			-- (skipped when it changes nothing: slow on a long paste in micro's Lua)
			if lineIndent ~= pasteIndent then
				text = text:gsub("\n" .. pasteIndent, "\n" .. lineIndent)
			end
		end
	end
	return text
end

-- Paste `text` at the cursor of `bp`, as micro's own paste does
-- (BufPane.paste in micro's internal/action/actions.go), which plugins
-- can't call with their own text: re-indent it if smartpaste is on,
-- replace the selection, leave the cursor after the text, and scroll to it.
local function insertAtCursor(bp, text)
	text = smartIndent(bp.Buf, bp.Cursor, text)
	if bp.Cursor:HasSelection() then
		bp.Cursor:DeleteSelection()
		bp.Cursor:ResetSelection()
	end
	-- (bp.Cursor.Loc reaches Lua as a pointer; Insert takes a value)
	bp.Buf:Insert(buffer.Loc(bp.Cursor.X, bp.Cursor.Y), text)
	bp:Relocate()
end

-- Paste `text` at every cursor. micro stops running Paste for the other
-- cursors once prePaste cancels it, so a paste we handle has to do them all.
local function insertAtCursors(bp, text)
	if refuseBinary(text) then
		return
	end
	local cursors = bp.Buf:GetCursors()
	for i = 1, #cursors do
		bp.Buf:SetCurCursor(cursors[i].Num)
		bp.Cursor = cursors[i]
		insertAtCursor(bp, text)
	end
end

-- Copy the file at `path` beside the note, unless it's already there. Returns
-- the markdown link; if the copy failed, this shows an error and returns nil.
local function copyBesideNote(baseDir, path)
	local filename = filepath.Base(path)
	local dst = filepath.Join(baseDir, filename)

	-- Only copy if src and dst differ
	if path ~= dst then
		local f, pathOrErr = util.createUnique(baseDir, filename)
		local cerr
		if f == nil then
			cerr = pathOrErr
		else
			dst = pathOrErr
			cerr = util.copyInto(path, f)
			f:Close()
			if cerr ~= nil then
				os.Remove(dst)
			end
		end
		if cerr ~= nil then
			micro.InfoBar():Error("zettle: media copy failed: " .. cerr:gsub("%c", "?"))
			micro.Log("zettle: media copy failed: " .. cerr)
			return nil
		end
		filename = filepath.Base(dst)
	end

	return mediaLink(filename)
end

-- Is the copied file at `path` an image, video, audio or PDF, going by its contents?
-- If it can't be read, shows an error and returns false.
local function isCopiedMedia(path)
	local head, err = shell.ExecCommand("head", "-c", "512", path)
	if err ~= nil then
		local message = "zettle: couldn't read " .. path:gsub("%c", "?")
		micro.InfoBar():Error(message)
		micro.Log(message)
		return false
	end
	return media.isMedia(head)
end

-- The text to paste for files copied in a file manager, one per line: media
-- files, going by their contents, are copied beside the note and
-- linked, any other file is its path, and any other URI is itself.
local function pasteCopiedLocations(baseDir, items)
	local text
	for _, item in ipairs(items) do
		local line = item.uri
		if line == nil and isCopiedMedia(item.path) then
			-- nil if the copy failed, leaving the plain path below
			line = copyBesideNote(baseDir, item.path)
		end
		if line == nil then
			line = item.path
		end
		text = text and (text .. "\n" .. line) or line
	end
	return text
end

-- Save media of type `mime` (in lowercase) in baseDir as
-- pasted_<image|video|audio|document>_<timestamp>.<ext>, never overwriting a file. Only
-- saves data that really is of a type we allow.
-- Returns the file's name, or nil and an error.
local function saveMedia(baseDir, mime, data)
	local ext = media.extension(mime)
	if ext == nil or data == nil or not media.looksLike(mime, data) then
		return nil, "not a valid " .. mime .. " file"
	end
	local kind = mime:match("^(video)/")
		or mime:match("^(audio)/")
		or (mime:find("pdf", 1, true) and "document")
		or "image"
	local name = "pasted_" .. kind .. "_" .. time.Now():Format("20060102-150405") .. "." .. ext
	local f, dst = util.createUnique(baseDir, name)
	if f == nil then
		return nil, dst
	end
	local _, werr = f:WriteString(data)
	f:Close()
	if werr ~= nil then
		os.Remove(dst)
		return nil, werr:Error()
	end
	return filepath.Base(dst)
end

-- Save the clipboard's media of type `mime` beside the note.
-- Returns the markdown link, or false on error.
local function try_paste_media_data(baseDir, mime)
	local data = clipboard.read(mime)
	if data == nil then
		micro.InfoBar():Error("zettle: could not read " .. mime .. " from the clipboard")
		micro.Log("zettle: could not read " .. mime .. " from the clipboard")
		return false
	end

	local name, err = saveMedia(baseDir, mime:lower(), data)
	if name == nil then
		micro.InfoBar():Error("zettle: " .. err)
		return false
	end
	micro.InfoBar():Message("zettle: saved " .. name)
	return mediaLink(name)
end

-- Decode a data: URL. Returns its mimetype and contents, or nil.
local function decodeDataURL(url)
	local meta, payload = url:match("^data:([^,]*),(.*)$")
	if meta == nil then
		return nil
	end
	local mime = (meta:match("^([^;]+)") or "text/plain"):lower()
	local data
	if meta:find(";%s*base64") then
		data = base64.decode(payload)
	else
		data = util.urlDecode(payload)
	end
	return mime, data
end

-- Save data: media beside the note; returns the src to link to, or nil.
local function saveDataMedia(baseDir, url)
	local mime, data = decodeDataURL(url)
	if mime == nil then
		micro.Log("zettle: not saving a malformed data: URL")
		return nil
	end
	local name, err = saveMedia(baseDir, mime, data)
	if name == nil then
		micro.Log("zettle: not saving a pasted data: URL: " .. err)
		return nil
	end
	return "./" .. util.urlEncode(name)
end

-- Convert pasted HTML to Markdown, adding the media to download to `remoteMedia`.
-- `source` is the page it was copied from (or only its site), if known.
local function convertHtml(baseDir, html, source, remoteMedia)
	local download = config.GetGlobalOption("zettle.download-media")
	return require("markdownify").convert(html, {
		-- links within the copied page go to its headings in the note, and
		-- its footnotes are kept
		source = source,
		anchor = util.slugify,
		imageHandler = function(src, _, title)
			-- media embedded in the HTML are saved beside the note,
			-- rather than putting their base64 in it
			if src:find("^data:") then
				return saveDataMedia(baseDir, src)
			end
			-- links that markdownify would wrap in <> can't be found to swap later
			if download and src:find("^https?://") and not src:find("[%s()<>]") then
				local downloaded = downloads.downloadedLink(src, baseDir)
				if downloaded then
					return downloaded
				end
				if #remoteMedia >= downloads.MAX_DOWNLOADS_PER_PASTE then
					return src
				end
				local marker = downloads.newMarker()
				remoteMedia[#remoteMedia + 1] = { url = src, marker = marker, title = title }
				return src, nil, marker
			end
			return src
		end,
	})
end

-- Paste the clipboard's HTML (rich text copied from a browser, a word
-- processor or Google Docs) as Markdown, as GitHub and Obsidian do.
-- `plain`, the clipboard's text, is pasted if the HTML can't be
-- converted; `source` is the page it was copied from, or its site, if known.
local function pasteHtml(bp, baseDir, html, plain, source)
	-- browsers don't send a page's #fragment as the Referer
	local pageUrl = source and source:match("^[^#]*")
	local buf = bp.Buf
	-- micro only redraws between events, so convert in a later one to show this
	micro.InfoBar():Message("zettle: pasting rich text...")
	micro.After(0, function()
		if bp.Buf ~= buf or not util.bufferIsOpen(buf) or buf.Type.Readonly then
			micro.InfoBar():Message("zettle: rich text paste cancelled")
			return
		end
		-- downloaded once their links are in the note
		local remoteMedia = {}
		local ok, md = pcall(convertHtml, baseDir, html, source, remoteMedia)
		if not ok then
			micro.Log("zettle: couldn't convert pasted HTML: " .. tostring(md))
		end
		if not ok or md == nil or md == "" then
			-- the fallback text doesn't have this paste's media links
			remoteMedia = {}
			md = plain or ""
			if md == "" then
				micro.InfoBar():Error("zettle: could not convert the clipboard's HTML")
				return
			end
		end
		if refuseBinary(md) then
			return
		end
		insertAtCursors(bp, md)
		downloads.queue(buf, baseDir, remoteMedia, pageUrl)
		micro.InfoBar():Message("zettle: pasted rich text")
	end)
end

-- prePaste intercepts pastes of media, either as media data or as media file
-- paths: it saves or copies the media into the current buffer's directory and
-- inserts a markdown media link instead. It also pastes rich text (HTML) as
-- Markdown.
local function pasteClipboard(bp)
	-- a read-only note can't take the link, so don't save anything for it
	if bp.Buf.Type.Readonly then
		return true
	end
	-- only "external" is the system clipboard that we know how to read
	if config.GetGlobalOption("clipboard") ~= "external" then
		return true
	end
	-- handles pastes from the internal micro Ctrl-V keybind
	-- micro:Log("zettle: prePaste on " .. tostring(bp.Buf))
	local baseDir = filepath.Dir(bp.Buf.AbsPath)
	local availableTypes = clipboard.availableTypes()

	local replacement
	local mime = media.selectType(availableTypes)
	-- apps can offer a PDF rendering of copied text; the text is what was meant
	if
		mime
		and mime:lower():find("pdf", 1, true)
		and (availableTypes["text/html"] or clipboard.hasPlainText(availableTypes))
	then
		mime = nil
	end
	local copied = availableTypes["text/uri-list"] and clipboard.copiedLocations()
	if copied and #copied > 0 then
		-- files copied in a file manager
		replacement = pasteCopiedLocations(baseDir, copied)
	elseif mime then
		-- media, e.g. "Copy Image" in a browser, or a screenshot
		replacement = try_paste_media_data(baseDir, mime)
	else
		-- no media we can save, so look for text
		local hasHtml = availableTypes["text/html"] ~= nil
		-- (asking a clipboard with no plain text for text can return its media or HTML)
		local plain
		if clipboard.hasPlainText(availableTypes) or not (hasHtml or clipboard.hasMedia(availableTypes)) then
			plain = clipboard.read()
			if plain == "" then
				plain = nil
			end
		end
		if hasHtml and config.GetGlobalOption("zettle.convert-html") then
			local html = clipboard.read(availableTypes["text/html"])
			if html ~= nil and html ~= "" then
				pasteHtml(bp, baseDir, html, plain, clipboard.sourceUrl())
				return false
			end
		end
		if plain == nil and clipboard.hasMedia(availableTypes) then
			local unknown = clipboard.printableMediaType(availableTypes)
			micro.InfoBar():Error("zettle: refusing to paste unknown media type" .. (unknown and " " .. unknown or ""))
			return false
		elseif plain == nil and hasHtml then
			micro.InfoBar():Error("zettle: refusing to paste HTML with no plain text")
			return false
		end
		-- micro inserts plain text itself (per cursor), so it misses insertAtCursor's guard
		if refuseBinary(plain) then
			return false
		end
	end

	if replacement ~= nil then
		if replacement == false then
			-- ERROR
			return false
		end
		-- Cancel the default paste and insert the link ourselves
		insertAtCursors(bp, replacement)
		return false
	else
		return true
	end
end

return {
	pasteClipboard = pasteClipboard,
}
