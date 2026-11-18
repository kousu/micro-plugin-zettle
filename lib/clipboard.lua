-- Reading the system clipboard, which can offer one copy as several types of data.

local shell = import("micro/shell")
local os = import("os")
local runtime = import("runtime")

local util = require("zettle.util")

-- Which tool reads the clipboard: "pbpaste", "wl-paste", "xclip", "xsel", or nil.
-- Mirrors micro's own choice (github.com/zyedidia/clipper): pbpaste on macOS,
-- wl-paste when running under Wayland and it's installed, else xclip if it's
-- installed (it also works under Wayland, through XWayland), else xsel.
-- Only wl-paste and xclip can select a mimetype; pbpaste and xsel are text-only.
-- Cached for the session; false means "checked, none found".
local clipboardToolCache = nil
local function clipboardTool()
	if clipboardToolCache == nil then
		if runtime.GOOS == "darwin" then
			clipboardToolCache = "pbpaste"
		elseif os.Getenv("WAYLAND_DISPLAY") ~= "" and util.installed("wl-paste", "--version") then
			clipboardToolCache = "wl-paste"
		elseif util.installed("xclip", "-version") then
			clipboardToolCache = "xclip"
		elseif util.installed("xsel", "--version") then
			clipboardToolCache = "xsel"
		else
			clipboardToolCache = false
		end
	end
	return clipboardToolCache or nil
end

-- Return the mimetypes the clipboard offers, without duplicates, as both a list
-- in the clipboard's order (types[1], types[2], ...) and a lookup by lowercase
-- name. Mimetypes are case-insensitive but clipboard targets are read by their
-- exact spelling, so the lookup gives that: types["image/x-ms-bmp"] == "image/x-MS-bmp".
-- Empty when they can't be listed (e.g. on macOS, or with only xsel).
--
-- A single copy is usually offered as several types of data at once, and
-- whoever pastes picks one. Images especially: Copy Image in Firefox gives
--
--   $ wl-paste --list-types
--   image/webp
--   image/tiff
--   image/jpeg
--   ...
--   image/avif
--   ...
--   image/png
--   text/_moz_htmlcontext
--   text/_moz_htmlinfo
--   text/html
local function availableTypes()
	local out, err
	local tool = clipboardTool()
	if tool == "wl-paste" then
		out, err = shell.ExecCommand("wl-paste", "--list-types")
	elseif tool == "xclip" then
		out, err = shell.ExecCommand("xclip", "-selection", "clipboard", "-t", "TARGETS", "-o")
	else
		-- no tool that can list types
		return {}
	end

	local types = {}
	if err == nil then
		for line in out:gmatch("[^\r\n]+") do
			local mime = line:match("^%s*(.-)%s*$")
			if not types[mime:lower()] then
				types[mime:lower()] = mime
				types[#types + 1] = mime
			end
		end
	end
	return types
end

-- Is `mime` an image, video, audio or PDF type?
local function isMediaType(mime)
	local m = mime:lower()
	local kind = m:match("^(%a+)/")
	return kind == "image" or kind == "video" or kind == "audio" or m == "application/pdf" or m == "application/x-pdf"
end

-- The first image, video, audio or PDF type the clipboard offers, for showing in an error message.
-- Clipboard type names come from other apps, so only return one that's safe to
-- print: short, with no control characters.
local function printableMediaType(availableTypes)
	for _, mime in ipairs(availableTypes) do
		if #mime <= 64 and mime:lower():match("^[%a%-]+/[%w%.%+%-]+$") and isMediaType(mime) then
			return mime
		end
	end
	return nil
end

-- Does the clipboard offer plain text?
-- (UTF8_STRING, STRING and TEXT are the plain text targets of X11 apps.)
local function hasPlainText(availableTypes)
	for _, mime in ipairs(availableTypes) do
		local m = mime:lower()
		if m:match("^text/plain") or m == "utf8_string" or m == "string" or m == "text" then
			return true
		end
	end
	return false
end

-- Does the clipboard offer an image, video, audio or PDF?
local function hasMedia(availableTypes)
	for _, mime in ipairs(availableTypes) do
		if isMediaType(mime) then
			return true
		end
	end
	return false
end

-- Read the clipboard's contents: as type `mime`, or plain text if `mime` is nil.
local function read(mime)
	local out, err
	local tool = clipboardTool()
	if tool == "wl-paste" then
		if mime then
			out, err = shell.ExecCommand("wl-paste", "-t", mime)
		else
			out, err = shell.ExecCommand("wl-paste", "--no-newline")
		end
	elseif tool == "xclip" then
		if mime then
			out, err = shell.ExecCommand("xclip", "-selection", "clipboard", "-t", mime, "-o")
		else
			out, err = shell.ExecCommand("xclip", "-out", "-selection", "clipboard")
		end
	elseif tool == "xsel" then
		if mime then
			return nil -- can't select a type
		else
			out, err = shell.ExecCommand("xsel", "--output", "--clipboard")
		end
	elseif tool == "pbpaste" then
		if mime then
			return nil -- can't select a type
		else
			out, err = shell.ExecCommand("pbpaste")
		end
	else
		return nil
	end

	if err ~= nil then
		return nil
	end
	-- plain text loses its final newline; data of a specific type stays exact
	if not mime and tool ~= "wl-paste" then
		out = out:match("^(.-)\n?$")
	end
	return out
end

-- What was copied to the clipboard, from its text/uri-list: a list with
-- { path = decoded path } for each local file and { uri = uri } for anything else.
local function copiedLocations()
	local list = read("text/uri-list")
	if list == nil then
		return nil
	end
	local items = {}
	for line in list:gmatch("[^\r\n]+") do
		if not line:match("^#") then
			local path = line:match("^file://[^/]*(/.*)$")
			items[#items + 1] = path and { path = util.urlDecode(path) } or { uri = line }
		end
	end
	return items
end

return {
	read = read,
	availableTypes = availableTypes,
	printableMediaType = printableMediaType,
	hasPlainText = hasPlainText,
	hasMedia = hasMedia,
	copiedLocations = copiedLocations,
}
