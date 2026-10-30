--[[--
MiMo TTS 语音听书

Listen to your books with the Xiaomi MiMo-2.5 text-to-speech service.

Text is extracted from the opened document page by page (or from the current
selection), sent to the MiMo TTS API, and played through an external audio
player. In "continuous listening" mode the plugin keeps turning pages until
the end of the book.

@module koplugin.MiMoTTS
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

-- Load plugin translations before evaluating any UI string (also covers
-- _meta.lua, which is loaded right after this module).
pcall(function() require("translations").load() end)

local Chunker = require("chunker")
local MiMoAPI = require("mimoapi")
local Player = require("player")
local TextProvider = require("textprovider")

local DEFAULTS = {
    base_url      = "https://token-plan-cn.xiaomimimo.com/v1",
    api_key       = "",
    model         = "mimo-v2.5-tts",
    voice         = "mimo_default",
    audio_format  = "mp3",
    speed         = 1.0,
    style_prompt  = "",
    style_tag     = "",
    voice_description = "",
    voice_sample  = "",
    use_streaming = false,
    optimize_text_preview = false,
    underline    = true,
    player_backend = "auto",
    chunk_size    = 300,
    player_cmd    = "",
}

-- 预置音色（MiMo-V2.5-TTS 官方音色列表）
local PRESET_VOICES = {
    { id = "mimo_default", label = _("MiMo default") },
    { id = "冰糖", label = _("Bingtang (Chinese, female)") },
    { id = "茉莉", label = _("Jasmine (Chinese, female)") },
    { id = "苏打", label = _("Soda (Chinese, male)") },
    { id = "白桦", label = _("Birch (Chinese, male)") },
    { id = "Mia", label = _("Mia (English, female)") },
    { id = "Chloe", label = _("Chloe (English, female)") },
    { id = "Milo", label = _("Milo (English, male)") },
    { id = "Dean", label = _("Dean (English, male)") },
}

local MiMoTTS = WidgetContainer:extend{
    name = "mimo_tts",
    is_doc_only = false,
    version = "1.0.2", -- release version (kept in sync with git tags vX.Y.Z)
}

-- Settings & instances -----------------------------------------------------

function MiMoTTS:init()
    self.settings = self:_loadSettings()
    self.cache_dir = DataStorage:getDataDir() .. "/cache/mimo_tts"
    os.execute("mkdir -p " .. util.shell_escape({ self.cache_dir }))
    self:_setupPlayback()
    self.session = nil
    self._poll_fn = function()
        self:_poll()
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:ensureIcon()
    if G_reader_settings:readSetting("mimo_tts_top_icon") ~= false then
        self:ensureTopIcon(true)
    end
    logger.info("MiMoTTS: plugin loaded, cache dir:", self.cache_dir)
end

function MiMoTTS:_loadSettings()
    local saved = G_reader_settings:readSetting("mimo_tts_settings") or {}
    local settings = {}
    for k, v in pairs(DEFAULTS) do
        if saved[k] ~= nil then
            settings[k] = saved[k]
        else
            settings[k] = v
        end
    end
    return settings
end

function MiMoTTS:_saveSettings()
    G_reader_settings:saveSetting("mimo_tts_settings", self.settings)
    G_reader_settings:flush()
end

--- Create the playback backend for this device and negotiate the audio
-- output format it accepts (e.g. the Android OpenSL ES backend takes WAV).
function MiMoTTS:_setupPlayback()
    self.player = Player:new{
        cache_dir = self.cache_dir,
        forced_cmd = self.settings.player_cmd,
        backend_name = self.settings.player_backend,
    }
    self.audio_format = self.player:negotiateFormat(self.settings.audio_format)
    if self.audio_format ~= (self.settings.audio_format or "mp3") then
        logger.info("MiMoTTS: audio format negotiated:", self.settings.audio_format, "->", self.audio_format)
    end
    self.api = self:_makeAPI()
end

function MiMoTTS:_makeAPI()
    local s = self.settings
    return MiMoAPI:new{
        base_url = s.base_url,
        api_key = s.api_key,
        model = s.model,
        voice = s.voice,
        audio_format = self.audio_format or s.audio_format,
        style_prompt = s.style_prompt,
        style_tag = s.style_tag,
        voice_description = s.voice_description,
        voice_sample = s.voice_sample,
        use_streaming = s.use_streaming,
        optimize_text_preview = s.optimize_text_preview,
        cache_dir = self.cache_dir,
        speed = s.speed,
    }
end

function MiMoTTS:_applySettings()
    self:_setupPlayback()
    self:_saveSettings()
end

-- Dispatcher ---------------------------------------------------------------

function MiMoTTS:onDispatcherRegisterActions()
    Dispatcher:registerAction("mimo_tts_toggle",
        { category = "none", event = "MiMoTTSToggle", title = _("MiMo TTS: start/stop reading"), general = true })
    Dispatcher:registerAction("mimo_tts_start_page",
        { category = "none", event = "MiMoTTSStartPage", title = _("MiMo TTS: read current page"), general = true })
    Dispatcher:registerAction("mimo_tts_start_book",
        { category = "none", event = "MiMoTTSStartBook", title = _("MiMo TTS: read the whole book"), general = true })
    Dispatcher:registerAction("mimo_tts_stop",
        { category = "none", event = "MiMoTTSStop", title = _("MiMo TTS: stop reading"), general = true })
    Dispatcher:registerAction("mimo_tts_next",
        { category = "none", event = "MiMoTTSNext", title = _("MiMo TTS: next segment"), general = true })
    Dispatcher:registerAction("mimo_tts_prev",
        { category = "none", event = "MiMoTTSPrev", title = _("MiMo TTS: previous segment"), general = true })
end

function MiMoTTS:onMiMoTTSToggle()
    if self.session then
        self:stopListening()
    else
        self:startListening("book")
    end
end

function MiMoTTS:onMiMoTTSStartPage()
    self:startListening("page")
end

function MiMoTTS:onMiMoTTSStartBook()
    self:startListening("book")
end

function MiMoTTS:onMiMoTTSStop()
    self:stopListening()
end

function MiMoTTS:onMiMoTTSNext()
    self:_step(1)
end

function MiMoTTS:onMiMoTTSPrev()
    self:_step(-1)
end

function MiMoTTS:onCloseDocument()
    self:stopListening(true)
end

-- Menu ---------------------------------------------------------------------

function MiMoTTS:addToMainMenu(menu_items)
    -- 顶部菜单（阅读页）图标：它是顶部菜单的一个 tab，点击后 tab 页
    -- 直接显示插件菜单（TouchMenu 原生支持勾选/子菜单/开关保持打开）。
    -- 菜单项单独注册并由 MenuSorter 放入 tab；图标关闭时它们退化为
    -- “更多工具”里的普通行。
    menu_items.mimo_tts_tab = {
        icon = "mimo_tts",
        text = _("MiMo TTS Read-aloud"),
        remember = false,
        sorting_hint = "more_tools",
    }
    for i, item in ipairs(self:getMenuItems()) do
        item.sorting_hint = "more_tools"
        menu_items[self:_itemId(i)] = item
    end
end

function MiMoTTS:_itemId(i)
    return "mimo_tts_item_" .. i
end

function MiMoTTS:getMenuItems()
    return {
        {
            text = _("Listen to the whole book (auto page turn)"),
                callback = function()
                    self:startListening("book")
                end,
            },
            {
                text = _("Read current page"),
                callback = function()
                    self:startListening("page")
                end,
            },
            {
                text = _("Read selected text"),
                callback = function()
                    self:startListening("selection")
                end,
            },
            {
                text = _("Next segment"),
                callback = function()
                    self:_step(1)
                end,
            },
            {
                text = _("Previous segment"),
                callback = function()
                    self:_step(-1)
                end,
            },
            {
                text = _("Stop reading"),
                callback = function()
                    self:stopListening()
                end,
            },
            {
                text = _("Test reading"),
                callback = function()
                    self:testTTS()
                end,
            },
            {
                text = _("Playback diagnostics…"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = self.player:diagnostics(),
                        timeout = 10,
                    })
                end,
            },
            {
                text = _("Choose preset voice"),
                text_func = function()
                    local label = self.settings.voice
                    for _, v in ipairs(PRESET_VOICES) do
                        if v.id == label then
                            label = v.label
                            break
                        end
                    end
                    return T(_("Choose preset voice (current: %1)"), label)
                end,
                sub_item_table_func = function()
                    return self:buildVoiceMenu()
                end,
            },
            {
                text = _("Streaming synthesis (steadier for long texts)"),
                checked_func = function()
                    return self.settings.use_streaming
                end,
                keep_menu_open = true,
                callback = function()
                    self.settings.use_streaming = not self.settings.use_streaming
                    self:_applySettings()
                    UIManager:show(InfoMessage:new{
                        text = self.settings.use_streaming and _("Streaming synthesis enabled") or _("Streaming synthesis disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("Top menu icon"),
                checked_func = function()
                    return self:isTopIconEnabled()
                end,
                keep_menu_open = true,
                callback = function()
                    self:toggleTopIcon()
                end,
            },
            {
                text = _("Underline text while reading"),
                checked_func = function()
                    return self.settings.underline
                end,
                keep_menu_open = true,
                callback = function()
                    self.settings.underline = not self.settings.underline
                    self:_applySettings()
                    if not self.settings.underline then
                        self:_clearUnderline()
                    end
                    UIManager:show(InfoMessage:new{
                        text = self.settings.underline and _("Reading underline enabled") or _("Reading underline disabled"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("API & model settings…"),
                callback = function()
                    self:showAPISettings()
                end,
            },
            {
                text = _("Voice & style settings…"),
                callback = function()
                    self:showVoiceStyleSettings()
                end,
            },
            {
                text = _("Playback & segmentation settings…"),
                callback = function()
                    self:showPlaybackSettings()
                end,
            },
            {
                text = _("Clear audio cache"),
                callback = function()
                    self:clearCache()
                end,
            },
            {
                text = _("About MiMo TTS"),
                callback = function()
                    self:showAbout()
                end,
            },
    }
end

function MiMoTTS:showAbout()
    UIManager:show(InfoMessage:new{
        text = T(_("MiMo TTS Read-aloud v%1"), MiMoTTS.version) .. "\n\n"
            .. "https://github.com/joey5403/mimo-tts.koplugin\n"
            .. "README.md (EN) / README.zh-CN.md (简体中文)",
        width = math.floor(require("device").screen:getWidth() * 0.9),
    })
end

-- 顶部菜单图标（tab） ---------------------------------------------------------


local function serializeMenuOrder(v, indent)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local parts = {}
        local maxn = 0
        for k in pairs(v) do
            if type(k) == "number" and k > maxn then
                maxn = k
            end
        end
        for i = 1, maxn do
            parts[#parts + 1] = serializeMenuOrder(v[i], indent .. "  ")
        end
        for k, val in pairs(v) do
            if type(k) ~= "number" or k < 1 or k > maxn then
                local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
                parts[#parts + 1] = key .. " = " .. serializeMenuOrder(val, indent .. "  ")
            end
        end
        if #parts == 0 then
            return "{}"
        end
        return "{\n" .. indent .. "  " .. table.concat(parts, ",\n" .. indent .. "  ") .. ",\n" .. indent .. "}"
    end
    return "nil"
end

function MiMoTTS:_menuOrderPath()
    return DataStorage:getSettingsDir() .. "/reader_menu_order.lua"
end

--- 把（或移除）听书 tab 写进 KOReader 的菜单排序配置。
-- 只追加/删除我们自己的条目，不破坏用户已有定制。
function MiMoTTS:ensureTopIcon(enabled)
    local lfs = require("libs/libkoreader-lfs")
    local path = self:_menuOrderPath()
    local order = {}
    if lfs.attributes(path, "mode") == "file" then
        local ok, user = pcall(dofile, path)
        if ok and type(user) == "table" then
            order = user
        end
    end
    local tabs = order["KOMenu:menu_buttons"]
    if enabled then
        if type(tabs) ~= "table" then
            local core = require("ui/elements/reader_menu_order")
            tabs = {}
            for _, id in ipairs(core["KOMenu:menu_buttons"] or {}) do
                tabs[#tabs + 1] = id
            end
            order["KOMenu:menu_buttons"] = tabs
        end
        local found = false
        for _, id in ipairs(tabs) do
            if id == "mimo_tts_tab" then
                found = true
            end
        end
        if not found then
            tabs[#tabs + 1] = "mimo_tts_tab"
        end
        -- the tab page shows the plugin menu items directly
        local ids = {}
        for i = 1, #self:getMenuItems() do
            ids[i] = self:_itemId(i)
        end
        order["mimo_tts_tab"] = ids
    else
        if type(tabs) == "table" then
            for i = #tabs, 1, -1 do
                if tabs[i] == "mimo_tts_tab" then
                    table.remove(tabs, i)
                end
            end
        end
        order["mimo_tts_tab"] = nil
    end
    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write("-- Menu order customization (managed by the MiMo TTS plugin)\n")
    f:write("return " .. serializeMenuOrder(order, "") .. "\n")
    f:close()
    return true
end

function MiMoTTS:isTopIconEnabled()
    local lfs = require("libs/libkoreader-lfs")
    local path = self:_menuOrderPath()
    if lfs.attributes(path, "mode") ~= "file" then
        return false
    end
    local ok, order = pcall(dofile, path)
    if not ok or type(order) ~= "table" then
        return false
    end
    for _, id in ipairs(order["KOMenu:menu_buttons"] or {}) do
        if id == "mimo_tts_tab" then
            return true
        end
    end
    return false
end

function MiMoTTS:toggleTopIcon()
    local enable = not self:isTopIconEnabled()
    self:ensureTopIcon(enable)
    G_reader_settings:saveSetting("mimo_tts_top_icon", enable)
    G_reader_settings:flush()
    if self.ui.menu then
        self.ui.menu.tab_item_table = nil -- 强制下次重建顶部菜单
    end
    UIManager:show(InfoMessage:new{
        text = enable and _("Reading icon added to the top menu (reopen the menu to see it)")
            or _("Reading icon removed from the top menu"),
        timeout = 3,
    })
end

--- 把自带图标复制到用户图标目录（IconWidget 会优先从那里查找）
function MiMoTTS:ensureIcon()
    if not self.path then
        return
    end
    local lfs = require("libs/libkoreader-lfs")
    local dst_dir = DataStorage:getDataDir() .. "/icons"
    local dst = dst_dir .. "/mimo_tts.svg"
    local src_path = self.path .. "/icons/mimo_tts.svg"
    local f = io.open(src_path, "rb")
    if not f then
        return
    end
    local data = f:read("*a")
    f:close()
    -- already up to date?
    local g = io.open(dst, "rb")
    if g then
        local existing = g:read("*a")
        g:close()
        if existing == data then
            return
        end
    end
    os.execute("mkdir -p " .. util.shell_escape({ dst_dir }))
    local out = io.open(dst, "wb")
    if out then
        out:write(data)
        out:close()
    end
end

function MiMoTTS:buildVoiceMenu()
    local items = {}
    for _, v in ipairs(PRESET_VOICES) do
        items[#items + 1] = {
            text = v.label,
            checked_func = function()
                return self.settings.voice == v.id
            end,
            callback = function()
                self.settings.voice = v.id
                self:_applySettings()
                UIManager:show(InfoMessage:new{
                    text = T(_("Voice changed to %1"), v.label),
                    timeout = 2,
                })
            end,
        }
    end
    return items
end

-- Listening session --------------------------------------------------------

function MiMoTTS:_chunksForPage(page)
    local text = TextProvider.getPageText(self.ui, page)
    return Chunker.split(text, self.settings.chunk_size)
end

--- Start listening.
-- @string mode "book" (continuous, auto page turns), "page" (current page only)
--   or "selection" (current text selection)
function MiMoTTS:startListening(mode)
    if not self.ui.document then
        UIManager:show(InfoMessage:new{ text = _("Please open a book first") })
        return
    end
    if not self.api then
        self.api = self:_makeAPI()
    end
    self:stopListening(true)

    local session = {
        mode = mode,
        index = 1,
        page = TextProvider.getCurrentPage(self.ui),
        pages = TextProvider.getPageCount(self.ui),
    }
    if mode == "selection" then
        local text = TextProvider.getSelectionText(self.ui)
        if text == "" then
            UIManager:show(InfoMessage:new{ text = _("No text selected (long-press to select text first)") })
            return
        end
        session.chunks = Chunker.split(text, self.settings.chunk_size)
    else
        session.chunks = self:_chunksForPage(session.page)
    end
    if #session.chunks == 0 then
        UIManager:show(InfoMessage:new{ text = _("No readable text found") })
        return
    end

    self.session = session
    logger.info("MiMoTTS: start listening", mode, "page", session.page, #session.chunks, "chunks")
    UIManager:show(InfoMessage:new{
        text = T(_("Start reading (page %1, %2 segments)"), session.page, #session.chunks),
        timeout = 2,
    })
    self:_playCurrentChunk()
end

--- Stop listening (idempotent).
function MiMoTTS:stopListening(silent)
    if self.session then
        self.session = nil
        self.player:stop()
        UIManager:unschedule(self._poll_fn)
        self:_clearUnderline()
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("Reading stopped"), timeout = 2 })
        end
    end
end

function MiMoTTS:_finish()
    self:stopListening(true)
    UIManager:show(InfoMessage:new{ text = _("Finished reading"), timeout = 3 })
end

-- Playback state machine ---------------------------------------------------

function MiMoTTS:_schedulePoll()
    UIManager:unschedule(self._poll_fn)
    -- Short interval: with one sentence per chunk, playback must advance
    -- quickly when a sentence ends (the poller itself is cheap).
    UIManager:scheduleIn(0.2, self._poll_fn)
end

--- Cache path for a chunk, synthesizing it when it is not cached yet.
function MiMoTTS:_cachePath(chunk)
    local tts_text = chunk.text or chunk
    local ext
    if self.settings.use_streaming then
        ext = "wav" -- streaming always yields 24kHz PCM16 wrapped as WAV
    else
        ext = (self.audio_format or self.settings.audio_format or "mp3"):lower()
    end
    return string.format("%s/%s.%s", self.cache_dir, self.api:cacheKey(tts_text), ext)
end

function MiMoTTS:_isCached(chunk)
    local f = io.open(self:_cachePath(chunk), "rb")
    if f then
        f:close()
        return true
    end
    return false
end

function MiMoTTS:_audioFileFor(chunk, quiet)
    local tts_text = chunk.text or chunk
    local path = self:_cachePath(chunk)
    if self:_isCached(chunk) then
        return path
    end
    logger.info("MiMoTTS: synthesizing chunk of", #tts_text, "bytes")
    local ok, err = self.api:synthesize(tts_text, self.settings.speed, path)
    if not ok then
        logger.warn("MiMoTTS: synthesis failed:", err)
        if not quiet then
            UIManager:show(InfoMessage:new{
                text = T(_("MiMo TTS 合成失败：%1"), err),
                timeout = 6,
            })
        end
        return nil
    end
    return path
end

function MiMoTTS:_playCurrentChunk()
    local session = self.session
    if not session then
        return
    end
    local chunk = session.chunks[session.index]
    if not chunk then
        self:_finish()
        return
    end
    local path = self:_audioFileFor(chunk)
    if not path then
        self:stopListening(true)
        return
    end
    local ok, err = self.player:play(path)
    if not ok then
        logger.warn("MiMoTTS: playback failed:", err)
        self:stopListening(true)
        UIManager:show(InfoMessage:new{ text = err, timeout = 6 })
        return
    end
    if self.settings.underline then
        self:_underlineChunk(session)
    else
        self:_clearUnderline()
    end
    self:_schedulePoll()
end

function MiMoTTS:_poll()
    local session = self.session
    if not session then
        return
    end
    if self.player:isBusy() then
        self:_prefetch(session)
        self:_schedulePoll()
    else
        self:_step(1)
    end
end

--- Keep a few upcoming sentences synthesized while the current one plays, so
-- playback is gapless. Only one synthesis per tick, to keep each UI stall
-- short (chunks are single sentences now).
function MiMoTTS:_prefetch(session)
    local LOOKAHEAD = 3
    for k = 1, LOOKAHEAD do
        local nxt = session.chunks[session.index + k]
        if nxt and not self:_isCached(nxt) then
            self:_audioFileFor(nxt, true)
            return
        end
    end
    -- Keep page turns seamless in book mode: warm up the next page's first
    -- sentences once the end of the current page is in sight.
    if session.mode == "book" and session.page < session.pages then
        if not session.next_page_chunks then
            session.next_page_chunks = self:_chunksForPage(session.page + 1)
        end
        local rel = session.index + LOOKAHEAD + 1 - #session.chunks
        local nxt = rel > 0 and session.next_page_chunks[rel] or nil
        if nxt and not self:_isCached(nxt) then
            self:_audioFileFor(nxt, true)
        end
    end
end

--- Move to another chunk (`direction` = 1 or -1), loading new pages as needed.
function MiMoTTS:_step(direction)
    local session = self.session
    if not session then
        return
    end
    self.player:stop()
    UIManager:unschedule(self._poll_fn)
    session.index = (session.index or 1) + direction
    while true do
        if session.index >= 1 and session.index <= #session.chunks then
            self:_playCurrentChunk()
            return
        end
        if direction > 0 then
            if session.mode ~= "book" or session.page >= session.pages then
                self:_finish()
                return
            end
            session.page = session.page + 1
        else
            if session.mode ~= "book" or session.page <= 1 then
                -- page/selection modes never leave their own text
                session.index = math.min(1, #session.chunks)
                if session.index >= 1 then
                    self:_playCurrentChunk()
                else
                    self:_finish()
                end
                return
            end
            session.page = session.page - 1
        end
        self:_gotoPage(session.page)
        session.chunks = session.next_page_chunks or self:_chunksForPage(session.page)
        session.next_page_chunks = nil
        if direction > 0 then
            session.index = 1
        else
            -- land on the last chunk of the previous page (0 keeps walking
            -- backwards past empty pages)
            session.index = #session.chunks
        end
    end
end

function MiMoTTS:_gotoPage(page)
    if self.ui.document then
        self._turning_page = true
        self.ui:handleEvent(Event:new("GotoPage", page))
        self._turning_page = false
    end
end

--- Keep the session in sync when the user turns pages manually.
function MiMoTTS:onPageUpdate(pageno)
    if self.session and not self._turning_page and type(pageno) == "number" then
        self.session.page = pageno
        if self.session.mode == "book" and pageno > self.session.pages then
            self.session.pages = pageno
        end
        -- the underlined boxes belong to the previous page
        self:_clearUnderline()
    end
end

-- 朗读下划线 ---------------------------------------------------------------

--- Underline the chunk that is currently being played.
function MiMoTTS:_underlineChunk(session)
    local view = self.ui.view
    if not (view and view.highlight) then
        return
    end
    local chunk = session.chunks[session.index]
    local boxes = TextProvider.getChunkBoxes(self.ui, chunk, session.page, session.mode)
    if not boxes then
        logger.dbg("MiMoTTS: no underline boxes for chunk", session.index)
        return
    end
    if self._saved_temp_drawer == nil then
        self._saved_temp_drawer = view.highlight.temp_drawer
    end
    view.highlight.temp_drawer = "underscore"
    local temp = view.highlight.temp
    if self._underlined_page and temp then
        temp[self._underlined_page] = nil
    end
    temp[session.page] = boxes
    self._underlined_page = session.page
    UIManager:setDirty(self.ui.dialog or self.ui, "ui")
end

--- Remove the reading underline (and restore any previous temp drawer).
function MiMoTTS:_clearUnderline()
    local view = self.ui.view
    if view and view.highlight then
        if self._underlined_page and view.highlight.temp then
            view.highlight.temp[self._underlined_page] = nil
        end
        if self._saved_temp_drawer then
            view.highlight.temp_drawer = self._saved_temp_drawer
            self._saved_temp_drawer = nil
        end
    end
    self._underlined_page = nil
    if self.ui and self.ui.document then
        UIManager:setDirty(self.ui.dialog or self.ui, "ui")
    end
end

-- Settings -----------------------------------------------------------------

function MiMoTTS:showAPISettings()
    local s = self.settings
    local dialog
    dialog = MultiInputDialog:new{
        title = _("MiMo TTS API & model settings"),
        fields = {
            { description = _("API base URL"), text = s.base_url, hint = "https://token-plan-cn.xiaomimimo.com/v1" },
            { description = _("API key"), text = s.api_key, hint = _("Required") },
            { description = _("TTS model"), text = s.model, hint = "mimo-v2.5-tts / -voicedesign / -voiceclone" },
            { description = _("Audio format (mp3 / wav)"), text = s.audio_format, hint = "mp3" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        s.base_url = tostring(fields[1] or ""):gsub("%s", "")
                        s.api_key = tostring(fields[2] or ""):gsub("%s", "")
                        s.model = tostring(fields[3] or ""):gsub("%s", "")
                        local fmt = tostring(fields[4] or ""):gsub("%s", ""):lower()
                        s.audio_format = (fmt == "wav") and "wav" or "mp3"
                        self:_applySettings()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = _("Settings saved"), timeout = 2 })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function MiMoTTS:showVoiceStyleSettings()
    local s = self.settings
    local dialog
    dialog = MultiInputDialog:new{
        title = _("MiMo TTS voice & style settings"),
        fields = {
            { description = _("Style tag (e.g. gentle; optional)"), text = s.style_tag, hint = "(温柔)文本…" },
            { description = _("Style prompt (natural-language instruction; optional)"), text = s.style_prompt, hint = _("e.g. A warm audiobook narrator") },
            { description = _("Voice description (required for voice design)"), text = s.voice_description, hint = _("e.g. A mellow, deep middle-aged male voice") },
            { description = _("Voice sample file (voice clone mode, mp3/wav)"), text = s.voice_sample, hint = "/path/to/voice.mp3" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        s.style_tag = tostring(fields[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        s.style_prompt = tostring(fields[2] or "")
                        s.voice_description = tostring(fields[3] or "")
                        s.voice_sample = tostring(fields[4] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        self:_applySettings()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = _("Settings saved"), timeout = 2 })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function MiMoTTS:showPlaybackSettings()
    local s = self.settings
    local dialog
    dialog = MultiInputDialog:new{
        title = _("MiMo TTS playback & segmentation settings"),
        fields = {
            { description = _("Speed (1.0 = normal)"), input_type = "number", text = tostring(s.speed), hint = "1.0" },
            { description = _("Max segment length (longer ones are split)"), input_type = "number", text = tostring(s.chunk_size), hint = "300" },
            { description = _("Player command (empty = auto-detect)"), text = s.player_cmd, hint = "mpv --no-video" },
            { description = _("Playback backend (auto/command/opensles)"), text = s.player_backend, hint = "auto" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        s.speed = tonumber(fields[1]) or 1.0
                        if s.speed <= 0 then
                            s.speed = 1.0
                        end
                        s.chunk_size = math.floor(tonumber(fields[2]) or 300)
                        s.player_cmd = tostring(fields[3] or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        local backend = tostring(fields[4] or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
                        s.player_backend = (backend == "command" or backend == "opensles") and backend or "auto"
                        self:_applySettings()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ text = _("Settings saved"), timeout = 2 })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- Utilities ----------------------------------------------------------------

function MiMoTTS:testTTS()
    local text = _("你好，这是 MiMo TTS 语音听书测试。")
    local path = string.format("%s/test.%s", self.cache_dir, (self.audio_format or "mp3"):lower())
    os.remove(path)
    UIManager:show(InfoMessage:new{ text = _("Synthesizing test audio…") })
    local ok, err = self.api:synthesize(text, self.settings.speed, path)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("MiMo TTS 合成失败：%1"), err),
            timeout = 6,
        })
        return
    end
    local played, play_err = self.player:play(path)
    if not played then
        UIManager:show(InfoMessage:new{ text = play_err, timeout = 6 })
    end
end

function MiMoTTS:clearCache()
    UIManager:show(ConfirmBox:new{
        text = _("Delete all cached audio files?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self.player:stop()
            os.execute("rm -f " .. util.shell_escape({ self.cache_dir }) .. "/*")
            UIManager:show(InfoMessage:new{ text = _("Audio cache cleared"), timeout = 2 })
        end,
    })
end

return MiMoTTS
