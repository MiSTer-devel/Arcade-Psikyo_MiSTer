-- Capture a Psikyo game's video state at a list of frames, with the Flip
-- Screen DIP forced to a chosen setting. Driven by scripts/mame_flip_capture.py.
--
-- The question it answers: does the GAME react to Flip Screen (mirroring its
-- own sprite coordinates or scroll values), or is the flip done entirely by
-- the video hardware from the DIP line (psikyo_v.cpp: flip_screen_set is
-- "hardwired to a DSW bit")? Run it twice with the DIP off and on; if the
-- dumps are identical frame for frame, the game ignores the switch.
--
-- Environment:
--   PSK_OUT     output directory (must exist)
--   PSK_FRAMES  comma-separated frame numbers, ascending
--   PSK_FLIP    "1" = Flip Screen On, "0" = Off
--
-- Everything is read through the 68020 program space, big-endian words.

local OUT    = os.getenv("PSK_OUT") or "."
local FLIP   = os.getenv("PSK_FLIP") == "1"
local FRAMES = {}
for n in string.gmatch(os.getenv("PSK_FRAMES") or "600", "%d+") do
    FRAMES[#FRAMES + 1] = tonumber(n)
end

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]

local regions = {
    { 0x400000, 0x2000,  "spriteram" },
    { 0x600000, 0x2000,  "palette"   },
    { 0x800000, 0x4000,  "vram"      },   -- layer 0 then layer 1
    { 0x804000, 0x4000,  "vregs"     },   -- rowscroll tables + scroll/ctrl
    { 0xfe0000, 0x20000, "workram"   },
}

-- ---- force the Flip Screen DIP ----
local flip_field
for _, port in pairs(mach.ioport.ports) do
    for fname, field in pairs(port.fields) do
        if fname == "Flip Screen" then flip_field = field end
    end
end
if flip_field == nil then error("no 'Flip Screen' field in this driver") end
-- active low: value 0 is On (psikyo.cpp PORT_DIPNAME 0x00010000 ... On = 0)
flip_field.user_value = FLIP and 0 or flip_field.mask
print(string.format("CAPTURE  Flip Screen %s (user_value=%X)", FLIP and "On" or "Off", flip_field.user_value))

-- SH403/SH404 tile banking is a write-only register at 0xC00007
-- (psikyo.cpp s1945_mcu_bctrl_w), outside every RAM region above, so track
-- the last value written. The 68020 bus is 32-bit big-endian: 0xC00007 is
-- the low byte lane of the long at 0xC00004.
local bctrl = -1
_G.__psk_bctrl_tap = prog:install_write_tap(0xc00004, 0xc00007, "bctrl", function(offset, data, mask)
    if (offset & ~3) == 0xc00004 and (mask & 0xFF) ~= 0 then bctrl = data & 0xFF end
    return data
end)

local function dump(frame, addr, len, name)
    local path = string.format("%s/f%05d_%s.bin", OUT, frame, name)
    local f = assert(io.open(path, "wb"))
    local buf = {}
    for i = 0, len - 2, 2 do
        local w = prog:read_u16(addr + i)
        buf[#buf + 1] = string.char((w >> 8) & 0xFF, w & 0xFF)
    end
    f:write(table.concat(buf))
    f:close()
end

local function fail(msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then f:write("notifier: " .. tostring(msg) .. "\n"); f:close() end
    print("LUAFAIL notifier: " .. tostring(msg))
    mach:exit()
end

local idx = 1
local function frame_body()
    if idx > #FRAMES then return end
    local n = scr:frame_number()
    if n < FRAMES[idx] then return end
    for _, r in ipairs(regions) do dump(FRAMES[idx], r[1], r[2], r[3]) end
    local bf = assert(io.open(string.format("%s/f%05d_bctrl.txt", OUT, FRAMES[idx]), "w"))
    bf:write(string.format("%d\n", bctrl))   -- -1: never written (not an SH404 set)
    bf:close()
    mach.video:snapshot()
    print(string.format("CAPTURE  frame %d (wanted %d)", n, FRAMES[idx]))
    idx = idx + 1
    if idx > #FRAMES then
        print("CAPTURE  done")
        mach:exit()
    end
end

-- keep the subscription referenced, or it is collected and stops firing
_G.__psk_frame_notifier = emu.add_machine_frame_notifier(function()
    local ok, err = pcall(frame_body)
    if not ok then fail(err) end
end)
