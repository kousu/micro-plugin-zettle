-- The HTML5 tokenizer: a state machine following
-- https://html.spec.whatwg.org/multipage/parsing.html#tokenization
--
-- Tokens:
--   { type = "text", text = "..." }          (a run of characters)
--   { type = "start", tag = "p", attrs = {...}, attr_order = {...}, self_closing = bool }
--   { type = "end", tag = "p" }
--   { type = "comment", data = "..." }
--   { type = "pi", target = "...", data = "..." }   (a processing instruction)
--   { type = "doctype", name = ..., public_id = ..., system_id = ..., force_quirks = bool }
--   { type = "eof" }
--
-- The tree builder drives it: it switches the tokenizer into the RCDATA,
-- RAWTEXT, script data or PLAINTEXT states after the matching start tags,
-- and tells it whether CDATA sections are allowed (only in SVG and MathML).
-- Parse errors aren't reported.

local entity_table = require("lusoup.entity_table")

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

local MAX_ENTITY_LENGTH = 0
for name in pairs(entity_table) do
    if #name > MAX_ENTITY_LENGTH then
        MAX_ENTITY_LENGTH = #name
    end
end

-- Encode a code point as UTF-8, without bit operators so it runs on Lua 5.1.
local function utf8_char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    else
        return string.char(
            0xF0 + math.floor(code / 0x40000),
            0x80 + math.floor(code / 0x1000) % 0x40,
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40
        )
    end
end

-- Numeric references to C1 control codes mean the windows-1252 characters.
local C1_REPLACEMENTS = {
    [0x80] = 0x20AC,
    [0x82] = 0x201A,
    [0x83] = 0x0192,
    [0x84] = 0x201E,
    [0x85] = 0x2026,
    [0x86] = 0x2020,
    [0x87] = 0x2021,
    [0x88] = 0x02C6,
    [0x89] = 0x2030,
    [0x8A] = 0x0160,
    [0x8B] = 0x2039,
    [0x8C] = 0x0152,
    [0x8E] = 0x017D,
    [0x91] = 0x2018,
    [0x92] = 0x2019,
    [0x93] = 0x201C,
    [0x94] = 0x201D,
    [0x95] = 0x2022,
    [0x96] = 0x2013,
    [0x97] = 0x2014,
    [0x98] = 0x02DC,
    [0x99] = 0x2122,
    [0x9A] = 0x0161,
    [0x9B] = 0x203A,
    [0x9C] = 0x0153,
    [0x9E] = 0x017E,
    [0x9F] = 0x0178,
}

local REPLACEMENT = "\239\191\189" -- U+FFFD

local function is_alpha(c)
    return c ~= nil and c:find("^%a") ~= nil
end

local function is_alnum(c)
    return c ~= nil and c:find("^%w") ~= nil
end

local function is_space(c)
    return c == " " or c == "\t" or c == "\n" or c == "\f"
end

local Tokenizer = {}
Tokenizer.__index = Tokenizer

local function new(input)
    -- HTML normalizes line endings to LF before tokenizing
    if input:find("\r", 1, true) then
        input = input:gsub("\r\n?", "\n")
    end
    return setmetatable({
        input = input,
        pos = 1,
        state = "data",
        return_state = nil,
        text = {}, -- pending character run
        queue = {}, -- tokens ready to return
        token = nil, -- tag, comment or doctype being built
        attr_name = nil, -- attribute being built
        attr_value = nil,
        buffer = "", -- the spec's "temporary buffer"
        last_start_tag = nil,
        char_ref_code = 0,
        allow_cdata = nil, -- set by the tree builder: function() -> bool
        done = false,
        next_at = {}, -- see next_of()
        simple_tags = {}, -- see fast_data()
    }, Tokenizer)
end

-- ── Emitting ────────────────────────────────────────────────────────────────

function Tokenizer:emit_char(c)
    self.text[#self.text + 1] = c
end

function Tokenizer:flush_text()
    if #self.text > 0 then
        self.queue[#self.queue + 1] = { type = "text", text = concat(self.text) }
        self.text = {}
    end
end

function Tokenizer:emit(token)
    self:flush_text()
    if token.type == "start" then
        self.last_start_tag = token.tag
    end
    self.queue[#self.queue + 1] = token
end

function Tokenizer:emit_current_tag()
    self:finish_attribute()
    local token = self.token
    if token.type == "end" then
        -- end tags have no attributes
        token.attrs, token.attr_order = nil, nil
    end
    self:emit(token)
end

function Tokenizer:emit_eof()
    self:emit({ type = "eof" })
    self.done = true
end

-- ── Tags and attributes ────────────────────────────────────────────────────

function Tokenizer:new_tag(kind)
    self.token = { type = kind, tag = "", attrs = {}, attr_order = {}, self_closing = false }
    self.attr_name = nil
end

function Tokenizer:start_attribute(c)
    self:finish_attribute()
    self.attr_name, self.attr_value = c or "", {}
end

function Tokenizer:finish_attribute()
    local name = self.attr_name
    if name then
        local token = self.token
        -- like browsers, the first occurrence of an attribute wins
        if token.attrs[name] == nil then
            token.attrs[name] = concat(self.attr_value)
            token.attr_order[#token.attr_order + 1] = name
        end
        self.attr_name = nil
    end
end

-- Is the current end tag the one that ends the last start tag?
function Tokenizer:appropriate_end_tag()
    return self.last_start_tag ~= nil and self.token.tag == self.last_start_tag
end

-- ── Driving ─────────────────────────────────────────────────────────────────

local states = {}

function Tokenizer:reconsume(state)
    self.pos = self.pos - 1
    self.state = state
end

local fast_data -- defined below

-- Return the next token.
function Tokenizer:next()
    local queue = self.queue
    while #queue == 0 do
        if self.done then
            return { type = "eof" }
        end
        -- in the data state, take whole text runs and well-formed tags at
        -- once; anything else goes through the state machine a character at
        -- a time
        local fast = self.state == "data" and fast_data(self)
        if fast and fast ~= true then
            -- a tag, returned directly rather than through the queue
            if fast.type == "start" then
                self.last_start_tag = fast.tag
            end
            local text = self.text
            if #text > 0 then
                self.text = {}
                queue[1] = fast
                return { type = "text", text = concat(text) }
            end
            return fast
        elseif not fast then
            local pos = self.pos
            local c = self.input:sub(pos, pos)
            if c == "" then
                c = nil
            end
            self.pos = pos + 1
            states[self.state](self, c)
            queue = self.queue
        end
    end
    if #queue == 1 then
        local t = queue[1]
        queue[1] = nil
        return t
    end
    return table.remove(queue, 1)
end

-- Does the input at the current position (case-insensitively) start with `s`?
function Tokenizer:lookahead(s, case_insensitive)
    local got = self.input:sub(self.pos, self.pos + #s - 1)
    if case_insensitive then
        got = got:lower()
    end
    return got == s
end

local RUN_DATA, RUN_LT, RUN_NONE, RUN_COMMENT = { "<", "&" }, { "<" }, {}, { "-", "<" }

-- The position of the next `ch` at or after the current position, or false.
-- Positions are remembered, so that each character is searched for once per
-- occurrence rather than on every call (which would be quadratic for
-- characters that don't occur). Plain searches, because pattern searches
-- are slow in some Lua implementations (micro's gopher-lua).
function Tokenizer:next_of(ch)
    local next_at = self.next_at
    local at = next_at[ch]
    if at == nil or (at and at < self.pos) then
        at = self.input:find(ch, self.pos, true) or false
        next_at[ch] = at
    end
    return at
end

-- Consume a run of ordinary text up to the next character that matters in
-- the data, RCDATA, RAWTEXT, script data or PLAINTEXT states: one of
-- `specials`, a list of characters, or a NUL.
function Tokenizer:consume_run(c, specials)
    local stop = self:next_of("\0")
    for i = 1, #specials do
        local at = self:next_of(specials[i])
        if at and (not stop or at < stop) then
            stop = at
        end
    end
    local input = self.input
    stop = stop or (#input + 1)
    self:emit_char(c .. input:sub(self.pos, stop - 1))
    self.pos = stop
end

-- ── Text states ─────────────────────────────────────────────────────────────

states.data = function(self, c)
    if c == "&" then
        self.return_state = "data"
        self.state = "character_reference"
    elseif c == "<" then
        self.state = "tag_open"
    elseif c == "\0" then
        self:emit_char("\0")
    elseif c == nil then
        self:emit_eof()
    else
        self:consume_run(c, RUN_DATA)
    end
end

states.rcdata = function(self, c)
    if c == "&" then
        self.return_state = "rcdata"
        self.state = "character_reference"
    elseif c == "<" then
        self.state = "rcdata_lt"
    elseif c == "\0" then
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self:consume_run(c, RUN_DATA)
    end
end

states.rawtext = function(self, c)
    if c == "<" then
        self.state = "rawtext_lt"
    elseif c == "\0" then
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self:consume_run(c, RUN_LT)
    end
end

states.script_data = function(self, c)
    if c == "<" then
        self.state = "script_data_lt"
    elseif c == "\0" then
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self:consume_run(c, RUN_LT)
    end
end

states.plaintext = function(self, c)
    if c == "\0" then
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self:consume_run(c, RUN_NONE)
    end
end

-- ── Tags ────────────────────────────────────────────────────────────────────

-- A fast path for the common case of a well-formed tag, read with patterns
-- instead of a character at a time (as upstream lusoup does). `start` is the
-- position of its name's first letter. Returns the position after the tag
-- and emits it, or returns nil, having consumed nothing, if the tag has
-- anything the state machine must handle: NULs, a missing `>` and so on.
-- Character references in attribute values are decoded as the state machine
-- would: a reference can't extend past the end of the value.
local byte = string.byte
local B_TAB, B_LF, B_FF, B_SPACE = 9, 10, 12, 32
local B_NUL, B_SLASH, B_EQ, B_GT, B_DQ, B_SQ, B_AMP = 0, 47, 61, 62, 34, 39, 38

local function is_space_byte(b)
    return b == B_SPACE or b == B_LF or b == B_TAB or b == B_FF
end

-- The position of the first byte at or after `pos` that is whitespace or one
-- of `a`, `b`, `c` (or the end of the input).
local function scan_to(input, pos, a, b, c)
    while true do
        local x = byte(input, pos)
        if x == nil or x == a or x == b or x == c or x == B_NUL or is_space_byte(x) then
            return pos
        end
        pos = pos + 1
    end
end

local function skip_space(input, pos)
    while is_space_byte(byte(input, pos)) do
        pos = pos + 1
    end
    return pos
end

local function fast_start_tag(self, start, no_emit)
    local input = self.input
    local e = scan_to(input, start, B_SLASH, B_GT)
    local token = {
        type = "start",
        tag = input:sub(start, e - 1):lower(),
        attrs = {},
        attr_order = {},
        self_closing = false,
    }
    local attrs, order = token.attrs, token.attr_order
    local pos = e
    while true do
        pos = skip_space(input, pos)
        local x = byte(input, pos)
        if x == B_GT then
            break
        elseif x == B_SLASH then
            if byte(input, pos + 1) == B_GT then
                token.self_closing = true
                pos = pos + 1
                break
            end
            pos = pos + 1
        elseif x == nil or x == B_NUL or x == B_EQ then
            return nil
        else
            local ae = scan_to(input, pos + 1, B_SLASH, B_GT, B_EQ)
            if byte(input, ae) == B_NUL then
                return nil
            end
            local aname = input:sub(pos, ae - 1):lower()
            local value = ""
            pos = skip_space(input, ae)
            if byte(input, pos) == B_EQ then
                pos = skip_space(input, pos + 1)
                local q = byte(input, pos)
                if q == B_DQ or q == B_SQ then
                    local close = input:find(q == B_DQ and '"' or "'", pos + 1, true)
                    if not close then
                        return nil
                    end
                    value = input:sub(pos + 1, close - 1)
                    pos = close + 1
                elseif q ~= B_GT then
                    local ve = scan_to(input, pos, B_GT)
                    -- the value must end the way the state machine would end it
                    local after = byte(input, ve)
                    if after == nil or after == B_NUL or ve == pos then
                        return nil
                    end
                    value = input:sub(pos, ve - 1)
                    pos = ve
                end
                if value:find("\0", 1, true) then
                    return nil
                end
                if value:find("&", 1, true) then
                    -- required here: lusoup.entities requires this module
                    value = require("lusoup.entities").decode(value, true)
                end
            end
            if attrs[aname] == nil then
                attrs[aname] = value
                order[#order + 1] = aname
            end
        end
    end
    if not no_emit then
        self:emit(token)
    end
    return pos + 1, token
end

local B_LT = 60

-- Is byte `b` an ASCII letter?
local function is_alpha_byte(b)
    return b ~= nil and ((b >= 97 and b <= 122) or (b >= 65 and b <= 90))
end

-- What the text between a `<` and the next `>` is, if it's a tag without
-- attributes: { end_tag, name }, or false if it's anything else.
local function classify_simple_tag(s)
    if s:find("^[A-Za-z][A-Za-z0-9]*$") then
        return { false, s:lower() }
    elseif s:find("^/[A-Za-z][A-Za-z0-9]*$") then
        return { true, s:sub(2):lower() }
    end
    return false
end

local MAX_SIMPLE_TAG = 16

-- The data state's fast path, at the current position: consume a run of
-- text up to the next `<`, `&` or NUL and return true, or consume a
-- well-formed start or end tag and return its token (not emitted), or
-- consume nothing and return false.
function fast_data(self)
    local input, pos = self.input, self.pos
    local b = byte(input, pos)
    if b == B_LT then
        -- most tags have no attributes and recur often (<td>, </tr>): look
        -- them up by their text
        local gt = self:next_of(">")
        if gt and gt - pos <= MAX_SIMPLE_TAG + 1 then
            local s = input:sub(pos + 1, gt - 1)
            local simple = self.simple_tags
            local hit = simple[s]
            if hit == nil then
                hit = classify_simple_tag(s)
                simple[s] = hit
            end
            if hit then
                self.pos = gt + 1
                if hit[1] then
                    return { type = "end", tag = hit[2] }
                end
                return { type = "start", tag = hit[2], attrs = {}, attr_order = {}, self_closing = false }
            end
        end
        local b2 = byte(input, pos + 1)
        if b2 == B_SLASH then
            if is_alpha_byte(byte(input, pos + 2)) then
                local e = scan_to(input, pos + 3, B_SLASH, B_GT)
                if byte(input, e) == B_GT then
                    self.pos = e + 1
                    return { type = "end", tag = input:sub(pos + 2, e - 1):lower() }
                end
            end
        elseif is_alpha_byte(b2) then
            local after, token = fast_start_tag(self, pos + 1, true)
            if after then
                self.pos = after
                return token
            end
        end
        return false
    elseif b == nil or b == B_AMP or b == B_NUL then
        return false
    end
    local stop = self:next_of("<")
    local at = self:next_of("&")
    if at and (not stop or at < stop) then
        stop = at
    end
    at = self:next_of("\0")
    if at and (not stop or at < stop) then
        stop = at
    end
    stop = stop or (#input + 1)
    local text = self.text
    text[#text + 1] = input:sub(pos, stop - 1)
    self.pos = stop
    return true
end

states.tag_open = function(self, c)
    if c == "!" then
        self.state = "markup_declaration_open"
    elseif c == "/" then
        local input, start = self.input, self.pos
        if is_alpha(input:sub(start, start)) then
            local e = scan_to(input, start + 1, B_SLASH, B_GT)
            if byte(input, e) == B_GT then
                self:emit({ type = "end", tag = input:sub(start, e - 1):lower() })
                self.pos = e + 1
                self.state = "data"
                return
            end
        end
        self.state = "end_tag_open"
    elseif is_alpha(c) then
        local after = fast_start_tag(self, self.pos - 1)
        if after then
            self.pos = after
            self.state = "data"
            return
        end
        self:new_tag("start")
        self:reconsume("tag_name")
    elseif c == "?" then
        self.buffer = ""
        self.state = "processing_instruction_open"
    elseif c == nil then
        self:emit_char("<")
        self:emit_eof()
    else
        self:emit_char("<")
        self:reconsume("data")
    end
end

states.end_tag_open = function(self, c)
    if is_alpha(c) then
        self:new_tag("end")
        self:reconsume("tag_name")
    elseif c == ">" then
        self.state = "data"
    elseif c == nil then
        self:emit_char("</")
        self:emit_eof()
    else
        self.token = { type = "comment", data = "" }
        self:reconsume("bogus_comment")
    end
end

states.tag_name = function(self, c)
    if is_space(c) then
        self.state = "before_attribute_name"
    elseif c == "/" then
        self.state = "self_closing_start_tag"
    elseif c == ">" then
        self.state = "data"
        self:emit_current_tag()
    elseif c == "\0" then
        self.token.tag = self.token.tag .. REPLACEMENT
    elseif c == nil then
        self:emit_eof()
    else
        -- consume the rest of the name at once
        local name = self.input:match("^[^%s/>%z]*", self.pos)
        self.token.tag = self.token.tag .. (c .. name):lower()
        self.pos = self.pos + #name
    end
end

-- The RCDATA, RAWTEXT and script data "less-than sign", "end tag open" and
-- "end tag name" states only differ in which state they return to.
local function lt_state(text_state, end_tag_open_state)
    return function(self, c)
        if c == "/" then
            self.buffer = ""
            self.state = end_tag_open_state
        else
            self:emit_char("<")
            self:reconsume(text_state)
        end
    end
end

local function end_tag_open_state(text_state, end_tag_name_state)
    return function(self, c)
        if is_alpha(c) then
            self:new_tag("end")
            self:reconsume(end_tag_name_state)
        else
            self:emit_char("</")
            self:reconsume(text_state)
        end
    end
end

local function end_tag_name_state(text_state)
    return function(self, c)
        if is_space(c) and self:appropriate_end_tag() then
            self.state = "before_attribute_name"
        elseif c == "/" and self:appropriate_end_tag() then
            self.state = "self_closing_start_tag"
        elseif c == ">" and self:appropriate_end_tag() then
            self.state = "data"
            self:emit_current_tag()
        elseif is_alpha(c) then
            self.token.tag = self.token.tag .. c:lower()
            self.buffer = self.buffer .. c
        else
            self:emit_char("</" .. self.buffer)
            self:reconsume(text_state)
        end
    end
end

states.rcdata_lt = lt_state("rcdata", "rcdata_end_tag_open")
states.rcdata_end_tag_open = end_tag_open_state("rcdata", "rcdata_end_tag_name")
states.rcdata_end_tag_name = end_tag_name_state("rcdata")
states.rawtext_lt = lt_state("rawtext", "rawtext_end_tag_open")
states.rawtext_end_tag_open = end_tag_open_state("rawtext", "rawtext_end_tag_name")
states.rawtext_end_tag_name = end_tag_name_state("rawtext")

-- ── Script data ─────────────────────────────────────────────────────────────

states.script_data_lt = function(self, c)
    if c == "/" then
        self.buffer = ""
        self.state = "script_data_end_tag_open"
    elseif c == "!" then
        self.state = "script_data_escape_start"
        self:emit_char("<!")
    else
        self:emit_char("<")
        self:reconsume("script_data")
    end
end
states.script_data_end_tag_open = end_tag_open_state("script_data", "script_data_end_tag_name")
states.script_data_end_tag_name = end_tag_name_state("script_data")

states.script_data_escape_start = function(self, c)
    if c == "-" then
        self.state = "script_data_escape_start_dash"
        self:emit_char("-")
    else
        self:reconsume("script_data")
    end
end

states.script_data_escape_start_dash = function(self, c)
    if c == "-" then
        self.state = "script_data_escaped_dash_dash"
        self:emit_char("-")
    else
        self:reconsume("script_data")
    end
end

states.script_data_escaped = function(self, c)
    if c == "-" then
        self.state = "script_data_escaped_dash"
        self:emit_char("-")
    elseif c == "<" then
        self.state = "script_data_escaped_lt"
    elseif c == "\0" then
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self:consume_run(c, RUN_COMMENT)
    end
end

states.script_data_escaped_dash = function(self, c)
    if c == "-" then
        self.state = "script_data_escaped_dash_dash"
        self:emit_char("-")
    elseif c == "<" then
        self.state = "script_data_escaped_lt"
    elseif c == "\0" then
        self.state = "script_data_escaped"
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self.state = "script_data_escaped"
        self:emit_char(c)
    end
end

states.script_data_escaped_dash_dash = function(self, c)
    if c == "-" then
        self:emit_char("-")
    elseif c == "<" then
        self.state = "script_data_escaped_lt"
    elseif c == ">" then
        self.state = "script_data"
        self:emit_char(">")
    elseif c == "\0" then
        self.state = "script_data_escaped"
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self.state = "script_data_escaped"
        self:emit_char(c)
    end
end

states.script_data_escaped_lt = function(self, c)
    if c == "/" then
        self.buffer = ""
        self.state = "script_data_escaped_end_tag_open"
    elseif is_alpha(c) then
        self.buffer = ""
        self:emit_char("<")
        self:reconsume("script_data_double_escape_start")
    else
        self:emit_char("<")
        self:reconsume("script_data_escaped")
    end
end
states.script_data_escaped_end_tag_open = end_tag_open_state("script_data_escaped", "script_data_escaped_end_tag_name")
states.script_data_escaped_end_tag_name = end_tag_name_state("script_data_escaped")

-- double escape start and end differ only in which states they switch between
local function double_escape_state(matched_state, other_state)
    return function(self, c)
        if is_space(c) or c == "/" or c == ">" then
            self.state = self.buffer == "script" and matched_state or other_state
            self:emit_char(c)
        elseif is_alpha(c) then
            self.buffer = self.buffer .. c:lower()
            self:emit_char(c)
        else
            self:reconsume(other_state)
        end
    end
end
states.script_data_double_escape_start = double_escape_state("script_data_double_escaped", "script_data_escaped")
states.script_data_double_escape_end = double_escape_state("script_data_escaped", "script_data_double_escaped")

states.script_data_double_escaped = function(self, c)
    if c == "-" then
        self.state = "script_data_double_escaped_dash"
        self:emit_char("-")
    elseif c == "<" then
        self.state = "script_data_double_escaped_lt"
        self:emit_char("<")
    elseif c == "\0" then
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self:emit_char(c)
    end
end

states.script_data_double_escaped_dash = function(self, c)
    if c == "-" then
        self.state = "script_data_double_escaped_dash_dash"
        self:emit_char("-")
    elseif c == "<" then
        self.state = "script_data_double_escaped_lt"
        self:emit_char("<")
    elseif c == "\0" then
        self.state = "script_data_double_escaped"
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self.state = "script_data_double_escaped"
        self:emit_char(c)
    end
end

states.script_data_double_escaped_dash_dash = function(self, c)
    if c == "-" then
        self:emit_char("-")
    elseif c == "<" then
        self.state = "script_data_double_escaped_lt"
        self:emit_char("<")
    elseif c == ">" then
        self.state = "script_data"
        self:emit_char(">")
    elseif c == "\0" then
        self.state = "script_data_double_escaped"
        self:emit_char(REPLACEMENT)
    elseif c == nil then
        self:emit_eof()
    else
        self.state = "script_data_double_escaped"
        self:emit_char(c)
    end
end

states.script_data_double_escaped_lt = function(self, c)
    if c == "/" then
        self.buffer = ""
        self.state = "script_data_double_escape_end"
        self:emit_char("/")
    else
        self:reconsume("script_data_double_escaped")
    end
end

-- ── Attributes ──────────────────────────────────────────────────────────────

states.before_attribute_name = function(self, c)
    if is_space(c) then
        return
    elseif c == "/" or c == ">" or c == nil then
        self:reconsume("after_attribute_name")
    elseif c == "=" then
        self:start_attribute("=")
        self.state = "attribute_name"
    else
        self:start_attribute("")
        self:reconsume("attribute_name")
    end
end

states.attribute_name = function(self, c)
    if is_space(c) or c == "/" or c == ">" or c == nil then
        self:reconsume("after_attribute_name")
    elseif c == "=" then
        self.state = "before_attribute_value"
    elseif c == "\0" then
        self.attr_name = self.attr_name .. REPLACEMENT
    else
        self.attr_name = self.attr_name .. c:lower()
    end
end

states.after_attribute_name = function(self, c)
    if is_space(c) then
        return
    elseif c == "/" then
        self.state = "self_closing_start_tag"
    elseif c == "=" then
        self.state = "before_attribute_value"
    elseif c == ">" then
        self.state = "data"
        self:emit_current_tag()
    elseif c == nil then
        self:emit_eof()
    else
        self:start_attribute("")
        self:reconsume("attribute_name")
    end
end

states.before_attribute_value = function(self, c)
    if is_space(c) then
        return
    elseif c == '"' then
        self.state = "attribute_value_double"
    elseif c == "'" then
        self.state = "attribute_value_single"
    elseif c == ">" then
        self.state = "data"
        self:emit_current_tag()
    else
        self:reconsume("attribute_value_unquoted")
    end
end

local function quoted_value_state(quote, state_name)
    return function(self, c)
        if c == quote then
            self.state = "after_attribute_value_quoted"
        elseif c == "&" then
            self.return_state = state_name
            self.state = "character_reference"
        elseif c == "\0" then
            self.attr_value[#self.attr_value + 1] = REPLACEMENT
        elseif c == nil then
            self:emit_eof()
        else
            local run = self.input:match(quote == '"' and '^[^"&%z]*' or "^[^'&%z]*", self.pos)
            self.attr_value[#self.attr_value + 1] = c .. run
            self.pos = self.pos + #run
        end
    end
end
states.attribute_value_double = quoted_value_state('"', "attribute_value_double")
states.attribute_value_single = quoted_value_state("'", "attribute_value_single")

states.attribute_value_unquoted = function(self, c)
    if is_space(c) then
        self.state = "before_attribute_name"
    elseif c == "&" then
        self.return_state = "attribute_value_unquoted"
        self.state = "character_reference"
    elseif c == ">" then
        self.state = "data"
        self:emit_current_tag()
    elseif c == "\0" then
        self.attr_value[#self.attr_value + 1] = REPLACEMENT
    elseif c == nil then
        self:emit_eof()
    else
        self.attr_value[#self.attr_value + 1] = c
    end
end

states.after_attribute_value_quoted = function(self, c)
    if is_space(c) then
        self.state = "before_attribute_name"
    elseif c == "/" then
        self.state = "self_closing_start_tag"
    elseif c == ">" then
        self.state = "data"
        self:emit_current_tag()
    elseif c == nil then
        self:emit_eof()
    else
        self:reconsume("before_attribute_name")
    end
end

states.self_closing_start_tag = function(self, c)
    if c == ">" then
        self.token.self_closing = true
        self.state = "data"
        self:emit_current_tag()
    elseif c == nil then
        self:emit_eof()
    else
        self:reconsume("before_attribute_name")
    end
end

-- ── Comments ────────────────────────────────────────────────────────────────

states.bogus_comment = function(self, c)
    if c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        self:emit(self.token)
        self:emit_eof()
    elseif c == "\0" then
        self.token.data = self.token.data .. REPLACEMENT
    else
        self.token.data = self.token.data .. c
    end
end

states.markup_declaration_open = function(self, c)
    self.pos = self.pos - 1 -- this state looks ahead instead of consuming
    if self:lookahead("--") then
        self.pos = self.pos + 2
        self.token = { type = "comment", data = "" }
        self.state = "comment_start"
    elseif self:lookahead("doctype", true) then
        self.pos = self.pos + 7
        self.state = "doctype"
    elseif self:lookahead("[CDATA[") and self.allow_cdata and self.allow_cdata() then
        self.pos = self.pos + 7
        self.state = "cdata_section"
    else
        self.token = { type = "comment", data = "" }
        self.state = "bogus_comment"
    end
end

states.comment_start = function(self, c)
    if c == "-" then
        self.state = "comment_start_dash"
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    else
        self:reconsume("comment")
    end
end

states.comment_start_dash = function(self, c)
    if c == "-" then
        self.state = "comment_end"
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        self:emit(self.token)
        self:emit_eof()
    else
        self.token.data = self.token.data .. "-"
        self:reconsume("comment")
    end
end

states.comment = function(self, c)
    if c == "<" then
        self.token.data = self.token.data .. c
        self.state = "comment_lt"
    elseif c == "-" then
        self.state = "comment_end_dash"
    elseif c == "\0" then
        self.token.data = self.token.data .. REPLACEMENT
    elseif c == nil then
        self:emit(self.token)
        self:emit_eof()
    else
        local run = self.input:match("^[^<%-%z]*", self.pos)
        self.token.data = self.token.data .. c .. run
        self.pos = self.pos + #run
    end
end

states.comment_lt = function(self, c)
    if c == "!" then
        self.token.data = self.token.data .. c
        self.state = "comment_lt_bang"
    elseif c == "<" then
        self.token.data = self.token.data .. c
    else
        self:reconsume("comment")
    end
end

states.comment_lt_bang = function(self, c)
    if c == "-" then
        self.state = "comment_lt_bang_dash"
    else
        self:reconsume("comment")
    end
end

states.comment_lt_bang_dash = function(self, c)
    if c == "-" then
        self.state = "comment_lt_bang_dash_dash"
    else
        self:reconsume("comment_end_dash")
    end
end

states.comment_lt_bang_dash_dash = function(self, c)
    self:reconsume("comment_end")
end

states.comment_end_dash = function(self, c)
    if c == "-" then
        self.state = "comment_end"
    elseif c == nil then
        self:emit(self.token)
        self:emit_eof()
    else
        self.token.data = self.token.data .. "-"
        self:reconsume("comment")
    end
end

states.comment_end = function(self, c)
    if c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == "!" then
        self.state = "comment_end_bang"
    elseif c == "-" then
        self.token.data = self.token.data .. "-"
    elseif c == nil then
        self:emit(self.token)
        self:emit_eof()
    else
        self.token.data = self.token.data .. "--"
        self:reconsume("comment")
    end
end

states.comment_end_bang = function(self, c)
    if c == "-" then
        self.token.data = self.token.data .. "--!"
        self.state = "comment_end_dash"
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        self:emit(self.token)
        self:emit_eof()
    else
        self.token.data = self.token.data .. "--!"
        self:reconsume("comment")
    end
end

-- ── Processing instructions ─────────────────────────────────────────────────

-- "<?" followed by something that isn't a valid target becomes a bogus comment.
function Tokenizer:buffer_to_comment()
    self.token = { type = "comment", data = "?" .. self.buffer }
end

states.processing_instruction_open = function(self, c)
    if c ~= nil and c:find("^[%a_]") then
        self:reconsume("processing_instruction_target")
    elseif c == nil then
        self:emit_eof()
    else
        self:buffer_to_comment()
        self:reconsume("bogus_comment")
    end
end

states.processing_instruction_target = function(self, c)
    if is_space(c) or c == "?" or c == ">" then
        local target = self.buffer
        local lower = target:lower()
        if lower == "xml" or lower == "xml-stylesheet" then
            self:buffer_to_comment()
            self:reconsume("bogus_comment")
        else
            self.token = { type = "pi", target = target, data = "" }
            self:reconsume("after_processing_instruction_target")
        end
    elseif c ~= nil and c:find("^[%w_%-]") then
        self.buffer = self.buffer .. c
    elseif c == nil then
        self:emit_eof()
    else
        self:buffer_to_comment()
        self:reconsume("bogus_comment")
    end
end

states.after_processing_instruction_target = function(self, c)
    if is_space(c) then
        return
    end
    self:reconsume("processing_instruction_data")
end

states.processing_instruction_data = function(self, c)
    if c == "?" then
        self.state = "processing_instruction_questionable"
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        -- an unfinished processing instruction is dropped
        self:emit_eof()
    else
        self.token.data = self.token.data .. c
    end
end

states.processing_instruction_questionable = function(self, c)
    if c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        self:emit_eof()
    else
        self.token.data = self.token.data .. "?"
        self:reconsume("processing_instruction_data")
    end
end

-- ── DOCTYPEs ────────────────────────────────────────────────────────────────

local function new_doctype()
    return { type = "doctype", name = nil, public_id = nil, system_id = nil, force_quirks = false }
end

function Tokenizer:doctype_eof()
    self.token.force_quirks = true
    self:emit(self.token)
    self:emit_eof()
end

states.doctype = function(self, c)
    if is_space(c) then
        self.state = "before_doctype_name"
    elseif c == ">" then
        self:reconsume("before_doctype_name")
    elseif c == nil then
        self.token = new_doctype()
        self:doctype_eof()
    else
        self:reconsume("before_doctype_name")
    end
end

states.before_doctype_name = function(self, c)
    if is_space(c) then
        return
    elseif c == "\0" then
        self.token = new_doctype()
        self.token.name = REPLACEMENT
        self.state = "doctype_name"
    elseif c == ">" then
        self.token = new_doctype()
        self.token.force_quirks = true
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        self.token = new_doctype()
        self:doctype_eof()
    else
        self.token = new_doctype()
        self.token.name = c:lower()
        self.state = "doctype_name"
    end
end

states.doctype_name = function(self, c)
    if is_space(c) then
        self.state = "after_doctype_name"
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == "\0" then
        self.token.name = self.token.name .. REPLACEMENT
    elseif c == nil then
        self:doctype_eof()
    else
        self.token.name = self.token.name .. c:lower()
    end
end

states.after_doctype_name = function(self, c)
    if is_space(c) then
        return
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        self:doctype_eof()
    else
        self.pos = self.pos - 1
        if self:lookahead("public", true) then
            self.pos = self.pos + 6
            self.state = "after_doctype_public_keyword"
        elseif self:lookahead("system", true) then
            self.pos = self.pos + 6
            self.state = "after_doctype_system_keyword"
        else
            self.pos = self.pos + 1
            self.token.force_quirks = true
            self:reconsume("bogus_doctype")
        end
    end
end

-- The public and system identifier states are the same apart from which
-- field they fill in and where they go next.
local function after_keyword_state(field, before_state, double_state, single_state)
    return function(self, c)
        if is_space(c) then
            self.state = before_state
        elseif c == '"' then
            self.token[field] = ""
            self.state = double_state
        elseif c == "'" then
            self.token[field] = ""
            self.state = single_state
        elseif c == ">" then
            self.token.force_quirks = true
            self.state = "data"
            self:emit(self.token)
        elseif c == nil then
            self:doctype_eof()
        else
            self.token.force_quirks = true
            self:reconsume("bogus_doctype")
        end
    end
end

local function before_id_state(field, double_state, single_state)
    return function(self, c)
        if is_space(c) then
            return
        elseif c == '"' then
            self.token[field] = ""
            self.state = double_state
        elseif c == "'" then
            self.token[field] = ""
            self.state = single_state
        elseif c == ">" then
            self.token.force_quirks = true
            self.state = "data"
            self:emit(self.token)
        elseif c == nil then
            self:doctype_eof()
        else
            self.token.force_quirks = true
            self:reconsume("bogus_doctype")
        end
    end
end

local function id_state(field, quote, after_state)
    return function(self, c)
        if c == quote then
            self.state = after_state
        elseif c == "\0" then
            self.token[field] = self.token[field] .. REPLACEMENT
        elseif c == ">" then
            self.token.force_quirks = true
            self.state = "data"
            self:emit(self.token)
        elseif c == nil then
            self:doctype_eof()
        else
            self.token[field] = self.token[field] .. c
        end
    end
end

states.after_doctype_public_keyword =
    after_keyword_state("public_id", "before_doctype_public_id", "doctype_public_id_double", "doctype_public_id_single")
states.before_doctype_public_id = before_id_state("public_id", "doctype_public_id_double", "doctype_public_id_single")
states.doctype_public_id_double = id_state("public_id", '"', "after_doctype_public_id")
states.doctype_public_id_single = id_state("public_id", "'", "after_doctype_public_id")

states.after_doctype_public_id = function(self, c)
    if is_space(c) then
        self.state = "between_doctype_public_and_system"
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == '"' then
        self.token.system_id = ""
        self.state = "doctype_system_id_double"
    elseif c == "'" then
        self.token.system_id = ""
        self.state = "doctype_system_id_single"
    elseif c == nil then
        self:doctype_eof()
    else
        self.token.force_quirks = true
        self:reconsume("bogus_doctype")
    end
end

states.between_doctype_public_and_system = function(self, c)
    if is_space(c) then
        return
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == '"' then
        self.token.system_id = ""
        self.state = "doctype_system_id_double"
    elseif c == "'" then
        self.token.system_id = ""
        self.state = "doctype_system_id_single"
    elseif c == nil then
        self:doctype_eof()
    else
        self.token.force_quirks = true
        self:reconsume("bogus_doctype")
    end
end

states.after_doctype_system_keyword =
    after_keyword_state("system_id", "before_doctype_system_id", "doctype_system_id_double", "doctype_system_id_single")
states.before_doctype_system_id = before_id_state("system_id", "doctype_system_id_double", "doctype_system_id_single")
states.doctype_system_id_double = id_state("system_id", '"', "after_doctype_system_id")
states.doctype_system_id_single = id_state("system_id", "'", "after_doctype_system_id")

states.after_doctype_system_id = function(self, c)
    if is_space(c) then
        return
    elseif c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        self:doctype_eof()
    else
        -- not a parse error that sets force-quirks
        self:reconsume("bogus_doctype")
    end
end

states.bogus_doctype = function(self, c)
    if c == ">" then
        self.state = "data"
        self:emit(self.token)
    elseif c == nil then
        self:emit(self.token)
        self:emit_eof()
    end
end

-- ── CDATA sections (only in SVG and MathML) ─────────────────────────────────

states.cdata_section = function(self, c)
    if c == "]" then
        self.state = "cdata_section_bracket"
    elseif c == nil then
        self:emit_eof()
    else
        self:emit_char(c)
    end
end

states.cdata_section_bracket = function(self, c)
    if c == "]" then
        self.state = "cdata_section_end"
    else
        self:emit_char("]")
        self:reconsume("cdata_section")
    end
end

states.cdata_section_end = function(self, c)
    if c == "]" then
        self:emit_char("]")
    elseif c == ">" then
        self.state = "data"
    else
        self:emit_char("]]")
        self:reconsume("cdata_section")
    end
end

-- ── Character references ────────────────────────────────────────────────────

function Tokenizer:in_attribute()
    local r = self.return_state
    return r == "attribute_value_double" or r == "attribute_value_single" or r == "attribute_value_unquoted"
end

-- Add text from a character reference to wherever it belongs.
function Tokenizer:flush_reference(s)
    if self:in_attribute() then
        self.attr_value[#self.attr_value + 1] = s
    else
        self:emit_char(s)
    end
end

states.character_reference = function(self, c)
    self.buffer = "&"
    if is_alnum(c) then
        self:reconsume("named_character_reference")
    elseif c == "#" then
        self.buffer = "&#"
        self.state = "numeric_character_reference"
    else
        self:flush_reference(self.buffer)
        self:reconsume(self.return_state)
    end
end

states.named_character_reference = function(self, c)
    self.pos = self.pos - 1
    local candidate = self.input:sub(self.pos, self.pos + MAX_ENTITY_LENGTH - 1)
    local match, value
    for len = #candidate, 1, -1 do
        local name = candidate:sub(1, len)
        local v = entity_table[name]
        if v then
            match, value = name, v
            break
        end
    end
    if not match then
        self:flush_reference(self.buffer)
        self.state = "ambiguous_ampersand"
        return
    end
    local next_char = self.input:sub(self.pos + #match, self.pos + #match)
    self.pos = self.pos + #match
    if self:in_attribute() and match:sub(-1) ~= ";" and (next_char == "=" or is_alnum(next_char)) then
        -- historical: in attributes, "&copy=2" in a URL is left alone
        self:flush_reference("&" .. match)
    else
        self:flush_reference(value)
    end
    self.state = self.return_state
end

states.ambiguous_ampersand = function(self, c)
    if is_alnum(c) then
        local run = self.input:match("^%w*", self.pos)
        self:flush_reference(c .. run)
        self.pos = self.pos + #run
    else
        self:reconsume(self.return_state)
    end
end

states.numeric_character_reference = function(self, c)
    self.char_ref_code = 0
    if c == "x" or c == "X" then
        self.buffer = self.buffer .. c
        self.state = "hexadecimal_character_reference_start"
    else
        self:reconsume("decimal_character_reference_start")
    end
end

states.hexadecimal_character_reference_start = function(self, c)
    if c and c:find("^%x") then
        self:reconsume("hexadecimal_character_reference")
    else
        self:flush_reference(self.buffer)
        self:reconsume(self.return_state)
    end
end

states.decimal_character_reference_start = function(self, c)
    if c and c:find("^%d") then
        self:reconsume("decimal_character_reference")
    else
        self:flush_reference(self.buffer)
        self:reconsume(self.return_state)
    end
end

local function add_digit(self, value, base)
    -- clamp, so that huge references don't overflow
    self.char_ref_code = math.min(self.char_ref_code * base + value, 0x110000)
end

states.hexadecimal_character_reference = function(self, c)
    if c and c:find("^%x") then
        add_digit(self, tonumber(c, 16), 16)
    elseif c == ";" then
        self.state = "numeric_character_reference_end"
    else
        self:reconsume("numeric_character_reference_end")
    end
end

states.decimal_character_reference = function(self, c)
    if c and c:find("^%d") then
        add_digit(self, tonumber(c), 10)
    elseif c == ";" then
        self.state = "numeric_character_reference_end"
    else
        self:reconsume("numeric_character_reference_end")
    end
end

states.numeric_character_reference_end = function(self, c)
    self.pos = self.pos - 1 -- this state doesn't consume
    local code = self.char_ref_code
    if code == 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
        code = 0xFFFD
    elseif C1_REPLACEMENTS[code] then
        code = C1_REPLACEMENTS[code]
    end
    self:flush_reference(utf8_char(code))
    self.state = self.return_state
end

return {
    new = new,
    utf8_char = utf8_char,
}
