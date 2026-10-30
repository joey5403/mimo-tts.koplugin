-- Feature tests: style tags, voicedesign/voiceclone payloads, streaming synthesis
io.stdout:setvbuf("no")
dofile("setupkoenv.lua")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open("/tmp/mimottest/settings.lua")
package.loaded["device"] = {
    screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
}
package.path = "/tmp/mimottest/plugin/?.lua;" .. package.path

local function check(cond, msg)
    if cond then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg)
        os.exit(1)
    end
end

local MiMoAPI = require("mimoapi")

--------------------------------------------------------------- style tag
local api = MiMoAPI:new{ style_tag = "温柔" }
check(api:applyStyleTag("你好。") == "(温柔)你好。", "style tag applied")
check(api:applyStyleTag("(平静)你好。") == "(平静)你好。", "no double tag for ()")
check(api:applyStyleTag("（平静）你好。") == "（平静）你好。", "no double tag for fullwidth")
check(api:applyStyleTag("[叹气]你好。") == "[叹气]你好。", "no double tag for audio tag")
check(MiMoAPI:new{ style_tag = "" }:applyStyleTag("你好。") == "你好。", "empty style tag untouched")
check(MiMoAPI:new{ style_tag = "  磁性  " }:applyStyleTag("你好。") == "(磁性)你好。", "style tag trimmed")

--------------------------------------------------------------- style instruction
local inst = MiMoAPI:new{ style_prompt = "温柔的旁白" }:buildStyleInstruction(1.25)
check(inst:find("温柔的旁白") ~= nil and inst:find("1.25 倍") ~= nil, "style+speed instruction: " .. inst)
check(MiMoAPI:new{ style_prompt = "" }:buildStyleInstruction(1.0) == "", "no instruction at speed 1.0")
check(MiMoAPI:new{ style_prompt = "" }:buildStyleInstruction(nil) == "", "no instruction without speed")

--------------------------------------------------------------- payload modes
local preset = MiMoAPI:new{ model = "mimo-v2.5-tts", voice = "冰糖", audio_format = "mp3", style_tag = "温柔" }
local p = preset:buildPayload("正文", 1.0)
check(p.audio.voice == "冰糖" and p.audio.format == "mp3", "preset payload voice/format")
check(p.messages[#p.messages].content == "(温柔)正文", "preset payload style tag in assistant")
check(p.audio.optimize_text_preview == nil, "preset payload has no optimize_text_preview")
check(p.stream == nil, "non-streaming payload has no stream key")

local design = MiMoAPI:new{ model = "mimo-v2.5-tts-voicedesign", voice_description = "一位温和的女声旁白",
    optimize_text_preview = true, audio_format = "wav" }
p = design:buildPayload("正文", 1.0)
check(p.messages[1].role == "user" and p.messages[1].content == "一位温和的女声旁白",
    "voicedesign user message is voice description")
check(p.audio.voice == nil, "voicedesign payload has no voice")
check(p.audio.optimize_text_preview == true, "voicedesign optimize_text_preview")

local no_desc = MiMoAPI:new{ model = "mimo-v2.5-tts-voicedesign", voice_description = "" }
local p2, err = no_desc:buildPayload("正文", 1.0)
check(p2 == nil and err:find("音色描述") ~= nil, "voicedesign without description errors: " .. tostring(err))

-- voiceclone with a real sample file
local sample = "/tmp/mimottest/tone.wav"
local clone = MiMoAPI:new{ model = "mimo-v2.5-tts-voiceclone", voice_sample = sample, audio_format = "mp3" }
p = clone:buildPayload("正文", 1.0)
check(type(p.audio.voice) == "string" and p.audio.voice:find("^data:audio/wav;base64,") ~= nil,
    "voiceclone data URI prefix: " .. tostring(p.audio.voice):sub(1, 30))
local Base64 = require("base64")
local encoded = p.audio.voice:match("^data:audio/wav;base64,(.*)$")
local f = io.open(sample, "rb")
local raw = f:read("*a")
f:close()
check(Base64.decode(encoded) == raw, "voiceclone sample round-trips")

local clone_missing = MiMoAPI:new{ model = "mimo-v2.5-tts-voiceclone", voice_sample = "/nonexistent.mp3" }
p2, err = clone_missing:buildPayload("正文", 1.0)
check(p2 == nil and err:find("找不到音色样本") ~= nil, "voiceclone missing sample errors")

local mp3_clone = MiMoAPI:new{ model = "mimo-v2.5-tts-voiceclone", voice_sample = "/tmp/mimottest/fake.mp3" }
local mf = io.open("/tmp/mimottest/fake.mp3", "wb")
mf:write("ID3" .. string.rep("\0", 7) .. "\xff\xfb\x90\x64" .. string.rep("\0", 40))
mf:close()
p = mp3_clone:buildPayload("正文", 1.0)
check(p.audio.voice:find("^data:audio/mpeg;base64,") ~= nil, "voiceclone mp3 mime")

--------------------------------------------------------------- wav header
p = MiMoAPI:new{ use_streaming = true, model = "mimo-v2.5-tts", voice = "mimo_default" }
    :buildPayload("正文", 1.0, true)
check(p.stream == true and p.audio.format == "pcm16", "streaming payload uses pcm16 + stream flag")

local stream_api = MiMoAPI:new{
    base_url = "http://127.0.0.1:18923/v1", api_key = "test-key",
    model = "mimo-v2.5-tts", voice = "mimo_default", audio_format = "mp3",
    use_streaming = true, cache_dir = "/tmp/mimottest",
}
local out = "/tmp/mimottest/stream_test.wav"
os.remove(out)
local ok, res = stream_api:synthesize("这是流式合成测试。", 1.0, out)
check(ok == true, "streaming synthesize ok: " .. tostring(res))
local sf = io.open(out, "rb")
local sdata = sf:read("*a")
sf:close()
check(sdata:sub(1, 4) == "RIFF" and sdata:sub(9, 12) == "WAVE", "streamed wav magic")
local function u32(s, off) return s:byte(off) + s:byte(off + 1) * 256 + s:byte(off + 2) * 65536 + s:byte(off + 3) * 16777216 end
local pcm_size = u32(sdata, 41)
check(pcm_size == 3 * 4800 and #sdata == 44 + pcm_size,
    string.format("streamed wav sizes (pcm=%d total=%d)", pcm_size, #sdata))
check(u32(sdata, 25) == 24000, "streamed wav sample rate 24kHz")
os.remove(out)

--------------------------------------------------------------- non-streaming via mock
local plain = MiMoAPI:new{
    base_url = "http://127.0.0.1:18923/v1", api_key = "test-key",
    model = "mimo-v2.5-tts", voice = "茉莉", audio_format = "mp3",
    style_tag = "磁性", cache_dir = "/tmp/mimottest",
}
out = "/tmp/mimottest/plain_test.mp3"
os.remove(out)
ok, res = plain:synthesize("普通合成测试。", 1.0, out)
check(ok == true and io.open(out, "rb") ~= nil, "non-streaming mp3 synthesize ok: " .. tostring(res))

local design_api = MiMoAPI:new{
    base_url = "http://127.0.0.1:18923/v1", api_key = "test-key",
    model = "mimo-v2.5-tts-voicedesign", voice_description = "一位温和的女声旁白",
    audio_format = "wav", cache_dir = "/tmp/mimottest",
}
out = "/tmp/mimottest/design_test.wav"
ok, res = design_api:synthesize("音色设计测试。", 1.0, out)
check(ok == true, "voicedesign synthesize ok (mock validated shape): " .. tostring(res))

local clone_api = MiMoAPI:new{
    base_url = "http://127.0.0.1:18923/v1", api_key = "test-key",
    model = "mimo-v2.5-tts-voiceclone", voice_sample = sample,
    audio_format = "wav", cache_dir = "/tmp/mimottest",
}
out = "/tmp/mimottest/clone_test.wav"
ok, res = clone_api:synthesize("音色复刻测试。", 1.0, out)
check(ok == true, "voiceclone synthesize ok (mock validated shape): " .. tostring(res))

--------------------------------------------------------------- cache keys
local k = MiMoAPI:new{ model = "m", voice = "v" }
check(k:cacheKey("abc") ~= MiMoAPI:new{ model = "m", voice = "v", style_tag = "温柔" }:cacheKey("abc"),
    "cacheKey changes with style tag")
check(k:cacheKey("abc") ~= MiMoAPI:new{ model = "m", voice = "v", use_streaming = true }:cacheKey("abc"),
    "cacheKey changes with streaming mode")
check(k:cacheKey("abc") ~= MiMoAPI:new{ model = "m", voice = "v", voice_description = "x" }:cacheKey("abc"),
    "cacheKey changes with voice description")

print("ALL FEATURE TESTS PASSED")
