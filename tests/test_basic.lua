-- Headless test-suite for the MiMo TTS plugin (run from the koreader shim dir)
io.stdout:setvbuf("no")
dofile("setupkoenv.lua")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("/tmp/mimottest/settings.lua")

local fake_screen = {
    getWidth = function() return 600 end, getHeight = function() return 800 end,
    getDPI = function() return 300 end, getSize = function() return { w = 600, h = 800 } end,
    scaleBySize = function(_, x) return x end, isColorEnabled = function() return false end, fb_bpp = 8,
}
local fake_device = {
    screen = fake_screen, model = "Test",
    hasBGRFrameBuffer = function() return false end, hasEinkScreen = function() return true end,
    isAndroid = function() return false end, isDesktop = function() return true end,
    isEmulator = function() return true end, isKindle = function() return false end,
    isPocketBook = function() return false end, hasSystemFonts = function() return true end,
    isRemarkable = function() return false end, isSDL = function() return true end,
    isLinux = function() return true end, canHWDither = false, screen_dpi = 300,
    enableCPUCores = function() end, _UIManagerReady = function() end,
}
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

------------------------------------------------------------------ base64
local Base64 = require("base64")
check(Base64.decode("aGVsbG8=") == "hello", "base64 padded")
check(Base64.decode("aGVsbG8") == "hello", "base64 unpadded")
check(Base64.decode("aGVsbG8h") == "hello!", "base64 3 bytes")
check(Base64.decode("AAECAw==") == string.char(0, 1, 2, 3), "base64 binary")
check(Base64.decode("aGVs bG8=") == "hello", "base64 whitespace")
local long = string.rep("AB", 10000)
check(#Base64.decode(long) == 15000, "base64 long input")

------------------------------------------------------------------ chunker
local Chunker = require("chunker")
local t = Chunker.normalize("你好，  世界。\r\n\r\n\n第二段  文本。")
check(t == "你好， 世界。\n第二段文本。", "chunker normalize: " .. t:gsub("\n", "|"))
local sents = Chunker.splitSentences("甲。乙！丙？丁")
check(#sents == 4 and sents[1].text == "甲。" and sents[4].text == "丁", "splitSentences: " .. #sents)
check(sents[1].s == 1 and sents[2].s == 7 and sents[4].e == 21, "sentence byte ranges: "
    .. sents[1].s .. "," .. sents[2].s .. "," .. sents[4].e)
sents = Chunker.splitSentences('他说：“你好。”然后走了。')
check(sents[1].text == '他说：“你好。”' and sents[2].text == "然后走了。", "sentence keeps quotes: " .. sents[1].text)
local function clen(x) local _, n = x:gsub("[^\128-\191]", "") return n end
local src = ("一二三四五六七八九。"):rep(3)
local chunks = Chunker.split(src, 20)
check(#chunks == 3 and clen(chunks[1].text) == 10 and clen(chunks[2].text) == 10,
    "one chunk per sentence: " .. #chunks .. " chunks of " .. clen(chunks[1].text) .. " chars")
check(chunks[1].range.s == 1 and chunks[1].range.e == 30 and chunks[3].range.e == #src
    and chunks[2].orig == src:sub(31, 60), "chunk ranges map to source: "
    .. chunks[1].range.s .. ".." .. chunks[1].range.e .. "," .. chunks[3].range.s .. ".." .. chunks[3].range.e)
chunks = Chunker.split(("字"):rep(55) .. "。", 20)
check(#chunks == 3, "hard cut overlong sentence: " .. #chunks)
local covered = 0
for _, c in ipairs(chunks) do covered = covered + #c.orig end
check(covered == 55 * 3 + 3, "hard cut ranges cover the source: " .. covered)
check(#Chunker.split("   ", 20) == 0, "empty text -> no chunks")

------------------------------------------------------------------ mimoapi
local MiMoAPI = require("mimoapi")
local api = MiMoAPI:new{
    base_url = "http://127.0.0.1:18923/v1",
    api_key = "test-key",
    model = "mimo-v2.5-tts",
    voice = "mimo_default",
    audio_format = "mp3",
    style_prompt = "温柔的旁白",
}
local payload = api:buildPayload("你好世界", 1.25)
check(payload.model == "mimo-v2.5-tts", "payload model")
check(payload.audio.format == "mp3" and payload.audio.voice == "mimo_default", "payload audio block")
check(payload.messages[#payload.messages].role == "assistant", "payload assistant message")
check(payload.messages[#payload.messages].content == "你好世界", "payload text")
check(payload.messages[1].content:find("1.25 倍") ~= nil, "payload speed instruction")
check(payload.messages[1].content:find("温柔的旁白") ~= nil, "payload style prompt")
local p2 = api:buildPayload("hi")
check(#p2.messages == 2 and p2.messages[1].content == "温柔的旁白"
    and not p2.messages[1].content:find("speed"), "payload without speed: " .. p2.messages[1].content)
local p3 = MiMoAPI:new{ model = "m", audio_format = "mp3" }:buildPayload("hi")
check(#p3.messages == 1 and p3.messages[1].role == "assistant", "payload without user message")

-- response extraction
local wav = "RIFF$\0\0\0WAVEfmt " .. string.rep("\0", 32)
local mp3 = "ID3" .. string.rep("\0", 7) .. "\xff\xfb\x90\x64" .. string.rep("\0", 40)
local function b64enc(s)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return (s:gsub(".", function(x)
        local r, byte = "", x:byte()
        for i = 8, 1, -1 do r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return b:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#s % 3 + 1]
end
local wav_b64 = b64enc(wav)
local body_ok = '{"choices":[{"message":{"audio":{"data":"' .. wav_b64 .. '"}}}]}'
check(api:extractAudioData(body_ok) == wav_b64, "extractAudioData via json")
package.loaded["rapidjson"] = nil
local api2 = MiMoAPI:new{ audio_format = "mp3" }
-- pattern fallback (simulate decode failure by feeding garbage-free body)
check(api2:extractAudioData('{"choices":[{"message":{"audio":{"data":"' .. wav_b64 .. '"}}}]}') == wav_b64,
    "extractAudioData via pattern")

local key1 = api:cacheKey("abc")
local key2 = api:cacheKey("abc")
local key3 = api:cacheKey("abd")
check(key1 == key2 and key1 ~= key3 and #key1 == 16, "cacheKey stable and distinct")

------------------------------------------------------------------ player
local Player = require("player")
local player = Player:new{ cache_dir = "/tmp/mimottest", forced_cmd = "sh -c 'sleep 2' x" }
check(player:getDescription():find("sleep 2", 1, true) ~= nil, "player forced command")
check(player:play("/tmp/mimottest/book.txt") == true, "player play")
check(player:isBusy() == true, "player busy while sleeping")
player:stop()
check(player:isBusy() == false, "player not busy after stop")
local player2 = Player:new{ cache_dir = "/tmp/mimottest", forced_cmd = "definitely_not_a_command_xyz" }
check(player2:play("/tmp/mimottest/book.txt") == true, "play spawns even for unknown cmd")
player2:stop()
local player3 = Player:new{ cache_dir = "/tmp/mimottest" }
print("INFO: autodetected player: " .. tostring(player3:getDescription()))

print("ALL BASIC TESTS PASSED")
