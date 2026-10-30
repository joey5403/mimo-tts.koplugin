-- Integration tests: mock MiMo server + main.lua state machine + textprovider
io.stdout:setvbuf("no")
dofile("setupkoenv.lua")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("/tmp/mimottest/settings.lua")

local fake_screen = {
    getWidth = function() return 600 end, getHeight = function() return 800 end,
    getDPI = function() return 300 end, getSize = function() return { w = 600, h = 800 } end,
    scaleBySize = function(_, x) return x end, scaleByDPI = function(_, x) return x end,
    isColorEnabled = function() return false end, fb_bpp = 8, getScreenWidth = function() return 600 end,
}
local fake_device = {
    screen = fake_screen, model = "Test",
    hasBGRFrameBuffer = function() return false end, hasEinkScreen = function() return true end,
    isAndroid = function() return false end, isDesktop = function() return true end,
    isEmulator = function() return true end, isKindle = function() return false end,
    isPocketBook = function() return false end, hasSystemFonts = function() return true end,
    isRemarkable = function() return false end, isSDL = function() return true end,
    isLinux = function() return true end, canHWDither = function() return false end, screen_dpi = 300,
    enableCPUCores = function() end, _UIManagerReady = function() end,
    initNetworkManager = function() end, setDateTime = function() end, getDateTime = function() return os.date("*t") end,
    getPowerDevice = function() return { isCharging = function() return false end, getCapacity = function() return 100 end } end,
    input = { eventAdjustHook = function() end, gamepadRumble = function() end, getRotationMode = function() return 0 end,
        setRotationMode = function() end, isTextInputVisible = function() return false end },
}
setmetatable(fake_device, { __index = function(_, k)
    if type(k) == "string" and (k:match("^has") or k:match("^is") or k:match("^can") or k:match("^supports")) then
        return function() return false end
    end
    return nil
end })
package.loaded["device"] = fake_device
package.path = "/tmp/mimottest/plugin/?.lua;" .. package.path

local function check(cond, msg)
    if cond then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg)
        os.exit(1)
    end
end

------------------------------------------------------------------ synthesize against mock server
local MiMoAPI = require("mimoapi")
local api = MiMoAPI:new{
    base_url = "http://127.0.0.1:18923/v1/",
    api_key = "test-key",
    model = "mimo-v2.5-tts",
    voice = "mimo_default",
    audio_format = "wav",
}
local out = "/tmp/mimottest/synth_test.wav"
os.remove(out)
local ok, err = api:synthesize("你好，MiMo。", 1.0, out)
check(ok == true, "synthesize ok: " .. tostring(err))
local f = io.open(out, "rb")
local data = f:read("*a")
f:close()
check(data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WAVE", "synthesized wav magic")
os.remove(out)

-- wrong key -> auth error
local api_bad = MiMoAPI:new{ base_url = "http://127.0.0.1:18923/v1", api_key = "wrong",
    model = "mimo-v2.5-tts", audio_format = "wav" }
ok, err = api_bad:synthesize("hi", 1.0, out)
check(ok == nil and err:find("认证失败") ~= nil, "auth failure message: " .. tostring(err))

-- wrong model -> upstream error message surfaced
local api_bad2 = MiMoAPI:new{ base_url = "http://127.0.0.1:18923/v1", api_key = "test-key",
    model = "wrong-model", audio_format = "wav" }
ok, err = api_bad2:synthesize("hi", 1.0, out)
check(ok == nil and err:find("wrong-model", 1, true) ~= nil, "upstream error surfaced: " .. tostring(err))

-- missing key -> local error
local api_bad3 = MiMoAPI:new{ base_url = "http://127.0.0.1:18923/v1", model = "mimo-v2.5-tts" }
ok, err = api_bad3:synthesize("hi", 1.0, out)
check(ok == nil and err:find("API key") ~= nil, "missing api key error: " .. tostring(err))

-- connection refused -> graceful error
local api_bad4 = MiMoAPI:new{ base_url = "http://127.0.0.1:1/v1", api_key = "k",
    model = "mimo-v2.5-tts", audio_format = "wav" }
ok, err = api_bad4:synthesize("hi", 1.0, out)
check(ok == nil and type(err) == "string", "connection failure handled: " .. tostring(err))
check(not io.open(out, "rb"), "no audio file written on failure")

------------------------------------------------------------------ textprovider with a real CreDocument
local CanvasContext = require("document/canvascontext")
CanvasContext:init(fake_device)
local CreDocument = require("document/credocument")
local doc = CreDocument:new{ file = "/tmp/mimottest/book2.txt" }
doc:loadDocument("/tmp/mimottest/book2.txt")
doc:setupDefaultView()
doc:render()

local TextProvider = require("textprovider")
local pages = doc:getPageCount()
local ui = {
    document = doc,
    rolling = true,
    getCurrentPage = function() return 1 end,
}
local text = TextProvider.getPageText(ui)
check(text:find("第1句") ~= nil, "textprovider rolling current page")
-- last page: XPointer extraction has no "end of document" anchor, so the
-- provider falls back to the visible page -- which is what the plugin shows
-- via GotoPage before extraction (mirrored here with doc:gotoPage)
doc:gotoPage(pages)
local last = TextProvider.getPageText(ui, pages)
check(last:find("第57句") ~= nil, "textprovider rolling last page: " .. last:sub(1, 30))
check(TextProvider.getPageCount(ui) == pages, "textprovider page count")

-- selection text
ui.highlight = { selected_text = { text = "选中的文字。" } }
check(TextProvider.getSelectionText(ui) == "选中的文字。", "selection text")
ui.highlight = { selected_text = { text = "  " } }
check(TextProvider.getSelectionText(ui) == "", "empty selection ignored")

------------------------------------------------------------------ main.lua: load, menu, state machine
local UIManager = require("ui/uimanager")
UIManager.show = function() end -- silence widget display
UIManager.close = function() end

local MiMoTTS = dofile("/tmp/mimottest/plugin/main.lua")
check(type(MiMoTTS) == "table" and MiMoTTS.name == "mimo_tts", "plugin module loaded")

local pages_text = {
    [1] = ("一二三四五六七八九。"):rep(2), -- 2 sentences -> 2 chunks (one per sentence)
    [2] = "句子三。",
    [3] = "句子五。",
}
TextProvider.getPageText = function(_, page) return pages_text[page] or "" end
TextProvider.getCurrentPage = function() return 1 end
TextProvider.getPageCount = function() return 3 end

local played, stopped = {}, 0
local fake_player = {
    busy = false,
    play = function(self, path) played[#played + 1] = path self.busy = true return true end,
    isBusy = function(self) return self.busy end,
    stop = function(self) self.busy = false stopped = stopped + 1 end,
}
local synthesized = {}
local fake_api = {
    cacheKey = function(_, text)
        synthesized[text] = synthesized[text] or ("k" .. tostring(#synthesized + 1))
        return synthesized[text]
    end,
    synthesize = function(_, text, speed, path)
        synthesized[text] = synthesized[text] or ("k" .. tostring(#synthesized + 1))
        local fh = io.open(path, "wb")
        fh:write("RIFFfakeWAVE")
        fh:close()
        return true, path
    end,
}
local current_page = 1
local fake_ui = {
    document = doc,
    rolling = true,
    menu = { registerToMainMenu = function() end },
    getCurrentPage = function() return current_page end,
    handleEvent = function(_, ev) current_page = (ev.args and ev.args[1]) or current_page end,
}

local plugin = MiMoTTS:new{ ui = fake_ui }
check(plugin.settings ~= nil, "settings loaded")
plugin.api = fake_api
plugin.player = fake_player
plugin.cache_dir = "/tmp/mimottest"
plugin.settings.chunk_size = 20

local menu_items = {}
plugin:addToMainMenu(menu_items)
local flat = 0
for k in pairs(menu_items) do
    if k:match("^mimo_tts_item_") then flat = flat + 1 end
end
check(menu_items.mimo_tts_tab ~= nil and flat == 17, "menu items registered (tab + 17 flat): " .. flat)

-- book mode: 2 chunks on page 1, 1 on page 2, 1 on page 3 -> 4 plays, auto page turns
plugin:startListening("book")
print("DEBUG session:", plugin.session, plugin.session and #plugin.session.chunks,
    plugin.session and plugin.session.page, plugin.session and plugin.session.pages)
print("DEBUG chunksForPage(1):", #plugin:_chunksForPage(1), "text:", TextProvider.getPageText(plugin.ui, 1):sub(1, 20))
check(plugin.session ~= nil and #plugin.session.chunks == 2, "session starts with 2 chunks")
check(#played == 1, "first chunk playing")
fake_player.busy = true
plugin:_poll() -- busy -> prefetch
check(next(synthesized) ~= nil, "prefetch happened while playing")
fake_player.busy = false
plugin:_poll() -- chunk 2
check(#played == 2, "advanced to chunk 2")
fake_player.busy = false
plugin:_poll() -- page 2
check(#played == 3 and current_page == 2, "auto page turn to page 2: " .. tostring(current_page))
fake_player.busy = false
plugin:_poll() -- page 3
check(#played == 4 and current_page == 3, "auto page turn to page 3")
fake_player.busy = false
plugin:_poll() -- end of book
check(plugin.session == nil, "session finished at end of book")

-- page mode: stops after current page chunks
current_page = 1
played = {}
plugin:startListening("page")
check(#played == 1 and #plugin.session.chunks == 2, "page mode start")
fake_player.busy = false
plugin:_poll()
check(#played == 2, "page mode chunk 2")
fake_player.busy = false
plugin:_poll()
check(plugin.session == nil, "page mode stops at page end")

-- navigation: next/prev across pages
current_page = 1
played = {}
plugin:startListening("book")
plugin:onMiMoTTSPrev() -- already at first chunk, page 1 -> restarts it
check(plugin.session and #played == 2, "prev at start restarts first chunk")
plugin:onMiMoTTSNext()
check(#played == 3, "next goes to chunk 2")
plugin:onMiMoTTSNext() -- chunk 2 is last of page 1 -> page 2
check(current_page == 2 and #played == 4, "next crosses to page 2")
plugin:onMiMoTTSPrev()
check(current_page == 1 and #played == 5, "prev crosses back to page 1")

-- deep backward navigation: page 3 -> page 2 (last chunk) -> page 2 (first chunk) -> page 1 (last chunk)
current_page = 1
played = {}
plugin:startListening("book")
plugin:onMiMoTTSNext() -- page 1, chunk 2
plugin:onMiMoTTSNext() -- page 2, chunk 1 (the only one)
plugin:onMiMoTTSNext() -- page 3, chunk 1 (the only one)
check(current_page == 3, "navigated to page 3")
plugin:onMiMoTTSPrev() -- must land on page 2's last chunk, NOT skip to page 1
check(current_page == 2, "prev from page 3 lands on page 2, got " .. tostring(current_page))
plugin:onMiMoTTSPrev() -- page 1, last chunk (chunk 2 of 2)
check(current_page == 1 and plugin.session.index == 2,
    "prev from page 2 lands on page 1 last chunk: " .. tostring(plugin.session.index))
plugin:onMiMoTTSStop()
check(plugin.session == nil, "stop clears session")

-- selection mode never crosses page boundaries
current_page = 2
played = {}
TextProvider.getSelectionText = function() return ("选段一。"):rep(2) end -- 2 sentences -> 2 chunks
plugin:startListening("selection")
check(#plugin.session.chunks == 2, "selection mode has 2 chunks")
plugin:onMiMoTTSPrev() -- restart first chunk, must not jump to previous page
check(current_page == 2 and plugin.session.index == 1, "selection prev stays in selection")
plugin:onMiMoTTSNext()
check(plugin.session.index == 2, "selection next within selection")
plugin:onMiMoTTSNext() -- end of selection -> finish, no page turn
check(plugin.session == nil and current_page == 2, "selection mode ends without page turn")

-- toggle
plugin:onMiMoTTSToggle()
check(plugin.session ~= nil, "toggle starts")
plugin:onMiMoTTSToggle()
check(plugin.session == nil, "toggle stops")

print("ALL INTEGRATION TESTS PASSED")
