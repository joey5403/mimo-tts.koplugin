--[[--
Xiaomi MiMo TTS client.

Implements the documented MiMo speech-synthesis API
(<https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/audio/speech-synthesis-v2.5>):

    POST {base_url}/chat/completions
    api-key: <key>
    {
      "model": "mimo-v2.5-tts",          -- or -voicedesign / -voiceclone
      "messages": [
        {"role": "user", "content": "<自然语言风格指令 / 音色描述>"},
        {"role": "assistant", "content": "(风格标签)要朗读的文字"}
      ],
      "audio": {"format": "mp3", "voice": "mimo_default"}
    }

- 预置音色 (``mimo-v2.5-tts``): ``audio.voice`` is a preset voice ID.
- 音色设计 (``mimo-v2.5-tts-voicedesign``): the *user* message carries the
  voice description (required); ``audio.voice`` is omitted; optional
  ``audio.optimize_text_preview``.
- 音色复刻 (``mimo-v2.5-tts-voiceclone``): ``audio.voice`` is a data URI
  (``data:{mime};base64,...``) of a mp3/wav sample (max 10MB).
- 自然语言风格控制 goes in the *user* message; 音格标签控制
  (``(风格)`` / ``[音频标签]``) goes in the *assistant* message.
- 流式合成 (``stream=true``) must use ``format=pcm16`` (24kHz mono PCM16LE);
  the audio arrives as base64 in ``choices[1].delta.audio.data``.

The response audio (non-streaming) is base64 in ``choices[1].message.audio.data``.
]]

local Base64 = require("base64")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socketutil = require("socketutil")
local util = require("util")

-- HTTPS support (LuaSec) is loaded lazily, so plain HTTP keeps working even
-- on builds without it.
local https

-- JSON encoder/decoder (rapidjson first, LuaJSON fallback)
local JSON
do
    local ok, mod = pcall(require, "rapidjson")
    if ok then
        JSON = mod
    else
        ok, mod = pcall(require, "json")
        if ok then
            JSON = mod
        end
    end
end

local MiMoAPI = {}
MiMoAPI.__index = MiMoAPI

-- Streaming audio is always 24kHz mono PCM16LE (per the API documentation)
MiMoAPI.STREAM_SAMPLE_RATE = 24000

function MiMoAPI:new(o)
    return setmetatable(o or {}, MiMoAPI)
end

function MiMoAPI:endpoint()
    return (self.base_url or ""):gsub("/+$", "") .. "/chat/completions"
end

--- Synthesis mode derived from the configured model: "preset", "voicedesign"
-- or "voiceclone".
function MiMoAPI:getMode()
    local model = self.model or ""
    if model:find("voicedesign", 1, true) then
        return "voicedesign"
    elseif model:find("voiceclone", 1, true) then
        return "voiceclone"
    end
    return "preset"
end

-- Request building ---------------------------------------------------------

--- Build the natural language instruction (user message content).
function MiMoAPI:buildStyleInstruction(speed)
    local parts = {}
    local style = (self.style_prompt or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if style ~= "" then
        parts[#parts + 1] = style
    end
    speed = tonumber(speed)
    if speed and speed > 0 and speed ~= 1 then
        parts[#parts + 1] = string.format("语速约为正常的 %g 倍。", speed)
    end
    return table.concat(parts, " ")
end

--- Apply the 风格标签 prefix (e.g. `(温柔)`) to the target text.
function MiMoAPI:applyStyleTag(text)
    local tag = (self.style_tag or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if tag == "" then
        return text
    end
    -- Do not double-tag texts that already start with a style/audio tag
    if text:find("^%s*%(") or text:find("^%s*（") or text:find("^%s*%[") then
        return text
    end
    return "(" .. tag .. ")" .. text
end

--- Read the voice sample and turn it into a data URI (voiceclone).
function MiMoAPI:voiceSampleDataURI()
    if self._voice_sample_cache then
        return self._voice_sample_cache
    end
    local path = self.voice_sample or ""
    local f = io.open(path, "rb")
    if not f then
        return nil, "找不到音色样本文件：" .. path
    end
    local data = f:read("*a")
    f:close()
    if not data or #data < 16 then
        return nil, "音色样本文件无效：" .. path
    end
    if #data > 10 * 1024 * 1024 then
        return nil, "音色样本超过 10MB 限制"
    end
    local mime = path:lower():match("%.wav$") and "audio/wav" or "audio/mpeg"
    self._voice_sample_cache = "data:" .. mime .. ";base64," .. Base64.encode(data)
    return self._voice_sample_cache
end

--- Build the chat-completions payload for one chunk of text.
-- @treturn table|nil payload
-- @treturn string|nil error message
function MiMoAPI:buildPayload(text, speed, streaming)
    local mode = self:getMode()
    local messages = {}
    if mode == "voicedesign" then
        -- user message = voice design description (required by the API)
        local desc = (self.voice_description or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if desc == "" then
            return nil, "音色设计模式（mimo-v2.5-tts-voicedesign）需要填写音色描述"
        end
        messages[#messages + 1] = { role = "user", content = desc }
    else
        local instruction = self:buildStyleInstruction(speed)
        if instruction ~= "" then
            messages[#messages + 1] = { role = "user", content = instruction }
        end
    end
    messages[#messages + 1] = { role = "assistant", content = self:applyStyleTag(text) }

    local audio = {}
    if streaming then
        audio.format = "pcm16"
    else
        audio.format = (self.audio_format or "mp3"):lower() == "wav" and "wav" or "mp3"
    end
    if mode == "preset" then
        audio.voice = self.voice ~= "" and self.voice or "mimo_default"
    elseif mode == "voiceclone" then
        local data_uri, err = self:voiceSampleDataURI()
        if not data_uri then
            return nil, err
        end
        audio.voice = data_uri
    else -- voicedesign
        if self.optimize_text_preview then
            audio.optimize_text_preview = true
        end
    end

    local payload = {
        model = self.model,
        messages = messages,
        audio = audio,
    }
    if streaming then
        payload.stream = true
    end
    return payload
end

-- JSON helpers -------------------------------------------------------------

local function encode_json(tbl)
    if not JSON then
        return nil, "no JSON library available"
    end
    local ok, res = pcall(JSON.encode, tbl)
    if ok then
        return res
    end
    return nil, res
end

local function decode_json(str)
    if not JSON then
        return nil
    end
    local ok, res = pcall(JSON.decode, str)
    if ok then
        return res
    end
    return nil
end

--- Extract the base64 audio payload from a non-streaming response body.
function MiMoAPI:extractAudioData(body_str)
    local decoded = decode_json(body_str)
    if type(decoded) == "table" then
        local choices = decoded.choices
        if type(choices) == "table" and type(choices[1]) == "table" then
            local message = choices[1].message
            if type(message) == "table" and type(message.audio) == "table"
                and type(message.audio.data) == "string" then
                return message.audio.data
            end
        end
    end
    -- Fallback: plain pattern matching (also used when no JSON lib is found)
    return body_str:match('"data"%s*:%s*"([%w%+%/%=%-%_]+)"')
end

--- Extract one base64 audio chunk from a streaming (SSE) event payload.
function MiMoAPI:extractStreamAudioData(event_str)
    local decoded = decode_json(event_str)
    if type(decoded) == "table" then
        local choices = decoded.choices
        if type(choices) == "table" and type(choices[1]) == "table" then
            local choice = choices[1]
            -- streaming: delta.audio.data (also handles the compatibility mode
            -- where a full message.audio.data is sent as the only event)
            for _, key in ipairs({ "delta", "message" }) do
                local holder = choice[key]
                if type(holder) == "table" and type(holder.audio) == "table"
                    and type(holder.audio.data) == "string" then
                    return holder.audio.data
                end
            end
        end
    end
    return event_str:match('"data"%s*:%s*"([%w%+%/%=%-%_]+)"')
end

--- Extract an error message from a failed response body, if any.
local function extractErrorMessage(body_str)
    local decoded = decode_json(body_str)
    if type(decoded) == "table" and type(decoded.error) == "table"
        and type(decoded.error.message) == "string" then
        return decoded.error.message
    end
    return body_str:match('"message"%s*:%s*"(.-)"')
end

-- Audio validation ---------------------------------------------------------

local function is_valid_audio(audio_bytes, audio_format)
    if type(audio_bytes) ~= "string" or #audio_bytes < 12 then
        return false
    end
    if audio_format == "wav" or audio_format == "pcm16" then
        return audio_bytes:sub(1, 4) == "RIFF" and audio_bytes:sub(9, 12) == "WAVE"
    end
    if audio_format == "mp3" then
        local offset = 1
        if audio_bytes:sub(1, 3) == "ID3" then
            if #audio_bytes < 10 then
                return false
            end
            local size = 0
            for i = 7, 10 do
                local b = audio_bytes:byte(i)
                if b >= 128 then
                    return false
                end
                size = size * 128 + b
            end
            offset = 11 + size
        end
        if offset + 3 > #audio_bytes then
            return false
        end
        local b1, b2, b3 = audio_bytes:byte(offset, offset + 2)
        local sync = b1 == 0xFF and bit.band(b2, 0xE0) == 0xE0
        local version = bit.band(b2, 0x18) ~= 0x08
        local layer = bit.band(b2, 0x06) ~= 0x00
        local br = bit.rshift(bit.band(b3, 0xF0), 4)
        local bitrate = br ~= 0x0 and br ~= 0xF
        local samplerate = bit.band(b3, 0x0C) ~= 0x0C
        return sync and version and layer and bitrate and samplerate
    end
    -- unknown format: only check that it is not obviously empty/JSON
    return audio_bytes:sub(1, 1) ~= "{"
end

--- Build a 44-byte WAV header for raw PCM16 audio.
local function wav_header(pcm_size, sample_rate, channels)
    local function u32(n)
        return string.char(n % 256, math.floor(n / 256) % 256,
            math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
    end
    local function u16(n)
        return string.char(n % 256, math.floor(n / 256) % 256)
    end
    local byte_rate = sample_rate * channels * 2
    return "RIFF" .. u32(36 + pcm_size) .. "WAVE"
        .. "fmt " .. u32(16) .. u16(1) .. u16(channels)
        .. u32(sample_rate) .. u32(byte_rate) .. u16(channels * 2) .. u16(16)
        .. "data" .. u32(pcm_size)
end

-- HTTP ---------------------------------------------------------------------

local function getRequestFunc(url)
    if url:sub(1, 6) == "https:" then
        if not https then
            local ok, mod = pcall(require, "ssl.https")
            if not ok then
                return nil, "HTTPS 不可用（当前 KOReader 构建缺少 LuaSec）"
            end
            https = mod
        end
        return https.request
    end
    return http.request
end

--- Perform one HTTP request, following a few redirects.
local function do_request(url, body, headers, sink)
    for _ = 1, 4 do
        local request_func, err = getRequestFunc(url)
        if not request_func then
            return nil, err, nil
        end
        local result, code, resp_headers = request_func{
            url = url,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(body), -- fresh source for every attempt
            sink = sink,
        }
        if type(code) == "number" and code >= 300 and code < 400 and resp_headers and resp_headers.location then
            url = resp_headers.location
        else
            return result, code, resp_headers
        end
    end
    return nil, "too many redirects", nil
end

--- Send a request and return the raw response body string.
-- @treturn string|nil body
-- @treturn number|string|nil status code
local function request_body(self, payload_body)
    local tmp_path = (self.cache_dir or "/tmp") .. "/mimo_tts_response.tmp"
    local tmp_file = io.open(tmp_path, "wb")
    if not tmp_file then
        return nil, "cannot write temp file " .. tmp_path
    end

    local api_key = self:_apiKey()
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, 60)
    local result, code = do_request(self:endpoint(), payload_body, {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
        ["Content-Length"] = tostring(#payload_body),
        ["api-key"] = api_key,
        ["Authorization"] = "Bearer " .. api_key,
    }, ltn12.sink.file(tmp_file))
    socketutil:reset_timeout()
    pcall(function() tmp_file:close() end) -- may already be closed by the sink

    local f = io.open(tmp_path, "rb")
    local body_str = f and f:read("*a") or nil
    if f then
        f:close()
    end
    os.remove(tmp_path)
    return body_str, code
end

function MiMoAPI:_apiKey()
    return (self.api_key or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Common checks and error mapping for the HTTP exchange.
-- @treturn boolean|nil ok
-- @treturn string body-or-error
local function check_response(self, body_str, code)
    if code == socketutil.TIMEOUT_CODE or code == "timeout" then
        return nil, "连接 MiMo TTS 超时"
    end
    if code == 401 or code == 403 then
        return nil, "MiMo TTS 认证失败（检查 API Key）"
    end
    if code ~= 200 or not body_str then
        if code ~= 200 and code ~= nil and type(code) ~= "number" then
            -- LuaSocket transport failure (e.g. "connection refused")
            return nil, "无法连接 MiMo TTS：" .. tostring(code)
        end
        local msg = body_str and extractErrorMessage(body_str)
        return nil, string.format("MiMo TTS 请求失败 (HTTP %s)%s",
            tostring(code), msg and (": " .. msg) or "")
    end
    return true, body_str
end

--- Synthesize one chunk of text into an audio file (non-streaming).
-- @string text text to speak
-- @number speed playback speed (1.0 = normal)
-- @string out_path where to write the audio bytes
-- @treturn boolean|nil success
-- @treturn string audio path on success, error message on failure
function MiMoAPI:synthesize(text, speed, out_path)
    if not text or text:find("%S") == nil then
        return nil, "empty text"
    end
    if self:_apiKey() == "" then
        return nil, "API key is not set (MiMo TTS 设置中填写 API Key)"
    end
    if not self.base_url or self.base_url == "" then
        return nil, "API base URL is not set"
    end

    local payload, err = self:buildPayload(text, speed, self.use_streaming)
    if not payload then
        return nil, err
    end
    local body
    body, err = encode_json(payload)
    if not body then
        return nil, "cannot encode request: " .. tostring(err)
    end

    if self.use_streaming then
        return self:_synthesizeStream(body, out_path)
    end

    local body_str, code = request_body(self, body)
    local ok
    ok, body_str = check_response(self, body_str, code)
    if not ok then
        return nil, body_str
    end

    local audio_b64 = self:extractAudioData(body_str)
    if not audio_b64 or audio_b64 == "" then
        local msg = extractErrorMessage(body_str)
        return nil, "MiMo TTS 未返回音频数据" .. (msg and (": " .. msg) or "")
    end

    local audio_bytes = Base64.decode(audio_b64)
    if not is_valid_audio(audio_bytes, (self.audio_format or "mp3"):lower()) then
        return nil, "MiMo TTS 返回的音频数据无效"
    end

    local out_file = io.open(out_path, "wb")
    if not out_file then
        return nil, "cannot write audio file " .. out_path
    end
    out_file:write(audio_bytes)
    out_file:close()
    logger.dbg("MiMoTTS: synthesized", #audio_bytes, "bytes to", out_path)
    return true, out_path
end

--- Streaming synthesis: request ``stream=true``/``pcm16``, collect the base64
-- PCM chunks from the SSE response and write them out as a WAV file.
function MiMoAPI:_synthesizeStream(body, out_path)
    local body_str, code = request_body(self, body)
    local ok
    ok, body_str = check_response(self, body_str, code)
    if not ok then
        return nil, body_str
    end

    local out_file = io.open(out_path, "wb")
    if not out_file then
        return nil, "cannot write audio file " .. out_path
    end
    -- Placeholder header, patched with the real sizes once all PCM arrived
    out_file:write(wav_header(0, self.STREAM_SAMPLE_RATE, 1))

    local pcm_size, chunks = 0, 0
    for line in body_str:gmatch("[^\n]+") do
        local payload_str = line:match("^data:%s*(.+)$")
        if payload_str and payload_str ~= "[DONE]" then
            local audio_b64 = self:extractStreamAudioData(payload_str)
            if audio_b64 and audio_b64 ~= "" then
                local pcm = Base64.decode(audio_b64)
                if #pcm > 0 then
                    out_file:write(pcm)
                    pcm_size = pcm_size + #pcm
                    chunks = chunks + 1
                end
            end
        end
    end

    if pcm_size == 0 then
        out_file:close()
        os.remove(out_path)
        return nil, "MiMo TTS 流式响应中没有音频数据"
    end
    out_file:seek("set", 0)
    out_file:write(wav_header(pcm_size, self.STREAM_SAMPLE_RATE, 1))
    out_file:close()
    logger.dbg("MiMoTTS: streamed", pcm_size, "pcm bytes in", chunks, "chunks to", out_path)
    return true, out_path
end

--- Build a cache file name for a chunk of text and the current voice settings.
function MiMoAPI:cacheKey(text)
    local sample_id = self.voice_sample or ""
    if sample_id ~= "" and self._voice_sample_cache then
        sample_id = tostring(#self._voice_sample_cache)
    end
    local parts = table.concat({
        self.base_url or "",
        self.model or "",
        self.voice or "",
        self.audio_format or "",
        tostring(self.style_prompt or ""),
        tostring(self.style_tag or ""),
        tostring(self.voice_description or ""),
        sample_id,
        self.use_streaming and "stream" or "plain",
        self.optimize_text_preview and "otp" or "-",
        tostring(self.speed or ""),
        text or "",
    }, "\1")
    -- Two rotate-xor accumulators (kept fully in 32-bit range), used as a
    -- cheap content hash for cache file names
    local h1, h2 = 2166136261, 2166136261
    for i = 1, #parts do
        local b = parts:byte(i)
        h1 = bit.band(bit.rol(bit.bxor(h1, b), 7) + 0x9E3779B9, 0xFFFFFFFF)
        h2 = bit.band(bit.rol(bit.bxor(h2, b), 11) + 0x85EBCA6B, 0xFFFFFFFF)
    end
    -- normalize to unsigned 32-bit before formatting (bit ops are signed)
    return string.format("%08x%08x", h1 % 4294967296, h2 % 4294967296)
end

return MiMoAPI
