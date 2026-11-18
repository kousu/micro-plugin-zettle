-- Which image, video, audio and PDF formats zettle saves, and how to recognize them.

local EXTENSIONS = {
	png = true,
	jpg = true,
	jpeg = true,
	gif = true,
	webp = true,
	svg = true,
	bmp = true,
	tiff = true,
	tif = true,
	ico = true,
	avif = true,
	heic = true,
	jxl = true,
	-- video
	mp4 = true,
	webm = true,
	mkv = true,
	avi = true,
	mov = true,
	-- audio
	m4a = true,
	mp3 = true,
	ogg = true,
	opus = true,
	wav = true,
	flac = true,
	-- documents
	pdf = true,
}

-- Mimetypes we can save, in lowercase, in order of preference, with their file
-- extensions and the signature (see `signature`) that their contents must have.
-- This is an allowlist: pasted content chooses its mimetype, so saving unlisted
-- types would let a web page drop files of any extension (.desktop, .html) into notes.
local MEDIA_MIMETYPES = {
	{ "image/png", "png", "png" },
	{ "image/jpeg", "jpg", "jpeg" },
	{ "image/gif", "gif", "gif" },
	{ "image/webp", "webp", "webp" },
	{ "image/avif", "avif", "iso" },
	{ "image/heic", "heic", "iso" },
	{ "image/jxl", "jxl", "jxl" },
	{ "image/svg+xml", "svg", "svg" },
	{ "image/tiff", "tiff", "tiff" },
	{ "image/bmp", "bmp", "bmp" },
	{ "image/x-bmp", "bmp", "bmp" },
	{ "image/x-ms-bmp", "bmp", "bmp" },
	{ "image/vnd.microsoft.icon", "ico", "ico" },
	{ "image/x-icon", "ico", "ico" },
	{ "image/x-ico", "ico", "ico" },
	{ "image/ico", "ico", "ico" },
	{ "image/icon", "ico", "ico" },
	{ "image/x-win-bitmap", "ico", "ico" },
	{ "application/ico", "ico", "ico" },
	{ "text/ico", "ico", "ico" },
	{ "video/mp4", "mp4", "iso" },
	{ "video/webm", "webm", "matroska" },
	{ "video/x-matroska", "mkv", "matroska" },
	{ "video/quicktime", "mov", "iso" },
	{ "video/x-msvideo", "avi", "avi" },
	{ "video/avi", "avi", "avi" },
	{ "audio/mp4", "m4a", "iso" },
	{ "audio/x-m4a", "m4a", "iso" },
	{ "audio/mpeg", "mp3", "mp3" },
	{ "audio/mp3", "mp3", "mp3" },
	{ "audio/ogg", "ogg", "ogg" },
	{ "audio/opus", "opus", "ogg" },
	{ "audio/webm", "webm", "matroska" },
	{ "audio/wav", "wav", "wav" },
	{ "audio/x-wav", "wav", "wav" },
	{ "audio/wave", "wav", "wav" },
	{ "audio/vnd.wave", "wav", "wav" },
	{ "audio/flac", "flac", "flac" },
	{ "audio/x-flac", "flac", "flac" },
	{ "application/pdf", "pdf", "pdf" },
	{ "application/x-pdf", "pdf", "pdf" },
}

local function lookup(mime)
	for _, m in ipairs(MEDIA_MIMETYPES) do
		if m[1] == mime then
			return m
		end
	end
	return nil
end

-- The file extension for `mime` (in lowercase), or nil if it's not on the allowlist.
local function extension(mime)
	local m = lookup(mime)
	return m and m[2]
end

-- Pick our favourite type from the clipboard's `availableTypes`. Returns mime,
-- in the clipboard's own spelling so that it can be read, and ext; or nil.
local function selectType(availableTypes)
	for _, m in ipairs(MEDIA_MIMETYPES) do
		if availableTypes[m[1]] then
			return availableTypes[m[1]], m[2]
		end
	end
	return nil
end

-- Does `data` start with an MPEG audio frame header?
local function isMp3Frame(data)
	local b1, b2, b3 = data:byte(1, 3)
	if b1 ~= 255 or not b3 or b2 < 224 then
		return false
	end
	local version = math.floor(b2 / 8) % 4
	local layer = math.floor(b2 / 2) % 4
	local bitrate = math.floor(b3 / 16)
	local sampleRate = math.floor(b3 / 4) % 4
	return version ~= 1 and layer ~= 0 and bitrate ~= 15 and sampleRate ~= 3
end

-- Which media format `data`, the start of a file, is, or nil. This needs to be
-- strict enough not to mistake ordinary text for media.
local function signature(data)
	local magic = data:sub(1, 4)
	if magic == "\137PNG" then
		return "png"
	elseif magic == "GIF8" then
		return "gif"
	elseif data:sub(1, 3) == "\255\216\255" then
		return "jpeg"
	elseif magic == "RIFF" then
		local form = data:sub(9, 12)
		return (form == "WEBP" and "webp") or (form == "AVI " and "avi") or (form == "WAVE" and "wav") or nil
	elseif magic == "II*\0" or magic == "MM\0*" then
		return "tiff"
	elseif data:sub(1, 2) == "\255\10" or data:sub(1, 12) == "\0\0\0\12JXL \13\10\135\10" then
		return "jxl"
	elseif data:sub(1, 2) == "BM" and data:sub(7, 10) == "\0\0\0\0" then
		return "bmp" -- whose reserved bytes tell it from text starting with "BM"
	elseif (magic == "\0\0\1\0" or magic == "\0\0\2\0") and #data >= 6 and data:sub(5, 6) ~= "\0\0" then
		return "ico" -- icon or cursor, with at least one image
	elseif magic == "\26\69\223\163" then
		return "matroska" -- also WebM
	elseif magic == "OggS" then
		return "ogg"
	elseif magic == "fLaC" then
		return "flac"
	elseif data:sub(1, 5) == "%PDF-" then
		return "pdf"
	elseif data:sub(1, 3) == "ID3" or isMp3Frame(data) then
		return "mp3"
	elseif data:byte(1) == 0 then
		-- ISO media (MP4, MOV, M4A, HEIC, AVIF): a box's size, then its type
		local box = data:sub(5, 8)
		return (box == "ftyp" or box == "moov" or box == "mdat") and "iso" or nil
	end

	-- SVG: the first element, after any BOM, XML declaration, comments and doctype
	local s = data:gsub("^\239\187\191", "")
	while true do
		s = s:gsub("^%s+", "")
		local rest = s:match("^<%?.-%?>(.*)") or s:match("^<!%-%-.-%-%->(.*)") or s:match("^<!.->(.*)")
		if not rest then
			break
		end
		s = rest
	end
	return s:match("^<svg[%s>]") and "svg" or nil
end

-- Check that `data` has the signature expected for `mime` (in lowercase).
-- Guards against writing error text (stderr is merged into ExecCommand's output) as media.
local function looksLike(mime, data)
	local m = lookup(mime)
	return m ~= nil and signature(data) == m[3]
end

-- Is `data`, the start of a file, an image, video, audio or PDF in a format we know?
local function isMedia(data)
	return signature(data) ~= nil
end

return {
	isMedia = isMedia,
	EXTENSIONS = EXTENSIONS,
	extension = extension,
	selectType = selectType,
	looksLike = looksLike,
}
