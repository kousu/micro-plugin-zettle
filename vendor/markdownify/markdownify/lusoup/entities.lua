-- Decode HTML character references (&amp;, &#233;, &eacute; ...) in a string,
-- following the same rules as the tokenizer: all of HTML5's named
-- references, the legacy ones also without a trailing semicolon, and
-- numeric references with the windows-1252 fixups for C1 control codes.
--
-- The parser decodes references itself as it tokenizes; this is for
-- decoding strings from elsewhere.

local entity_table = require("lusoup.entity_table")
local utf8_char = require("lusoup.tokenizer").utf8_char

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

-- Decode the reference starting at str[i] (just after the "&"). Returns the
-- replacement and the position after the reference, or nil if there isn't one.
local function decode_at(str, i, in_attribute)
    if str:sub(i, i) == "#" then
        local digits, base
        local x = str:sub(i + 1, i + 1)
        if x == "x" or x == "X" then
            digits, base = str:match("^%x+", i + 2), 16
            i = i + 2
        else
            digits, base = str:match("^%d+", i + 1), 10
            i = i + 1
        end
        if not digits then
            return nil
        end
        i = i + #digits
        if str:sub(i, i) == ";" then
            i = i + 1
        end
        -- huge numbers are out of range anyway; don't let them overflow
        local code = #digits:gsub("^0+", "") > 8 and 0x110000 or tonumber(digits, base)
        if code == 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
            code = 0xFFFD
        end
        return utf8_char(C1_REPLACEMENTS[code] or code), i
    end

    local candidate = str:sub(i, i + MAX_ENTITY_LENGTH - 1)
    for len = #candidate, 1, -1 do
        local name = candidate:sub(1, len)
        local value = entity_table[name]
        if value then
            local next_char = str:sub(i + len, i + len)
            -- in attributes, "&copy=2" in a URL is left alone
            if in_attribute and name:sub(-1) ~= ";" and next_char:match("[=%w]") then
                return nil
            end
            return value, i + len
        end
    end
    return nil
end

-- Decode character references in `str`. `in_attribute` applies HTML's rule
-- for attribute values: a legacy reference without a semicolon isn't decoded
-- when followed by "=" or an alphanumeric.
local function decode(str, in_attribute)
    if not str then
        return ""
    end
    if not str:find("&", 1, true) then
        return str
    end
    local out, pos = {}, 1
    while true do
        local amp = str:find("&", pos, true)
        if not amp then
            out[#out + 1] = str:sub(pos)
            break
        end
        out[#out + 1] = str:sub(pos, amp - 1)
        local replacement, after = decode_at(str, amp + 1, in_attribute)
        if replacement then
            out[#out + 1] = replacement
            pos = after
        else
            out[#out + 1] = "&"
            pos = amp + 1
        end
    end
    return concat(out)
end

return {
    decode = decode,
}
