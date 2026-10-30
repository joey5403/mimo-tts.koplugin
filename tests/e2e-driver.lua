-- KOReader user patch (late stage): MiMo TTS plugin E2E driver.
-- Installed as e2e-home/patches/2-mimo-tts-e2e.lua by tests/run_e2e.sh.
--
-- Drives the plugin through the complete listening flow inside a real
-- KOReader process and writes key=value results to
-- /tmp/mimottest/e2e-result.txt for run_e2e.sh to assert on.

local RESULT_PATH = "/tmp/mimottest/e2e-result.txt"
local TONE_WAV = "/tmp/mimottest/tone.wav"

local results = {}

local function write_results(status)
    results["status"] = status
    results["finished_at"] = os.date("%H:%M:%S")
    local f = io.open(RESULT_PATH, "w")
    if f then
        local keys = {}
        for k in pairs(results) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            f:write(string.format("%s=%s\n", k, tostring(results[k])))
        end
        f:close()
    end
end

local function run_e2e(ui)
    local UIManager = require("ui/uimanager")
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    -- the plugin instance is registered under its directory name
    local plugin = ui["mimo-tts"] or ui.mimo_tts

    results["plugin_loaded"] = tostring(plugin ~= nil)
    results["plugin_name"] = tostring(plugin and plugin.name)
    results["document_loaded"] = tostring(ui.document ~= nil)
    results["rolling_doc"] = tostring(ui.rolling ~= nil)
    results["start_page"] = ui:getCurrentPage()
    results["total_pages"] = ui.document:getPageCount()
    if not plugin then
        error("plugin instance not found on ReaderUI (ui['mimo-tts'])")
    end

    -- 1) real playback backend & real playback
    local real_player = plugin.player
    results["detected_player"] = tostring(real_player:getDescription())
    results["backend_name"] = tostring(real_player:getBackendName())
    results["negotiated_format"] = tostring(plugin.audio_format)
    local played_ok = real_player:play(TONE_WAV)
    results["real_play_started"] = tostring(played_ok == true)
    results["real_player_busy"] = tostring(real_player:isBusy())
    real_player:stop()
    results["real_player_stopped"] = tostring(real_player:isBusy() == false)

    -- 2) phase 1: book mode with auto page turns
    local plays, synths = 0, 0
    local orig_play = plugin.player.play
    plugin.player.play = function(self, path)
        plays = plays + 1
        return orig_play(self, path)
    end
    local orig_synth = plugin.api.synthesize
    plugin.api.synthesize = function(self, text, speed, path)
        synths = synths + 1
        return orig_synth(self, text, speed, path)
    end

    local start_page = ui:getCurrentPage()
    local max_page = start_page
    local phase1_started = os.time()
    plugin:startListening("book")
    results["phase1_started"] = tostring(plugin.session ~= nil)

    local function cache_file_count()
        local n = 0
        for entry in lfs.dir(DataStorage:getDataDir() .. "/cache/mimo_tts") do
            if entry:match("%.mp3$") or entry:match("%.wav$") then
                n = n + 1
            end
        end
        return n
    end

    local function finish()
        -- 3) extra API phases: plain preset / streaming / voicedesign / voiceclone
        -- (the mock server validates each documented request shape)
        local MiMoAPI = require("mimoapi")
        local s = plugin.settings
        local cache = DataStorage:getDataDir() .. "/cache/mimo_tts"
        local out_dir = "/tmp/mimottest"

        local function extra(name, api, path)
            local ok, res = api:synthesize("额外测试：" .. name .. "。", 1.0, path)
            results["extra_" .. name] = tostring(ok == true)
            if not ok then
                results["extra_" .. name .. "_error"] = tostring(res)
            end
        end

        extra("plain", MiMoAPI:new{
            base_url = s.base_url, api_key = s.api_key, model = "mimo-v2.5-tts",
            voice = s.voice, audio_format = "mp3", style_tag = s.style_tag, cache_dir = cache,
        }, out_dir .. "/e2e_plain.mp3")
        extra("stream", MiMoAPI:new{
            base_url = s.base_url, api_key = s.api_key, model = "mimo-v2.5-tts",
            voice = s.voice, audio_format = "mp3", use_streaming = true, cache_dir = cache,
        }, out_dir .. "/e2e_stream.wav")
        extra("design", MiMoAPI:new{
            base_url = s.base_url, api_key = s.api_key, model = "mimo-v2.5-tts-voicedesign",
            voice_description = "一位温和的女声旁白", audio_format = "wav", cache_dir = cache,
        }, out_dir .. "/e2e_design.wav")
        extra("clone", MiMoAPI:new{
            base_url = s.base_url, api_key = s.api_key, model = "mimo-v2.5-tts-voiceclone",
            voice_sample = TONE_WAV, audio_format = "wav", cache_dir = cache,
        }, out_dir .. "/e2e_clone.wav")

        results["plays"] = plays
        results["synths"] = synths
        results["cache_files"] = cache_file_count()
        write_results("PASS")
        io.stdout:write("MIMO_E2E_DONE\n")
        io.stdout:flush()
        os.exit(0)
    end

    local tick2
    local function tick1()
        max_page = math.max(max_page, ui:getCurrentPage())
        local temp = ui.view and ui.view.highlight and ui.view.highlight.temp
        if temp and next(temp) then
            results["underline_seen"] = "true"
            for _, boxes in pairs(temp) do
                results["underline_boxes"] = #boxes
            end
        end
        if plugin.session == nil or (os.time() - phase1_started) > 90 then
            results["phase1_auto_page_turn"] = tostring(max_page > start_page)
            results["phase1_max_page"] = max_page
            results["phase1_finished"] = tostring(plugin.session == nil)
            if plugin.session then
                plugin:stopListening(true) -- timeout, clean up
            end
            -- 4) phase 2: page mode must not turn pages
            local page_before = ui:getCurrentPage()
            local phase2_started = os.time()
            plugin:startListening("page")
            results["phase2_started"] = tostring(plugin.session ~= nil)
            tick2 = function()
                if plugin.session == nil or (os.time() - phase2_started) > 40 then
                    results["phase2_no_page_turn"] = tostring(ui:getCurrentPage() == page_before)
                    results["phase2_finished"] = tostring(plugin.session == nil)
                    if plugin.session then
                        plugin:stopListening(true)
                    end
                    finish()
                else
                    UIManager:scheduleIn(0.5, tick2)
                end
            end
            UIManager:nextTick(tick2)
        else
            UIManager:scheduleIn(0.5, tick1)
        end
    end
    UIManager:nextTick(tick1)
end

local ReaderUI = require("apps/reader/readerui")
local orig_init = ReaderUI.init
ReaderUI.init = function(self, ...)
    orig_init(self, ...)
    -- NOTE: postReaderReadyCallback is consumed *inside* init(), so the
    -- driver is simply scheduled right after the reader is fully ready.
    local ui = self
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        local ok, err = xpcall(run_e2e, debug.traceback, ui)
        if not ok then
            results["error"] = tostring(err)
            write_results("FAIL")
            io.stdout:write("MIMO_E2E_FAIL\n")
            io.stdout:flush()
            os.exit(1)
        end
    end)
end
