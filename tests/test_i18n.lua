-- i18n tests: plugin translation loader, catalog coverage, localized menus
io.stdout:setvbuf("no")
dofile("setupkoenv.lua")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("/tmp/mimottest/settings.lua")
local fake_screen = {
    getWidth = function() return 600 end, getHeight = function() return 800 end,
    getDPI = function() return 300 end, getSize = function() return { w = 600, h = 800 } end,
    scaleBySize = function(_, x) return x end, scaleByDPI = function(_, x) return x end,
    isColorEnabled = function() return false end, fb_bpp = 8,
}
local fake_device = {
    screen = fake_screen, model = "Test",
    hasBGRFrameBuffer = function() return false end, hasEinkScreen = function() return true end,
    isAndroid = function() return false end, isDesktop = function() return true end,
    isEmulator = function() return true end, isKindle = function() return false end,
    isPocketBook = function() return false end, hasSystemFonts = function() return true end,
    isRemarkable = function() return false end, isSDL = function() return true end,
    isLinux = function() return true end, canHWDither = function() return false end,
    screen_dpi = 300, enableCPUCores = function() end, _UIManagerReady = function() end,
    initNetworkManager = function() end,
    getPowerDevice = function() return { isCharging = function() return false end,
        getCapacity = function() return 100 end } end,
    input = { eventAdjustHook = function() end },
}
setmetatable(fake_device, { __index = function(_, k)
    if type(k) == "string" and (k:match("^has") or k:match("^is") or k:match("^can") or k:match("^supports")) then
        return function() return false end
    end
    return nil
end })
package.loaded["device"] = fake_device
require("document/canvascontext").init(require("document/canvascontext"), fake_device)
package.path = "/tmp/mimottest/plugin/?.lua;" .. package.path

local function check(cond, msg)
    if cond then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg)
        os.exit(1)
    end
end

local GetText = require("gettext")
local translations = require("translations")
local lfs = require("libs/libkoreader-lfs")

--------------------------------------------------------------- catalog files
local mo_path = translations.getDir() .. "/zh_CN/mimo_tts.mo"
check(lfs.attributes(mo_path, "mode") == "file", "compiled zh_CN catalog shipped")

--------------------------------------------------------------- zh_CN loading
GetText.changeLang("zh_CN")
check(GetText.current_lang == "zh_CN", "language set to zh_CN")
local loaded = translations.load()
check(loaded == "zh_CN", "zh_CN catalog loaded: " .. tostring(loaded))
check(GetText("Listen to the whole book (auto page turn)") == "连续听书（自动翻页）",
    "menu string translated to Chinese")
check(GetText("Choose preset voice (current: %1)") == "选择预置音色（当前：%1）",
    "templated menu string translated")
check(GetText("Cancel") == "取消", "button translated")

--------------------------------------------------------------- core-wins on shared msgids
GetText.translation["Save"] = "CORE_SAVE"
translations.load()
check(GetText.translation["Save"] == "CORE_SAVE", "core translation wins for shared msgids")
GetText.translation["Save"] = nil

--------------------------------------------------------------- base language fallback
-- synthesize l10n/zz/mimo_tts.mo and try the zz_BB locale
local l10n_dir = translations.getDir()
os.execute("mkdir -p " .. l10n_dir .. "/zz")
os.execute("cp " .. mo_path .. " " .. l10n_dir .. "/zz/mimo_tts.mo")
GetText.changeLang("zz_BB")
G_reader_settings:saveSetting("language", "zz_BB") -- core has no zz_BB catalog
local loaded2 = translations.load()
G_reader_settings:delSetting("language")
check(loaded2 == "zz", "base language fallback (zz_BB -> zz): " .. tostring(loaded2))
os.execute("rm -rf " .. l10n_dir .. "/zz")

--------------------------------------------------------------- missing locale -> source
GetText.changeLang("fr_FR")
check(translations.load() == "", "no catalog for fr_FR")
check(GetText("Listen to the whole book (auto page turn)") == "Listen to the whole book (auto page turn)",
    "unknown locale falls back to English source")

--------------------------------------------------------------- en_US / C -> source
GetText.changeLang("en_US")
check(translations.load() == "", "en_US: localization disabled, nothing to load")
check(GetText("Stop reading") == "Stop reading", "en_US shows source strings")

--------------------------------------------------------------- real plugin menus
local function build_menu_texts(lang)
    GetText.changeLang(lang)
    -- main.lua loads translations itself at require time; reload for this lang
    package.loaded["translations"] = nil
    local old = package.loaded["main"]
    package.loaded["main"] = nil
    local MiMoTTS = dofile("/tmp/mimottest/plugin/main.lua")
    local ui = {
        document = {}, rolling = true,
        menu = { registerToMainMenu = function() end },
        getCurrentPage = function() return 1 end,
        handleEvent = function() end,
    }
    local plugin = MiMoTTS:new{ ui = ui }
    local menu_items = {}
    plugin:addToMainMenu(menu_items)
    return menu_items
end

local zh = build_menu_texts("zh_CN")
local texts = {}
for k, v in pairs(zh) do
    if type(v) == "table" and v.text then texts[#texts + 1] = v.text end
end
local joined = table.concat(texts, "\n")
check(joined:find("连续听书（自动翻页）", 1, true) ~= nil, "plugin menu is Chinese under zh_CN")
check(joined:find("Listen to the whole book", 1, true) == nil, "no English left under zh_CN")

local en = build_menu_texts("en_US")
local texts2 = {}
for k, v in pairs(en) do
    if type(v) == "table" and v.text then texts2[#texts2 + 1] = v.text end
end
local joined2 = table.concat(texts2, "\n")
check(joined2:find("Listen to the whole book (auto page turn)", 1, true) ~= nil, "plugin menu is English under en_US")
check(joined2:find("连续听书", 1, true) == nil, "no Chinese left under en_US")

-- voice labels localized too
local zh_tab
for _, v in pairs(zh) do
    if type(v) == "table" and v.icon == "mimo_tts" then zh_tab = v end
end
check(zh_tab ~= nil, "top-menu tab registered")

print("ALL I18N TESTS PASSED")
