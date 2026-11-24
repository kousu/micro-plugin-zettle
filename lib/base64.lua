-- Decode base64 (standard or URL-safe), without bit operators.
local BASE64 = {}
for i = 1, 64 do
	BASE64[("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):sub(i, i)] = i - 1
end
BASE64["-"], BASE64["_"] = 62, 63

-- table.concat, in pieces: gopher-lua (micro's Lua) pushes every element onto
-- its fixed-size registry, so concatenating more than a few thousand at once
-- fails with "registry overflow".
local function concat(t)
	while #t > 1000 do
		local chunks = {}
		for i = 1, #t, 1000 do
			chunks[#chunks + 1] = table.concat(t, "", i, math.min(i + 999, #t))
		end
		t = chunks
	end
	return table.concat(t)
end

local function decode(s)
	s = s:gsub("[%s=]", "")
	if s:find("[^%w%+/%-_]") then
		return nil
	end
	local out = {}
	for i = 1, #s, 4 do
		local chunk = s:sub(i, i + 3)
		local n = 0
		for j = 1, 4 do
			n = n * 64 + (BASE64[chunk:sub(j, j)] or 0)
		end
		local bytes = string.char(math.floor(n / 65536), math.floor(n / 256) % 256, n % 256)
		-- a short last chunk holds fewer bytes
		out[#out + 1] = bytes:sub(1, math.floor(#chunk * 6 / 8))
	end
	return concat(out)
end

return {
	decode = decode,
}
