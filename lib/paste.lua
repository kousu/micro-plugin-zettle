-- Pasting into a note: media are saved beside it, and rich text becomes Markdown.

local micro = import("micro")
local buffer = import("micro/buffer")
local config = import("micro/config")
local time = import("time")
local fmt = import("fmt")
local os = import("os")
local filepath = import("filepath")

local util = require("zettle.util")
local media = require("zettle.media")
local clipboard = require("zettle.clipboard")

-- Convert a Go []byte userdata to a Lua string.
local function goBytes(b)
	return fmt.Sprintf("%s", b)
end

-- Build a markdown media link to `filename` in the note's own folder.
local function mediaLink(filename)
	return "![" .. filename .. "](./" .. util.urlEncode(filename) .. ")"
end

-- Never paste binary data into a note: shows an error and returns true if `text` is binary.
local function refuseBinary(text)
	if text ~= nil and text:find("\0", 1, true) then
		micro.InfoBar():Error("zettle: refusing to paste binary clipboard contents")
		return true
	end
	return false
end

local function try_paste_media(baseDir, clip)
	if clip == nil or clip == "" then
		-- micro:Log("zettle: empty clipboard ")
		return
	end

	-- Must look like a file path (no newlines, no URL scheme)
	if clip:find("\n") then
		-- micro:Log("zettle: clipboard contains newlines ")
		return
	end
	if clip:match("^[%a][%a%d+%-%.]*://") then
		-- micro:Log("zettle: clipboard is a uri")
		return
	end

	-- Check extension
	local ext = clip:match("%.([^%.%s]+)$")
	if not ext or not media.EXTENSIONS[ext:lower()] then
		-- micro:Log("zettle: extension not media: " .. tostring(ext))
		return
	end
	-- micro:Log("zettle: copy has media extension " .. ext)

	-- Verify the file exists
	local _, serr = os.Stat(clip)
	if serr ~= nil then
		micro.InfoBar():Error("zettle: " .. clip .. ": " .. serr.Error())
		micro:Log("zettle: " .. clip .. ": " .. serr.Error())
		return
	end

	-- Determine destination directory (same as the current buffer)
	local filename = filepath.Base(clip)
	local dst = filepath.Join(baseDir, filename)

	-- Only copy if src and dst differ
	if clip ~= dst then
		-- TODO: what if dst already exists?
		local cerr = util.copyFile(clip, dst)
		if cerr ~= nil then
			micro.InfoBar():Error("zettle: media copy failed: " .. cerr)
			micro.Log("zettle: media copy failed: " .. cerr)
			return false
		end
		micro.InfoBar():Message("zettle: inserted media from " .. clip)
	end

	return mediaLink(filename)
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
	if mime then
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
		-- the path of a media file, copied as text
		replacement = try_paste_media(baseDir, plain)
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

local function rewriteTerminalPaste(buf, te)
	-- micro:Log("zettle: onBeforeTextEvent on " .. tostring(buf) .. " and " .. tostring(te))
	-- handles  terminal "bracket-pastes", i.e. those that most terminals make on "Ctrl-Shift-V"
	-- Convert the Go []byte delta text to a Lua string.
	-- luar exposes []byte as a Go slice; tostring() gives us the raw content.
	if #te.Deltas == 0 then
		return true
	end

	-- terminal "bracket-pastes" are multi-character events; a single character is a regular keystroke
	if #te.Deltas[1].Text <= 1 then
		return true
	end

	local start = buffer.Loc(te.Deltas[1].Start.X, te.Deltas[1].Start.Y)
	local clip = goBytes(te.Deltas[1].Text)

	local baseDir = filepath.Dir(buf.AbsPath)
	local replacement = try_paste_media(baseDir, clip)
	if replacement ~= nil then
		if replacement == false then
			-- ERROR
			return false
		end
		-- modify the paste event to contain our replacement markdown link
		-- and fallthrough to 'return true' to let the next event handler actually apply it
		te.Deltas[1].Text = replacement
	end
	return true
end

return {
	pasteClipboard = pasteClipboard,
	rewriteTerminalPaste = rewriteTerminalPaste,
}
