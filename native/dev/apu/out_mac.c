/*
 * hakuX native core — the APU's output on macOS: 48 kHz 16-bit stereo on
 * the default output device (an AudioUnit), as out.c does on AAudio.
 *
 * The frame thread pushes each EP frame into a ring; the AudioUnit's render
 * callback drains it. With no device (or NC_AUDIO=0), a thread drains the
 * ring at the device's rate instead: the sound goes nowhere, the APU keeps
 * its timing.
 */
#include "native/dev/apu/apu_int.h"

#include <AudioToolbox/AudioToolbox.h>

#define OUT_RATE 48000
#define OUT_FRAME_BYTES 4   /* a stereo sample: two 16-bit channels */

static struct {
    uint8_t *buf;
    uint32_t cap;
    uint64_t head, tail;     /* bytes written, bytes read */
    int samples;             /* a callback's size, in frames */
    pthread_cond_t *wake;
    AudioComponentInstance unit;
    bool app_paused;
    uint32_t callbacks, short_callbacks;
} g_out;

int apu_out_queued(void)
{
    return (int)(apu_ld_acq(&g_out.head) - apu_ld_acq(&g_out.tail));
}

void apu_out_push(const void *frame, int bytes)
{
    const uint64_t head = g_out.head;
    assert(head + (uint64_t)bytes - apu_ld_acq(&g_out.tail) <= g_out.cap);
    const uint32_t at = (uint32_t)(head % g_out.cap);
    const uint32_t first = MIN((uint32_t)bytes, g_out.cap - at);
    memcpy(g_out.buf + at, frame, first);
    memcpy(g_out.buf, (const uint8_t *)frame + first, (uint32_t)bytes - first);
    apu_st_rel(&g_out.head, head + (uint64_t)bytes);
}

static int pop(uint8_t *out, int bytes)
{
    const uint64_t tail = g_out.tail;
    const int n = (int)MIN((uint64_t)bytes, apu_ld_acq(&g_out.head) - tail);
    const uint32_t at = (uint32_t)(tail % g_out.cap);
    const uint32_t first = MIN((uint32_t)n, g_out.cap - at);
    memcpy(out, g_out.buf + at, first);
    memcpy(out + first, g_out.buf, (uint32_t)n - first);
    apu_st_rel(&g_out.tail, tail + (uint64_t)n);
    return n;
}

void apu_out_stats(uint32_t *callbacks, uint32_t *short_callbacks)
{
    *callbacks = apu_xchg(&g_out.callbacks, 0);
    *short_callbacks = apu_xchg(&g_out.short_callbacks, 0);
}

static void fill(uint8_t *stream, int bytes)
{
    if (nc_paused() || g_out.app_paused) {
        memset(stream, 0, (size_t)bytes);
        return;
    }
    const int n = pop(stream, bytes);
    apu_inc(&g_out.callbacks);
    if (n < bytes) {
        apu_inc(&g_out.short_callbacks);
        memset(stream + n, 0, (size_t)(bytes - n));
    }
    pthread_cond_broadcast(g_out.wake);
}

static OSStatus on_render(void *user, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                          UInt32 frames, AudioBufferList *data)
{
    fill(data->mBuffers[0].mData, (int)(frames * OUT_FRAME_BYTES));
    return noErr;
}

static void *drain_thread(void *arg)
{
    static uint8_t buf[16384];
    const int len = MIN(g_out.samples * OUT_FRAME_BYTES, (int)sizeof(buf));
    const long period_ns = (long)((int64_t)(len / OUT_FRAME_BYTES) * 1000000000LL / OUT_RATE);
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    for (;;) {
        next.tv_nsec += period_ns;
        while (next.tv_nsec >= 1000000000L) {
            next.tv_nsec -= 1000000000L;
            next.tv_sec++;
        }
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
        fill(buf, len);
    }
    return NULL;
}

static bool open_unit(void)
{
    AudioComponentDescription d = { .componentType = kAudioUnitType_Output,
                                    .componentSubType = kAudioUnitSubType_DefaultOutput,
                                    .componentManufacturer = kAudioUnitManufacturer_Apple };
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    if (!comp || AudioComponentInstanceNew(comp, &g_out.unit) != noErr) {
        return false;
    }
    AudioStreamBasicDescription f = { .mSampleRate = OUT_RATE,
                                      .mFormatID = kAudioFormatLinearPCM,
                                      .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                      .mBytesPerPacket = OUT_FRAME_BYTES, .mFramesPerPacket = 1,
                                      .mBytesPerFrame = OUT_FRAME_BYTES, .mChannelsPerFrame = 2,
                                      .mBitsPerChannel = 16 };
    AURenderCallbackStruct cb = { .inputProc = on_render };
    UInt32 max = (UInt32)g_out.samples;
    if (AudioUnitSetProperty(g_out.unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof(f)) ||
        AudioUnitSetProperty(g_out.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                             sizeof(cb))) {
        AudioComponentInstanceDispose(g_out.unit);
        g_out.unit = NULL;
        return false;
    }
    AudioUnitSetProperty(g_out.unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &max,
                         sizeof(max));
    if (AudioUnitInitialize(g_out.unit) != noErr || AudioOutputUnitStart(g_out.unit) != noErr) {
        AudioComponentInstanceDispose(g_out.unit);
        g_out.unit = NULL;
        return false;
    }
    return true;
}

int apu_out_open(int capacity_bytes, int samples, pthread_cond_t *wake)
{
    g_out.buf = calloc(1, (size_t)capacity_bytes);
    g_out.cap = (uint32_t)capacity_bytes;
    g_out.samples = samples;
    g_out.wake = wake;
    const char *e = getenv("NC_AUDIO");
    if ((e && e[0] == '0') || !open_unit()) {
        nc_log("hakuX-apu", "no output device%s: draining without sound", e && e[0] == '0' ? " (NC_AUDIO=0)" : "");
        pthread_t t;
        apu_thread_start(&t, "apu.drain", drain_thread, NULL, false);
    }
    return samples * OUT_FRAME_BYTES;
}

void nc_audio_set_paused(bool on)
{
    g_out.app_paused = on;
}
