-- Reading the system clipboard, which can offer one copy as several types of data.

local shell = import("micro/shell")
local os = import("os")
local runtime = import("runtime")

-- Read the system clipboard contents, returns nil on failure.
-- Mirrors the tool priority in github.com/zyedidia/clipper:
--   macOS:          pbpaste
--   Linux Wayland:  wl-paste --no-newline  (when WAYLAND_DISPLAY is set)
--   Linux X11:      xclip, then xsel
local function read()
	local out, err

	if runtime.GOOS == "darwin" then
		out, err = shell.ExecCommand("pbpaste")
		if err ~= nil then
			return nil
		end
		return out:match("^(.-)\n?$")
	end

	-- Linux: prefer Wayland when available
	if os.Getenv("WAYLAND_DISPLAY") ~= "" then
		out, err = shell.ExecCommand("wl-paste", "--no-newline")
		if err == nil then
			return out
		end
		-- wl-paste not installed or failed; fall through to X11 tools
	end

	-- xclip
	out, err = shell.ExecCommand("xclip", "-out", "-selection", "clipboard")
	if err == nil then
		return out:match("^(.-)\n?$")
	end

	-- xsel
	out, err = shell.ExecCommand("xsel", "--output", "--clipboard")
	if err == nil then
		return out:match("^(.-)\n?$")
	end

	return nil
end

return {
	read = read,
}
