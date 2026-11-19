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

local Node = {}

-- Node kinds besides elements, which are distinguished by their tag:
--   "#text"     text_content is the (decoded) text
--   "#comment"  text_content is the comment's text
--   "#doctype"  name, public_id and system_id
--   "#processing-instruction"  target, and text_content is its data
--   "document" and "#document-fragment": the roots of parsed trees
local function is_element(node)
    return node.tag:sub(1, 1) ~= "#" and node.tag ~= "document"
end
Node.is_element = is_element

function Node.new(tag, attrs, parent)
    local self = {
        tag = tag or "document",
        attrs = attrs or {},
        children = {},
        parent = parent or nil,
        text_content = nil,
    }
    return setmetatable(self, Node)
end

-- A node's own fields, as opposed to names of child nodes that can be
-- accessed with the same syntax (e.g. node.children vs node.ul.li).
local DECLARED_FIELDS = {
    tag = true,
    attrs = true,
    children = true,
    parent = true,
    text_content = true,
    namespace = true,
    attr_ns = true,
    content = true,
    name = true,
    public_id = true,
    system_id = true,
    target = true,
}

function Node.__index(table, key)
    if Node[key] ~= nil then
        return Node[key]
    end
    if DECLARED_FIELDS[key] then
        -- We end up here if someone asks for an undefined node attribute,
        -- e.g. someone asks for node.parent but node is the root.
        -- In that case, avoid incorrectly (and expensively) searching the tree.
        return nil
    end
    if type(key) == "string" and not key:match("^_") then
        local child = table:find(key)
        if child then
            return child
        end
    end
    return rawget(table, key)
end

function Node:append_child(child)
    child.parent = self
    table.insert(self.children, child)
end

function Node:attr(key)
    if not key then
        return nil
    end
    return self.attrs[key:lower()]
end

function Node:text()
    if self.tag == "#text" then
        return self.text_content or ""
    elseif not is_element(self) and self.tag ~= "document" and self.tag ~= "#document-fragment" then
        return "" -- comments, doctypes and processing instructions have no text
    end

    local texts = {}
    for _, child in ipairs(self.children) do
        local t = child:text()
        if t and t ~= "" then
            table.insert(texts, t)
        end
    end

    -- in parentheses, so only the string is returned, not gsub's count
    return (concat(texts, " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Node:parent_node()
    return self.parent
end

function Node:children_nodes()
    local res = {}
    for _, child in ipairs(self.children) do
        if is_element(child) then
            table.insert(res, child)
        end
    end
    return res
end

function Node:next_sibling()
    if not self.parent then
        return nil
    end
    local siblings = self.parent.children
    for i, child in ipairs(siblings) do
        if child == self then
            for j = i + 1, #siblings do
                if is_element(siblings[j]) then
                    return siblings[j]
                end
            end
            break
        end
    end
    return nil
end

function Node:prev_sibling()
    if not self.parent then
        return nil
    end
    local siblings = self.parent.children
    for i, child in ipairs(siblings) do
        if child == self then
            for j = i - 1, 1, -1 do
                if is_element(siblings[j]) then
                    return siblings[j]
                end
            end
            break
        end
    end
    return nil
end

function Node:closest(tag_or_rule)
    local current = self.parent
    while current and current.tag ~= "document" do
        if type(tag_or_rule) == "string" and current.tag:lower() == tag_or_rule:lower() then
            return current
        elseif type(tag_or_rule) == "function" and tag_or_rule(current) then
            return current
        end
        current = current.parent
    end
    return nil
end

local function collect_all_nodes(node, list)
    for _, child in ipairs(node.children) do
        if is_element(child) then
            table.insert(list, child)
            collect_all_nodes(child, list)
        end
    end
end

function Node:next_element()
    local root = self
    while root.parent do
        root = root.parent
    end
    local flat_list = {}
    collect_all_nodes(root, flat_list)
    for i, node in ipairs(flat_list) do
        if node == self then
            return flat_list[i + 1]
        end
    end
    return nil
end

function Node:prev_element()
    local root = self
    while root.parent do
        root = root.parent
    end
    local flat_list = {}
    collect_all_nodes(root, flat_list)
    for i, node in ipairs(flat_list) do
        if node == self then
            return flat_list[i - 1]
        end
    end
    return nil
end

function Node:decompose()
    if not self.parent then
        return
    end
    for i, child in ipairs(self.parent.children) do
        if child == self then
            table.remove(self.parent.children, i)
            self.parent = nil
            break
        end
    end
end

-- Elements whose text is serialized as-is, without escaping.
local RAW_TEXT = {
    style = true,
    script = true,
    xmp = true,
    iframe = true,
    noembed = true,
    noframes = true,
    plaintext = true,
    noscript = true,
}

local VOID_ELEMENTS = {
    area = true,
    base = true,
    br = true,
    col = true,
    embed = true,
    hr = true,
    img = true,
    input = true,
    link = true,
    meta = true,
    param = true,
    source = true,
    track = true,
    wbr = true,
    basefont = true,
    bgsound = true,
    frame = true,
    keygen = true,
}

local function escape_text(s)
    return (s:gsub("&", "&amp;"):gsub("\194\160", "&nbsp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function escape_attr(s)
    return (s:gsub("&", "&amp;"):gsub("\194\160", "&nbsp;"):gsub('"', "&quot;"))
end

function Node:inner_html()
    if self.tag:sub(1, 1) == "#" and self.tag ~= "#document-fragment" then
        return ""
    end
    local parts = {}
    -- a <template>'s children are in its content
    local children = (self.content or self).children
    for _, child in ipairs(children) do
        if child.tag == "#text" and RAW_TEXT[self.tag] and not self.namespace then
            table.insert(parts, child.text_content or "")
        else
            table.insert(parts, child:outer_html())
        end
    end
    return concat(parts, "")
end

function Node:outer_html()
    if self.tag == "#text" then
        return escape_text(self.text_content or "")
    elseif self.tag == "#comment" then
        return "<!--" .. (self.text_content or "") .. "-->"
    elseif self.tag == "#processing-instruction" then
        return "<?" .. self.target .. " " .. (self.text_content or "") .. "?>"
    elseif self.tag == "#doctype" then
        return "<!DOCTYPE " .. (self.name or "") .. ">"
    elseif not is_element(self) then
        return self:inner_html()
    end

    local attr_parts = {}
    for k, v in pairs(self.attrs) do
        if v == true or v == k then
            table.insert(attr_parts, k)
        else
            -- values are stored decoded, so escape them again
            table.insert(attr_parts, string.format('%s="%s"', k, escape_attr(tostring(v))))
        end
    end

    local attr_str = ""
    if #attr_parts > 0 then
        table.sort(attr_parts)
        attr_str = " " .. concat(attr_parts, " ")
    end

    if VOID_ELEMENTS[self.tag] and not self.namespace then
        return string.format("<%s%s />", self.tag, attr_str)
    end

    return string.format("<%s%s>%s</%s>", self.tag, attr_str, self:inner_html(), self.tag)
end

function Node:find(tag, attrs)
    local results = self:find_all(tag, attrs)
    return results[1]
end

function Node:find_all(tag, attrs)
    local results = {}

    local function match_node(node)
        if tag and tag ~= "*" and node.tag:lower() ~= tag:lower() then
            return false
        end

        if attrs then
            for k, v in pairs(attrs) do
                local attr_val = node:attr(k)
                if not attr_val then
                    return false
                end
                if type(v) == "string" and attr_val ~= v then
                    return false
                end
            end
        end

        return true
    end

    local function traverse(node)
        for _, child in ipairs(node.children) do
            if is_element(child) then
                if match_node(child) then
                    table.insert(results, child)
                end
                traverse(child)
            end
        end
    end

    traverse(self)
    return results
end

return Node
