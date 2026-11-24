-- Downloading the media in pasted rich text, in the background.

local micro = import("micro")
local shell = import("micro/shell")
local fmt = import("fmt")
local ioutil = import("io/ioutil")
local time = import("time")
local os = import("os")
local filepath = import("filepath")

local util = require("zettle.util")
local media = require("zettle.media")

-- ── Downloading remote media ────────────────────────────────────────────────
-- With zettle.download-media on, media in pasted rich text that live on the
-- web are downloaded beside the note. The paste happens at once, linking to
-- the remote URLs; each download runs in the background (as a curl process,
-- since plugin Lua can't start threads), and when it succeeds, the link's URL
-- is swapped for the local file. A failed download leaves the remote URL,
-- which still works, so failures need no cleanup.

local MAX_DOWNLOADS = 4 -- at once
local MAX_DOWNLOADS_PER_PASTE = 50

-- downloads[url] = { state = "pending", waiters = { { buf =, baseDir =, marker =, title = }, ... }, baseDir = ..., referer = ... }
--               or { state = "done", path = ..., baseDir = ... }
-- Failed downloads are forgotten, so pasting the URL again retries.
local downloads = {}

-- Some sites refuse curl's own User-Agent, so downloads present as a common
-- browser, picked once per session.
local USER_AGENTS = {
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 Edg/146.0.0.0",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:146.0) Gecko/20100101 Firefox/146.0",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:145.0) Gecko/20100101 Firefox/145.0",
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:146.0) Gecko/20100101 Firefox/146.0",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:145.0) Gecko/20100101 Firefox/145.0",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36 Edg/146.0.0.0",
	"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
	"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
	"Mozilla/5.0 (X11; Linux x86_64; rv:146.0) Gecko/20100101 Firefox/146.0",
	"Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:145.0) Gecko/20100101 Firefox/145.0",
	"Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0",
}
math.randomseed(time.Now():UnixNano() % 2147483647)
local USER_AGENT = USER_AGENTS[math.random(#USER_AGENTS)]
local queue = {} -- urls waiting for a free slot
local running = 0
local results = { done = 0, failed = 0 }

-- A file name for media downloaded from `url`: the URL's own name, with an
-- extension from its content type if it doesn't already have a media one.
local function downloadName(url, contentType)
	local path = url:match("^[%a][%w+.-]*://[^/]*(/[^?#]*)") or ""
	local name = util.urlDecode(path:match("([^/]*)$") or ""):gsub("[^%w%-%._]", "_")
	if name == "" or name:match("^[._]+$") then
		name = "media"
	end
	local mime = contentType:lower():match("^%s*([^;%s]+)") or ""
	local ext = media.extension(mime)
	local current = name:match("%.([^%.]+)$")
	if ext and not (current and media.EXTENSIONS[current:lower()]) then
		name = name .. "." .. ext
	end
	return name
end

-- `s` made safe to show in the InfoBar: it comes from a web server.
local function printable(s)
	s = s:gsub("%c", "?")
	return #s > 80 and (s:sub(1, 77) .. "...") or s
end

-- Why a download failed, from what curl reported.
local function downloadFailure(status, exitCode, mime, message)
	if exitCode == "28" then
		return "timed out"
	elseif status and tonumber(status) >= 400 then
		return "HTTP " .. status
	elseif exitCode and exitCode ~= "" and exitCode ~= "0" then
		return message ~= "" and printable(message) or ("curl error " .. exitCode)
	elseif status ~= "200" then
		return "HTTP " .. tostring(status)
	elseif not (mime and media.extension(mime)) then
		return "got " .. printable(mime or "an unknown type") .. " instead of an image, video, audio or PDF"
	end
	return "not a valid file of its type (" .. printable(mime) .. ")"
end

-- The first n bytes of a file, as a string.
local function fileHead(path, n)
	local data, err = ioutil.ReadFile(path)
	if err ~= nil then
		return ""
	end
	local chars = {}
	for i = 1, math.min(#data, n) do
		chars[i] = string.char(data[i])
	end
	return table.concat(chars)
end

-- A whole file, as a string, or nil.
local function readFile(path)
	local data, err = ioutil.ReadFile(path)
	if err ~= nil then
		return nil
	end
	return fmt.Sprintf("%s", data)
end

-- The file in `dir` with the same contents as `path`, among `name` and the
-- numbered names that createUnique would have given it, or nil.
local function findIdentical(dir, name, path)
	local info, err = os.Stat(path)
	if err ~= nil then
		return nil
	end
	local stem, ext = name:match("^(.+)(%.[^%.]+)$")
	if not stem then
		stem, ext = name, ""
	end
	local contents
	local candidate = filepath.Join(dir, name)
	for n = 1, 500 do
		local other, otherErr = os.Stat(candidate)
		if otherErr ~= nil then
			return nil
		end
		-- comparing sizes first means most files never need reading
		if not other:IsDir() and other:Size() == info:Size() then
			contents = contents or readFile(path)
			if contents ~= nil and readFile(candidate) == contents then
				return candidate
			end
		end
		candidate = filepath.Join(dir, stem .. "-" .. n .. ext)
	end
	return nil
end

-- A marker for a pasted link, unique even among notes saved in other sessions.
-- It's the link's title until its download finishes, so that swapping the link
-- can't touch anything that the paste didn't insert.
local markerCount = 0
local function newMarker()
	markerCount = markerCount + 1
	return ("zettle:%x-%x"):format(time.Now():Unix(), markerCount)
end

-- The end of a Markdown link to `dest`.
local function linkEnd(dest, title)
	if title and title ~= "" then
		return "](" .. dest .. ' "' .. title:gsub('[\\"]', "\\%0") .. '")'
	end
	return "](" .. dest .. ")"
end

-- Point every copy of `waiter`'s marked link in its note at `dest`, restoring
-- the link's own title. Returns whether there were any.
local function swapLink(waiter, url, dest)
	local buf = waiter.buf
	if buf.Type.Readonly then
		return false
	end
	local needle = linkEnd(url, waiter.marker)
	local replacement = linkEnd(dest, waiter.title)
	local swapped = false
	local s, e = util.findInBuffer(buf, needle)
	while s do
		buf.EventHandler:Replace(s, e, replacement)
		swapped = true
		s, e = util.findInBuffer(buf, needle)
	end
	return swapped
end

-- Put back the remote links of a download that won't happen.
local function restoreLinks(entry, url)
	for _, waiter in ipairs(entry.waiters or {}) do
		if util.bufferIsOpen(waiter.buf) then
			swapLink(waiter, url, url)
		end
	end
end

-- The file for a finished download beside a note in `baseDir`, copying it
-- there if need be, or nil if it's gone.
local function localCopy(entry, baseDir)
	local _, err = os.Stat(entry.path)
	if err ~= nil then
		return nil
	end
	local name = filepath.Base(entry.path)
	local identical = findIdentical(baseDir, name, entry.path)
	if identical then
		return identical
	end
	local f, dst = util.createUnique(baseDir, name)
	if f == nil then
		return nil
	end
	local cerr = util.copyInto(entry.path, f)
	f:Close()
	if cerr ~= nil then
		os.Remove(dst)
		return nil
	end
	return dst
end

local startDownloads

-- Finish the download of `url`: `file` is where it was saved if `ok`,
-- otherwise `reason` says why it failed.
local function finishDownload(url, ok, file, reason)
	local entry = downloads[url]
	running = running - 1
	if not ok then
		restoreLinks(entry, url)
		downloads[url] = nil
		results.failed = results.failed + 1
		local message = ("zettle: couldn't download %s: %s"):format(
			printable(url:match("^[^?#]*")),
			reason or "unknown error"
		)
		micro.Log(message)
		micro.InfoBar():Error(message)
	else
		entry.state, entry.path = "done", file
		local swapped = false
		for _, waiter in ipairs(entry.waiters) do
			if util.bufferIsOpen(waiter.buf) and util.findInBuffer(waiter.buf, linkEnd(url, waiter.marker)) then
				-- a note in another folder needs its own copy
				local copy = waiter.baseDir == entry.baseDir and file or localCopy(entry, waiter.baseDir)
				if copy and swapLink(waiter, url, "./" .. util.urlEncode(filepath.Base(copy))) then
					swapped = true
				end
			end
		end
		entry.waiters = nil
		if swapped then
			results.done = results.done + 1
		else
			-- the link was edited away, or its note closed: keep the file, but
			-- a later paste should check that it's still there
			downloads[url] = nil
			micro.Log("zettle: downloaded " .. url .. " to " .. file .. " but its link is gone")
		end
	end
	startDownloads()
	if running == 0 and #queue == 0 then
		-- a single failure's own error is more useful, so leave it showing
		if results.failed > 1 then
			micro
				.InfoBar()
				:Error(
					("zettle: downloaded %d files; %d failed and keep their URLs"):format(results.done, results.failed)
				)
		end
		results.done, results.failed = 0, 0
	end
end

local function startDownload(url)
	local entry = downloads[url]
	local part, partPath = util.createUnique(entry.baseDir, ".zettle-download.part")
	if part == nil then
		micro.Log("zettle: can't download " .. url .. ": " .. partPath)
		running = running + 1
		finishDownload(url, false, nil, printable(partPath))
		return
	end
	part:Close()
	running = running + 1
	local noop = function() end
	local args = {
		"-fsL",
		"-A",
		USER_AGENT,
		-- ";auto" alone sends no Referer except on redirects
		"-e",
		(entry.referer or "") .. ";auto",
		"--connect-timeout",
		"10",
		"--max-time",
		"60",
		"--max-filesize",
		"50M",
		"-o",
		partPath,
		"-w",
		"\n%{http_code}\t%{exitcode}\t%{content_type}\t%{errormsg}",
		url,
	}
	micro.Log("zettle: curl " .. table.concat(args, " "))
	shell.JobSpawn("curl", args, noop, noop, function(output)
		local report = (output or ""):match("([^\n]*)\n?$")
		local status, exitCode, contentType, message = report:match("^(%d%d%d)\t(%d*)\t([^\t]*)\t(.*)$")
		local mime = contentType and contentType:lower():match("^%s*([^;%s]+)")
		if not (status == "200" and exitCode == "0" and mime and media.looksLike(mime, fileHead(partPath, 512))) then
			micro.Log(("zettle: curl reported for %s: %s"):format(url, report))
			os.Remove(partPath)
			finishDownload(url, false, nil, downloadFailure(status, exitCode, mime, message or ""))
			return
		end
		local name = downloadName(url, contentType)
		local identical = findIdentical(downloads[url].baseDir, name, partPath)
		if identical then
			-- already beside the note, e.g. from pasting this page before
			os.Remove(partPath)
			finishDownload(url, true, identical)
			return
		end
		local f, dst = util.createUnique(downloads[url].baseDir, name)
		if f == nil then
			os.Remove(partPath)
			finishDownload(url, false, nil, "couldn't save it: " .. printable(dst))
			return
		end
		f:Close()
		local err = os.Rename(partPath, dst)
		if err ~= nil then
			os.Remove(partPath)
			os.Remove(dst)
			finishDownload(url, false, nil, "couldn't save it: " .. printable(err:Error()))
			return
		end
		finishDownload(url, true, dst)
	end)
end

startDownloads = function()
	while running < MAX_DOWNLOADS and #queue > 0 do
		startDownload(table.remove(queue, 1))
	end
end

-- The Referer to send when downloading `url`: the page it was copied from,
-- if known, else the media's own site. Hotlink protection usually only
-- checks that the Referer is from the same site.
local function downloadReferer(url, pageUrl)
	if pageUrl then
		return pageUrl
	end
	local origin = url:match("^(https?://[^/?#]+)")
	return origin and origin .. "/" or nil
end

-- Start any queued downloads.
local function startQueuedDownloads()
	if #queue == 0 then
		return
	end
	if not util.installed("curl", "--version") then
		micro.InfoBar():Error("zettle: zettle.download-media needs curl, which isn't installed")
		for _, url in ipairs(queue) do
			restoreLinks(downloads[url], url)
			downloads[url] = nil
		end
		queue = {}
		return
	end
	startDownloads()
end

-- The local link for `url` if it's already been downloaded, copying the file
-- beside a note in `baseDir` if need be, or nil.
local function downloadedLink(url, baseDir)
	local entry = downloads[url]
	local file = entry and entry.state == "done" and localCopy(entry, baseDir)
	return file and "./" .. util.urlEncode(filepath.Base(file)) or nil
end

-- Download the media in `items`, { url =, marker =, title = }, whose marked
-- links have just been pasted into `buf`, to `baseDir`. Each link is swapped
-- for the local file when it's ready, or restored if the download fails.
local function queueMediaDownloads(buf, baseDir, items, pageUrl)
	for _, item in ipairs(items) do
		local waiter = { buf = buf, baseDir = baseDir, marker = item.marker, title = item.title }
		local entry = downloads[item.url]
		if entry and entry.state == "pending" then
			-- already downloading: swap this paste's link too when it's done
			entry.waiters[#entry.waiters + 1] = waiter
		else
			downloads[item.url] = {
				state = "pending",
				waiters = { waiter },
				baseDir = baseDir,
				referer = downloadReferer(item.url, pageUrl),
			}
			queue[#queue + 1] = item.url
		end
	end
	startQueuedDownloads()
end

return {
	MAX_DOWNLOADS_PER_PASTE = MAX_DOWNLOADS_PER_PASTE,
	newMarker = newMarker,
	downloadedLink = downloadedLink,
	queue = queueMediaDownloads,
}
