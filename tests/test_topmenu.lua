-- Top-menu icon wiring test: icon install + menu order override + MenuSorter
io.stdout:setvbuf("no")
dofile("setupkoenv.lua")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(os.getenv("KO_HOME") .. "/settings.reader.lua")
package.loaded["device"] = {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end,
        getDPI = function() return 300 end, getSize = function() return { w = 600, h = 800 } end,
        scaleBySize = function(_, x) return x end, scaleByDPI = function(_, x) return x end,
        isColorEnabled = function() return false end, fb_bpp = 8 },
    model = "Test",
    hasBGRFrameBuffer = function() return false end, hasEinkScreen = function() return true end,
    isAndroid = function() return false end, isDesktop = function() return true end,
    isEmulator = function() return true end, isKindle = function() return false end,
    isPocketBook = function() return false end, hasSystemFonts = function() return true end,
    isRemarkable = function() return false end, isSDL = function() return true end,
    isLinux = function() return true end, canHWDither = function() return false end,
    screen_dpi = 300, enableCPUCores = function() end, _UIManagerReady = function() end,
    initNetworkManager = function() end, setDateTime = function() end,
    getDateTime = function() return os.date("*t") end,
    getPowerDevice = function() return { isCharging = function() return false end,
        getCapacity = function() return 100 end, isCharged = function() return false end,
        state = function() return "discharging" end } end,
    input = { eventAdjustHook = function() end },
}
setmetatable(package.loaded["device"], { __index = function(_, k)
    if type(k) == "string" and (k:match("^has") or k:match("^is") or k:match("^can") or k:match("^supports")) then
        return function() return false end
    end
    return nil
end })
package.path = "/tmp/mimottest/plugin/?.lua;" .. package.path
require("document/canvascontext").init(require("document/canvascontext"), package.loaded["device"])

local function check(cond, msg)
    if cond then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg)
        os.exit(1)
    end
end

local UIManager = require("ui/uimanager")
UIManager.show = function() end
UIManager.close = function() end

local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local MiMoTTS = dofile("/tmp/mimottest/plugin/main.lua")
local fake_ui = {
    document = {}, rolling = true,
    menu = { registerToMainMenu = function() end },
    getCurrentPage = function() return 1 end,
    handleEvent = function() end,
}
local plugin = MiMoTTS:new{ ui = fake_ui }
plugin.path = "/tmp/mimottest/plugin" -- normally set by PluginLoader

--------------------------------------------------------------- icon install
plugin:ensureIcon()
local icon_path = DataStorage:getDataDir() .. "/icons/mimo_tts.svg"
check(lfs.attributes(icon_path, "mode") == "file", "icon copied to user icons dir: " .. icon_path)
local f = io.open(icon_path, "rb")
local svg = f:read("*a")
f:close()
check(svg:find("<svg") ~= nil and svg:find("path") ~= nil, "icon is a valid svg")

--------------------------------------------------------------- menu order override
plugin:ensureTopIcon(true)
local order_path = DataStorage:getSettingsDir() .. "/reader_menu_order.lua"
check(lfs.attributes(order_path, "mode") == "file", "menu order override written")
check(plugin:isTopIconEnabled() == true, "isTopIconEnabled true")
local order = dofile(order_path)
local found_tab = false
for _, id in ipairs(order["KOMenu:menu_buttons"]) do
    if id == "mimo_tts_tab" then found_tab = true end
end
check(found_tab, "tab id present in KOMenu:menu_buttons")
check(type(order["mimo_tts_tab"]) == "table", "tab order entry exists")

-- re-running must be idempotent (no duplicate entries)
plugin:ensureTopIcon(true)
order = dofile(order_path)
local count = 0
for _, id in ipairs(order["KOMenu:menu_buttons"]) do
    if id == "mimo_tts_tab" then count = count + 1 end
end
check(count == 1, "ensureTopIcon idempotent (single tab entry)")

--------------------------------------------------------------- MenuSorter wiring
local MenuSorter = require("ui/menusorter")
local menu_items = {
    ["KOMenu:menu_buttons"] = {}, -- what ReaderMenu provides
    tools = {},
    more_tools = {},
}
plugin:addToMainMenu(menu_items)
check(menu_items.mimo_tts_tab ~= nil and menu_items.mimo_tts_tab.icon == "mimo_tts",
    "mimo_tts_tab registered with icon")
check(menu_items.mimo_tts_tab.icon == "mimo_tts", "tab keeps its icon")

local tabs = MenuSorter:mergeAndSort("reader", menu_items, require("ui/elements/reader_menu_order"))
check(type(tabs) == "table", "MenuSorter produced the top menu")

local tab_entry
for _, v in ipairs(tabs) do
    if type(v) == "table" and v.icon == "mimo_tts" then
        tab_entry = v
    end
end
check(tab_entry ~= nil, "top-menu icon bar contains the mimo_tts tab")
check(tab_entry and #tab_entry == 17, "tab page holds the 17 plugin items: " .. tostring(tab_entry and #tab_entry))
check(tab_entry and tab_entry[1] and tab_entry[1].callback ~= nil, "tab items are actionable")

-- the classic menu entry must still exist (fallback row / more_tools)
local function findItem(items, depth)
    for _, v in ipairs(items) do
        if type(v) == "table" then
            if v.text == "MiMo TTS 语音听书" and v.sub_item_table then
                return v
            end
            if depth > 0 then
                if v.sub_item_table then
                    local r = findItem(v.sub_item_table, depth - 1)
                    if r then return r end
                end
                local r = findItem(v, depth - 1)
                if r then return r end
            end
        end
    end
end
local menu_entry = nil
for _, v in ipairs(tab_entry or {}) do
    if v.text == "Listen to the whole book (auto page turn)" then menu_entry = v end
end
check(menu_entry ~= nil and menu_entry.callback ~= nil, "plugin action reachable from the icon tab")

--------------------------------------------------------------- toggle off
plugin:toggleTopIcon()
check(plugin:isTopIconEnabled() == false, "isTopIconEnabled false after toggle")
order = dofile(order_path)
local still = false
for _, id in ipairs(order["KOMenu:menu_buttons"] or {}) do
    if id == "mimo_tts_tab" then still = true end
end
check(not still, "tab removed from order file")
local menu_items2 = { ["KOMenu:menu_buttons"] = {}, tools = {}, more_tools = {} }
plugin:addToMainMenu(menu_items2)
local tabs2 = MenuSorter:mergeAndSort("reader", menu_items2, require("ui/elements/reader_menu_order"))
local icon_tab = false
for _, v in ipairs(tabs2) do
    if type(v) == "table" and v.icon == "mimo_tts" then icon_tab = true end
end
check(not icon_tab, "no icon tab after disabling")

-- toggle back on for the real install
plugin:toggleTopIcon()
check(plugin:isTopIconEnabled() == true, "top icon re-enabled")

print("ALL TOP-MENU TESTS PASSED")
