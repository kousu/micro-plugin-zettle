-- Pasting into a note: media are saved beside it, and rich text becomes Markdown.

local micro = import("micro")
local buffer = import("micro/buffer")
local shell = import("micro/shell")
local config = import("micro/config")
local time = import("time")
local os = import("os")
local filepath = import("filepath")

local util = require("zettle.util")
local media = require("zettle.media")
local clipboard = require("zettle.clipboard")

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

-- Copy the file at `path` beside the note, unless it's already there. Returns
-- the markdown link; if the copy failed, this shows an error and returns nil.
local function copyBesideNote(baseDir, path)
	local filename = filepath.Base(path)
	local dst = filepath.Join(baseDir, filename)

	-- Only copy if src and dst differ
	if path ~= dst then
		-- TODO: what if dst already exists?
		local cerr = util.copyFile(path, dst)
		if cerr ~= nil then
			micro.InfoBar():Error("zettle: media copy failed: " .. cerr:gsub("%c", "?"))
			micro.Log("zettle: media copy failed: " .. cerr)
			return nil
		end
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

-- Save clipboard media of type `mime` into baseDir as pasted_<kind>_<timestamp>.<ext>.
-- Returns the markdown link, or false on error.
local function try_paste_media_data(baseDir, mime, ext)
	local data = clipboard.read(mime)
	if data == nil or not media.looksLike(mime:lower(), data) then
		micro.InfoBar():Error("zettle: could not read " .. mime .. " from the clipboard")
		micro.Log("zettle: could not read " .. mime .. " from the clipboard")
		return false
	end

	local kind = mime:match("^(video)/")
		or mime:match("^(audio)/")
		or (mime:find("pdf", 1, true) and "document")
		or "image"
	local name = "pasted_" .. kind .. "_" .. time.Now():Format("20060102-150405") .. "." .. ext
	local f, dst = util.createUnique(baseDir, name)
	if f == nil then
		micro.InfoBar():Error("zettle: " .. dst)
		return false
	end
	local _, werr = f:WriteString(data)
	f:Close()
	if werr ~= nil then
		os.Remove(dst)
		micro.InfoBar():Error("zettle: " .. werr:Error())
		return false
	end

	micro.InfoBar():Message("zettle: saved " .. filepath.Base(dst))
	return mediaLink(filepath.Base(dst))
end

-- prePaste intercepts pastes of media, either as media data or as media file
-- paths: it saves or copies the media into the current buffer's directory and
-- inserts a markdown media link instead.
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
	local mime, ext = media.selectType(availableTypes)
	local copied = availableTypes["text/uri-list"] and clipboard.copiedLocations()
	if copied and #copied > 0 then
		-- files copied in a file manager
		replacement = pasteCopiedLocations(baseDir, copied)
	elseif mime then
		-- media, e.g. "Copy Image" in a browser, or a screenshot
		replacement = try_paste_media_data(baseDir, mime, ext)
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
		if plain == nil and clipboard.hasMedia(availableTypes) then
			local unknown = clipboard.printableMediaType(availableTypes)
			micro.InfoBar():Error("zettle: refusing to paste unknown media type" .. (unknown and " " .. unknown or ""))
			return false
		elseif plain == nil and hasHtml then
			micro.InfoBar():Error("zettle: refusing to paste HTML with no plain text")
			return false
		end
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
		local start = buffer.Loc(bp.Cursor.X, bp.Cursor.Y)
		bp.Buf.EventHandler:Insert(start, replacement)
		-- bp.Cursor:GotoLoc(start + #replacement)
		return false
	else
		return true
	end
end

return {
	pasteClipboard = pasteClipboard,
}
