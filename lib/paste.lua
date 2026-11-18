-- Pasting into a note: media are saved beside it, and rich text becomes Markdown.

local micro = import("micro")
local buffer = import("micro/buffer")
local config = import("micro/config")
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

	-- Build the markdown media link
	local encodedName = util.urlEncode(filename)
	local link = "![" .. filename .. "](./" .. encodedName .. ")"

	return link
end

-- prePaste intercepts pastes of media file paths: copies the media into the
-- current buffer's directory and inserts a markdown media link instead.
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
	local clip = clipboard.read()
	if refuseBinary(clip) then
		return false
	end

	local baseDir = filepath.Dir(bp.Buf.AbsPath)
	local replacement = try_paste_media(baseDir, clip)

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
