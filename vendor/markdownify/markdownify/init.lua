-- markdownify: convert HTML to Markdown, as GitHub and Obsidian do when
-- pasting rich text: keep what Markdown can represent (headings, emphasis,
-- links, images, lists, tables, quotes, code), keep the text of everything
-- else, and drop what's only presentation (styles, scripts).
--
--   local markdownify = require("markdownify")
--   markdownify.convert(html, { imageHandler = function(src, alt, title) ... end })
--
-- imageHandler, if given, is called for every image with its src, alt and
-- title as plain text, and returns src, alt, title. A nil src drops the image
-- (leaving its alt text). A nil alt or title keeps the original; "" removes it.
--
-- anchor, if given, turns a heading's Markdown line ("## Some heading") into
-- the anchor that links to it ("some-heading"); it's used to point links to
-- sections of the copied page at those headings. The default is GitHub's.
--
-- yield, if given, is called often during the conversion, e.g. to yield a
-- coroutine so that converting a large document doesn't block.

-- markdownify needs lusoup's HTML5 parser, which upstream lusoup doesn't
-- have yet, so a copy is bundled as markdownify.lusoup. Make lusoup's
-- modules (which require each other as "lusoup.*") load from that copy.
-- table.concat, in pieces: gopher-lua (micro's Lua) pushes every element
-- onto its fixed-size registry, so concatenating more than a few thousand
-- at once fails with "registry overflow".
local function concat(t, sep)
	sep = sep or ""
	local n = #t
	if n <= 1000 then
		return table.concat(t, sep)
	end
	local chunks = {}
	for i = 1, n, 1000 do
		chunks[#chunks + 1] = table.concat(t, sep, i, math.min(i + 999, n))
	end
	return concat(chunks, sep)
end

for _, name in ipairs({ "init", "dom", "tokenizer", "treebuilder", "selector", "entities", "entity_table" }) do
	local module = name == "init" and "lusoup" or ("lusoup." .. name)
	local bundled = name == "init" and "markdownify.lusoup" or ("markdownify.lusoup." .. name)
	if package.loaded[module] == nil then
		package.preload[module] = function()
			return require(bundled)
		end
	end
end

local M = {}

local function set(list)
	local t = {}
	for name in list:gmatch("%S+") do
		t[name] = true
	end
	return t
end

-- Elements whose content is dropped entirely.
local SKIP = set("head title style script noscript template meta link object embed iframe select textarea")

-- Elements that start blocks; anything else is inline.
local BLOCK = set([[address article aside blockquote body center dd details dialog
	div dl dt fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header
	hgroup hr html li main menu nav ol p pre search section summary table tbody
	td tfoot th thead tr ul]])

local HEADINGS = { h1 = 1, h2 = 2, h3 = 3, h4 = 4, h5 = 5, h6 = 6 }

local NBSP = "\194\160"

-- A hard line break inside a paragraph, kept as a marker until the
-- paragraph's whitespace has been tidied.
local BREAK = "\0"

-- ── Text ────────────────────────────────────────────────────────────────────

-- Remove invisible characters that only affect layout or could disguise the
-- text, so that the Markdown can be searched and edited; a document can be
-- hyphenated again when it's next typeset. Removes C0 controls (except
-- whitespace), DEL, C1 controls, soft hyphens, zero-width spaces, word joiners,
-- byte order marks, and bidi embeddings and overrides. Turns non-breaking
-- hyphens into plain ones.
--
-- Keeps what some text needs: ZWJ and ZWNJ (emoji, Persian, Indic scripts),
-- variation selectors, tag characters (subdivision flags), and LRM, RLM and
-- bidi isolates (mixed left-to-right and right-to-left text).
local function clean_text(s)
	-- most text has none of these bytes: checking first saves pattern
	-- searches, which are slow in some Lua implementations (micro's gopher-lua)
	if not s:find("[%z\1-\8\11\14-\31\127\194\226\239]") then
		return s
	end
	s = s:gsub("[%z\1-\8\11\14-\31\127]", "")
	if s:find("\194", 1, true) then
		s = s:gsub("\194[\128-\159\173]", "") -- C1 controls, soft hyphen
	end
	if s:find("\226", 1, true) then
		s = s
			:gsub("\226\128[\139\170-\174]", "") -- zero-width space, bidi embeddings and overrides
			:gsub("\226\129\160", "") -- word joiner
			:gsub("\226\128\145", "-") -- non-breaking hyphen
	end
	if s:find("\239\187\191", 1, true) then
		s = s:gsub("\239\187\191", "") -- byte order mark
	end
	return s
end

-- Plain searches are fast everywhere; pattern searches and gsub() are slow
-- in some Lua implementations (micro's gopher-lua copies the string and
-- recompiles the pattern on every call, then runs it at every position), so
-- these check with plain searches whether a pattern is needed at all.
local find, byte = string.find, string.byte

-- Does `s` contain any of the strings in `list`?
local function has_any(s, list)
	for i = 1, #list do
		if find(s, list[i], 1, true) then
			return true
		end
	end
	return false
end

local MARKDOWN_SPECIALS = { "\\", "`", "*", "_", "[", "]" }

-- Escape characters that Markdown would otherwise read as formatting.
local function escape_inline(s)
	if not has_any(s, MARKDOWN_SPECIALS) then
		return s
	end
	return (s:gsub("([\\`*_%[%]])", "\\%1"))
end

-- Escape what would end a Markdown link title in double quotes.
local function escape_title(s)
	return (s:gsub('([\\"])', "\\%1"))
end

-- Escape what would start a block if it began a line: "# ", "> ", "- ",
-- "+ ", "1. " and so on.
local function escape_line_start(line)
	-- only these can start a block; checking first saves pattern searches,
	-- which are slow in some Lua implementations (micro's gopher-lua)
	local b = line:byte(1)
	if not (b == 35 or b == 62 or b == 45 or b == 43 or (b and b >= 48 and b <= 57)) then -- # > - + 0-9
		return line
	end
	if b == 62 then -- >
		return "\\" .. line
	elseif b == 35 then -- #
		if line:find("^#+ ") or line:find("^#+$") then
			return "\\" .. line
		end
		return line
	elseif b == 45 or b == 43 then -- - +
		local b2 = line:byte(2)
		if b2 == 32 or b2 == nil then
			return "\\" .. line
		end
		return line
	end
	-- a digit: only a run of digits then . or ) can start a list
	local d = 2
	while true do
		local x = line:byte(d)
		if x == nil or x < 48 or x > 57 then
			if x ~= 46 and x ~= 41 then
				return line
			end
			break
		end
		d = d + 1
	end
	local digits, rest = line:match("^(%d+)([.)].*)$")
	if digits and (rest:find("^[.)] ") or #rest == 1) then
		return digits .. "\\" .. rest
	end
	return line
end

-- Tidy a paragraph's text: collapse whitespace, turn break markers into
-- Markdown hard breaks, and trim.
local SPACE_RUNS = { "\t", "\n", "\r", "\f", "  " }

-- `s` without leading and trailing spaces.
local function trim_spaces(s)
	local i, j = 1, #s
	while byte(s, i) == 32 do
		i = i + 1
	end
	while j >= i and byte(s, j) == 32 do
		j = j - 1
	end
	if i == 1 and j == #s then
		return s
	end
	return s:sub(i, j)
end

local function is_space_byte(b)
	return b == 32 or b == 10 or b == 9 or b == 13 or b == 12
end

-- `s` with each run of whitespace turned into a single space. Plain
-- searches for where runs start, so the work is per run, not per byte.
local function collapse_spaces(s)
	local next_at = {}
	local out, pos = {}, 1
	while true do
		local at
		for i = 1, #SPACE_RUNS do
			local c = SPACE_RUNS[i]
			local a = next_at[c]
			if a == nil or (a and a < pos) then
				a = find(s, c, pos, true) or false
				next_at[c] = a
			end
			if a and (not at or a < at) then
				at = a
			end
		end
		if not at then
			break
		end
		local start, e = at, at
		while start > pos and byte(s, start - 1) == 32 do
			start = start - 1
		end
		while is_space_byte(byte(s, e + 1)) do
			e = e + 1
		end
		out[#out + 1] = s:sub(pos, start - 1)
		out[#out + 1] = " "
		pos = e + 1
	end
	if pos == 1 then
		return s
	end
	out[#out + 1] = s:sub(pos)
	return concat(out)
end

local function finish_paragraph(s)
	if find(s, NBSP, 1, true) then
		s = s:gsub(NBSP, " ")
	end
	s = collapse_spaces(s)
	local lines = {}
	if find(s, BREAK, 1, true) then
		for line in (s .. BREAK):gmatch("(.-)%z") do
			lines[#lines + 1] = escape_line_start(trim_spaces(line))
		end
	else
		lines[1] = escape_line_start(trim_spaces(s))
	end
	-- drop empty lines from breaks at the start or end
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	while #lines > 0 and lines[1] == "" do
		table.remove(lines, 1)
	end
	return concat(lines, "\\\n")
end

-- The raw text of a node, for code: whitespace kept, <br> as a newline.
local function raw_text(node)
	if node.tag == "#text" then
		return node.text_content
	elseif node.tag == "br" then
		return "\n"
	end
	local parts = {}
	for _, child in ipairs(node.children) do
		parts[#parts + 1] = raw_text(child)
	end
	return concat(parts)
end

-- The shortest run of backticks that doesn't occur in s, with one more for a fence.
local function backticks_for(s, minimum)
	local longest = 0
	for run in s:gmatch("`+") do
		longest = math.max(longest, #run)
	end
	return string.rep("`", math.max(minimum, longest + 1))
end

-- ── Inline content ──────────────────────────────────────────────────────────

-- Wrap text in a Markdown delimiter (**, *, ~~), keeping leading and
-- trailing spaces outside it, where Markdown needs them.
local function wrap(delimiter, s)
	-- spaces and break markers (NULs) stay outside
	local i, j = 1, #s
	while byte(s, i) == 32 or byte(s, i) == 0 do
		i = i + 1
	end
	if i > j then
		return s
	end
	while byte(s, j) == 32 or byte(s, j) == 0 do
		j = j - 1
	end
	return s:sub(1, i - 1) .. delimiter .. s:sub(i, j) .. delimiter .. s:sub(j + 1)
end

-- What an element's inline style says about weight, slant and strike-through.
local function style_hints(node)
	if not node.attrs.style then
		return nil, false, false
	end
	local style = node.attrs.style:lower():gsub("%s", "")
	local weight = style:match("font%-weight:(%w+)")
	local bold
	if weight then
		bold = weight == "bold" or weight == "bolder" or (tonumber(weight) or 0) >= 600
	end
	local italic = style:find("font%-style:italic") ~= nil or style:find("font%-style:oblique") ~= nil
	local strike = style:find("text%-decoration[%w%-]*:[^;]*line%-through") ~= nil
	return bold, italic, strike
end

local function link_destination(url)
	if url:find("[%s()<>]") then
		return "<" .. url:gsub("[<>]", function(c)
			return c == "<" and "%3C" or "%3E"
		end) .. ">"
	end
	return url
end

local render_inline
local heading_line

-- The fragment of `href`, whose "#" is at `hash`, %-decoded.
local function url_fragment(href, hash)
	local fragment = href:sub(hash + 1)
	if fragment:find("%", 1, true) then
		fragment = fragment:gsub("%%(%x%x)", function(h)
			return string.char(tonumber(h, 16))
		end)
	end
	return fragment
end

-- A URL without its fragment, and the fragment, %-decoded (or nil).
local function split_fragment(href)
	local hash = href:find("#", 1, true)
	if not hash then
		return href, nil
	end
	return href:sub(1, hash - 1), url_fragment(href, hash)
end

-- The element in the converted document that `href` points at, or nil. Only
-- links to the copied page count: relative ones ("#notes"), and ones to the
-- page the HTML was copied from (see find_page()).
local function link_target(href, opts)
	local base, fragment = split_fragment(href)
	if not fragment or fragment == "" then
		return nil
	end
	local target = opts.ids[fragment]
	if target and (base == "" or base == opts.page) then
		return target
	end
	return nil
end

-- If `href` links to a heading in the converted document, a link to it in
-- the Markdown ("#slug") and the heading's text, else nil.
local function local_anchor(href, opts)
	local target = link_target(href, opts)
	if not target or not HEADINGS[target.tag] then
		return nil
	end
	local line = heading_line(target, opts)
	if line == "" then
		return nil
	end
	return "#" .. opts.anchor(line), line:gsub("^#+ ", "")
end

local function inline_children(node, opts)
	local parts = {}
	local after_item = false
	for _, child in ipairs(node.children) do
		local text = opts.footnotes.targets[child] and "" or render_inline(child, opts)
		-- blocks met inline (e.g. a list in a table cell) mustn't run together:
		-- separate list items with a middle dot, as Wikipedia's lists show
		if child.tag == "li" then
			if after_item and text ~= "" then
				text = " · " .. text
			end
			after_item = after_item or text ~= ""
		elseif BLOCK[child.tag] and text ~= "" then
			text = " " .. text .. " "
		end
		parts[#parts + 1] = text
	end
	return concat(parts)
end

-- A heading's Markdown line ("## Text"), or "" if it has no text.
heading_line = function(node, opts)
	local text = finish_paragraph(inline_children(node, opts)):gsub("\\\n", " ")
	if text == "" then
		return ""
	end
	return string.rep("#", HEADINGS[node.tag]) .. " " .. text
end

render_inline = function(node, opts)
	local tag = node.tag
	if tag == "#text" then
		return escape_inline(clean_text(node.text_content))
	elseif not node:is_element() or SKIP[tag] then
		return ""
	elseif tag == "br" then
		return BREAK
	elseif tag == "code" or tag == "kbd" or tag == "samp" or tag == "tt" then
		local text = raw_text(node):gsub("[\n\r]", " ")
		if text == "" then
			return ""
		end
		local fence = backticks_for(text, 1)
		local pad = (text:find("^`") or text:find("`$")) and " " or ""
		return fence .. pad .. text .. pad .. fence
	elseif tag == "sup" and opts.footnotes.refs[node] then
		return "[^" .. opts.footnotes.refs[node].label .. "]"
	elseif tag == "a" then
		local text = inline_children(node, opts)
		local href = node.attrs.href
		if not href or href == "" or href:lower():find("^%s*javascript:") then
			return text
		end
		local target = link_target(href, opts)
		if target and (opts.footnotes.refs[target] or (target.parent and opts.footnotes.refs[target.parent])) then
			-- a footnote's link back to where it's cited: Markdown makes its own
			return ""
		end
		local core = finish_paragraph(text)
		local anchor, heading = local_anchor(href, opts)
		if core == "" and heading then
			-- e.g. a table of contents whose text the browser didn't copy
			text = heading
		elseif core == "" then
			-- browsers sometimes copy a link without its text (Firefox does,
			-- for Wikipedia's navigation boxes); its title usually names it
			local title = node.attrs.title
			if not title or not title:find("%S") then
				return ""
			end
			text = escape_inline(clean_text(title))
		elseif core == escape_inline(href) then
			return "<" .. href .. ">"
		end
		return "[" .. text .. "](" .. link_destination(anchor or href) .. ")"
	elseif tag == "img" then
		local alt = clean_text(node.attrs.alt or "")
		local title = clean_text(node.attrs.title or "")
		local src = node.attrs.src or ""
		if opts.imageHandler then
			local newAlt, newTitle
			src, newAlt, newTitle = opts.imageHandler(src, alt, title ~= "" and title or nil)
			alt = newAlt == nil and alt or newAlt
			title = newTitle == nil and title or newTitle
		end
		if not src or src == "" then
			return escape_inline(alt)
		end
		local dest = link_destination(src)
		if title ~= "" then
			dest = dest .. ' "' .. escape_title(title) .. '"'
		end
		return "![" .. escape_inline(alt) .. "](" .. dest .. ")"
	elseif tag == "input" then
		if (node.attrs.type or ""):lower() == "checkbox" then
			return node.attrs.checked and "[x] " or "[ ] "
		end
		return ""
	end

	local text = inline_children(node, opts)
	local bold, italic, strike = style_hints(node)
	if tag == "strong" or tag == "b" then
		-- Google Docs wraps everything in <b style="font-weight:normal">
		bold = bold ~= false
	elseif tag == "em" or tag == "i" or tag == "cite" or tag == "dfn" or tag == "var" then
		italic = true
	elseif tag == "del" or tag == "s" or tag == "strike" then
		strike = true
	end
	if strike then
		text = wrap("~~", text)
	end
	if italic then
		text = wrap("*", text)
	end
	if bold then
		text = wrap("**", text)
	end
	return text
end

-- ── Blocks ──────────────────────────────────────────────────────────────────

local render_blocks

-- Prefix the first line of `block` with `first` and the others with `rest`.
local function indent(block, first, rest)
	local out, i = {}, 0
	for line in (block .. "\n"):gmatch("(.-)\n") do
		i = i + 1
		local prefix = i == 1 and first or rest
		out[#out + 1] = line == "" and prefix:gsub("%s+$", "") or prefix .. line
	end
	return concat(out, "\n")
end

local function render_list(node, opts, ordered)
	local items = {}
	local number = tonumber(node.attrs.start or "") or 1
	for _, child in ipairs(node.children) do
		if opts.footnotes.targets[child] then
			-- rendered as a footnote instead
		elseif child.tag == "li" then
			local marker = ordered and (number .. ". ") or "- "
			number = number + 1
			-- a sub-list directly after text stays tight: "- a\n  - b"
			local body = ""
			for i, block in ipairs(render_blocks(child, opts)) do
				local is_list = block:find("^%- ") or block:find("^%d+%. ")
				body = i == 1 and block or body .. (is_list and "\n" or "\n\n") .. block
			end
			items[#items + 1] = indent(body, marker, string.rep(" ", #marker))
		elseif child:is_element() then
			-- stray content directly in a list
			for _, block in ipairs(render_blocks(child, opts)) do
				items[#items + 1] = block
			end
		end
	end
	-- items that span several blocks need blank lines between items too
	local loose = false
	for _, item in ipairs(items) do
		if item:find("\n\n") then
			loose = true
		end
	end
	return concat(items, loose and "\n\n" or "\n")
end

local function table_rows(node, rows)
	for _, child in ipairs(node.children) do
		if child.tag == "tr" then
			rows[#rows + 1] = child
		elseif child.tag == "thead" or child.tag == "tbody" or child.tag == "tfoot" then
			table_rows(child, rows)
		end
	end
	return rows
end

local function render_table(node, opts)
	local rows, width = {}, 0
	for _, tr in ipairs(table_rows(node, {})) do
		local cells = {}
		for _, cell in ipairs(tr.children) do
			if cell.tag == "td" or cell.tag == "th" then
				local text = finish_paragraph(inline_children(cell, opts))
				if find(text, "\\\n", 1, true) then
					text = text:gsub("\\\n", " ")
				end
				if find(text, "|", 1, true) then
					text = text:gsub("|", "\\|")
				end
				cells[#cells + 1] = text
			end
		end
		if #cells > 0 then
			rows[#rows + 1] = cells
			width = math.max(width, #cells)
		end
	end
	if #rows == 0 then
		return nil
	end
	local lines = {}
	local function add(cells)
		local padded = {}
		for i = 1, width do
			padded[i] = cells[i] or ""
		end
		lines[#lines + 1] = "| " .. concat(padded, " | ") .. " |"
	end
	-- Markdown tables need a header row; use the first row
	add(rows[1])
	lines[#lines + 1] = "|" .. string.rep(" --- |", width)
	for i = 2, #rows do
		add(rows[i])
	end
	return concat(lines, "\n")
end

local function code_language(node)
	local function language(n)
		local class = n.attrs and n.attrs.class or ""
		return class:match("language%-([%w_+#-]+)") or class:match("lang%-([%w_+#-]+)")
	end
	local lang = language(node)
	if not lang then
		for _, child in ipairs(node.children) do
			if child.tag == "code" then
				lang = language(child)
			end
		end
	end
	return lang or ""
end

-- Render a node's children as a list of Markdown blocks, gathering inline
-- content between blocks into paragraphs.
render_blocks = function(node, opts)
	local blocks, inline = {}, {}
	local function flush()
		local text = finish_paragraph(concat(inline))
		if text ~= "" then
			blocks[#blocks + 1] = text
		end
		inline = {}
	end
	local function add(block)
		if block and block ~= "" then
			blocks[#blocks + 1] = block
		end
	end

	for _, child in ipairs(node.children) do
		if opts.yield then
			opts.yield()
		end
		local tag = child.tag
		if opts.footnotes.targets[child] then
			-- rendered as a footnote instead
		elseif child:is_element() and BLOCK[tag] and not SKIP[tag] then
			flush()
			if HEADINGS[tag] then
				add(heading_line(child, opts))
			elseif tag == "hr" then
				add("---")
			elseif tag == "pre" then
				local text = raw_text(child):gsub("\n$", "")
				local fence = backticks_for(text, 3)
				add(fence .. code_language(child) .. "\n" .. text .. "\n" .. fence)
			elseif tag == "blockquote" then
				local body = concat(render_blocks(child, opts), "\n\n")
				if body ~= "" then
					add(indent(body, "> ", "> "))
				end
			elseif tag == "ul" or tag == "menu" then
				add(render_list(child, opts, false))
			elseif tag == "ol" then
				add(render_list(child, opts, true))
			elseif tag == "table" then
				add(render_table(child, opts))
			elseif tag == "dt" or tag == "summary" then
				add(wrap("**", finish_paragraph(inline_children(child, opts))))
			else
				-- containers (div, p, section, li, td outside a table, ...)
				for _, block in ipairs(render_blocks(child, opts)) do
					add(block)
				end
			end
		else
			inline[#inline + 1] = render_inline(child, opts)
		end
	end
	flush()
	return blocks
end

-- ── Entry point ─────────────────────────────────────────────────────────────

-- Browsers mark the copied part of clipboard HTML with these comments.
-- The position of the first `<!--name-->` comment in html, and of its end.
-- Looks for the name with a plain search first: a pattern search through a
-- large document is slow in some Lua implementations (micro's gopher-lua).
local function find_marker(html, name)
	local init = 1
	while true do
		local at = html:find(name, init, true)
		if not at then
			return nil
		end
		local s, e = html:find("<!%-%-%s*" .. name .. "%s*%-%->", math.max(1, at - 16))
		if s and s <= at then
			return s, e
		end
		init = at + 1
	end
end

local function clipboard_fragment(html)
	local start = select(2, find_marker(html, "StartFragment"))
	local stop = find_marker(html, "EndFragment")
	if start and stop and stop > start then
		return html:sub(start + 1, stop - 1)
	end
	return html
end

-- GitHub's anchor for a heading line: lowercase, punctuation dropped,
-- spaces as hyphens. (Unlike GitHub, non-ASCII letters are kept as they are.)
local function github_anchor(line)
	local text = line:gsub("^#+%s+", ""):lower()
	return (text:gsub("[%p]", function(c)
		return (c == "-" or c == "_") and c or ""
	end):gsub("%s", "-"))
end

local function site_of(url)
	return url:match("^(%a[%w+.-]*://[^/?#]*)")
end

-- Every element in `body` with an id, as { id = node }, the URLs of its
-- links, and its <sup>s, in document order.
local function index_document(body)
	local ids, links, sups = {}, {}, {}
	local function walk(node)
		if node.attrs then
			local id = node.attrs.id
			if id and ids[id] == nil then
				ids[id] = node
			end
			if node.tag == "a" and node.attrs.href then
				links[#links + 1] = node.attrs.href
			elseif node.tag == "sup" then
				sups[#sups + 1] = node
			end
		end
		for _, child in ipairs(node.children or {}) do
			walk(child)
		end
	end
	walk(body)
	return ids, links, sups
end

-- The page the HTML was copied from, as links to it appear: browsers copy
-- in-page links ("#History") as absolute ones ("https://host/page#History").
-- `source` is the page's URL (Chromium gives it), or only its site (Firefox
-- does). Given only the site, the page is the one there whose links reach
-- elements in the HTML, if there's exactly one; otherwise there's no telling
-- links to it from links to other pages, and nil is returned.
local function find_page(source, ids, links)
	if not source then
		return nil
	end
	local base = split_fragment(source)
	local site = site_of(base)
	if not site then
		return nil
	end
	if base ~= site and base ~= site .. "/" then
		return base
	end
	local page
	for _, href in ipairs(links) do
		local b, fragment = split_fragment(href)
		if fragment and ids[fragment] and b ~= "" and site_of(b) == site and b ~= page then
			if page then
				return nil -- two pages: ambiguous
			end
			page = b
		end
	end
	return page
end

-- If `sup` is a footnote reference, a <sup> holding just a link, the link.
local function footnote_link(sup)
	local link
	for _, child in ipairs(sup.children) do
		if child.tag == "a" and child.attrs.href and not link then
			link = child
		elseif child.tag ~= "#text" or child.text_content:find("%S") then
			return nil
		end
	end
	return link
end

-- The document's footnotes: refs maps each footnote reference (<sup>) to its
-- note; notes are { label, href, target }, in order, with target the element
-- holding the note's text if it was copied too; targets is the set of those.
local function find_footnotes(sups, opts)
	local footnotes = { refs = {}, order = {}, targets = {} }
	local by_href, labels = {}, {}
	for _, sup in ipairs(sups) do
		local link = footnote_link(sup)
		if link then
			local href = link.attrs.href
			local note = by_href[href]
			if not note then
				-- "[7]" -> "7"; "[note 1]" -> "note-1"
				local label = raw_text(link):gsub("[%[%]]", ""):gsub("^%s+", ""):gsub("%s+$", "")
				label = label:gsub("%s+", "-"):gsub("[^%w%-_.]", "")
				if label == "" then
					label = tostring(#footnotes.order + 1)
				end
				local unique, n = label, 1
				while labels[unique] do
					n = n + 1
					unique = label .. "-" .. n
				end
				labels[unique] = true
				note = { label = unique, href = href, target = link_target(href, opts) }
				by_href[href] = note
				footnotes.order[#footnotes.order + 1] = note
				if note.target then
					footnotes.targets[note.target] = true
				end
			end
			footnotes.refs[sup] = note
		end
	end
	return footnotes
end

-- The footnotes' definitions: the copied text of each, or a link to it.
local function render_footnotes(opts)
	local defs = {}
	for _, note in ipairs(opts.footnotes.order) do
		local body
		if note.target then
			-- render the target itself, which is skipped where it was
			opts.footnotes.targets[note.target] = nil
			body = concat(render_blocks(note.target, opts), "\n\n")
			opts.footnotes.targets[note.target] = true
		end
		if not body or body == "" then
			local href = note.href
			body = href:find("[%s<>()]") and ("[" .. escape_inline(href) .. "](" .. link_destination(href) .. ")")
				or ("<" .. href .. ">")
		end
		defs[#defs + 1] = "[^" .. note.label .. "]: " .. body:gsub("\n(.)", "\n    %1")
	end
	return concat(defs, "\n")
end

function M.convert(html, opts)
	opts = opts or {}
	local lusoup = require("lusoup")
	local document = lusoup.parse_document(clipboard_fragment(html), { yield = opts.yield })
	local body
	for _, child in ipairs(document.children) do
		if child.tag == "html" then
			for _, part in ipairs(child.children) do
				if part.tag == "body" then
					body = part
				end
			end
		end
	end
	if not body then
		return ""
	end
	local ctx = {}
	for k, v in pairs(opts) do
		ctx[k] = v
	end
	ctx.anchor = opts.anchor or github_anchor
	local links, sups
	ctx.ids, links, sups = index_document(body)
	ctx.page = find_page(opts.source, ctx.ids, links)
	ctx.footnotes = find_footnotes(sups, ctx)
	local md = concat(render_blocks(body, ctx), "\n\n")
	if #ctx.footnotes.order > 0 then
		md = md .. "\n\n" .. render_footnotes(ctx)
	end
	if md:find("\n\n\n", 1, true) then
		md = md:gsub("\n\n\n+", "\n\n")
	end
	return md
end

return M
