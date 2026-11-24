-- Small helpers shared by zettle's modules.

local micro = import("micro")
local buffer = import("micro/buffer")
local shell = import("micro/shell")
local filepath = import("filepath")
local io = import("io")
local os = import("os")

-- Decode %XX percent-encoding in a URL path component.
local function urlDecode(s)
	return (s:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

-- Percent-encode a file path for use in a markdown link.
-- Encodes everything except unreserved characters and '/'.
local function urlEncode(s)
	return (s:gsub("([^%w%-%.%_%~%/])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Is `cmd` installed? Runs it with `versionFlag` (we can't search PATH from Lua).
local function installed(cmd, versionFlag)
	local _, err = shell.ExecCommand(cmd, versionFlag)
	return err == nil
end

-- Convert a markdown header line to its GitHub-style anchor slug.
-- e.g. "## Guide to Your New Life!" → "guide-to-your-new-life"
local function slugify(line)
	-- Strip leading #'s and surrounding whitespace
	local text = line:match("^#+%s+(.-)%s*$") or line
	text = text:lower()
	-- Remove anything that isn't alphanumeric, space, or hyphen
	text = text:gsub("[^%w%s%-]", "")
	-- Collapse spaces/runs to a single hyphen
	text = text:gsub("%s+", "-")
	return text
end

-- Copy the contents of file `src` into the open file `dstFile`.
-- Returns an error string, or nil on success.
local function copyInto(src, dstFile)
	local srcFile, err = os.Open(src)
	if err ~= nil then
		return err:Error()
	end
	local _, err2 = io.Copy(dstFile, srcFile)
	srcFile:Close()
	if err2 ~= nil then
		return err2:Error()
	end
	return nil
end

-- Create a new file in `dir` named `name`, adding "-1", "-2", ... before the
-- extension if that name is taken. Never overwrites an existing file.
-- Returns the open file and its path, or nil and an error string.
local function createUnique(dir, name)
	local stem, ext = name:match("^(.+)(%.[^%.]+)$")
	if not stem then
		stem, ext = name, ""
	end
	local flags = os.O_WRONLY + os.O_CREATE + os.O_EXCL
	local path = filepath.Join(dir, name)
	for n = 1, 500 do
		local f, err = os.OpenFile(path, flags, tonumber("644", 8))
		if err == nil then
			return f, path
		elseif not os.IsExist(err) then
			return nil, err:Error()
		end
		path = filepath.Join(dir, stem .. "-" .. n .. ext)
	end
	return nil, "too many files named like " .. name
end

-- Is this buffer still open in some pane?
local function bufferIsOpen(buf)
	local ok, open = pcall(function()
		local tabs = micro.Tabs().List
		for i = 1, #tabs do
			local panes = tabs[i].Panes
			for j = 1, #panes do
				local pane = panes[j]
				if pane.Buf == buf then
					return true
				end
			end
		end
		return false
	end)
	-- if the panes can't be inspected, assume it's open
	return not ok or open
end

-- The number of characters in `s`.
local function runeCount(s)
	return select(2, s:gsub("[^\128-\191]", ""))
end

-- The start and end of the first occurrence of the one-line `needle` in
-- `buf`, or nil.
local function findInBuffer(buf, needle)
	for y = 0, buf:LinesNum() - 1 do
		local line = buf:Line(y)
		local s, e = line:find(needle, 1, true)
		if s then
			-- micro's columns count characters, not bytes
			return buffer.Loc(runeCount(line:sub(1, s - 1)), y), buffer.Loc(runeCount(line:sub(1, e)), y)
		end
	end
	return nil
end

return {
	urlDecode = urlDecode,
	urlEncode = urlEncode,
	installed = installed,
	slugify = slugify,
	copyInto = copyInto,
	createUnique = createUnique,
	bufferIsOpen = bufferIsOpen,
	findInBuffer = findInBuffer,
}
