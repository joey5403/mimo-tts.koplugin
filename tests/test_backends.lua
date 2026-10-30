-- Multi-backend playback tests: WAV parsing, OpenSL ES (mock lib), manager
-- backend selection and output-format negotiation.
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

local ffi = require("ffi")
local OpenSLES = require("openslesplayer")
local Player = require("player")

-- speed up the mock's playback timing
local mock = ffi.load("/tmp/mimottest/mocksl/libOpenSLES.so")
ffi.cdef[[ void mock_set_timescale(double s); void mock_reset(void); uint64_t mock_enqueued_total(void); uint32_t mock_play_state(void); ]]
mock.mock_set_timescale(0.01) -- 1s of PCM ~= 10ms busy

--------------------------------------------------------------- WAV parsing
local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function make_wav(pcm, rate, channels, extra_chunk)
    local fmt = "fmt " .. u32(16) .. u16(1) .. u16(channels) .. u32(rate) .. u32(rate * channels * 2) .. u16(channels * 2) .. u16(16)
    local extra = extra_chunk and ("LIST" .. u32(4) .. "INFO") or ""
    local body = "WAVE" .. fmt .. extra .. "data" .. u32(#pcm) .. pcm
    return "RIFF" .. u32(#body) .. body
end
local wav_path = "/tmp/mimottest/t_parse.wav"
local f = io.open(wav_path, "wb")
f:write(make_wav(string.rep("\1\2", 24000), 24000, 1, true)) -- 1s mono + LIST chunk
f:close()
local wav = OpenSLES.parseWav(wav_path)
check(wav ~= nil and wav.rate == 24000 and wav.channels == 1 and #wav.pcm == 48000,
    "parseWav: rate/channels/pcm size (with extra chunk)")
local bad = { "/tmp/mimottest/nope.wav" }
check(OpenSLES.parseWav("/tmp/mimottest/nope.wav") == nil, "parseWav: missing file")
local f2 = io.open("/tmp/mimottest/t_bad.wav", "wb")
f2:write("NOTAWAVFILEDATA" .. string.rep("\0", 40))
f2:close()
check(OpenSLES.parseWav("/tmp/mimottest/t_bad.wav") == nil, "parseWav: rejects non-wav")

--------------------------------------------------------------- OpenSL ES backend (mock)
local ok_avail, err_avail = OpenSLES.available()
check(ok_avail, "opensles backend available via mock lib: " .. tostring(err_avail))
local sl = OpenSLES:new{}
mock.mock_reset()
check(sl:isBusy() == false, "opensles idle before play")
check(sl:play(wav_path) == true, "opensles play")
check(sl:isBusy() == true, "opensles busy during playback")
check(sl._pinned ~= nil and #sl._pinned == 48000, "PCM buffer pinned during playback")
check(mock.mock_enqueued_total() == 48000, "PCM enqueued exactly once")
check(mock.mock_play_state() == 3, "play state = PLAYING")
local t0 = os.clock()
while sl:isBusy() and os.clock() - t0 < 2 do end
check(sl:isBusy() == false, "opensles finishes playback")
sl:play(wav_path)
sl:stop()
check(sl:isBusy() == false, "opensles stop() takes effect immediately")
check(mock.mock_play_state() == 1, "play state = STOPPED after stop")

-- stereo wav (player recreation on format change)
local f3 = io.open("/tmp/mimottest/t_stereo.wav", "wb")
f3:write(make_wav(string.rep("\1\2", 48000), 44100, 2))
f3:close()
check(sl:play("/tmp/mimottest/t_stereo.wav") == true, "opensles play stereo 44.1k (format change)")
sl:stop()
check(sl:play("/tmp/mimottest/t_bad.wav") == nil, "opensles rejects non-wav input")

--------------------------------------------------------------- manager: backend selection
local p1 = Player:new{ cache_dir = "/tmp/mimottest", forced_cmd = "sh -c 'sleep 0.2' x" }
check(p1:getBackendName() == "command", "forced command wins: " .. p1:getBackendName())
check(p1:getDescription():find("sh") ~= nil, "forced command used verbatim")

local p2 = Player:new{ cache_dir = "/tmp/mimottest", backend_name = "opensles" }
check(p2:getBackendName() == "opensles", "explicit opensles backend selected: " .. p2:getBackendName())
check(p2:getFormats().wav == true and not p2:getFormats().mp3, "opensles accepts wav only")
check(p2:negotiateFormat("mp3") == "wav" and p2:negotiateFormat("wav") == "wav",
    "format negotiation: mp3 -> wav on opensles")

local p3 = Player:new{ cache_dir = "/tmp/mimottest", backend_name = "command" }
check(p3:getBackendName() == "command", "explicit command backend")
check(p3:getFormats().mp3 == true, "detected command player handles mp3 (mpv on this box)")
check(p3:negotiateFormat("mp3") == "mp3", "format negotiation keeps mp3 for mpv")

local p4 = Player:new{ cache_dir = "/tmp/mimottest" } -- auto, non-Android
check(p4:getBackendName() == "command", "auto picks command backend on desktop: " .. p4:getBackendName())

local diag = p2:diagnostics()
check(type(diag) == "string" and diag:find("opensles") ~= nil, "diagnostics mentions backend")
check(diag:find("OpenSL ES") ~= nil, "diagnostics explains OpenSL ES")

-- real play/stop lifecycle through the manager
local p5 = Player:new{ cache_dir = "/tmp/mimottest", backend_name = "opensles" }
mock.mock_reset()
p5:play(wav_path)
check(p5:isBusy() == true, "manager play -> busy")
p5:stop()
check(p5:isBusy() == false, "manager stop -> idle")

--------------------------------------------------------------- plugin integration
local UIManager = require("ui/uimanager")
UIManager.show = function() end
UIManager.close = function() end
local MiMoTTS = dofile("/tmp/mimottest/plugin/main.lua")
local ui = {
    document = {}, rolling = true,
    menu = { registerToMainMenu = function() end },
    getCurrentPage = function() return 1 end,
    handleEvent = function() end,
}
local plugin = MiMoTTS:new{ ui = ui }
plugin.cache_dir = "/tmp/mimottest"
plugin.settings.player_backend = "opensles"
plugin.settings.player_cmd = ""
plugin.settings.audio_format = "mp3"
plugin:_setupPlayback()
check(plugin.player:getBackendName() == "opensles", "plugin uses opensles backend")
check(plugin.audio_format == "wav", "plugin negotiated wav for opensles: " .. tostring(plugin.audio_format))
check(plugin.api.audio_format == "wav", "api requests wav on opensles")
check(plugin:_cachePath({ text = "x" }):match("%.wav$") ~= nil, "cache file uses .wav")

print("ALL BACKEND TESTS PASSED")
