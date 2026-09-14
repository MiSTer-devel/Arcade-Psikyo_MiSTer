-- Bootstrap that makes Lua failures visible to the calling script
-- (after Arcade-Fuuki_MiSTer/scripts/mame/run.lua). MAME reports a broken
-- autoboot script with a modal dialog, which headless is invisible; this
-- writes the error to PSK_OUT/lua_error.txt instead.
--
-- Point -autoboot_script at THIS file and pass the real script in PSK_SCRIPT.

local OUT    = os.getenv("PSK_OUT")    or "."
local SCRIPT = os.getenv("PSK_SCRIPT")

local function record(kind, msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then
        f:write(kind .. ": " .. tostring(msg) .. "\n")
        f:close()
    end
    print("LUAFAIL " .. kind .. ": " .. tostring(msg))
end

if not SCRIPT then
    record("config", "PSK_SCRIPT is not set")
    manager.machine:exit()
    return
end

-- syntax errors surface here, before anything runs
local chunk, lerr = loadfile(SCRIPT)
if not chunk then
    record("syntax", lerr)
    manager.machine:exit()
    return
end

-- runtime errors in the script's top level
local ok, rerr = pcall(chunk)
if not ok then
    record("runtime", rerr)
    manager.machine:exit()
end
