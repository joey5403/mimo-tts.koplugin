/* Mock of Android's libOpenSLES.so for headless testing of the OpenSL ES
 * playback backend.
 *
 * IMPORTANT: the vtables below follow the *real* NDK headers slot by slot
 * (SLES/OpenSLES.h and SLES/OpenSLESAndroid.h), and the SL_IID_* symbols are
 * exported as pointer variables exactly like the real library does
 * (const SLInterfaceID SL_IID_ENGINE = &...).  If openslesplayer.lua drifts
 * from the real ABI, the wrong slot is called and the poison stub aborts
 * with a loud message -- so keep this file in sync with the NDK headers,
 * NOT with whatever openslesplayer.lua happens to declare.
 *
 * Test hooks:
 *   mock_reset(), mock_enqueued_total(), mock_busy(), mock_play_state(),
 *   mock_buffers_seen(), mock_set_timescale(), mock_get_timescale()
 *
 * Busy semantics: an enqueued buffer is "playing" for bytes / (24000*2)
 * seconds (24kHz mono PCM16) -- realistic timing without real audio output.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef uint32_t SLresult;
typedef uint32_t SLuint32;
typedef int32_t  SLint32;
typedef uint32_t SLboolean;
#define SL_RESULT_SUCCESS 0
#define SL_RESULT_PARAMETER_INVALID 1
#define SL_BOOLEAN_TRUE 1

/* constant values straight from SLES/OpenSLES.h + SLES/OpenSLESAndroid.h;
   validated in eng_create_* like wilhelm's checkDataSource/checkDataSink,
   so a wrong constant fails the battery instead of crashing a device */
#define SL_DATAFORMAT_MIME   1u
#define SL_DATAFORMAT_PCM    2u
#define SL_DATALOCATOR_OUTPUTMIX 4u
#define SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE 0x800007BDu
#define SL_BYTEORDER_LITTLEENDIAN 2u

struct SLDataSource_ { void *pLocator; void *pFormat; };
struct SLDataLocator_BufQ_ { SLuint32 locatorType; SLuint32 numBuffers; };
struct SLDataLocator_OutputMix_ { SLuint32 locatorType; void *outputMix; };
struct SLDataFormat_PCM_ {
    SLuint32 formatType, numChannels, samplesPerSec, bitsPerSample;
    SLuint32 containerSize, channelMask, endianness;
};

/* ---- interface IDs: exported as pointer variables (real-lib shape) ---- */
struct SLInterfaceID_ { int dummy[4]; };
typedef const struct SLInterfaceID_ *SLInterfaceID;
static const struct SLInterfaceID_ iid_engine_v = {{0}};
static const struct SLInterfaceID_ iid_play_v   = {{0}};
static const struct SLInterfaceID_ iid_bufq_v   = {{0}};
const SLInterfaceID SL_IID_ENGINE  = &iid_engine_v;
const SLInterfaceID SL_IID_PLAY    = &iid_play_v;
const SLInterfaceID SL_IID_ANDROIDSIMPLEBUFFERQUEUE = &iid_bufq_v;

/* ---- real NDK vtable layouts (interface handles are pointers to
   vtable pointers, like the real ABI) ---- */
typedef struct SLObjectItf_ **SLObjectItf;
struct SLObjectItf_ {
    SLresult (*Realize)(SLObjectItf self, SLboolean async);
    void *Resume;
    void *GetState;
    SLresult (*GetInterface)(SLObjectItf self, const SLInterfaceID iid, void *out);
    void *RegisterCallback;
    void *AbortAsyncOperation;
    void (*Destroy)(SLObjectItf self);
    void *SetPriority;
    void *GetPriority;
    void *SetLossOfControlInterfaces;
};

typedef struct SLEngineItf_ **SLEngineItf;
struct SLEngineItf_ {
    void *CreateLEDDevice;
    void *CreateVibraDevice;
    SLresult (*CreateAudioPlayer)(SLEngineItf self, SLObjectItf *player,
        void *audioSrc, void *audioSnk, SLuint32 n,
        const SLInterfaceID *ids, const SLboolean *req);
    void *CreateAudioRecorder;
    void *CreateMidiPlayer;
    void *CreateListener;
    void *Create3DGroup;
    SLresult (*CreateOutputMix)(SLEngineItf self, SLObjectItf *mix, SLuint32 n,
        const SLInterfaceID *ids, const SLboolean *req);
    void *CreateMetadataExtractor;
    void *CreateExtensionObject;
    void *QueryNumSupportedInterfaces;
    void *QuerySupportedInterfaces;
    void *QueryNumSupportedExtensions;
    void *QuerySupportedExtension;
    void *IsExtensionSupported;
};

typedef struct SLPlayItf_ **SLPlayItf;
struct SLPlayItf_ {
    SLresult (*SetPlayState)(SLPlayItf self, SLuint32 state);
    SLresult (*GetPlayState)(SLPlayItf self, SLuint32 *state);
    void *pad[10];
};

typedef struct SLAndroidSimpleBufferQueueState_ { SLuint32 count; SLuint32 index; } SLAndroidSimpleBufferQueueState;
typedef struct SLAndroidSimpleBufferQueueItf_ **SLAndroidSimpleBufferQueueItf;
struct SLAndroidSimpleBufferQueueItf_ {
    SLresult (*Enqueue)(SLAndroidSimpleBufferQueueItf self, const void *buf, SLuint32 size);
    SLresult (*Clear)(SLAndroidSimpleBufferQueueItf self);
    SLresult (*GetState)(SLAndroidSimpleBufferQueueItf self, SLAndroidSimpleBufferQueueState *state);
    void *RegisterCallback;
};

/* called through the wrong vtable slot: the caller drifted from the ABI */
static void poison(void) {
    fprintf(stderr, "mocksl: call through a wrong vtable slot (ABI drift!)\n");
    abort();
}

/* ---- mock state ---- */
static double busy_until = 0;
static uint64_t enqueued_total = 0;
static uint32_t queue_count = 0;
static uint32_t play_state = 1; /* STOPPED=1 PAUSED=2 PLAYING=3 */
static uint32_t enq_index = 0;
static uint32_t fmt_rate_milli = 24000000, fmt_channels = 1, fmt_bits = 16;

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double time_scale = 1.0;
void mock_set_timescale(double s) { time_scale = s > 0 ? s : 1.0; }
double mock_get_timescale(void) { return time_scale; }

void mock_reset(void) { busy_until = 0; enqueued_total = 0; queue_count = 0; play_state = 1; enq_index = 0; }
uint64_t mock_enqueued_total(void) { return enqueued_total; }
int mock_busy(void) { return queue_count > 0 && now_s() < busy_until; }
uint32_t mock_play_state(void) { return play_state; }
uint32_t mock_buffers_seen(void) { return enq_index; }
uint32_t mock_rate_milli(void) { return fmt_rate_milli; }

/* ---- vtable implementations ---- */
static SLresult obj_realize(SLObjectItf self, SLboolean async) { (void)self; (void)async; return SL_RESULT_SUCCESS; }
static void obj_destroy(SLObjectItf self) { (void)self; }

static SLresult play_set_state(SLPlayItf self, SLuint32 state) {
    (void)self; play_state = state;
    if (state == 1) { queue_count = 0; busy_until = 0; }
    return SL_RESULT_SUCCESS;
}
static SLresult play_get_state(SLPlayItf self, SLuint32 *state) { (void)self; *state = play_state; return SL_RESULT_SUCCESS; }

static SLresult bufq_enqueue(SLAndroidSimpleBufferQueueItf self, const void *buf, SLuint32 size) {
    (void)self; (void)buf;
    enqueued_total += size; enq_index++; queue_count = 1;
    busy_until = now_s() + (double)size / (fmt_rate_milli / 1000.0 * fmt_channels * fmt_bits / 8.0) * time_scale;
    return SL_RESULT_SUCCESS;
}
static SLresult bufq_clear(SLAndroidSimpleBufferQueueItf self) { (void)self; queue_count = 0; busy_until = 0; return SL_RESULT_SUCCESS; }
static SLresult bufq_get_state(SLAndroidSimpleBufferQueueItf self, SLAndroidSimpleBufferQueueState *st) {
    (void)self; st->count = mock_busy() ? 1 : 0; st->index = enq_index; return SL_RESULT_SUCCESS;
}

static SLresult get_interface(SLObjectItf self, const SLInterfaceID iid, void *out);
static SLresult eng_create_output_mix(SLEngineItf self, SLObjectItf *mix, SLuint32 n,
                                      const SLInterfaceID *ids, const SLboolean *req);
static SLresult eng_create_audio_player(SLEngineItf self, SLObjectItf *player, void *src, void *snk,
                                        SLuint32 n, const SLInterfaceID *ids, const SLboolean *req);

static struct SLObjectItf_ obj_vt = {
    obj_realize, (void *)poison, (void *)poison, get_interface,
    (void *)poison, (void *)poison, obj_destroy,
    (void *)poison, (void *)poison, (void *)poison,
};
static struct SLObjectItf_ *obj_vt_p = &obj_vt;
static struct SLPlayItf_ play_vt = {
    play_set_state, play_get_state,
    {(void *)poison, (void *)poison, (void *)poison, (void *)poison, (void *)poison,
     (void *)poison, (void *)poison, (void *)poison, (void *)poison, (void *)poison},
};
static struct SLPlayItf_ *play_vt_p = &play_vt;
static struct SLAndroidSimpleBufferQueueItf_ bufq_vt = {
    bufq_enqueue, bufq_clear, bufq_get_state, (void *)poison,
};
static struct SLAndroidSimpleBufferQueueItf_ *bufq_vt_p = &bufq_vt;
static struct SLEngineItf_ engine_vt = {
    (void *)poison, (void *)poison, eng_create_audio_player,
    (void *)poison, (void *)poison, (void *)poison, (void *)poison, eng_create_output_mix,
    (void *)poison, (void *)poison, (void *)poison, (void *)poison,
    (void *)poison, (void *)poison, (void *)poison,
};
static struct SLEngineItf_ *engine_vt_p = &engine_vt;

static SLObjectItf engine_obj  = &obj_vt_p;
static SLObjectItf mix_obj     = &obj_vt_p;
static SLObjectItf player_obj  = &obj_vt_p;
static SLEngineItf engine_itf  = &engine_vt_p;
static SLPlayItf play_itf      = &play_vt_p;
static SLAndroidSimpleBufferQueueItf bufq_itf = &bufq_vt_p;

static SLresult get_interface(SLObjectItf self, const SLInterfaceID iid, void *out) {
    (void)self;
    if (iid == &iid_engine_v) { *(SLEngineItf *)out = engine_itf; return SL_RESULT_SUCCESS; }
    if (iid == &iid_play_v)   { *(SLPlayItf *)out = play_itf; return SL_RESULT_SUCCESS; }
    if (iid == &iid_bufq_v)   { *(SLAndroidSimpleBufferQueueItf *)out = bufq_itf; return SL_RESULT_SUCCESS; }
    return SL_RESULT_PARAMETER_INVALID;
}
static SLresult eng_create_output_mix(SLEngineItf self, SLObjectItf *mix, SLuint32 n,
                                      const SLInterfaceID *ids, const SLboolean *req) {
    (void)self; (void)n; (void)ids; (void)req; *mix = mix_obj; return SL_RESULT_SUCCESS;
}
static SLresult eng_create_audio_player(SLEngineItf self, SLObjectItf *player, void *src, void *snk,
                                        SLuint32 n, const SLInterfaceID *ids, const SLboolean *req) {
    (void)self; (void)n; (void)ids; (void)req;
    if (!src || !snk || !player) return SL_RESULT_PARAMETER_INVALID;
    /* checkDataSource: the source must be a simple buffer queue of PCM */
    const struct SLDataSource_ *s = (const struct SLDataSource_ *)src;
    const struct SLDataLocator_BufQ_ *loc = (const struct SLDataLocator_BufQ_ *)s->pLocator;
    const struct SLDataFormat_PCM_ *fmt = (const struct SLDataFormat_PCM_ *)s->pFormat;
    if (!loc || loc->locatorType != SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE)
        return SL_RESULT_PARAMETER_INVALID;
    if (!fmt || fmt->formatType != SL_DATAFORMAT_PCM)
        return SL_RESULT_PARAMETER_INVALID;
    if (fmt->numChannels < 1 || fmt->numChannels > 2 || fmt->bitsPerSample != 16 ||
        fmt->containerSize != fmt->bitsPerSample ||
        fmt->samplesPerSec < 8000000u || fmt->samplesPerSec > 192000000u ||
        fmt->endianness != SL_BYTEORDER_LITTLEENDIAN)
        return SL_RESULT_PARAMETER_INVALID;
    /* checkDataSink: the sink must be an output mix */
    const struct SLDataSource_ *snk_s = (const struct SLDataSource_ *)snk;
    const struct SLDataLocator_OutputMix_ *snk_loc =
        (const struct SLDataLocator_OutputMix_ *)snk_s->pLocator;
    if (!snk_loc || snk_loc->locatorType != SL_DATALOCATOR_OUTPUTMIX)
        return SL_RESULT_PARAMETER_INVALID;
    /* remember the declared format: tests read it back via mock_rate_milli() */
    fmt_rate_milli = fmt->samplesPerSec;
    fmt_channels = fmt->numChannels;
    fmt_bits = fmt->bitsPerSample;
    *player = player_obj; return SL_RESULT_SUCCESS;
}

SLresult slCreateEngine(SLObjectItf *engine, SLuint32 nopts, const void *opts,
                        SLuint32 nif, const void *ids, const void *req) {
    (void)nopts; (void)opts; (void)nif; (void)ids; (void)req;
    *engine = engine_obj;
    return SL_RESULT_SUCCESS;
}
