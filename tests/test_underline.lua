-- Underline feature tests: chunk ranges -> boxes -> temp highlight drawing
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
local CanvasContext = require("document/canvascontext")
CanvasContext:init(fake_device)
package.path = "/tmp/mimottest/plugin/?.lua;" .. package.path

local function check(cond, msg)
    if cond then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg)
        os.exit(1)
    end
end

local Chunker = require("chunker")
local TextProvider = require("textprovider")

--------------------------------------------------------------- paging: offset mapping
local fake_boxes = {
    [1] = {
        { { word = "Hello", x0 = 10, y0 = 10, x1 = 50, y1 = 20 },
          { word = "world", x0 = 55, y0 = 10, x1 = 95, y1 = 20 } },
        { { word = "第二行", x0 = 10, y0 = 30, x1 = 50, y1 = 40 } },
    },
}
local fake_doc = {
    getTextBoxes = function(_, page) return fake_boxes[page] end,
    nativeToPageRectTransform = function(_, _, box) return box end,
    findText = function() return nil end,
    getPageCount = function() return 1 end,
}
local paging_ui = { document = fake_doc, paging = true } -- rolling == nil

check(TextProvider.getPageText(paging_ui) == "Hello world\n第二行", "paging flatten text")
local chunks = Chunker.split("Hello world\n第二行", 20)
check(#chunks == 2, "one chunk per sentence: " .. #chunks)
local boxes = TextProvider.getChunkBoxes(paging_ui, chunks[1], 1, nil)
check(boxes ~= nil and #boxes == 2, "sentence 1 underlines its 2 word boxes: " .. tostring(boxes and #boxes))
boxes = TextProvider.getChunkBoxes(paging_ui, chunks[2], 1, nil)
check(boxes ~= nil and #boxes == 1, "sentence 2 underlines its word box: " .. tostring(boxes and #boxes))

-- a sub-range chunk (simulating smaller chunk size) maps to the right words
local sub = { text = "world", orig = "world", range = { s = 7, e = 11 } }
boxes = TextProvider.getChunkBoxes(paging_ui, sub, 1, nil)
check(boxes ~= nil and #boxes == 1 and boxes[1].x == 55, "paging sub-chunk maps to its word box")
local sub2 = { text = "世界", orig = "第二行", range = { s = 13, e = 21 } }
boxes = TextProvider.getChunkBoxes(paging_ui, sub2, 1, nil)
check(boxes ~= nil and #boxes == 1 and boxes[1].y == 30, "paging CJK word box mapping")

-- selection mode on paging goes through findText (rects array)
fake_doc.findText = function(_, _, _, _, _, page)
    return { { x = 1, y = 2, w = 3, h = 4 }, page = page }
end
boxes = TextProvider.getChunkBoxes(paging_ui, sub, 1, "selection")
check(boxes ~= nil and #boxes == 1 and boxes[1].w == 3, "paging selection mode uses findText rects")
fake_doc.findText = function() return nil end

--------------------------------------------------------------- rolling: real CreDocument
local CreDocument = require("document/credocument")
local doc = CreDocument:new{ file = "/tmp/mimottest/book2.txt" }
doc:loadDocument("/tmp/mimottest/book2.txt")
doc:setupDefaultView()
doc:render()
local rolling_ui = {
    document = doc, rolling = true,
    getCurrentPage = function() return 1 end,
}
local page_text = TextProvider.getPageText(rolling_ui)
local rchunks = Chunker.split(page_text, 120)
check(#rchunks >= 2, "rolling page split into chunks: " .. #rchunks)
local all_ok = true
for i, c in ipairs(rchunks) do
    local b = TextProvider.getChunkBoxes(rolling_ui, c, 1, nil)
    if not b or #b == 0 then
        all_ok = false
        print("  (no boxes for chunk " .. i .. ")")
    end
end
check(all_ok, "rolling: every chunk gets underline boxes via findText")

--------------------------------------------------------------- underline UI state
local UIManager = require("ui/uimanager")
UIManager.show = function() end
UIManager.close = function() end
local MiMoTTS = dofile("/tmp/mimottest/plugin/main.lua")
local view = { highlight = { temp = {}, temp_drawer = "lighten" } }
local ui = {
    document = fake_doc, paging = true, view = view,
    menu = { registerToMainMenu = function() end },
    getCurrentPage = function() return 1 end,
    handleEvent = function() end,
}
local plugin = MiMoTTS:new{ ui = ui }
local session = { chunks = chunks, index = 1, page = 1, mode = "page" }
plugin:_underlineChunk(session)
check(view.highlight.temp_drawer == "underscore", "temp drawer switched to underscore")
check(view.highlight.temp[1] ~= nil and #view.highlight.temp[1] == 2, "underline boxes stored on page")
check(plugin._saved_temp_drawer == "lighten", "previous drawer remembered")
plugin:_clearUnderline()
check(view.highlight.temp_drawer == "lighten", "drawer restored after clear")
check(view.highlight.temp[1] == nil, "underline boxes cleared")
check(plugin._underlined_page == nil, "underlined page reset")

-- underline survives other temp highlights on other pages
plugin:_underlineChunk(session)
view.highlight.temp[2] = { { x = 0, y = 0, w = 1, h = 1 } } -- e.g. a search hit
plugin:_clearUnderline()
check(view.highlight.temp[1] == nil and view.highlight.temp[2] ~= nil, "clear only touches our underline")

-- manual page turn clears the underline
plugin:_underlineChunk(session)
check(view.highlight.temp[1] ~= nil, "underline set again")
plugin.session = session
plugin:onPageUpdate(2)
check(view.highlight.temp[1] == nil, "manual page turn clears underline")
check(plugin.session.page == 2, "session page resynced")

print("ALL UNDERLINE TESTS PASSED")
