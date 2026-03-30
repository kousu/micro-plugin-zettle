VERSION = "0.0.1"

local micro    = import("micro")
local buffer   = import("micro/buffer")
local config   = import("micro/config")
local shell    = import("micro/shell")
local fmt      = import("fmt")
local ioutil   = import("io/ioutil")
local time     = import("time")
local os       = import("os")
local runtime  = import("runtime")
local filepath = import("filepath")
local strings  = import("strings")

-- File extensions that should be opened inside micro rather than an external viewer.
local TEXT_EXTENSIONS = {
    txt=true,  md=true,   markdown=true,
    lua=true,  py=true,   js=true,   ts=true,  tsx=true, jsx=true,
    go=true,   rs=true,   c=true,    h=true,   cpp=true, cc=true, hpp=true,
    html=true, htm=true,  css=true,
    json=true, yaml=true, yml=true,  toml=true,
    sh=true,   bash=true, zsh=true,  fish=true,
    vim=true,  el=true,   rb=true,
    java=true, kt=true,   swift=true,
    r=true,    tex=true,  xml=true,  csv=true,
    ini=true,  cfg=true,  conf=true, sql=true,
    graphql=true, proto=true,
}

-- Returns true when the buffer is a markdown file.
local function isMarkdown(bp)
    local ft = bp.Buf.Settings["filetype"]
    return ft == "markdown"
end

-- Returns true when the path's extension suggests a text file.
local function isTextFile(path)
    local ext = path:match("%.([^%.]+)$")
    if ext then
        return TEXT_EXTENSIONS[ext:lower()] == true
    end
    return true  -- no extension → assume text
end

-- Toggle the checkbox on `line` (0-based row `y` in `bp`).
-- Returns true if a change was made.
local function toggleTodoOnLine(bp, y)
    local line = bp.Buf:Line(bp.Cursor.Y)
    local savedX, savedY = bp.Cursor.X, bp.Cursor.Y

    local function restore()
        bp.Cursor:GotoLoc(buffer.Loc(savedX, savedY))
    end

    -- Unchecked: - [ ] …
    local pos = line:find("%[ %]")
    if pos and line:match("^%s*-%s+%[ %]") then
        -- Lua pos is 1-based; buffer.Loc is 0-based.
        -- "[ ]" spans columns (pos-1)..(pos+1) inclusive; end arg to Replace is exclusive → pos+2.
        bp.Buf:Replace(buffer.Loc(pos - 1, y), buffer.Loc(pos + 2, y), "[x]")
        restore()
        return true
    end

    -- Checked: - [x] …
    pos = line:find("%[x%]")
    if pos and line:match("^%s*-%s+%[x%]") then
        bp.Buf:Replace(buffer.Loc(pos - 1, y), buffer.Loc(pos + 2, y), "[ ]")
        restore()
        return true
    end

    return false
end

-- If `curX` (0-based column) sits inside a markdown link [text](path), return the path string.
-- Otherwise return nil.
local function linkPathAtCol(line, curX)
    local pos = 1
    while pos <= #line do
        local s, e = line:find("%[.-%]", pos)
        if not s then break end

        -- The link syntax requires '(' immediately after ']'
        if e + 1 <= #line and line:sub(e + 1, e + 1) == "(" then
            local closePos = line:find(")", e + 2, true)
            if closePos then
                -- Full link span: columns (s-1)..(closePos-1) inclusive (0-based)
                if curX >= s - 1 and curX <= closePos - 1 then
                    return line:sub(e + 2, closePos - 1)
                end
                pos = closePos + 1
            else
                pos = e + 1
            end
        else
            pos = e + 1
        end
    end
    return nil
end

-- Navigation back-stack: each entry is an absolute file path with optional #fragment.
local backStack = {}

-- Root of the wiki: wherever the nearest .zettle file is
-- (some features still work without finding this)
local zettleRoot = nil

local function findVaultRoot()
    local cwd, err = os.Getwd()
    if err ~= nil then
        micro.InfoBar():Error("Finding zettle root: " .. tostring(err))
        return
    end

    -- Walk up the directory tree
    local dir = cwd
    while true do
        local candidate = filepath.Join(dir, ".zettle")
        micro:Log("Checking for .zettle in " .. candidate)
        local _, serr = os.Stat(candidate)
        if serr == nil then
            return dir
        end
        local parent = filepath.Dir(dir)
        if parent == dir then return end
        dir = parent
    end
end

-- Decode %XX percent-encoding in a URL path component.
local function urlDecode(s)
    return (s:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- Convert a markdown header line to its GitHub-style anchor slug.
-- e.g. "## Guide to Your New Life!" → "guide-to-your-new-life"
local function headerToAnchor(line)
    -- Strip leading #'s and surrounding whitespace
    local text = line:match("^#+%s+(.-)%s*$") or line
    text = text:lower()
    -- Remove anything that isn't alphanumeric, space, or hyphen
    text = text:gsub("[^%w%s%-]", "")
    -- Collapse spaces/runs to a single hyphen
    text = text:gsub("%s+", "-")
    return text
end


-- Jump bp's cursor to the first header whose anchor matches `fragment`.
local function jumpToFragment(bp, fragment)
    if not fragment or fragment == "" then return end
    for y = 0, bp.Buf:LinesNum() - 1 do
        local line = bp.Buf:Line(y)
        if line:match("^#+%s") and headerToAnchor(line) == fragment then
            bp.Cursor:GotoLoc(buffer.Loc(0, y))
            bp:Center()
            return
        end
    end
    micro.InfoBar():Message("Section not found: #" .. fragment)
end

-- Return the anchor slug of the nearest markdown header at or above the cursor, or nil.
local function nearestFragment(bp)
    for y = bp.Cursor.Y, 0, -1 do
        local line = bp.Buf:Line(y)
        if line:match("^#+%s") then
            return headerToAnchor(line)
        end
    end
    return nil
end

-- Push the current position onto the back-stack before any navigation.
function PushBack(bp)
    if bp.Buf.AbsPath == "" then return end
    backStack[#backStack + 1] = {
        path     = bp.Buf.AbsPath,
        fragment = nearestFragment(bp),
        x        = bp.Cursor.X,
        y        = bp.Cursor.Y,
    }
end

-- Open `path` (possibly relative to the current buffer) in micro or an external viewer.
local function openPath(bp, uri)

    -- Open a URI or file path with the OS default handler (non-blocking).
    local function openWithSystem(uri)
        local time = import("time")
        micro.InfoBar():Message("Opening: " .. uri)
        local cmd = runtime.GOOS == "darwin" and "open" or "xdg-open"
        local noop = function() end
        shell.JobSpawn(cmd, {uri}, noop, noop, noop)
        micro.After(3 * time.Second, function() micro.InfoBar():Reset() end)
    end

    -- Anything containing a scheme ("word://..." or "mailto:...") goes to the
    -- system viewer rather than being treated as an internal file path.
    -- (this *includes* file:// links -- those will open with the system viewer)
    if uri:match("^[%a][%a%d+%-%.]*://") or uri:match("^mailto:") then
        openWithSystem(uri)
        return
    end

    -- Anything else we assume is a file path
    path = urlDecode(uri)

    -- Split off a #fragment before any other processing.
    local fragment
    local hashPos = path:find("#", 1, true)
    if hashPos then
        fragment = path:sub(hashPos + 1)
        path     = path:sub(1, hashPos - 1)
    end

    if path == "" then
        -- A bare #fragment with no file path means jump within the current buffer.
        path = bp.Buf.AbsPath
    else
        -- resolve path relative to the open buffer
        -- micro:Log("bp.Buf.AbsPath = " .. bp.Buf.AbsPath)
        -- micro:Log("path = " .. path)
        -- micro:Log("filepath.Dir(bp.Buf.AbsPath) = " .. filepath.Dir(bp.Buf.AbsPath))
        path = filepath.Join(filepath.Dir(bp.Buf.AbsPath), path)
        -- micro:Log("edited path = " .. path)
    end

    -- Verify the file exists.
    -- XXX should we only allow opening files *within the vault*? is it a security problem otherwise?
    local _, err = os.Stat(path)
    if err ~= nil then
        micro.InfoBar():Error("File not found: " .. path)
        return
    end

    if isTextFile(path) then
        -- follow wiki links
        PushBack(bp)
        if path ~= bp.Buf.AbsPath then
            bp:HandleCommand("open " .. path)
        end
        if fragment and fragment ~= "" then
            jumpToFragment(bp, fragment)
        end
    else
        -- open
        -- TODO: can this be refactored to be combined with the URI case?
        openWithSystem(path)
    end
end

-- Toggle blockquote prefix on all selected lines.
-- Inserts "> " after each line's leading whitespace, or removes it if every
-- selected line already has it.
local function toggleBlockquoteLines(bp)
    local cur = bp.Cursor
    if not cur:HasSelection() then return false end

    -- CurSelection is a 2-element Go array; luar exposes it 1-indexed.
    -- sel[1] = CurSelection[0] (SetSelectionStart), sel[2] = CurSelection[1] (SetSelectionEnd).
    local sel = cur.CurSelection
    local startY = sel[1].Y
    local endY   = sel[2].Y
    local endX   = sel[2].X
    -- Track which sel index is the "bottom" of the selection so we can
    -- extend it later if needed.
    local bottomIsFirst = false
    -- Normalize direction
    if startY > endY or (startY == endY and sel[1].X > sel[2].X) then
        startY, endY = endY, startY
        endX = sel[1].X
        bottomIsFirst = true
    end
    -- If selection ends at col 0 of a line, don't include that line
    if endX == 0 and endY > startY then
        endY = endY - 1
    end

    -- Determine whether every line is already quoted at its indent level.
    local allQuoted = true
    for y = startY, endY do
        local line = bp.Buf:Line(y)
        local indent = line:match("^(%s*)") or ""
        local rest = line:sub(#indent + 1)
        if not rest:match("^> ") then
            allQuoted = false
            break
        end
    end

    if allQuoted then
        -- Extend the bottom of the selection one character into the next line
        -- before removing "> " prefixes. Without this, the deletions on the
        -- last line pull the selection endpoint back, so a subsequent toggle
        -- would miss that line.
        local extended = buffer.Loc(1, endY)
        if bottomIsFirst then
            cur:SetSelectionStart(extended)
        else
            cur:SetSelectionEnd(extended)
        end
    end

    -- Apply the toggle. Iterate bottom-up so column positions on earlier
    -- lines aren't affected by changes to later ones (though here only
    -- intra-line edits happen, top-down would also be fine).
    for y = endY, startY, -1 do
        local line = bp.Buf:Line(y)
        local indent = line:match("^(%s*)") or ""
        local col = #indent  -- 0-based insert/delete column
        if allQuoted then
            -- Remove the "> " (2 chars) that follows the indent.
            bp.Buf:Replace(buffer.Loc(col, y), buffer.Loc(col + 2, y), "")
        else
            bp.Buf.EventHandler:Insert(buffer.Loc(col, y), "> ")
        end
    end

    return true
end

-- ── Exported actions ─────────────────────────────────────────────────────────

-- ToggleTodo toggles the TODO checkbox only when the cursor is within the [ ] / [x] characters.
function ToggleTodo(bp)
    if not isMarkdown(bp) then return false end
    local line = bp.Buf:Line(bp.Cursor.Y)
    local chkPos = line:find("%[[ x]%]")
    if not (chkPos and line:match("^%s*-%s+%[[ x]%]")) then return false end
    -- checkbox occupies 0-based columns (chkPos-1)..(chkPos+1)
    if bp.Cursor.X < chkPos - 1 or bp.Cursor.X > chkPos + 1 then return false end
    return toggleTodoOnLine(bp, bp.Cursor.Y)
end

-- OpenLink follows the markdown link under the cursor, if any.
function OpenLink(bp)
    if not isMarkdown(bp) then return false end
    local line = bp.Buf:Line(bp.Cursor.Y)
    local path = linkPathAtCol(line, bp.Cursor.X)
    if path then
        openPath(bp, path)
        return true
    end
    return false
end

-- ToggleBlockquote wraps/unwraps the selected lines as a blockquote.
-- When there is no selection (or not in a markdown buffer), falls back to
-- inserting a literal ">" character.
function ToggleBlockquote(bp)
    if isMarkdown(bp) and bp.Cursor:HasSelection() then
        return toggleBlockquoteLines(bp)
    end
    -- Fallback: insert the character normally.
    bp.Buf.EventHandler:Insert(buffer.Loc(bp.Cursor.X, bp.Cursor.Y), ">")
    bp.Cursor:GotoLoc(buffer.Loc(bp.Cursor.X + 1, bp.Cursor.Y))
    return true
end

-- Activate tries ToggleTodo first, then OpenLink.
-- Bound to Ctrl-Space so one key handles both gestures.
function Activate(bp)
    if ToggleTodo(bp) then return true end
    return OpenLink(bp)
end

local function syncBufPane(bp)
    if bp.Buf.Type.Scratch then return end
    local absPath = bp.Buf.AbsPath
    if absPath == nil or absPath == "" then return end

    require("filemanager").Focus(absPath)
    if zettleRoot ~= nil then
        bp.Buf.Path = filepath.Rel(zettleRoot, absPath)
    end
end

function onBufPaneOpen(bp)
    syncBufPane(bp)
end

function onSetActive(bp)
    -- micro:Log("onSetActive")
    -- this runs when a pane is *switched* including when the filemanager is opened/closed
    syncBufPane(bp)
end

-- onMousePress is called after micro has already moved the cursor to the
-- clicked position, so bp.Cursor.{X,Y} reflect the click location.
function onMousePress(bp, me)
    if not isMarkdown(bp) then return false end

    local y    = bp.Cursor.Y
    local curX = bp.Cursor.X
    local line = bp.Buf:Line(bp.Cursor.Y)

    -- 1. If the click landed on the [ ] / [x] characters, toggle the checkbox.
    local chkPos = line:find("%[[ x]%]")
    if chkPos and line:match("^%s*-%s+%[[ x]%]") then
        -- checkbox occupies 0-based columns (chkPos-1)..(chkPos+1)
        if curX >= chkPos - 1 and curX <= chkPos + 1 then
            toggleTodoOnLine(bp, y)
            return false
        end
    end

    -- 2. If the click landed on a [text](path) link, open the target.
    local path = linkPathAtCol(line, curX)
    if path then
        openPath(bp, path)
    end

    return false
end


-- NavigateBack pops the back-stack and restores the previous file and cursor position.
function NavigateBack(bp)
    if #backStack == 0 then
        micro.InfoBar():Message("zettle: nothing to go back to")
        return false
    end
    local prev = backStack[#backStack]
    backStack[#backStack] = nil
    if prev.path ~= bp.Buf.AbsPath then
        bp:HandleCommand("open " .. prev.path)
    end
    local inBounds = prev.y < bp.Buf:LinesNum() and
                     prev.x <= #bp.Buf:Line(prev.y)
    if inBounds then
        bp.Cursor:GotoLoc(buffer.Loc(prev.x, prev.y))
        bp:Center()
    else
        jumpToFragment(bp, prev.fragment)
    end
    return true
end

-- ── Initialisation ────────────────────────────────────────────────────────────

-- preinit runs before any plugin's init(), so we pre-populate GlobalSettings with
-- filemanager.openonstart=false before filemanager's init() registers it.
-- RegisterCommonOption only writes the default when the key is absent, so our value wins.
-- SetGlobalOptionNative is used because the option isn't registered yet at this point.
function preinit()
    -- Default to keeping the file tree closed, but respect an explicit user setting
    -- in settings.json (which is loaded into GlobalSettings before preinit runs).
    if config.GetGlobalOption("filemanager.openonstart") == nil then
        config.SetGlobalOptionNative("filemanager.openonstart", false)
    end
end

function init()

    zettleRoot = findVaultRoot()
    if zettleRoot ~= nil then
        micro.Log("zettle vault: " .. zettleRoot)
        micro.InfoBar():Message("zettle vault: " .. zettleRoot)
        micro.After(5 * time.Second, function() micro.InfoBar():Reset() end)

        os.Chdir(zettleRoot)
        require("filemanager").update_current_dir(zettleRoot)

        -- Enable autosaving.
        -- Setting this deadlocks if called too early but a delay to let micro
        -- boot, avoids it. (XXX perhaps a bug to report?)
        micro.After(1*time.Second, function()
            config.SetGlobalOption("autosave", "15")
        end)
    end

    -- Default keybinds; users can override in their bindings.json.
    -- Markdown features
    config.TryBindKey("Enter",      "lua:zettle.Activate|InsertNewline", false)
    config.TryBindKey(">",          "lua:zettle.ToggleBlockquote", false)
    -- Wiki features
    config.TryBindKey("Alt-Left",   "lua:zettle.NavigateBack",      false)
end
