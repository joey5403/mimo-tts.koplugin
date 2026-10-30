-- Proof that the listen/underline pipeline never invalidates crengine's
-- render buffer: every buffer-trashing call is replaced by an erroring stub.
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

local CreDocument = require("document/credocument")
local Chunker = require("chunker")
local TextProvider = require("textprovider")

local function run_on(epub, page, label)
    local doc = CreDocument:new{ file = epub }
    doc:loadDocument(epub)
    doc:setupDefaultView()
    doc:render()
    if page == "last" then page = doc:getPageCount() end

    -- Tripwires: any of these invalidates crengine's rendered page buffer
    local tripped = nil
    for _, name in ipairs({ "findText", "findAllText", "clearSelection",
                            "getTextFromXPointers", "getTextFromPositions",
                            "getWordFromPosition", "highlightXPointer" }) do
        doc[name] = function()
            tripped = name
            error("BUFFER TRASH: " .. name)
        end
    end

    doc:gotoPage(page) -- boxes are screen boxes of the *visible* page (the
                       -- plugin turns pages before locating, too)
    local ui = { document = doc, rolling = true, getCurrentPage = function() return page end }
    local t0 = os.clock()
    local text = TextProvider.getPageText(ui)
    local t_extract = os.clock() - t0
    check(tripped == nil and #text > 0, label .. ": page text without buffer trash (len=" .. #text .. ")")

    t0 = os.clock()
    local chunks = Chunker.split(text, 200)
    check(tripped == nil and #chunks > 0, label .. ": " .. #chunks .. " chunks, no trash")
    local total_boxes, missing = 0, 0
    local t_boxes = 0
    for _, c in ipairs(chunks) do
        local tb = os.clock()
        local boxes = TextProvider.getChunkBoxes(ui, c, page, nil)
        t_boxes = t_boxes + (os.clock() - tb)
        if boxes and #boxes > 0 then
            total_boxes = total_boxes + #boxes
        else
            missing = missing + 1
        end
    end
    check(tripped == nil, label .. ": chunk location without buffer trash")
    print(string.format("  %s timings: extract=%.3fs locate(all chunks)=%.3fs boxes=%d missing=%d",
        label, t_extract, t_boxes, total_boxes, missing))

    -- selection-mode chunks (text not aligned to page map) must also be safe
    if #chunks > 0 then
        local sel = { text = chunks[1].text, orig = chunks[1].orig }
        local b = TextProvider.getChunkBoxes(ui, sel, page, "selection")
        check(tripped == nil, label .. ": selection mode without buffer trash")
        check(b ~= nil, label .. ": selection mode found boxes")
    end
end

run_on("/tmp/mimottest/probe.epub", 1, "probe-epub(p1)")
run_on("/tmp/mimottest/big-book.epub", 30, "big-epub(p30)")
run_on("/tmp/mimottest/big-book.epub", "last", "big-epub(last)")
run_on("/tmp/mimottest/big-book.txt", "last", "big-txt(last)")

print("ALL ZERO-TRASH TESTS PASSED")
