VERSION = "1.0.0"

local micro    = import("micro")
local buffer   = import("micro/buffer")
local config   = import("micro/config")
local shell    = import("micro/shell")
local fmt      = import("fmt")
local ioutil   = import("io/ioutil")
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
local function toggleTodoOnLine(bp, y, line)
    -- Unchecked: - [ ] …
    local pos = line:find("%[ %]")
    if pos and line:match("^%s*-%s+%[ %]") then
        -- Lua pos is 1-based; buffer.Loc is 0-based.
        -- "[ ]" spans columns (pos-1)..(pos+1) inclusive; end arg to Replace is exclusive → pos+2.
        bp.Buf:Replace(buffer.Loc(pos - 1, y), buffer.Loc(pos + 2, y), "[x]")
        return true
    end

    -- Checked: - [x] …
    pos = line:find("%[x%]")
    if pos and line:match("^%s*-%s+%[x%]") then
        bp.Buf:Replace(buffer.Loc(pos - 1, y), buffer.Loc(pos + 2, y), "[ ]")
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

-- Navigation back-stack: each entry is an absolute file path.
local backStack = {}

-- Project config loaded from .zettlr.json in the working directory.
-- nil  → file not found (no project config).
-- table → file was found; contains parsed settings (or {} if parse failed).
local zettlrConfig = nil

-- Read and (TODO: properly parse) .zettlr.json from the current working directory.
local function loadProjectConfig()
    local cwd, err = os.Getwd()
    if err ~= nil then return end

    local configPath = filepath.Join(cwd, ".zettlr.json")
    local _, err = os.Stat(configPath)
    if err ~= nil then return end  -- file not found; leave zettlrConfig = nil

    local data, err = ioutil.ReadFile(configPath)
    if err ~= nil then
        -- Unreadable — treat as empty config so autosave still activates.
        zettlrConfig = {}
        return
    end

    -- Store the raw file contents for future JSON parsing.
    -- TODO: parse into a proper Lua table keyed by option name.
    local _raw = fmt.Sprintf("%s", data)
    zettlrConfig = {}
end

-- Open `path` (possibly relative to the current buffer) in micro or an external viewer.
local function openPath(bp, path)
    -- Skip external URLs silently (or show a hint in the info bar)
    if strings.HasPrefix(path, "http://")  or strings.HasPrefix(path, "https://")
    or strings.HasPrefix(path, "ftp://")   or strings.HasPrefix(path, "mailto:") then
        micro.InfoBar():Message("URL link (not opening in editor): " .. path)
        return
    end

    -- Resolve path relative to the buffer's own directory.
    local absPath
    if strings.HasPrefix(path, "/") then
        absPath = path
    else
        local bufDir
        if bp.Buf.AbsPath ~= "" then
            bufDir = filepath.Dir(bp.Buf.AbsPath)
        else
            bufDir, _ = os.Getwd()
        end
        absPath = filepath.Join(bufDir, path)
    end

    -- Verify the file exists.
    local _, err = os.Stat(absPath)
    if err ~= nil then
        micro.InfoBar():Error("File not found: " .. absPath)
        return
    end

    if isTextFile(absPath) then
        -- Push the current file onto the back-stack before navigating.
        if bp.Buf.AbsPath ~= "" then
            backStack[#backStack + 1] = bp.Buf.AbsPath
        end
        bp:HandleCommand("open " .. absPath)
    else
        -- Open with the system viewer.
        local goos = runtime.GOOS
        if goos == "darwin" then
            shell.ExecCommand("open", absPath)
        else
            shell.ExecCommand("xdg-open", absPath)
        end
    end
end

-- ── Exported actions ─────────────────────────────────────────────────────────

-- ToggleTodo toggles the TODO checkbox on the current line (any column).
function ToggleTodo(bp)
    if not isMarkdown(bp) then return false end
    local line = bp.Buf:Line(bp.Cursor.Y)
    return toggleTodoOnLine(bp, bp.Cursor.Y, line)
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

-- Activate tries ToggleTodo first, then OpenLink.
-- Bound to Ctrl-Space so one key handles both gestures.
function Activate(bp)
    if ToggleTodo(bp) then return true end
    return OpenLink(bp)
end

-- ── Mouse handler ─────────────────────────────────────────────────────────────

-- onMousePress is called after micro has already moved the cursor to the
-- clicked position, so bp.Cursor.{X,Y} reflect the click location.
function onMousePress(bp, me)
    if not isMarkdown(bp) then return false end

    local y    = bp.Cursor.Y
    local curX = bp.Cursor.X
    local line = bp.Buf:Line(y)

    -- 1. If the click landed on the [ ] / [x] characters, toggle the checkbox.
    local chkPos = line:find("%[[ x]%]")
    if chkPos and line:match("^%s*-%s+%[[ x]%]") then
        -- checkbox occupies 0-based columns (chkPos-1)..(chkPos+1)
        if curX >= chkPos - 1 and curX <= chkPos + 1 then
            toggleTodoOnLine(bp, y, line)
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

-- NavigateBack pops the back-stack and opens the previous file.
function NavigateBack(bp)
    if #backStack == 0 then
        micro.InfoBar():Message("zettlr: nothing to go back to")
        return false
    end
    local prev = backStack[#backStack]
    backStack[#backStack] = nil
    bp:HandleCommand("open " .. prev)
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
    loadProjectConfig()

    if zettlrConfig ~= nil then
        config.SetGlobalOption("autosave", 1)
    end

    -- Default keybinds; users can override in their bindings.json.
    config.TryBindKey("Ctrl-Space", "lua:zettlr.Activate",     false)
    config.TryBindKey("Alt-Left",   "lua:zettlr.NavigateBack", false)
end
