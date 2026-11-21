-- Small helpers shared by zettle's modules.

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

-- Copy src file to dst path. Returns error string or nil on success.
local function copyFile(src, dst)
	local srcFile, err = os.Open(src)
	if err ~= nil then
		return err:Error()
	end
	local dstFile, err2 = os.Create(dst)
	if err2 ~= nil then
		srcFile:Close()
		return err2:Error()
	end
	local _, err3 = io.Copy(dstFile, srcFile)
	srcFile:Close()
	dstFile:Close()
	if err3 ~= nil then
		return err3:Error()
	end
	return nil
end

return {
	urlDecode = urlDecode,
	urlEncode = urlEncode,
	slugify = slugify,
	copyFile = copyFile,
}
