local treebuilder = require("lusoup.treebuilder")
local selector = require("lusoup.selector")
local Node = require("lusoup.dom")

function Node:select(query)
    return selector.select(self, query)
end

function Node:select_one(query)
    local res = selector.select(self, query)
    return res[1]
end

local lusoup = {}

-- Parse an HTML fragment, as found inside a <body> (or the element named by
-- options.context). See lusoup.treebuilder for the options.
function lusoup.parse(html, options)
    return treebuilder.parse(html, options)
end

-- Parse a whole HTML document, building the <html>, <head> and <body> it implies.
function lusoup.parse_document(html, options)
    return treebuilder.parse_document(html, options)
end

return lusoup
