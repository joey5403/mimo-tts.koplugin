--[[--
Android OpenSL ES playback backend (LuaJIT FFI).

Plays PCM/WAV audio through ``libOpenSLES.so``, the NDK public audio library
that every Android device ships (Android 2.3+): no external binaries, no
changes to the KOReader app. The library is loaded lazily, so this module is
safe to require on any platform.

OpenSL ES notes:
- Interface handles are pointers to vtable pointers (``SLPlayItf`` etc.).
- ``Enqueue`` does *not* copy the buffer: the PCM string is pinned in
  ``self._pinned`` for the whole playback.
- A buffer is consumed by the sink once played, so the buffer queue state
  (``count``) is a reliable "still playing" signal.
]]

local ffi = require("ffi")
local logger = require("logger")

ffi.cdef([[
typedef uint32_t SLresult;
typedef uint32_t SLuint32;
typedef int32_t  SLint32;
typedef uint32_t SLboolean;

struct SLInterfaceID_;
typedef const struct SLInterfaceID_ *SLInterfaceID;
extern const struct SLInterfaceID_ SL_IID_ENGINE;
extern const struct SLInterfaceID_ SL_IID_PLAY;
extern const struct SLInterfaceID_ SL_IID_ANDROIDSIMPLEBUFFERQUEUE;

typedef struct SLObjectItf_ **SLObjectItf;
struct SLObjectItf_ {
    SLresult (*Realize)(SLObjectItf self, SLboolean async);
    SLresult (*GetInterface)(SLObjectItf self, const struct SLInterfaceID_ *iid, void *out);
    SLresult (*Destroy)(SLObjectItf self);
    void *pad[5];
};

typedef struct SLEngineItf_ **SLEngineItf;
struct SLEngineItf_ {
    void *CreateLEDDevice;
    void *CreateVibraDevice;
    SLresult (*CreateOutputMix)(SLEngineItf self, SLObjectItf *mix, SLuint32 n,
                                const void *ids, const void *req);
    void *pad1[4];
    SLresult (*CreateAudioPlayer)(SLEngineItf self, SLObjectItf *player,
                                  void *audioSrc, void *audioSnk, SLuint32 n,
                                  const void *ids, const void *req);
    void *pad2[5];
};

typedef struct SLPlayItf_ **SLPlayItf;
struct SLPlayItf_ {
    SLresult (*SetPlayState)(SLPlayItf self, SLuint32 state);
    SLresult (*GetPlayState)(SLPlayItf self, SLuint32 *state);
    void *pad[11];
};

typedef struct SLAndroidSimpleBufferQueueState_ {
    SLuint32 count;
    SLuint32 index;
} SLAndroidSimpleBufferQueueState;
typedef struct SLAndroidSimpleBufferQueueItf_ **SLAndroidSimpleBufferQueueItf;
struct SLAndroidSimpleBufferQueueItf_ {
    SLresult (*Enqueue)(SLAndroidSimpleBufferQueueItf self, const void *buf, SLuint32 size);
    SLresult (*Clear)(SLAndroidSimpleBufferQueueItf self);
    SLresult (*GetState)(SLAndroidSimpleBufferQueueItf self, SLAndroidSimpleBufferQueueState *st);
    void *pad[1];
};

struct SLDataLocator_AndroidSimpleBufferQueue_ { SLuint32 locatorType; SLuint32 numBuffers; };
struct SLDataFormat_PCM_ {
    SLuint32 formatType;
    SLuint32 numChannels;
    SLuint32 samplesPerSec; /* in milliHz */
    SLuint32 bitsPerSample;
    SLuint32 containerSize;
    SLuint32 channelMask;
    SLuint32 endianness;
};
struct SLDataLocator_OutputMix_ { SLuint32 locatorType; SLObjectItf outputMix; };
struct SLDataSource_ { void *pLocator; void *pFormat; };
struct SLDataSink_ { void *pLocator; void *pFormat; };

SLresult slCreateEngine(SLObjectItf *engine, SLuint32 numOptions, const void *options,
                        SLuint32 numInterfaces, const void *ids, const void *req);
]])

-- constants (SLES/OpenSLES.h, SLES/OpenSLESAndroid.h)
local SL_BOOLEAN_TRUE = 1
local SL_PLAYSTATE_STOPPED = 1
local SL_PLAYSTATE_PLAYING = 3
local SL_DATAFORMAT_PCM = 1
local SL_DATALOCATOR_OUTPUTMIX = 3
local SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE = 0x800007BD
local SL_BYTEORDER_LITTLEENDIAN = 2
local SL_SPEAKER_FRONT_LEFT = 1
local SL_SPEAKER_FRONT_RIGHT = 2
local SL_SPEAKER_FRONT_CENTER = 4

local OpenSLESPlayer = {}
OpenSLESPlayer.__index = OpenSLESPlayer
OpenSLESPlayer.backend_name = "opensles"
OpenSLESPlayer.accepts = { wav = true, pcm = true, mp3 = false }

--- Load the OpenSL ES library; returns lib or nil, err.
local function load_lib()
    local names = { "libOpenSLES.so", "OpenSLES", "libOpenSLES.so.0" }
    local errs = {}
    for _, name in ipairs(names) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            return lib
        end
        errs[#errs + 1] = tostring(lib)
    end
    return nil, table.concat(errs, "; ")
end

--- Whether this backend can run here (Android or a libOpenSLES.so around).
function OpenSLESPlayer.available()
    local lib = load_lib()
    if not lib then
        return false, "libOpenSLES.so 不可用"
    end
    local ok = pcall(function()
        return lib.slCreateEngine, lib.SL_IID_ENGINE, lib.SL_IID_PLAY,
            lib.SL_IID_ANDROIDSIMPLEBUFFERQUEUE
    end)
    if not ok then
        return false, "libOpenSLES.so 缺少所需符号"
    end
    return true
end

function OpenSLESPlayer:new(o)
    return setmetatable(o or {}, OpenSLESPlayer)
end

--- Parse a WAV file into `{ pcm, rate, channels, bits }`.
function OpenSLESPlayer.parseWav(path)
    local f = io.open(path, "rb")
    if not f then
        return nil, "无法打开音频文件：" .. tostring(path)
    end
    local data = f:read("*a")
    f:close()
    if not data or #data < 44 or data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then
        return nil, "不是 WAV 音频文件"
    end
    local function u16(off)
        local b1, b2 = data:byte(off, off + 1)
        return b1 + b2 * 256
    end
    local function u32(off)
        local b1, b2, b3, b4 = data:byte(off, off + 3)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    local fmt, pcm
    local pos = 13
    while pos + 8 <= #data do
        local id = data:sub(pos, pos + 3)
        local size = u32(pos + 4)
        if id == "fmt " and size >= 16 then
            fmt = {
                format = u16(pos + 8),
                channels = u16(pos + 10),
                rate = u32(pos + 12),
                bits = u16(pos + 22),
            }
        elseif id == "data" then
            pcm = data:sub(pos + 8, math.min(pos + 8 + size - 1, #data))
        end
        pos = pos + 8 + size + (size % 2) -- chunks are 16-bit aligned
    end
    if not fmt or not pcm then
        return nil, "WAV 缺少 fmt/data 块"
    end
    if fmt.format ~= 1 then
        return nil, "只支持 PCM 编码的 WAV"
    end
    return { pcm = pcm, rate = fmt.rate, channels = fmt.channels, bits = fmt.bits or 16 }
end

--- Create the engine and output mix once.
function OpenSLESPlayer:_ensureCore()
    if self._engine then
        return true
    end
    local lib = load_lib()
    if not lib then
        return nil, "libOpenSLES.so 不可用"
    end
    self._lib = lib

    local engine_slot = ffi.new("SLObjectItf[1]")
    if lib.slCreateEngine(engine_slot, 0, nil, 0, nil, nil) ~= 0 then
        return nil, "slCreateEngine 失败"
    end
    local engine = engine_slot[0]
    engine[0][0].Realize(engine, 0)
    local eng_itf_slot = ffi.new("SLEngineItf[1]")
    engine[0][0].GetInterface(engine, lib.SL_IID_ENGINE, eng_itf_slot)
    local engine_itf = eng_itf_slot[0]

    local mix_slot = ffi.new("SLObjectItf[1]")
    engine_itf[0][0].CreateOutputMix(engine_itf, mix_slot, 0, nil, nil)
    local mix = mix_slot[0]
    mix[0][0].Realize(mix, 0)

    self._engine, self._engine_itf, self._mix = engine, engine_itf, mix
    return true
end

--- Create a fresh audio player for one WAV format.
function OpenSLESPlayer:_ensurePlayer(fmt)
    -- a fresh player per format avoids stale-state bugs at negligible cost
    self:_destroyPlayer()
    local lib = self._lib

    local bufq_loc = ffi.new("struct SLDataLocator_AndroidSimpleBufferQueue_",
        SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, 2)
    local pcm_fmt = ffi.new("struct SLDataFormat_PCM_",
        SL_DATAFORMAT_PCM,
        fmt.channels,
        fmt.rate * 1000, -- samplesPerSec is in milliHz
        fmt.bits,
        fmt.bits,
        fmt.channels == 1 and SL_SPEAKER_FRONT_CENTER
            or (SL_SPEAKER_FRONT_LEFT + SL_SPEAKER_FRONT_RIGHT),
        SL_BYTEORDER_LITTLEENDIAN)
    local src = ffi.new("struct SLDataSource_", bufq_loc, pcm_fmt)
    local outmix_loc = ffi.new("struct SLDataLocator_OutputMix_", SL_DATALOCATOR_OUTPUTMIX, self._mix)
    local snk = ffi.new("struct SLDataSink_", outmix_loc, nil)

    local ids = ffi.new("SLInterfaceID[1]")
    ids[0] = lib.SL_IID_ANDROIDSIMPLEBUFFERQUEUE
    local reqs = ffi.new("SLboolean[1]", SL_BOOLEAN_TRUE)

    local player_slot = ffi.new("SLObjectItf[1]")
    local res = self._engine_itf[0][0].CreateAudioPlayer(
        self._engine_itf, player_slot, src, snk, 1, ids, reqs)
    if res ~= 0 then
        return nil, "CreateAudioPlayer 失败"
    end
    local player = player_slot[0]
    player[0][0].Realize(player, 0)

    local play_slot = ffi.new("SLPlayItf[1]")
    player[0][0].GetInterface(player, lib.SL_IID_PLAY, play_slot)
    local bufq_slot = ffi.new("SLAndroidSimpleBufferQueueItf[1]")
    player[0][0].GetInterface(player, lib.SL_IID_ANDROIDSIMPLEBUFFERQUEUE, bufq_slot)

    self._player, self._play, self._bufq = player, play_slot[0], bufq_slot[0]
    self._fmt = fmt
    return true
end

function OpenSLESPlayer:_destroyPlayer()
    if self._player then
        pcall(function() self._player[0][0].Destroy(self._player) end)
    end
    self._player, self._play, self._bufq = nil, nil, nil
    self._pinned = nil
end

--- Play a WAV file; returns true or nil, err.
function OpenSLESPlayer:play(file_path)
    local wav, err = self.parseWav(file_path)
    if not wav then
        return nil, err
    end
    local ok
    ok, err = self:_ensureCore()
    if not ok then
        return nil, err
    end
    ok, err = self:_ensurePlayer(wav)
    if not ok then
        return nil, err
    end
    -- OpenSL ES keeps a reference to the buffer while playing: pin it
    self._pinned = wav.pcm
    self._play[0][0].SetPlayState(self._play, SL_PLAYSTATE_STOPPED)
    self._bufq[0][0].Clear(self._bufq)
    self._bufq[0][0].Enqueue(self._bufq, wav.pcm, #wav.pcm)
    self._play[0][0].SetPlayState(self._play, SL_PLAYSTATE_PLAYING)
    logger.dbg("OpenSLES: playing", file_path, #wav.pcm, "bytes of PCM")
    return true
end

function OpenSLESPlayer:isBusy()
    if not self._bufq then
        return false
    end
    local st = ffi.new("SLAndroidSimpleBufferQueueState[1]")
    self._bufq[0][0].GetState(self._bufq, st)
    return st[0].count > 0
end

function OpenSLESPlayer:stop()
    if self._play and self._bufq then
        self._play[0][0].SetPlayState(self._play, SL_PLAYSTATE_STOPPED)
        self._bufq[0][0].Clear(self._bufq)
    end
    self._pinned = nil
end

--- Formats this backend accepts, e.g. `{ wav = true }`.
function OpenSLESPlayer:getFormats()
    return self.accepts
end

function OpenSLESPlayer:describe()
    return "OpenSL ES（安卓原生，LuaJIT FFI）"
end

return OpenSLESPlayer
