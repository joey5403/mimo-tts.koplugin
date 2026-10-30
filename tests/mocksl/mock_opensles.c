/* Mock of Android's libOpenSLES.so for headless testing of the OpenSL ES
 * playback backend. Implements the exact vtable layouts used by
 * openslesplayer.lua and exposes test hooks:
 *   mock_reset(), mock_enqueued_total(), mock_busy(), mock_play_state()
 *
 * Busy semantics: an enqueued buffer is "playing" for bytes / (24000*2)
 * seconds (24kHz mono PCM16) -- realistic timing without real audio output.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef uint32_t SLresult;
typedef uint32_t SLuint32;
typedef int32_t  SLint32;
typedef uint32_t SLboolean;
#define SL_RESULT_SUCCESS 0
#define SL_BOOLEAN_TRUE 1

/* exported interface IDs (data symbols, resolved via dlsym) */
struct SLInterfaceID_ { int dummy[4]; };
const struct SLInterfaceID_ SL_IID_ENGINE  = {{0}};
const struct SLInterfaceID_ SL_IID_PLAY    = {{0}};
const struct SLInterfaceID_ SL_IID_ANDROIDSIMPLEBUFFERQUEUE = {{0}};
#define IID_ENGINE  ((const struct SLInterfaceID_ *)&SL_IID_ENGINE)
#define IID_PLAY    ((const struct SLInterfaceID_ *)&SL_IID_PLAY)
#define IID_BUFQ    ((const struct SLInterfaceID_ *)&SL_IID_ANDROIDSIMPLEBUFFERQUEUE)

/* interface handles are pointers-to-vtable-pointer, like the real ABI */
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
    SLresult (*CreateOutputMix)(SLEngineItf self, SLObjectItf *mix, SLuint32 n, const void *ids, const void *req);
    void *pad1[4];
    SLresult (*CreateAudioPlayer)(SLEngineItf self, SLObjectItf *player,
        void *audioSrc, void *audioSnk, SLuint32 n, const void *ids, const void *req);
    void *pad2[5];
};

typedef struct SLPlayItf_ **SLPlayItf;
struct SLPlayItf_ {
    SLresult (*SetPlayState)(SLPlayItf self, SLuint32 state);
    SLresult (*GetPlayState)(SLPlayItf self, SLuint32 *state);
    void *pad[11];
};

typedef struct SLAndroidSimpleBufferQueueState_ { SLuint32 count; SLuint32 index; } SLAndroidSimpleBufferQueueState;
typedef struct SLAndroidSimpleBufferQueueItf_ **SLAndroidSimpleBufferQueueItf;
struct SLAndroidSimpleBufferQueueItf_ {
    SLresult (*Enqueue)(SLAndroidSimpleBufferQueueItf self, const void *buf, SLuint32 size);
    SLresult (*Clear)(SLAndroidSimpleBufferQueueItf self);
    SLresult (*GetState)(SLAndroidSimpleBufferQueueItf self, SLAndroidSimpleBufferQueueState *state);
    void *pad[1];
};

/* ---- mock state ---- */
static double busy_until = 0;
static uint64_t enqueued_total = 0;
static uint32_t queue_count = 0;
static uint32_t play_state = 1; /* STOPPED=1 PAUSED=2 PLAYING=3 */
static uint32_t enq_index = 0;

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

/* ---- vtables ---- */
static SLresult get_interface(SLObjectItf self, const struct SLInterfaceID_ *iid, void *out);
static SLresult obj_realize(SLObjectItf self, SLboolean async) { (void)self; (void)async; return SL_RESULT_SUCCESS; }
static SLresult obj_destroy(SLObjectItf self) { (void)self; return SL_RESULT_SUCCESS; }

static SLresult play_set_state(SLPlayItf self, SLuint32 state) {
    (void)self; play_state = state;
    if (state == 1) { queue_count = 0; busy_until = 0; }
    return SL_RESULT_SUCCESS;
}
static SLresult play_get_state(SLPlayItf self, SLuint32 *state) { (void)self; *state = play_state; return SL_RESULT_SUCCESS; }

static SLresult bufq_enqueue(SLAndroidSimpleBufferQueueItf self, const void *buf, SLuint32 size) {
    (void)self; (void)buf;
    enqueued_total += size; enq_index++; queue_count = 1;
    busy_until = now_s() + (double)size / 48000.0 * time_scale;
    return SL_RESULT_SUCCESS;
}
static SLresult bufq_clear(SLAndroidSimpleBufferQueueItf self) { (void)self; queue_count = 0; busy_until = 0; return SL_RESULT_SUCCESS; }
static SLresult bufq_get_state(SLAndroidSimpleBufferQueueItf self, SLAndroidSimpleBufferQueueState *st) {
    (void)self; st->count = mock_busy() ? 1 : 0; st->index = enq_index; return SL_RESULT_SUCCESS;
}

static SLresult eng_create_output_mix(SLEngineItf self, SLObjectItf *mix, SLuint32 n, const void *ids, const void *req);
static SLresult eng_create_audio_player(SLEngineItf self, SLObjectItf *player, void *src, void *snk,
                                        SLuint32 n, const void *ids, const void *req);

static struct SLObjectItf_ obj_vt = { obj_realize, get_interface, obj_destroy, {0} };
static struct SLObjectItf_ *obj_vt_p = &obj_vt;
static struct SLPlayItf_ play_vt = { play_set_state, play_get_state, {0} };
static struct SLPlayItf_ *play_vt_p = &play_vt;
static struct SLAndroidSimpleBufferQueueItf_ bufq_vt = { bufq_enqueue, bufq_clear, bufq_get_state, {0} };
static struct SLAndroidSimpleBufferQueueItf_ *bufq_vt_p = &bufq_vt;
static struct SLEngineItf_ engine_vt = {
    NULL, NULL, eng_create_output_mix, {0, 0, 0, 0}, eng_create_audio_player, {0, 0, 0, 0, 0}
};
static struct SLEngineItf_ *engine_vt_p = &engine_vt;

static SLObjectItf engine_obj  = &obj_vt_p;
static SLObjectItf mix_obj     = &obj_vt_p;
static SLObjectItf player_obj  = &obj_vt_p;
static SLEngineItf engine_itf  = &engine_vt_p;
static SLPlayItf play_itf      = &play_vt_p;
static SLAndroidSimpleBufferQueueItf bufq_itf = &bufq_vt_p;

static SLresult get_interface(SLObjectItf self, const struct SLInterfaceID_ *iid, void *out) {
    (void)self;
    if (iid == IID_ENGINE) { *(SLEngineItf *)out = engine_itf; return SL_RESULT_SUCCESS; }
    if (iid == IID_PLAY)   { *(SLPlayItf *)out = play_itf; return SL_RESULT_SUCCESS; }
    if (iid == IID_BUFQ)   { *(SLAndroidSimpleBufferQueueItf *)out = bufq_itf; return SL_RESULT_SUCCESS; }
    return 1;
}
static SLresult eng_create_output_mix(SLEngineItf self, SLObjectItf *mix, SLuint32 n, const void *ids, const void *req) {
    (void)self; (void)n; (void)ids; (void)req; *mix = mix_obj; return SL_RESULT_SUCCESS;
}
static SLresult eng_create_audio_player(SLEngineItf self, SLObjectItf *player, void *src, void *snk,
                                        SLuint32 n, const void *ids, const void *req) {
    (void)self; (void)src; (void)snk; (void)n; (void)ids; (void)req; *player = player_obj; return SL_RESULT_SUCCESS;
}

SLresult slCreateEngine(SLObjectItf *engine, SLuint32 nopts, const void *opts,
                        SLuint32 nif, const void *ids, const void *req) {
    (void)nopts; (void)opts; (void)nif; (void)ids; (void)req;
    *engine = engine_obj;
    return SL_RESULT_SUCCESS;
}
