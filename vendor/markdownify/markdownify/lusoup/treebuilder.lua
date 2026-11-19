-- The HTML5 tree builder, following
-- https://html.spec.whatwg.org/multipage/parsing.html#tree-construction
--
-- It reads tokens from lusoup.tokenizer and builds a tree of lusoup.dom
-- Nodes, with all of HTML5's insertion modes, the adoption agency
-- algorithm, foster parenting, foreign content (SVG and MathML), <template>
-- and the fragment parsing algorithm. Parse errors aren't reported, and
-- scripts don't run (but the scripting flag can be set, which changes how
-- <noscript> is parsed).

local Node = require("lusoup.dom")
local tokenizer_mod = require("lusoup.tokenizer")

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

local function set(list)
    local t = {}
    for tag in list:gmatch("%S+") do
        t[tag] = true
    end
    return t
end

-- ── Element categories ──────────────────────────────────────────────────────

local SPECIAL = set([[address applet area article aside base basefont bgsound
    blockquote body br button caption center col colgroup dd details dir div dl
    dt embed fieldset figcaption figure footer form frame frameset h1 h2 h3 h4
    h5 h6 head header hgroup hr html iframe img input keygen link li listing
    main marquee menu meta nav noembed noframes noscript object ol p param
    plaintext pre script search section select source style summary table
    tbody td template textarea tfoot th thead title tr track ul wbr xmp]])
local SPECIAL_MATHML = set("mi mo mn ms mtext annotation-xml")
local SPECIAL_SVG = set("foreignObject desc title")

local FORMATTING = set("a b big code em font i nobr s small strike strong tt u")
local HEADINGS = set("h1 h2 h3 h4 h5 h6")
local IMPLIED_END_TAGS = set("dd dt li optgroup option p rb rp rt rtc")
local IMPLIED_END_TAGS_THOROUGH = set([[caption colgroup dd dt li optgroup option p
    rb rp rt rtc tbody td tfoot th thead tr]])

-- scope boundaries in the HTML namespace
local SCOPE_HTML = set("applet caption html table td th marquee object template")
local SCOPE_MATHML = set("mi mo mn ms mtext annotation-xml")
local SCOPE_SVG = set("foreignObject desc title")

local function is_special(node)
    local ns = rawget(node, "namespace")
    if ns == nil then
        return SPECIAL[node.tag]
    elseif ns == "math" then
        return SPECIAL_MATHML[node.tag]
    else
        return SPECIAL_SVG[node.tag]
    end
end

-- Is `node` an HTML element with this tag?
local function is_html(node, tag)
    return node ~= nil and rawget(node, "namespace") == nil and node.tag == tag
end

-- ── Foreign content tables ──────────────────────────────────────────────────

local SVG_TAG_ADJUSTMENTS = {}
for name in
    ([[altGlyph altGlyphDef altGlyphItem animateColor animateMotion
    animateTransform clipPath feBlend feColorMatrix feComponentTransfer
    feComposite feConvolveMatrix feDiffuseLighting feDisplacementMap
    feDistantLight feDropShadow feFlood feFuncA feFuncB feFuncG feFuncR
    feGaussianBlur feImage feMerge feMergeNode feMorphology feOffset
    fePointLight feSpecularLighting feSpotLight feTile feTurbulence
    foreignObject glyphRef linearGradient radialGradient textPath]]):gmatch("%S+")
do
    SVG_TAG_ADJUSTMENTS[name:lower()] = name
end

local SVG_ATTR_ADJUSTMENTS = {}
for name in
    ([[attributeName attributeType baseFrequency baseProfile calcMode
    clipPathUnits diffuseConstant edgeMode filterUnits glyphRef gradientTransform
    gradientUnits kernelMatrix kernelUnitLength keyPoints keySplines keyTimes
    lengthAdjust limitingConeAngle markerHeight markerUnits markerWidth
    maskContentUnits maskUnits numOctaves pathLength patternContentUnits
    patternTransform patternUnits pointsAtX pointsAtY pointsAtZ preserveAlpha
    preserveAspectRatio primitiveUnits refX refY repeatCount repeatDur
    requiredExtensions requiredFeatures specularConstant specularExponent
    spreadMethod startOffset stdDeviation stitchTiles surfaceScale
    systemLanguage tableValues targetX targetY textLength viewBox viewTarget
    xChannelSelector yChannelSelector zoomAndPan]]):gmatch("%S+")
do
    SVG_ATTR_ADJUSTMENTS[name:lower()] = name
end

-- Attributes in foreign content that belong to a namespace.
local FOREIGN_ATTRS = {
    ["xlink:actuate"] = "xlink",
    ["xlink:arcrole"] = "xlink",
    ["xlink:href"] = "xlink",
    ["xlink:role"] = "xlink",
    ["xlink:show"] = "xlink",
    ["xlink:title"] = "xlink",
    ["xlink:type"] = "xlink",
    ["xml:lang"] = "xml",
    ["xml:space"] = "xml",
    ["xmlns"] = "xmlns",
    ["xmlns:xlink"] = "xmlns",
}

-- Start tags that break out of foreign content back into HTML.
local BREAKOUT = set([[b big blockquote body br center code dd div dl dt em embed
    h1 h2 h3 h4 h5 h6 head hr i img li listing menu meta nobr ol p pre ruby s
    small span strong strike sub sup table tt u ul var]])

-- ── Quirks mode ─────────────────────────────────────────────────────────────

local QUIRKS_PUBLIC_PREFIXES = {
    "+//silmaril//dtd html pro v0r11 19970101//",
    "-//as//dtd html 3.0 aswedit + extensions//",
    "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
    "-//ietf//dtd html 2.0 level 1//",
    "-//ietf//dtd html 2.0 level 2//",
    "-//ietf//dtd html 2.0 strict level 1//",
    "-//ietf//dtd html 2.0 strict level 2//",
    "-//ietf//dtd html 2.0 strict//",
    "-//ietf//dtd html 2.0//",
    "-//ietf//dtd html 2.1e//",
    "-//ietf//dtd html 3.0//",
    "-//ietf//dtd html 3.2 final//",
    "-//ietf//dtd html 3.2//",
    "-//ietf//dtd html 3//",
    "-//ietf//dtd html level 0//",
    "-//ietf//dtd html level 1//",
    "-//ietf//dtd html level 2//",
    "-//ietf//dtd html level 3//",
    "-//ietf//dtd html strict level 0//",
    "-//ietf//dtd html strict level 1//",
    "-//ietf//dtd html strict level 2//",
    "-//ietf//dtd html strict level 3//",
    "-//ietf//dtd html strict//",
    "-//ietf//dtd html//",
    "-//metrius//dtd metrius presentational//",
    "-//microsoft//dtd internet explorer 2.0 html strict//",
    "-//microsoft//dtd internet explorer 2.0 html//",
    "-//microsoft//dtd internet explorer 2.0 tables//",
    "-//microsoft//dtd internet explorer 3.0 html strict//",
    "-//microsoft//dtd internet explorer 3.0 html//",
    "-//microsoft//dtd internet explorer 3.0 tables//",
    "-//netscape comm. corp.//dtd html//",
    "-//netscape comm. corp.//dtd strict html//",
    "-//o'reilly and associates//dtd html 2.0//",
    "-//o'reilly and associates//dtd html extended 1.0//",
    "-//o'reilly and associates//dtd html extended relaxed 1.0//",
    "-//sq//dtd html 2.0 hotmetal + extensions//",
    "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
    "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
    "-//spyglass//dtd html 2.0 extended//",
    "-//sun microsystems corp.//dtd hotjava html//",
    "-//sun microsystems corp.//dtd hotjava strict html//",
    "-//w3c//dtd html 3 1995-03-24//",
    "-//w3c//dtd html 3.2 draft//",
    "-//w3c//dtd html 3.2 final//",
    "-//w3c//dtd html 3.2//",
    "-//w3c//dtd html 3.2s draft//",
    "-//w3c//dtd html 4.0 frameset//",
    "-//w3c//dtd html 4.0 transitional//",
    "-//w3c//dtd html experimental 19960712//",
    "-//w3c//dtd html experimental 970421//",
    "-//w3c//dtd w3 html//",
    "-//w3o//dtd w3 html 3.0//",
    "-//webtechs//dtd mozilla html 2.0//",
    "-//webtechs//dtd mozilla html//",
}

local function starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

local function doctype_mode(token)
    if token.force_quirks or token.name ~= "html" then
        return "quirks"
    end
    local public = token.public_id and token.public_id:lower()
    local system = token.system_id and token.system_id:lower()
    if public then
        if
            public == "-//w3o//dtd w3 html strict 3.0//en//"
            or public == "-/w3c/dtd html 4.0 transitional/en"
            or public == "html"
        then
            return "quirks"
        end
        for _, prefix in ipairs(QUIRKS_PUBLIC_PREFIXES) do
            if starts_with(public, prefix) then
                return "quirks"
            end
        end
        if
            system == nil
            and (
                starts_with(public, "-//w3c//dtd html 4.01 frameset//")
                or starts_with(public, "-//w3c//dtd html 4.01 transitional//")
            )
        then
            return "quirks"
        end
        if
            starts_with(public, "-//w3c//dtd xhtml 1.0 frameset//")
            or starts_with(public, "-//w3c//dtd xhtml 1.0 transitional//")
        then
            return "limited-quirks"
        end
        if
            system ~= nil
            and (
                starts_with(public, "-//w3c//dtd html 4.01 frameset//")
                or starts_with(public, "-//w3c//dtd html 4.01 transitional//")
            )
        then
            return "limited-quirks"
        end
    end
    if system == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd" then
        return "quirks"
    end
    return "no-quirks"
end

-- ── The builder ─────────────────────────────────────────────────────────────

local MARKER = { marker = true }

local Builder = {}
Builder.__index = Builder

-- These avoid patterns, which are slow in some Lua implementations (micro's
-- gopher-lua), on the path every text token takes.
local byte = string.byte

local function is_space_byte(b)
    return b == 32 or b == 10 or b == 9 or b == 12 or b == 13
end

-- The length of the whitespace at the start of s.
local function leading_whitespace(s)
    local i = 1
    while is_space_byte(byte(s, i)) do
        i = i + 1
    end
    return i - 1
end

local function is_whitespace_text(s)
    return leading_whitespace(s) == #s
end

-- Split text into its leading whitespace and the rest.
local function split_leading_whitespace(s)
    local n = leading_whitespace(s)
    return s:sub(1, n), s:sub(n + 1)
end

-- s without NULs.
local function strip_nuls(s)
    if s:find("\0", 1, true) then
        return (s:gsub("%z", ""))
    end
    return s
end

local function copy(t)
    local c = {}
    for k, v in pairs(t or {}) do
        c[k] = v
    end
    return c
end

function Builder:current()
    return self.stack[#self.stack]
end

-- The adjusted current node: the fragment's context element when parsing a
-- fragment and only the root is open.
function Builder:adjusted_current()
    if self.context and #self.stack == 1 then
        return self.context
    end
    return self:current()
end

-- ── Creating and inserting nodes ────────────────────────────────────────────

function Builder:create_element(token, namespace)
    local attrs = token.attrs
    -- most elements have no attributes: skip copying
    local node = Node.new(token.tag, (attrs == nil or next(attrs) == nil) and {} or copy(attrs))
    node.namespace = namespace
    if token.attr_ns then
        node.attr_ns = token.attr_ns
    end
    if namespace == nil and token.tag == "template" then
        node.content = Node.new("#document-fragment")
    end
    return node
end

-- Where new nodes go: returns the parent, and the child to insert before (or nil).
function Builder:insertion_location(override)
    local target = override or self.stack[#self.stack]
    local parent, before
    if
        self.foster_parenting
        and rawget(target, "namespace") == nil
        and (
            target.tag == "table"
            or target.tag == "tbody"
            or target.tag == "tfoot"
            or target.tag == "thead"
            or target.tag == "tr"
        )
    then
        local last_template, last_table
        for i = #self.stack, 1, -1 do
            local node = self.stack[i]
            if is_html(node, "template") and not last_template then
                last_template = i
            end
            if is_html(node, "table") and not last_table then
                last_table = i
            end
        end
        if last_template and (not last_table or last_template > last_table) then
            parent = self.stack[last_template].content
        elseif not last_table then
            parent = self.stack[1]
        elseif self.stack[last_table].parent then
            parent = self.stack[last_table].parent
            before = self.stack[last_table]
        else
            parent = self.stack[last_table - 1]
        end
    else
        parent = target
    end
    if parent ~= nil and parent.tag == "template" and rawget(parent, "namespace") == nil then
        parent = parent.content
    end
    return parent, before
end

local function insert_at(parent, before, node)
    node.parent = parent
    if before then
        for i, child in ipairs(parent.children) do
            if child == before then
                table.insert(parent.children, i, node)
                return
            end
        end
    end
    table.insert(parent.children, node)
end

local function detach(node)
    local parent = node.parent
    if parent then
        for i, child in ipairs(parent.children) do
            if child == node then
                table.remove(parent.children, i)
                break
            end
        end
        node.parent = nil
    end
end

function Builder:insert_foreign_element(token, namespace)
    local parent, before = self:insertion_location()
    local node = self:create_element(token, namespace)
    insert_at(parent, before, node)
    self.stack[#self.stack + 1] = node
    return node
end

function Builder:insert_html_element(token)
    return self:insert_foreign_element(token, nil)
end

function Builder:insert_text(text)
    if text == "" then
        return
    end
    local parent, before = self:insertion_location()
    if parent.tag == "document" then
        return -- text can't go directly in a document
    end
    -- merge with an adjacent text node
    local siblings = parent.children
    local prev
    if before then
        for i, child in ipairs(siblings) do
            if child == before then
                prev = siblings[i - 1]
                break
            end
        end
    else
        prev = siblings[#siblings]
    end
    if prev and prev.tag == "#text" then
        prev.text_content = prev.text_content .. text
        return
    end
    local node = Node.new("#text")
    node.text_content = text
    insert_at(parent, before, node)
end

-- Insert a comment or a processing instruction. (HTML puts processing
-- instructions wherever it puts comments.) Comments are dropped unless the
-- comments option is set.
function Builder:insert_comment(token, parent)
    local node
    if token.type == "pi" then
        node = Node.new("#processing-instruction")
        node.target = token.target
        node.text_content = token.data
    elseif not self.keep_comments then
        return
    else
        node = Node.new("#comment")
        node.text_content = token.data
    end
    if parent then
        insert_at(parent, nil, node)
    else
        local p, before = self:insertion_location()
        insert_at(p, before, node)
    end
end

-- ── The stack of open elements ──────────────────────────────────────────────

function Builder:pop()
    local stack = self.stack
    local n = #stack
    local node = stack[n]
    stack[n] = nil
    if node and node.tag == "option" and rawget(node, "namespace") == nil then
        self:maybe_clone_into_selectedcontent(node)
    end
    return node
end

local function first_descendant(root, predicate)
    for _, child in ipairs(root.children) do
        if predicate(child) then
            return child
        end
        local found = first_descendant(child, predicate)
        if found then
            return found
        end
    end
end

local function deep_clone(node)
    local clone = Node.new(node.tag, copy(node.attrs))
    clone.namespace = rawget(node, "namespace")
    clone.attr_ns = node.attr_ns
    clone.text_content = node.text_content
    for _, child in ipairs(node.children) do
        insert_at(clone, nil, deep_clone(child))
    end
    return clone
end

-- When an <option> is closed, and it's the selected option of a <select>
-- that has a <selectedcontent>, copy the option's contents into it.
function Builder:maybe_clone_into_selectedcontent(option)
    local select = option.parent
    while select and not is_html(select, "select") do
        select = select.parent
    end
    if not select then
        return
    end
    local selectedcontent = first_descendant(select, function(n)
        return is_html(n, "selectedcontent")
    end)
    if not selectedcontent then
        return
    end
    if option.attrs.selected == nil then
        -- without a selected attribute, the first option is selected, unless
        -- another option has the attribute
        local selected = first_descendant(select, function(n)
            return is_html(n, "option") and n.attrs.selected ~= nil
        end)
        local first = first_descendant(select, function(n)
            return is_html(n, "option")
        end)
        if selected or first ~= option then
            return
        end
    end
    for _, child in ipairs(selectedcontent.children) do
        child.parent = nil
    end
    selectedcontent.children = {}
    for _, child in ipairs(option.children) do
        insert_at(selectedcontent, nil, deep_clone(child))
    end
end

function Builder:pop_until(node)
    while #self.stack > 0 do
        if self:pop() == node then
            return
        end
    end
end

-- Pop until an HTML element with one of these tags has been popped.
function Builder:pop_until_tag(tags)
    while #self.stack > 0 do
        local node = self:pop()
        if rawget(node, "namespace") == nil and tags[node.tag] then
            return
        end
    end
end

function Builder:stack_index(node)
    for i = #self.stack, 1, -1 do
        if self.stack[i] == node then
            return i
        end
    end
end

function Builder:on_stack(node)
    return self:stack_index(node) ~= nil
end

-- Is a <template>'s content being parsed: is one open, or is the
-- fragment being parsed in one?
function Builder:parsing_template_contents()
    return self:stack_has_html("template") or (self.context ~= nil and is_html(self.context, "template"))
end

function Builder:stack_has_html(tag)
    for i = #self.stack, 1, -1 do
        if is_html(self.stack[i], tag) then
            return true
        end
    end
    return false
end

-- Is there an element with one of `tags` in scope? `kind` is "default",
-- "list", "button" or "table". Returns that element.
function Builder:in_scope(tags, kind)
    for i = #self.stack, 1, -1 do
        local node = self.stack[i]
        local html = rawget(node, "namespace") == nil
        if html and tags[node.tag] then
            return node
        end
        if kind == "table" then
            if html and (node.tag == "html" or node.tag == "table" or node.tag == "template") then
                return nil
            end
        else
            if html then
                if
                    SCOPE_HTML[node.tag]
                    or (kind == "list" and (node.tag == "ol" or node.tag == "ul"))
                    or (kind == "button" and node.tag == "button")
                then
                    return nil
                end
            elseif rawget(node, "namespace") == "math" then
                if SCOPE_MATHML[node.tag] then
                    return nil
                end
            elseif SCOPE_SVG[node.tag] then
                return nil
            end
        end
    end
    return nil
end

-- Is this specific element in (default) scope?
function Builder:element_in_scope(target)
    for i = #self.stack, 1, -1 do
        local node = self.stack[i]
        if node == target then
            return true
        end
        if
            rawget(node, "namespace") == nil and SCOPE_HTML[node.tag]
            or rawget(node, "namespace") == "math" and SCOPE_MATHML[node.tag]
            or rawget(node, "namespace") == "svg" and SCOPE_SVG[node.tag]
        then
            return false
        end
    end
    return false
end

function Builder:generate_implied_end_tags(except, thorough)
    local tags = thorough and IMPLIED_END_TAGS_THOROUGH or IMPLIED_END_TAGS
    local stack = self.stack
    while #stack > 0 do
        local node = stack[#stack]
        if rawget(node, "namespace") ~= nil or not tags[node.tag] or node.tag == except then
            return
        end
        self:pop()
    end
end

function Builder:close_p()
    self:generate_implied_end_tags("p")
    self:pop_until_tag({ p = true })
end

function Builder:close_p_if_in_button_scope()
    if self:in_scope({ p = true }, "button") then
        self:close_p()
    end
end

-- ── The list of active formatting elements ─────────────────────────────────

local function same_attrs(a, b)
    for k, v in pairs(a) do
        if b[k] ~= v then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

function Builder:push_formatting(node, token)
    local list = self.afe
    -- Noah's Ark: at most three identical elements after the last marker
    local count, earliest = 0, nil
    for i = #list, 1, -1 do
        local entry = list[i]
        if entry == MARKER then
            break
        end
        if entry.node.tag == node.tag and same_attrs(entry.token.attrs, token.attrs) then
            count = count + 1
            earliest = i
        end
    end
    if count >= 3 then
        table.remove(list, earliest)
    end
    list[#list + 1] = { node = node, token = token }
end

function Builder:afe_index(node)
    for i = #self.afe, 1, -1 do
        local entry = self.afe[i]
        if entry ~= MARKER and entry.node == node then
            return i
        end
    end
end

function Builder:reconstruct_formatting()
    local list = self.afe
    if #list == 0 then
        return
    end
    local entry = list[#list]
    if entry == MARKER or self:on_stack(entry.node) then
        return
    end
    local i = #list
    while i > 1 do
        local prev = list[i - 1]
        if prev == MARKER or self:on_stack(prev.node) then
            break
        end
        i = i - 1
    end
    for j = i, #list do
        local e = list[j]
        e.node = self:insert_html_element(e.token)
    end
end

function Builder:clear_formatting_to_marker()
    while #self.afe > 0 do
        if table.remove(self.afe) == MARKER then
            return
        end
    end
end

-- The last formatting element with this tag after the last marker.
function Builder:find_formatting(tag)
    for i = #self.afe, 1, -1 do
        local entry = self.afe[i]
        if entry == MARKER then
            return nil
        end
        if entry.node.tag == tag then
            return entry, i
        end
    end
end

-- The adoption agency algorithm, for the end tag of formatting element
-- `subject`. Returns true if the end tag should instead be handled as "any
-- other end tag".
function Builder:adoption_agency(subject)
    local current = self:current()
    if is_html(current, subject) and not self:afe_index(current) then
        self:pop()
        return false
    end

    for _ = 1, 8 do
        local entry = self:find_formatting(subject)
        if not entry then
            return true
        end
        local fe = entry.node
        local fe_pos = self:stack_index(fe)
        if not fe_pos then
            table.remove(self.afe, self:afe_index(fe))
            return false
        end
        if not self:element_in_scope(fe) then
            return false
        end
        -- an open <select> inside the formatting element shields it
        local select = self:in_scope({ select = true }, "default")
        if select and self:stack_index(select) > fe_pos then
            return false
        end

        local furthest_block
        for i = fe_pos + 1, #self.stack do
            if is_special(self.stack[i]) then
                furthest_block = self.stack[i]
                break
            end
        end
        if not furthest_block then
            self:pop_until(fe)
            table.remove(self.afe, self:afe_index(fe))
            return false
        end

        local common_ancestor = self.stack[fe_pos - 1]
        local bookmark = self:afe_index(fe)
        local node_pos = self:stack_index(furthest_block)
        local last = furthest_block
        local inner = 0
        while true do
            inner = inner + 1
            node_pos = node_pos - 1
            local node = self.stack[node_pos]
            if node == fe then
                break
            end
            local index = self:afe_index(node)
            if inner > 3 and index then
                table.remove(self.afe, index)
                if index < bookmark then
                    bookmark = bookmark - 1
                end
                index = nil
            end
            if not index then
                table.remove(self.stack, node_pos)
            else
                local node_entry = self.afe[index]
                local new_node = self:create_element(node_entry.token, nil)
                node_entry.node = new_node
                self.stack[node_pos] = new_node
                if last == furthest_block then
                    bookmark = index + 1
                end
                detach(last)
                insert_at(new_node, nil, last)
                last = new_node
            end
        end

        detach(last)
        local parent, before = self:insertion_location(common_ancestor)
        insert_at(parent, before, last)

        local new_fe = self:create_element(entry.token, nil)
        local children = furthest_block.children
        furthest_block.children = {}
        for _, child in ipairs(children) do
            insert_at(new_fe, nil, child)
        end
        insert_at(furthest_block, nil, new_fe)

        local index = self:afe_index(fe)
        table.remove(self.afe, index)
        if index < bookmark then
            bookmark = bookmark - 1
        end
        table.insert(self.afe, bookmark, { node = new_fe, token = entry.token })

        table.remove(self.stack, self:stack_index(fe))
        table.insert(self.stack, self:stack_index(furthest_block) + 1, new_fe)
    end
    return false
end

-- ── Insertion mode helpers ──────────────────────────────────────────────────

function Builder:reset_insertion_mode()
    for i = #self.stack, 1, -1 do
        local node = self.stack[i]
        local last = i == 1
        if last and self.context then
            node = self.context
        end
        local tag = rawget(node, "namespace") == nil and node.tag or nil
        if (tag == "td" or tag == "th") and not last then
            self.mode = "in_cell"
            return
        elseif tag == "tr" then
            self.mode = "in_row"
            return
        elseif tag == "tbody" or tag == "thead" or tag == "tfoot" then
            self.mode = "in_table_body"
            return
        elseif tag == "caption" then
            self.mode = "in_caption"
            return
        elseif tag == "colgroup" then
            self.mode = "in_column_group"
            return
        elseif tag == "table" then
            self.mode = "in_table"
            return
        elseif tag == "template" then
            self.mode = self.template_modes[#self.template_modes]
            return
        elseif tag == "head" and not last then
            self.mode = "in_head"
            return
        elseif tag == "body" then
            self.mode = "in_body"
            return
        elseif tag == "frameset" then
            self.mode = "in_frameset"
            return
        elseif tag == "html" then
            self.mode = self.head and "after_head" or "before_head"
            return
        elseif last then
            self.mode = "in_body"
            return
        end
    end
end

-- Insert an element whose content is raw text or RCDATA.
function Builder:parse_text_element(token, tokenizer_state)
    self:insert_html_element(token)
    self.tokenizer.state = tokenizer_state
    self.original_mode = self.mode
    self.mode = "text"
end

function Builder:clear_stack_to(tags)
    local stack = self.stack
    while #stack > 0 do
        local node = stack[#stack]
        if rawget(node, "namespace") == nil and tags[node.tag] then
            return
        end
        self:pop()
    end
end

local TABLE_CONTEXT = set("table template html")
local TABLE_BODY_CONTEXT = set("tbody tfoot thead template html")
local TABLE_ROW_CONTEXT = set("tr template html")

function Builder:close_cell()
    self:generate_implied_end_tags()
    self:pop_until_tag({ td = true, th = true })
    self:clear_formatting_to_marker()
    self.mode = "in_row"
end

-- Merge a token's attributes into an existing element (for repeated <html>/<body>).
local function merge_attributes(node, token)
    for k, v in pairs(token.attrs) do
        if node.attrs[k] == nil then
            node.attrs[k] = v
        end
    end
end

local function adjust_mathml_attributes(token)
    if token.attrs.definitionurl ~= nil then
        token.attrs.definitionURL = token.attrs.definitionurl
        token.attrs.definitionurl = nil
    end
end

local function adjust_svg_attributes(token)
    local adjusted = {}
    for k, v in pairs(token.attrs) do
        adjusted[SVG_ATTR_ADJUSTMENTS[k] or k] = v
    end
    token.attrs = adjusted
end

local function adjust_foreign_attributes(token)
    for k in pairs(token.attrs) do
        local ns = FOREIGN_ATTRS[k]
        if ns then
            token.attr_ns = token.attr_ns or {}
            token.attr_ns[k] = ns
        end
    end
end

-- ── Modes ───────────────────────────────────────────────────────────────────

local modes = {}

function Builder:process(token)
    return modes[self.mode](self, token)
end

-- Process a token using another mode's rules, without switching to it.
function Builder:process_using(mode, token)
    return modes[mode](self, token)
end

modes.initial = function(self, t)
    if t.type == "text" then
        local _, rest = split_leading_whitespace(t.text)
        if rest == "" then
            return
        end
        t.text = rest
    elseif t.type == "comment" or t.type == "pi" then
        self:insert_comment(t, self.document)
        return
    elseif t.type == "doctype" then
        local node = Node.new("#doctype")
        node.name = t.name or ""
        node.public_id = t.public_id or ""
        node.system_id = t.system_id or ""
        insert_at(self.document, nil, node)
        self.quirks = doctype_mode(t)
        self.mode = "before_html"
        return
    end
    self.quirks = "quirks"
    self.mode = "before_html"
    return self:process(t)
end

modes.before_html = function(self, t)
    if t.type == "doctype" then
        return
    elseif t.type == "comment" or t.type == "pi" then
        self:insert_comment(t, self.document)
        return
    elseif t.type == "text" then
        local _, rest = split_leading_whitespace(t.text)
        if rest == "" then
            return
        end
        t.text = rest
    elseif t.type == "start" and t.tag == "html" then
        local node = self:create_element(t, nil)
        insert_at(self.document, nil, node)
        self.stack[#self.stack + 1] = node
        self.mode = "before_head"
        return
    elseif t.type == "end" and not (t.tag == "head" or t.tag == "body" or t.tag == "html" or t.tag == "br") then
        return
    end
    local node = Node.new("html")
    insert_at(self.document, nil, node)
    self.stack[#self.stack + 1] = node
    self.mode = "before_head"
    return self:process(t)
end

modes.before_head = function(self, t)
    if t.type == "text" then
        local _, rest = split_leading_whitespace(t.text)
        if rest == "" then
            return
        end
        t.text = rest
    elseif t.type == "comment" or t.type == "pi" then
        self:insert_comment(t)
        return
    elseif t.type == "doctype" then
        return
    elseif t.type == "start" and t.tag == "html" then
        return self:process_using("in_body", t)
    elseif t.type == "start" and t.tag == "head" then
        self.head = self:insert_html_element(t)
        self.mode = "in_head"
        return
    elseif t.type == "end" and not (t.tag == "head" or t.tag == "body" or t.tag == "html" or t.tag == "br") then
        return
    end
    self.head = self:insert_html_element({ tag = "head", attrs = {} })
    self.mode = "in_head"
    return self:process(t)
end

modes.in_head = function(self, t)
    local tag = t.tag
    if t.type == "text" then
        local ws, rest = split_leading_whitespace(t.text)
        self:insert_text(ws)
        if rest == "" then
            return
        end
        t.text = rest
    elseif t.type == "comment" or t.type == "pi" then
        self:insert_comment(t)
        return
    elseif t.type == "doctype" then
        return
    elseif t.type == "start" then
        if tag == "html" then
            return self:process_using("in_body", t)
        elseif tag == "base" or tag == "basefont" or tag == "bgsound" or tag == "link" or tag == "meta" then
            self:insert_html_element(t)
            self:pop()
            return
        elseif tag == "title" then
            return self:parse_text_element(t, "rcdata")
        elseif (tag == "noscript" and self.scripting) or tag == "noframes" or tag == "style" then
            return self:parse_text_element(t, "rawtext")
        elseif tag == "noscript" then
            self:insert_html_element(t)
            self.mode = "in_head_noscript"
            return
        elseif tag == "script" then
            return self:parse_text_element(t, "script_data")
        elseif tag == "template" then
            self:insert_html_element(t)
            self.afe[#self.afe + 1] = MARKER
            self.frameset_ok = false
            self.mode = "in_template"
            self.template_modes[#self.template_modes + 1] = "in_template"
            return
        elseif tag == "head" then
            return
        end
    elseif t.type == "end" then
        if tag == "head" then
            self:pop()
            self.mode = "after_head"
            return
        elseif tag == "template" then
            if not self:stack_has_html("template") then
                return
            end
            self:generate_implied_end_tags(nil, true)
            self:pop_until_tag({ template = true })
            self:clear_formatting_to_marker()
            table.remove(self.template_modes)
            self:reset_insertion_mode()
            return
        elseif not (tag == "body" or tag == "html" or tag == "br") then
            return
        end
    end
    self:pop() -- the head
    self.mode = "after_head"
    return self:process(t)
end

modes.in_head_noscript = function(self, t)
    local tag = t.tag
    if t.type == "doctype" then
        return
    elseif t.type == "start" and tag == "html" then
        return self:process_using("in_body", t)
    elseif t.type == "end" and tag == "noscript" then
        self:pop()
        self.mode = "in_head"
        return
    elseif
        t.type == "comment"
        or t.type == "pi"
        or (
            t.type == "start"
            and (
                tag == "basefont"
                or tag == "bgsound"
                or tag == "link"
                or tag == "meta"
                or tag == "noframes"
                or tag == "style"
            )
        )
    then
        return self:process_using("in_head", t)
    elseif t.type == "text" then
        local ws, rest = split_leading_whitespace(t.text)
        if ws ~= "" then
            self:process_using("in_head", { type = "text", text = ws })
        end
        if rest == "" then
            return
        end
        t.text = rest
    elseif (t.type == "start" and (tag == "head" or tag == "noscript")) or (t.type == "end" and tag ~= "br") then
        return
    end
    self:pop()
    self.mode = "in_head"
    return self:process(t)
end

modes.after_head = function(self, t)
    local tag = t.tag
    if t.type == "text" then
        local ws, rest = split_leading_whitespace(t.text)
        self:insert_text(ws)
        if rest == "" then
            return
        end
        t.text = rest
    elseif t.type == "comment" or t.type == "pi" then
        self:insert_comment(t)
        return
    elseif t.type == "doctype" then
        return
    elseif t.type == "start" then
        if tag == "html" then
            return self:process_using("in_body", t)
        elseif tag == "body" then
            self:insert_html_element(t)
            self.frameset_ok = false
            self.mode = "in_body"
            return
        elseif tag == "frameset" then
            self:insert_html_element(t)
            self.mode = "in_frameset"
            return
        elseif
            tag == "base"
            or tag == "basefont"
            or tag == "bgsound"
            or tag == "link"
            or tag == "meta"
            or tag == "noframes"
            or tag == "script"
            or tag == "style"
            or tag == "template"
            or tag == "title"
        then
            self.stack[#self.stack + 1] = self.head
            self:process_using("in_head", t)
            for i = #self.stack, 1, -1 do
                if self.stack[i] == self.head then
                    table.remove(self.stack, i)
                    break
                end
            end
            return
        elseif tag == "head" then
            return
        end
    elseif t.type == "end" then
        if tag == "template" then
            return self:process_using("in_head", t)
        elseif not (tag == "body" or tag == "html" or tag == "br") then
            return
        end
    end
    self:insert_html_element({ tag = "body", attrs = {} })
    self.frameset_ok = true
    self.mode = "in_body"
    return self:process(t)
end

-- in body ─────────────────────────────────────────────────────────────────────

local CLOSES_P = set([[address article aside blockquote center details dialog dir
    div dl fieldset figcaption figure footer header hgroup main menu nav ol p
    search section summary ul]])

local IN_HEAD_START = set("base basefont bgsound link meta noframes script style template title")

local BLOCK_END = set([[address article aside blockquote button center details
    dialog dir div dl fieldset figcaption figure footer header hgroup listing main
    menu nav ol pre search section select summary ul]])

function Builder:body_text(text)
    text = strip_nuls(text)
    if text == "" then
        return
    end
    self:reconstruct_formatting()
    self:insert_text(text)
    if not is_whitespace_text(text) then
        self.frameset_ok = false
    end
end

-- Is this a fragment being parsed as the contents of a <select>?
function Builder:in_select_fragment()
    return self.context ~= nil and is_html(self.context, "select")
end

function Builder:any_other_end_tag(tag)
    for i = #self.stack, 1, -1 do
        local node = self.stack[i]
        if is_html(node, tag) then
            self:generate_implied_end_tags(tag)
            self:pop_until(node)
            return
        elseif is_special(node) then
            return
        end
    end
end

modes.in_body = function(self, t)
    local tag = t.tag
    if t.type == "text" then
        return self:body_text(t.text)
    elseif t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t)
    elseif t.type == "doctype" then
        return
    elseif t.type == "eof" then
        if #self.template_modes > 0 then
            return self:process_using("in_template", t)
        end
        self.stopped = true
        return
    elseif t.type == "start" then
        return self:in_body_start(t, tag)
    else
        return self:in_body_end(t, tag)
    end
end

function Builder:in_body_start(t, tag)
    if tag == "html" then
        if self:stack_has_html("template") then
            return
        end
        merge_attributes(self.stack[1], t)
    elseif IN_HEAD_START[tag] then
        return self:process_using("in_head", t)
    elseif tag == "body" then
        local body = self.stack[2]
        if not is_html(body, "body") or #self.stack == 1 or self:stack_has_html("template") then
            return
        end
        self.frameset_ok = false
        merge_attributes(body, t)
    elseif tag == "frameset" then
        local body = self.stack[2]
        if not is_html(body, "body") or not self.frameset_ok then
            return
        end
        detach(body)
        while #self.stack > 1 do
            self:pop()
        end
        self:insert_html_element(t)
        self.mode = "in_frameset"
    elseif CLOSES_P[tag] then
        self:close_p_if_in_button_scope()
        self:insert_html_element(t)
    elseif HEADINGS[tag] then
        self:close_p_if_in_button_scope()
        local current = self:current()
        if rawget(current, "namespace") == nil and HEADINGS[current.tag] then
            self:pop()
        end
        self:insert_html_element(t)
    elseif tag == "pre" or tag == "listing" then
        self:close_p_if_in_button_scope()
        self:insert_html_element(t)
        self.skip_newline = true
        self.frameset_ok = false
    elseif tag == "form" then
        local has_template = self:parsing_template_contents()
        if self.form and not has_template then
            return
        end
        self:close_p_if_in_button_scope()
        local node = self:insert_html_element(t)
        if not has_template then
            self.form = node
        end
    elseif tag == "li" or tag == "dd" or tag == "dt" then
        self.frameset_ok = false
        local targets = tag == "li" and { li = true } or { dd = true, dt = true }
        for i = #self.stack, 1, -1 do
            local node = self.stack[i]
            if rawget(node, "namespace") == nil and targets[node.tag] then
                self:generate_implied_end_tags(node.tag)
                self:pop_until_tag({ [node.tag] = true })
                break
            end
            if is_special(node) and not (is_html(node, "address") or is_html(node, "div") or is_html(node, "p")) then
                break
            end
        end
        self:close_p_if_in_button_scope()
        self:insert_html_element(t)
    elseif tag == "plaintext" then
        self:close_p_if_in_button_scope()
        self:insert_html_element(t)
        self.tokenizer.state = "plaintext"
    elseif tag == "button" then
        if self:in_scope({ button = true }, "default") then
            self:generate_implied_end_tags()
            self:pop_until_tag({ button = true })
        end
        self:reconstruct_formatting()
        self:insert_html_element(t)
        self.frameset_ok = false
    elseif tag == "a" then
        local entry = self:find_formatting("a")
        if entry then
            if self:adoption_agency("a") then
                self:any_other_end_tag("a")
            end
            local index = self:afe_index(entry.node)
            if index then
                table.remove(self.afe, index)
            end
            local pos = self:stack_index(entry.node)
            if pos then
                table.remove(self.stack, pos)
            end
        end
        self:reconstruct_formatting()
        local node = self:insert_html_element(t)
        self:push_formatting(node, t)
    elseif FORMATTING[tag] and tag ~= "nobr" then
        self:reconstruct_formatting()
        local node = self:insert_html_element(t)
        self:push_formatting(node, t)
    elseif tag == "nobr" then
        self:reconstruct_formatting()
        if self:in_scope({ nobr = true }, "default") then
            if self:adoption_agency("nobr") then
                self:any_other_end_tag("nobr")
            end
            self:reconstruct_formatting()
        end
        local node = self:insert_html_element(t)
        self:push_formatting(node, t)
    elseif tag == "applet" or tag == "marquee" or tag == "object" then
        self:reconstruct_formatting()
        self:insert_html_element(t)
        self.afe[#self.afe + 1] = MARKER
        self.frameset_ok = false
    elseif tag == "table" then
        if self.quirks ~= "quirks" then
            self:close_p_if_in_button_scope()
        end
        self:insert_html_element(t)
        self.frameset_ok = false
        self.mode = "in_table"
    elseif tag == "area" or tag == "br" or tag == "embed" or tag == "img" or tag == "keygen" or tag == "wbr" then
        self:reconstruct_formatting()
        self:insert_html_element(t)
        self:pop()
        self.frameset_ok = false
    elseif tag == "input" then
        if self:in_select_fragment() then
            return
        elseif self:in_scope({ select = true }, "default") then
            self:pop_until_tag({ select = true })
        end
        self:reconstruct_formatting()
        self:insert_html_element(t)
        self:pop()
        local type_ = t.attrs.type
        if not (type_ and type_:lower() == "hidden") then
            self.frameset_ok = false
        end
    elseif tag == "param" or tag == "source" or tag == "track" then
        self:insert_html_element(t)
        self:pop()
    elseif tag == "hr" then
        self:close_p_if_in_button_scope()
        if self:in_scope({ select = true }, "default") then
            self:generate_implied_end_tags()
        end
        self:insert_html_element(t)
        self:pop()
        self.frameset_ok = false
    elseif tag == "image" then
        t.tag = "img"
        return self:process(t)
    elseif tag == "textarea" then
        self:insert_html_element(t)
        self.skip_newline = true
        self.tokenizer.state = "rcdata"
        self.original_mode = self.mode
        self.frameset_ok = false
        self.mode = "text"
    elseif tag == "xmp" then
        self:close_p_if_in_button_scope()
        self:reconstruct_formatting()
        self.frameset_ok = false
        self:parse_text_element(t, "rawtext")
    elseif tag == "iframe" then
        self.frameset_ok = false
        self:parse_text_element(t, "rawtext")
    elseif tag == "noembed" or (tag == "noscript" and self.scripting) then
        self:parse_text_element(t, "rawtext")
    elseif tag == "select" then
        -- the "relaxed" select parsing of 2025: a <select> can contain
        -- other elements, and a nested <select> closes the open one
        if self:in_select_fragment() then
            return
        elseif self:in_scope({ select = true }, "default") then
            self:pop_until_tag({ select = true })
        else
            self:reconstruct_formatting()
            self:insert_html_element(t)
            self.frameset_ok = false
        end
    elseif tag == "option" then
        if self:in_scope({ select = true }, "default") then
            self:generate_implied_end_tags("optgroup")
        elseif is_html(self:current(), "option") then
            self:pop()
        end
        self:reconstruct_formatting()
        self:insert_html_element(t)
    elseif tag == "optgroup" then
        if self:in_scope({ select = true }, "default") then
            self:generate_implied_end_tags()
        elseif is_html(self:current(), "option") then
            self:pop()
        end
        self:reconstruct_formatting()
        self:insert_html_element(t)
    elseif tag == "rb" or tag == "rtc" then
        if self:in_scope({ ruby = true }, "default") then
            self:generate_implied_end_tags()
        end
        self:insert_html_element(t)
    elseif tag == "rp" or tag == "rt" then
        if self:in_scope({ ruby = true }, "default") then
            self:generate_implied_end_tags("rtc")
        end
        self:insert_html_element(t)
    elseif tag == "math" then
        self:reconstruct_formatting()
        adjust_mathml_attributes(t)
        adjust_foreign_attributes(t)
        self:insert_foreign_element(t, "math")
        if t.self_closing then
            self:pop()
        end
    elseif tag == "svg" then
        self:reconstruct_formatting()
        adjust_svg_attributes(t)
        adjust_foreign_attributes(t)
        self:insert_foreign_element(t, "svg")
        if t.self_closing then
            self:pop()
        end
    elseif
        tag == "caption"
        or tag == "col"
        or tag == "colgroup"
        or tag == "frame"
        or tag == "head"
        or tag == "tbody"
        or tag == "td"
        or tag == "tfoot"
        or tag == "th"
        or tag == "thead"
        or tag == "tr"
    then
        return
    else
        self:reconstruct_formatting()
        self:insert_html_element(t)
    end
end

function Builder:in_body_end(t, tag)
    if tag == "template" then
        return self:process_using("in_head", t)
    elseif tag == "body" or tag == "html" then
        if not self:in_scope({ body = true }, "default") then
            return
        end
        self.mode = "after_body"
        if tag == "html" then
            return self:process(t)
        end
    elseif BLOCK_END[tag] then
        if not self:in_scope({ [tag] = true }, "default") then
            return
        end
        self:generate_implied_end_tags()
        self:pop_until_tag({ [tag] = true })
    elseif tag == "form" then
        if not self:parsing_template_contents() then
            local node = self.form
            self.form = nil
            if not node or not self:element_in_scope(node) then
                return
            end
            self:generate_implied_end_tags()
            table.remove(self.stack, self:stack_index(node))
        else
            if not self:in_scope({ form = true }, "default") then
                return
            end
            self:generate_implied_end_tags()
            self:pop_until_tag({ form = true })
        end
    elseif tag == "p" then
        if not self:in_scope({ p = true }, "button") then
            self:insert_html_element({ tag = "p", attrs = {} })
        end
        self:close_p()
    elseif tag == "li" then
        if not self:in_scope({ li = true }, "list") then
            return
        end
        self:generate_implied_end_tags("li")
        self:pop_until_tag({ li = true })
    elseif tag == "dd" or tag == "dt" then
        if not self:in_scope({ [tag] = true }, "default") then
            return
        end
        self:generate_implied_end_tags(tag)
        self:pop_until_tag({ [tag] = true })
    elseif HEADINGS[tag] then
        if not self:in_scope(HEADINGS, "default") then
            return
        end
        self:generate_implied_end_tags()
        self:pop_until_tag(HEADINGS)
    elseif FORMATTING[tag] then
        if self:adoption_agency(tag) then
            self:any_other_end_tag(tag)
        end
    elseif tag == "applet" or tag == "marquee" or tag == "object" then
        if not self:in_scope({ [tag] = true }, "default") then
            return
        end
        self:generate_implied_end_tags()
        self:pop_until_tag({ [tag] = true })
        self:clear_formatting_to_marker()
    elseif tag == "br" then
        return self:in_body_start({ type = "start", tag = "br", attrs = {} }, "br")
    else
        self:any_other_end_tag(tag)
    end
end

modes.text = function(self, t)
    if t.type == "text" then
        return self:insert_text(t.text)
    elseif t.type == "eof" then
        self:pop()
        self.mode = self.original_mode
        return self:process(t)
    elseif t.type == "end" then
        self:pop()
        self.mode = self.original_mode
    end
end

-- in table ────────────────────────────────────────────────────────────────────

modes.in_table = function(self, t)
    local tag = t.tag
    local current = self:current()
    if
        t.type == "text"
        and rawget(current, "namespace") == nil
        and (
            current.tag == "table"
            or current.tag == "tbody"
            or current.tag == "template"
            or current.tag == "tfoot"
            or current.tag == "thead"
            or current.tag == "tr"
        )
    then
        self.pending_table_text = {}
        self.original_mode = self.mode
        self.mode = "in_table_text"
        return self:process(t)
    elseif t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t)
    elseif t.type == "doctype" then
        return
    elseif t.type == "start" then
        if tag == "caption" then
            self:clear_stack_to(TABLE_CONTEXT)
            self.afe[#self.afe + 1] = MARKER
            self:insert_html_element(t)
            self.mode = "in_caption"
            return
        elseif tag == "colgroup" then
            self:clear_stack_to(TABLE_CONTEXT)
            self:insert_html_element(t)
            self.mode = "in_column_group"
            return
        elseif tag == "col" then
            self:clear_stack_to(TABLE_CONTEXT)
            self:insert_html_element({ tag = "colgroup", attrs = {} })
            self.mode = "in_column_group"
            return self:process(t)
        elseif tag == "tbody" or tag == "tfoot" or tag == "thead" then
            self:clear_stack_to(TABLE_CONTEXT)
            self:insert_html_element(t)
            self.mode = "in_table_body"
            return
        elseif tag == "td" or tag == "th" or tag == "tr" then
            self:clear_stack_to(TABLE_CONTEXT)
            self:insert_html_element({ tag = "tbody", attrs = {} })
            self.mode = "in_table_body"
            return self:process(t)
        elseif tag == "table" then
            if not self:in_scope({ table = true }, "table") then
                return
            end
            self:pop_until_tag({ table = true })
            self:reset_insertion_mode()
            return self:process(t)
        elseif tag == "style" or tag == "script" or tag == "template" then
            return self:process_using("in_head", t)
        elseif tag == "input" then
            local type_ = t.attrs.type
            if type_ and type_:lower() == "hidden" then
                self:insert_html_element(t)
                self:pop()
                return
            end
        elseif tag == "form" then
            local in_template = self:parsing_template_contents()
            if self.form and not in_template then
                return
            end
            local node = self:insert_html_element(t)
            if not in_template then
                self.form = node
            end
            self:pop()
            return
        end
    elseif t.type == "end" then
        if tag == "table" then
            if not self:in_scope({ table = true }, "table") then
                return
            end
            self:pop_until_tag({ table = true })
            self:reset_insertion_mode()
            return
        elseif
            tag == "body"
            or tag == "caption"
            or tag == "col"
            or tag == "colgroup"
            or tag == "html"
            or tag == "tbody"
            or tag == "td"
            or tag == "tfoot"
            or tag == "th"
            or tag == "thead"
            or tag == "tr"
        then
            return
        elseif tag == "template" then
            return self:process_using("in_head", t)
        end
    elseif t.type == "eof" then
        return self:process_using("in_body", t)
    end
    -- anything else: process using in body, with foster parenting
    self.foster_parenting = true
    self:process_using("in_body", t)
    self.foster_parenting = false
end

modes.in_table_text = function(self, t)
    if t.type == "text" then
        local text = strip_nuls(t.text)
        if text ~= "" then
            self.pending_table_text[#self.pending_table_text + 1] = text
        end
        return
    end
    local text = concat(self.pending_table_text)
    self.pending_table_text = {}
    if text ~= "" then
        if not is_whitespace_text(text) then
            -- foster parent it, as in the "anything else" case of in table
            self.foster_parenting = true
            self:body_text(text)
            self.foster_parenting = false
        else
            self:insert_text(text)
        end
    end
    self.mode = self.original_mode
    return self:process(t)
end

modes.in_caption = function(self, t)
    local tag = t.tag
    if t.type == "end" and tag == "caption" then
        if not self:in_scope({ caption = true }, "table") then
            return
        end
        self:generate_implied_end_tags()
        self:pop_until_tag({ caption = true })
        self:clear_formatting_to_marker()
        self.mode = "in_table"
        return
    elseif
        (
            t.type == "start"
            and (
                tag == "caption"
                or tag == "col"
                or tag == "colgroup"
                or tag == "tbody"
                or tag == "td"
                or tag == "tfoot"
                or tag == "th"
                or tag == "thead"
                or tag == "tr"
            )
        ) or (t.type == "end" and tag == "table")
    then
        if not self:in_scope({ caption = true }, "table") then
            return
        end
        self:generate_implied_end_tags()
        self:pop_until_tag({ caption = true })
        self:clear_formatting_to_marker()
        self.mode = "in_table"
        return self:process(t)
    elseif
        t.type == "end"
        and (
            tag == "body"
            or tag == "col"
            or tag == "colgroup"
            or tag == "html"
            or tag == "tbody"
            or tag == "td"
            or tag == "tfoot"
            or tag == "th"
            or tag == "thead"
            or tag == "tr"
        )
    then
        return
    end
    return self:process_using("in_body", t)
end

modes.in_column_group = function(self, t)
    local tag = t.tag
    if t.type == "text" then
        local ws, rest = split_leading_whitespace(t.text)
        self:insert_text(ws)
        if rest == "" then
            return
        end
        t.text = rest
    elseif t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t)
    elseif t.type == "doctype" then
        return
    elseif t.type == "start" and tag == "html" then
        return self:process_using("in_body", t)
    elseif t.type == "start" and tag == "col" then
        self:insert_html_element(t)
        self:pop()
        return
    elseif t.type == "end" and tag == "colgroup" then
        if not is_html(self:current(), "colgroup") then
            return
        end
        self:pop()
        self.mode = "in_table"
        return
    elseif t.type == "end" and tag == "col" then
        return
    elseif (t.type == "start" or t.type == "end") and tag == "template" then
        return self:process_using("in_head", t)
    elseif t.type == "eof" then
        return self:process_using("in_body", t)
    end
    if not is_html(self:current(), "colgroup") then
        return
    end
    self:pop()
    self.mode = "in_table"
    return self:process(t)
end

modes.in_table_body = function(self, t)
    local tag = t.tag
    if t.type == "start" and tag == "tr" then
        self:clear_stack_to(TABLE_BODY_CONTEXT)
        self:insert_html_element(t)
        self.mode = "in_row"
        return
    elseif t.type == "start" and (tag == "th" or tag == "td") then
        self:clear_stack_to(TABLE_BODY_CONTEXT)
        self:insert_html_element({ tag = "tr", attrs = {} })
        self.mode = "in_row"
        return self:process(t)
    elseif t.type == "end" and (tag == "tbody" or tag == "tfoot" or tag == "thead") then
        if not self:in_scope({ [tag] = true }, "table") then
            return
        end
        self:clear_stack_to(TABLE_BODY_CONTEXT)
        self:pop()
        self.mode = "in_table"
        return
    elseif
        (
            t.type == "start"
            and (
                tag == "caption"
                or tag == "col"
                or tag == "colgroup"
                or tag == "tbody"
                or tag == "tfoot"
                or tag == "thead"
            )
        ) or (t.type == "end" and tag == "table")
    then
        if not self:in_scope({ tbody = true, thead = true, tfoot = true }, "table") then
            return
        end
        self:clear_stack_to(TABLE_BODY_CONTEXT)
        self:pop()
        self.mode = "in_table"
        return self:process(t)
    elseif
        t.type == "end"
        and (
            tag == "body"
            or tag == "caption"
            or tag == "col"
            or tag == "colgroup"
            or tag == "html"
            or tag == "td"
            or tag == "th"
            or tag == "tr"
        )
    then
        return
    end
    return self:process_using("in_table", t)
end

modes.in_row = function(self, t)
    local tag = t.tag
    if t.type == "start" and (tag == "th" or tag == "td") then
        self:clear_stack_to(TABLE_ROW_CONTEXT)
        self:insert_html_element(t)
        self.mode = "in_cell"
        self.afe[#self.afe + 1] = MARKER
        return
    elseif t.type == "end" and tag == "tr" then
        if not self:in_scope({ tr = true }, "table") then
            return
        end
        self:clear_stack_to(TABLE_ROW_CONTEXT)
        self:pop()
        self.mode = "in_table_body"
        return
    elseif
        (
            t.type == "start"
            and (
                tag == "caption"
                or tag == "col"
                or tag == "colgroup"
                or tag == "tbody"
                or tag == "tfoot"
                or tag == "thead"
                or tag == "tr"
            )
        ) or (t.type == "end" and tag == "table")
    then
        if not self:in_scope({ tr = true }, "table") then
            return
        end
        self:clear_stack_to(TABLE_ROW_CONTEXT)
        self:pop()
        self.mode = "in_table_body"
        return self:process(t)
    elseif t.type == "end" and (tag == "tbody" or tag == "tfoot" or tag == "thead") then
        if not self:in_scope({ [tag] = true }, "table") then
            return
        end
        if not self:in_scope({ tr = true }, "table") then
            return
        end
        self:clear_stack_to(TABLE_ROW_CONTEXT)
        self:pop()
        self.mode = "in_table_body"
        return self:process(t)
    elseif
        t.type == "end"
        and (
            tag == "body"
            or tag == "caption"
            or tag == "col"
            or tag == "colgroup"
            or tag == "html"
            or tag == "td"
            or tag == "th"
        )
    then
        return
    end
    return self:process_using("in_table", t)
end

modes.in_cell = function(self, t)
    local tag = t.tag
    if t.type == "end" and (tag == "td" or tag == "th") then
        if not self:in_scope({ [tag] = true }, "table") then
            return
        end
        self:generate_implied_end_tags()
        self:pop_until_tag({ [tag] = true })
        self:clear_formatting_to_marker()
        self.mode = "in_row"
        return
    elseif
        t.type == "start"
        and (
            tag == "caption"
            or tag == "col"
            or tag == "colgroup"
            or tag == "tbody"
            or tag == "td"
            or tag == "tfoot"
            or tag == "th"
            or tag == "thead"
            or tag == "tr"
        )
    then
        if not self:in_scope({ td = true, th = true }, "table") then
            return
        end
        self:close_cell()
        return self:process(t)
    elseif
        t.type == "end"
        and (tag == "body" or tag == "caption" or tag == "col" or tag == "colgroup" or tag == "html")
    then
        return
    elseif
        t.type == "end"
        and (tag == "table" or tag == "tbody" or tag == "tfoot" or tag == "thead" or tag == "tr")
    then
        if not self:in_scope({ [tag] = true }, "table") then
            return
        end
        self:close_cell()
        return self:process(t)
    end
    return self:process_using("in_body", t)
end

-- in template ─────────────────────────────────────────────────────────────────

modes.in_template = function(self, t)
    local tag = t.tag
    if t.type == "text" or t.type == "comment" or t.type == "pi" or t.type == "doctype" then
        return self:process_using("in_body", t)
    elseif t.type == "start" then
        if IN_HEAD_START[tag] then
            return self:process_using("in_head", t)
        end
        local new_mode
        if tag == "caption" or tag == "colgroup" or tag == "tbody" or tag == "tfoot" or tag == "thead" then
            new_mode = "in_table"
        elseif tag == "col" then
            new_mode = "in_column_group"
        elseif tag == "tr" then
            new_mode = "in_table_body"
        elseif tag == "td" or tag == "th" then
            new_mode = "in_row"
        else
            new_mode = "in_body"
        end
        self.template_modes[#self.template_modes] = new_mode
        self.mode = new_mode
        return self:process(t)
    elseif t.type == "end" then
        if tag == "template" then
            return self:process_using("in_head", t)
        end
        return
    elseif t.type == "eof" then
        if not self:stack_has_html("template") then
            self.stopped = true
            return
        end
        self:pop_until_tag({ template = true })
        self:clear_formatting_to_marker()
        table.remove(self.template_modes)
        self:reset_insertion_mode()
        return self:process(t)
    end
end

-- after body and frameset ─────────────────────────────────────────────────────

modes.after_body = function(self, t)
    if t.type == "text" then
        local ws, rest = split_leading_whitespace(t.text)
        if ws ~= "" then
            self:process_using("in_body", { type = "text", text = ws })
        end
        if rest == "" then
            return
        end
        t.text = rest
    elseif t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t, self.stack[1])
    elseif t.type == "doctype" then
        return
    elseif t.type == "start" and t.tag == "html" then
        return self:process_using("in_body", t)
    elseif t.type == "end" and t.tag == "html" then
        if self.context then
            return
        end
        self.mode = "after_after_body"
        return
    elseif t.type == "eof" then
        self.stopped = true
        return
    end
    self.mode = "in_body"
    return self:process(t)
end

modes.in_frameset = function(self, t)
    local tag = t.tag
    if t.type == "text" then
        local ws = t.text:gsub("[^ \t\n\f\r]", "")
        return self:insert_text(ws)
    elseif t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t)
    elseif t.type == "start" then
        if tag == "html" then
            return self:process_using("in_body", t)
        elseif tag == "frameset" then
            self:insert_html_element(t)
        elseif tag == "frame" then
            self:insert_html_element(t)
            self:pop()
        elseif tag == "noframes" then
            return self:process_using("in_head", t)
        end
    elseif t.type == "end" and tag == "frameset" then
        if #self.stack == 1 then
            return
        end
        self:pop()
        if not self.context and not is_html(self:current(), "frameset") then
            self.mode = "after_frameset"
        end
    elseif t.type == "eof" then
        self.stopped = true
    end
end

modes.after_frameset = function(self, t)
    local tag = t.tag
    if t.type == "text" then
        local ws = t.text:gsub("[^ \t\n\f\r]", "")
        return self:insert_text(ws)
    elseif t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t)
    elseif t.type == "start" and tag == "html" then
        return self:process_using("in_body", t)
    elseif t.type == "end" and tag == "html" then
        self.mode = "after_after_frameset"
    elseif t.type == "start" and tag == "noframes" then
        return self:process_using("in_head", t)
    elseif t.type == "eof" then
        self.stopped = true
    end
end

modes.after_after_body = function(self, t)
    if t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t, self.document)
    elseif t.type == "doctype" or (t.type == "start" and t.tag == "html") then
        return self:process_using("in_body", t)
    elseif t.type == "text" then
        local ws, rest = split_leading_whitespace(t.text)
        if ws ~= "" then
            self:process_using("in_body", { type = "text", text = ws })
        end
        if rest == "" then
            return
        end
        t.text = rest
    elseif t.type == "eof" then
        self.stopped = true
        return
    end
    self.mode = "in_body"
    return self:process(t)
end

modes.after_after_frameset = function(self, t)
    if t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t, self.document)
    elseif t.type == "doctype" or (t.type == "start" and t.tag == "html") then
        return self:process_using("in_body", t)
    elseif t.type == "text" then
        local ws = t.text:gsub("[^ \t\n\f\r]", "")
        if ws ~= "" then
            self:process_using("in_body", { type = "text", text = ws })
        end
    elseif t.type == "start" and t.tag == "noframes" then
        return self:process_using("in_head", t)
    elseif t.type == "eof" then
        self.stopped = true
    end
end

-- ── Foreign content ─────────────────────────────────────────────────────────

local function is_mathml_text_integration_point(node)
    return rawget(node, "namespace") == "math"
        and (node.tag == "mi" or node.tag == "mo" or node.tag == "mn" or node.tag == "ms" or node.tag == "mtext")
end

local function is_html_integration_point(node)
    if rawget(node, "namespace") == "math" and node.tag == "annotation-xml" then
        local encoding = node.attrs.encoding
        encoding = encoding and encoding:lower()
        return encoding == "text/html" or encoding == "application/xhtml+xml"
    end
    return rawget(node, "namespace") == "svg"
        and (node.tag == "foreignObject" or node.tag == "desc" or node.tag == "title")
end

-- Pop foreign elements until the current node is HTML or an integration point.
function Builder:pop_foreign()
    while true do
        local current = self:current()
        if
            rawget(current, "namespace") == nil
            or is_mathml_text_integration_point(current)
            or is_html_integration_point(current)
        then
            return
        end
        self:pop()
    end
end

function Builder:foreign_content(t)
    local tag = t.tag
    if t.type == "text" then
        local text = t.text
        if text:find("\0", 1, true) then
            text = text:gsub("%z", "\239\191\189")
        end
        self:insert_text(text)
        -- NULs (now U+FFFD) don't count
        if not is_whitespace_text(strip_nuls(t.text)) then
            self.frameset_ok = false
        end
        return
    elseif t.type == "comment" or t.type == "pi" then
        return self:insert_comment(t)
    elseif t.type == "doctype" then
        return
    elseif t.type == "start" then
        if
            BREAKOUT[tag]
            or (tag == "font" and (t.attrs.color ~= nil or t.attrs.face ~= nil or t.attrs.size ~= nil))
        then
            self:pop_foreign()
            return self:process(t)
        end
        local namespace = rawget(self:adjusted_current(), "namespace")
        if namespace == "math" then
            adjust_mathml_attributes(t)
        elseif namespace == "svg" then
            t.tag = SVG_TAG_ADJUSTMENTS[tag] or tag
            adjust_svg_attributes(t)
        end
        adjust_foreign_attributes(t)
        self:insert_foreign_element(t, namespace)
        if t.self_closing then
            self:pop()
        end
        return
    elseif t.type == "end" then
        if tag == "br" or tag == "p" then
            -- these are handled as HTML even in foreign content
            self:pop_foreign()
            return self:process(t)
        end
        local i = #self.stack
        local node = self.stack[i]
        while i > 1 do
            if node.tag:lower() == tag then
                self:pop_until(node)
                return
            end
            i = i - 1
            node = self.stack[i]
            if rawget(node, "namespace") == nil then
                return self:process(t)
            end
        end
    end
end

-- Should this token be handled by the rules for foreign content?
function Builder:use_foreign_rules(t)
    if #self.stack == 0 or t.type == "eof" then
        return false
    end
    local node = self:adjusted_current()
    if rawget(node, "namespace") == nil then
        return false
    end
    if is_mathml_text_integration_point(node) then
        if (t.type == "start" and t.tag ~= "mglyph" and t.tag ~= "malignmark") or t.type == "text" then
            return false
        end
    end
    if
        rawget(node, "namespace") == "math"
        and node.tag == "annotation-xml"
        and t.type == "start"
        and t.tag == "svg"
    then
        return false
    end
    if is_html_integration_point(node) and (t.type == "start" or t.type == "text") then
        return false
    end
    return true
end

-- ── Driving ─────────────────────────────────────────────────────────────────

function Builder:dispatch(t)
    if self:use_foreign_rules(t) then
        return self:foreign_content(t)
    end
    return self:process(t)
end

local function new_builder(html_str, options)
    options = options or {}
    local document = Node.new("document")
    local builder = setmetatable({
        document = document,
        stack = {},
        afe = {},
        template_modes = {},
        mode = "initial",
        original_mode = nil,
        head = nil,
        form = nil,
        frameset_ok = true,
        foster_parenting = false,
        pending_table_text = {},
        quirks = "no-quirks",
        scripting = options.scripting ~= false,
        yield = options.yield,
        keep_comments = options.comments,
        skip_newline = false,
        stopped = false,
    }, Builder)
    builder.tokenizer = tokenizer_mod.new(html_str or "")
    builder.tokenizer.allow_cdata = function()
        local node = builder:adjusted_current()
        return node ~= nil and rawget(node, "namespace") ~= nil
    end
    return builder
end

function Builder:run()
    local tokenizer = self.tokenizer
    local yield = self.yield
    while not self.stopped do
        local t = tokenizer:next()
        if self.skip_newline then
            -- a newline directly after <pre>, <listing> or <textarea> is dropped
            self.skip_newline = false
            if t.type == "text" then
                t.text = t.text:gsub("^\n", "")
                if t.text == "" then
                    t = nil
                end
            end
        end
        if t then
            -- dispatch(), inlined for the common case: the adjusted current
            -- node is an HTML element, so the foreign content rules don't apply
            local stack = self.stack
            local n = #stack
            local node = stack[n]
            if n == 1 and self.context then
                node = self.context
            end
            if node == nil or rawget(node, "namespace") == nil then
                modes[self.mode](self, t)
            else
                self:dispatch(t)
            end
            if t.type == "eof" then
                self.stopped = true
            end
        end
        if yield then
            yield()
        end
    end
    -- stop parsing: pop all the nodes off the stack
    while #self.stack > 0 do
        self:pop()
    end
end

-- Parse a whole HTML document, as browsers do: the result is a "document"
-- node holding the doctype (if any) and the <html> element, with its <head>
-- and <body>, whether or not they were written out.
--
-- options:
--   comments   keep comments (default false)
--   scripting  parse as if scripting is enabled, as in browsers (default true)
--   yield      a function called after each token, e.g. to yield a coroutine
local function parse_document(html_str, options)
    local builder = new_builder(html_str, options)
    builder:run()
    return builder.document
end

-- Parse an HTML fragment, as for setting innerHTML on an element: by default
-- a <body>, or the element named by options.context ("td", "svg path", ...).
-- The result is a "document" node whose children are the fragment's
-- top-level nodes. Takes the same options as parse_document().
local function parse(html_str, options)
    options = options or {}
    local builder = new_builder(html_str, options)
    local context_name = options.context or "body"
    local namespace, tag = nil, context_name
    if context_name:sub(1, 4) == "svg " then
        namespace, tag = "svg", context_name:sub(5)
    elseif context_name:sub(1, 5) == "math " then
        namespace, tag = "math", context_name:sub(6)
    end
    local context = Node.new(tag)
    context.namespace = namespace
    builder.context = context

    if namespace == nil then
        local state = ({
            title = "rcdata",
            textarea = "rcdata",
            style = "rawtext",
            xmp = "rawtext",
            iframe = "rawtext",
            noembed = "rawtext",
            noframes = "rawtext",
            script = "script_data",
            plaintext = "plaintext",
        })[tag]
        if tag == "noscript" and builder.scripting then
            state = "rawtext"
        end
        if state then
            builder.tokenizer.state = state
        end
    end

    local root = Node.new("html")
    insert_at(builder.document, nil, root)
    builder.stack = { root }
    if is_html(context, "template") then
        builder.template_modes = { "in_template" }
    end
    builder:reset_insertion_mode()
    builder:run()

    local result = Node.new("document")
    local children = root.children
    root.children = {}
    for _, child in ipairs(children) do
        insert_at(result, nil, child)
    end
    return result
end

return {
    parse = parse,
    parse_document = parse_document,
}
