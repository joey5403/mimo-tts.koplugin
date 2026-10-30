--[[--
Playback manager: picks the best audio backend for the current device.

Backend priority:

1. user-configured command (`player_cmd`) -- the escape hatch, wins over all;
2. ``opensles`` -- Android's NDK OpenSL ES library driven through LuaJIT FFI
   (works on every Android device, no external binaries);
3. ``command`` -- an external command line player, auto-detected among
   mpv / ffplay / mpg123 / madplay / ogg123 / sox `play` / aplay / paplay /
   afplay (desktop Linux, Kobo, Kindle, PocketBook, reMarkable...);
4. nothing found -> clear error and a diagnostics report.

Each backend declares which audio formats it accepts, so the synthesizer can
negotiate the output format (e.g. the OpenSL ES backend takes WAV only).
]]

local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local CommandBackend = {}
CommandBackend.__index = CommandBackend
CommandBackend.backend_name = "command"

-- Ordered by preference; first available binary wins.
local CANDIDATES = {
    { bin = "mpv",     args = { "--no-video", "--really-quiet", "--no-terminal", "--gapless-audio=yes" },
      formats = { mp3 = true, wav = true } },
    { bin = "ffplay",  args = { "-nodisp", "-autoexit", "-loglevel", "quiet", "-nostats" },
      formats = { mp3 = true, wav = true } },
    { bin = "mpg123",  args = { "-q" }, formats = { mp3 = true, wav = true } },
    { bin = "madplay", args = { "-Q" }, formats = { mp3 = true } },
    { bin = "ogg123",  args = { "-q" }, formats = { wav = true } },
    { bin = "play",    args = { "-q" }, formats = { mp3 = true, wav = true } },
    { bin = "aplay",   args = { "-q" }, formats = { wav = true } },
    { bin = "paplay",  args = {},      formats = { wav = true } },
    { bin = "afplay",  args = {},      formats = { mp3 = true, wav = true } }, -- macOS
}

local function shell_ok(cmd)
    local a = os.execute(cmd)
    if type(a) == "number" then
        return a == 0
    end
    return a == true
end

local function command_exists(bin)
    local quoted = util.shell_escape({ bin })
    return shell_ok("command -v " .. quoted .. " >/dev/null 2>&1")
        or shell_ok("which " .. quoted .. " >/dev/null 2>&1")
end

function CommandBackend:new(o)
    return setmetatable(o or {}, CommandBackend)
end

--- Resolve the command to use (custom one, or the first available player).
function CommandBackend:getCommand()
    if self.cached_cmd then
        return self.cached_cmd
    end
    local forced = (self.forced_cmd or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if forced ~= "" then
        self.cached_cmd = forced
        self.cached_formats = { mp3 = true, wav = true } -- user knows better
        self.cached_name = "自定义命令"
        return self.cached_cmd
    end
    for _, cand in ipairs(CANDIDATES) do
        if command_exists(cand.bin) then
            self.cached_cmd = table.concat({ cand.bin, unpack(cand.args) }, " ")
            self.cached_formats = cand.formats
            self.cached_name = cand.bin
            logger.info("MiMoTTS: using audio player:", self.cached_cmd)
            return self.cached_cmd
        end
    end
    return nil
end

function CommandBackend:getFormats()
    self:getCommand()
    return self.cached_formats or {}
end

function CommandBackend:play(file_path)
    self:stop()
    local cmd = self:getCommand()
    if not cmd then
        return nil, "找不到音频播放器（可安装 mpv / ffplay / mpg123 等，或在设置中指定播放器命令）"
    end
    if not self.pid_file then
        return nil, "player cache dir is not set"
    end
    local full = string.format("%s %s >/dev/null 2>&1 & echo $! > %s",
        cmd, util.shell_escape({ file_path }), util.shell_escape({ self.pid_file }))
    logger.dbg("MiMoTTS: spawn player:", full)
    shell_ok(full)
    self.last_file = file_path
    return true
end

function CommandBackend:isBusy()
    if not self.pid_file then
        return false
    end
    local lfs = require("libs/libkoreader-lfs")
    local f = io.open(self.pid_file, "r")
    local pid = f and tonumber(f:read("*l")) or nil
    if f then
        f:close()
    end
    if pid and lfs.attributes("/proc", "mode") == "directory" then
        -- cheap (no shell fork) and precise enough for gapless playback
        return lfs.attributes("/proc/" .. pid, "mode") == "directory"
    end
    return shell_ok(string.format("kill -0 $(cat %s 2>/dev/null) 2>/dev/null",
        util.shell_escape({ self.pid_file })))
end

function CommandBackend:stop()
    if not self.pid_file then
        return
    end
    shell_ok(string.format("kill $(cat %s 2>/dev/null) 2>/dev/null", util.shell_escape({ self.pid_file })))
    shell_ok(string.format("rm -f %s", util.shell_escape({ self.pid_file })))
end

function CommandBackend:describe()
    local cmd = self:getCommand()
    return cmd and ("命令行播放器：" .. cmd) or "未找到命令行播放器"
end

---------------------------------------------------------------------------

local Player = {}
Player.__index = Player

function Player:new(o)
    local self = setmetatable(o or {}, Player)
    self.pid_file = (self.cache_dir or "/tmp") .. "/mimo_tts_player.pid"
    return self
end

--- Get (and cache) the backend object, honouring the configured preference.
function Player:getBackend()
    if self._backend then
        return self._backend
    end
    local OpenSLES = require("openslesplayer")
    local want = (self.backend_name or "auto"):lower()

    local function command_backend()
        return CommandBackend:new{ pid_file = self.pid_file, forced_cmd = self.forced_cmd }
    end
    local function opensles_backend()
        local ok = OpenSLES.available()
        if ok then
            return OpenSLES:new{}
        end
        return nil
    end

    local backend, err
    if self.forced_cmd and self.forced_cmd ~= "" then
        -- an explicit command is the strongest user intent
        backend = command_backend()
    elseif want == "opensles" then
        backend = opensles_backend()
        err = not backend and "OpenSL ES 后端不可用" or nil
    elseif want == "command" then
        backend = command_backend()
    else -- auto
        local Device = require("device")
        if Device and Device.isAndroid and Device:isAndroid() then
            backend = opensles_backend() or command_backend()
        else
            backend = command_backend()
            if not backend:getCommand() then
                backend = opensles_backend() or backend
            end
        end
    end
    if not backend then
        backend = command_backend() -- reports a clear error when playing
    end
    self._backend = backend
    self._backend_err = err
    return backend
end

function Player:play(file_path)
    return self:getBackend():play(file_path)
end

function Player:isBusy()
    return self:getBackend():isBusy()
end

function Player:stop()
    self:getBackend():stop()
end

--- Formats this player accepts, e.g. `{ mp3 = true, wav = true }`.
function Player:getFormats()
    return self:getBackend():getFormats() or {}
end

--- Pick the best output format for this device.
function Player:negotiateFormat(wanted)
    wanted = (wanted or "mp3"):lower()
    local formats = self:getFormats()
    if formats[wanted] then
        return wanted
    end
    if formats.wav then
        return "wav"
    end
    if formats.mp3 then
        return "mp3"
    end
    return wanted
end

function Player:getDescription()
    return self:getBackend():describe()
end

function Player:getBackendName()
    return self:getBackend().backend_name
end

--- Multi-line playback report for the diagnostics menu item.
function Player:diagnostics()
    local backend = self:getBackend()
    local lines = {
        _("当前后端：") .. backend.backend_name,
        backend:describe(),
        _("支持格式：") .. table.concat((function()
            local t = {}
            for k, v in pairs(self:getFormats()) do
                if v then t[#t + 1] = k end
            end
            table.sort(t)
            return t
        end)(), " / "),
    }
    if self._backend_err then
        lines[#lines + 1] = _("注意：") .. self._backend_err
    end
    if backend.backend_name == "command" then
        local found = {}
        for _, cand in ipairs(CANDIDATES) do
            if command_exists(cand.bin) then
                found[#found + 1] = cand.bin
            end
        end
        lines[#lines + 1] = _("可用命令行播放器：") .. (#found > 0 and table.concat(found, " / ") or _("无"))
    elseif backend.backend_name == "opensles" then
        lines[#lines + 1] = _("OpenSL ES：所有 Android 设备自带，无需安装")
    end
    return table.concat(lines, "\n")
end

return Player
