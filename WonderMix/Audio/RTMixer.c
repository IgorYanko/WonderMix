#include "RTMixer.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RT_MIXER_SLOT_SETS 2

/// A dropout is declared when the gap between two IO cycles exceeds the expected
/// cycle duration by this factor.
#define RT_MIXER_DROPOUT_FACTOR 1.5

struct RTMixerChannel {
    _Atomic float gain;
    _Atomic float peak;
};

typedef struct RTDeviceMixStats {
    _Atomic uint64_t ioCycles;
    _Atomic uint64_t silentCycles;
    _Atomic uint64_t emptyInputCycles;
    _Atomic uint64_t clipCycles;
    _Atomic uint64_t dropoutCount;
    _Atomic uint64_t overloadCount;
    _Atomic uint64_t ioStoppedCount;
    _Atomic uint64_t maxGapNanos;
    _Atomic uint64_t lastProcessNanos;
    _Atomic uint64_t maxProcessNanos;
    _Atomic uint32_t lastFrameCount;
    _Atomic uint32_t lastInputChannels;
    _Atomic uint32_t lastOutputChannels;
} RTDeviceMixStats;

struct RTDeviceMix {
    RTTapSlot slots[RT_MIXER_SLOT_SETS][RT_MIXER_MAX_SLOTS];
    _Atomic uint32_t slotCounts[RT_MIXER_SLOT_SETS];
    _Atomic uint32_t activeSet;
    /// Set index the IO thread most recently finished reading, so a publisher can tell
    /// when the other set is free to overwrite.
    _Atomic uint32_t lastUsedSet;
    _Atomic uint32_t expectedInputChannels;
    _Atomic bool enabled;
    _Atomic double sampleRate;
    _Atomic uint64_t lastHostTime;
    uint32_t timebaseNumer;
    uint32_t timebaseDenom;
    RTDeviceMixStats stats;
};

/// One destination channel in the output buffer list, resolved once per IO cycle so
/// the inner loop stays a plain strided write.
typedef struct RTOutputTarget {
    float *base;
    uint32_t stride;
} RTOutputTarget;

//==================================================================================
#pragma mark - Channel

RTMixerChannel *RTMixerChannel_Create(float gain) {
    RTMixerChannel *channel = calloc(1, sizeof(RTMixerChannel));
    if (channel == NULL) {
        return NULL;
    }
    atomic_store_explicit(&channel->gain, gain, memory_order_relaxed);
    atomic_store_explicit(&channel->peak, 0.0f, memory_order_relaxed);
    return channel;
}

void RTMixerChannel_Destroy(RTMixerChannel *channel) {
    free(channel);
}

void RTMixerChannel_SetGain(RTMixerChannel *channel, float gain) {
    atomic_store_explicit(&channel->gain, gain, memory_order_relaxed);
}

float RTMixerChannel_GetGain(const RTMixerChannel *channel) {
    return atomic_load_explicit(&channel->gain, memory_order_relaxed);
}

float RTMixerChannel_GetPeak(const RTMixerChannel *channel) {
    return atomic_load_explicit(&channel->peak, memory_order_relaxed);
}

static inline void RTMixerChannel_SetPeak(RTMixerChannel *channel, float peak) {
    atomic_store_explicit(&channel->peak, peak, memory_order_relaxed);
}

//==================================================================================
#pragma mark - Device mix lifecycle

RTDeviceMix *RTMixer_DeviceMixCreate(void) {
    RTDeviceMix *mix = calloc(1, sizeof(RTDeviceMix));
    if (mix == NULL) {
        return NULL;
    }

    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) {
        timebase.numer = 1;
        timebase.denom = 1;
    }
    mix->timebaseNumer = timebase.numer;
    mix->timebaseDenom = timebase.denom;

    atomic_store_explicit(&mix->activeSet, 0, memory_order_relaxed);
    atomic_store_explicit(&mix->lastUsedSet, 0, memory_order_relaxed);
    atomic_store_explicit(&mix->slotCounts[0], 0, memory_order_relaxed);
    atomic_store_explicit(&mix->slotCounts[1], 0, memory_order_relaxed);
    atomic_store_explicit(&mix->expectedInputChannels, 0, memory_order_relaxed);
    atomic_store_explicit(&mix->enabled, false, memory_order_relaxed);
    atomic_store_explicit(&mix->sampleRate, 48000.0, memory_order_relaxed);
    atomic_store_explicit(&mix->lastHostTime, 0, memory_order_relaxed);
    return mix;
}

void RTMixer_DeviceMixDestroy(RTDeviceMix *mix) {
    free(mix);
}

void RTMixer_DeviceMixPublishSlots(
    RTDeviceMix *mix,
    const RTTapSlot *slots,
    uint32_t slotCount,
    uint32_t expectedInputChannels
) {
    if (slotCount > RT_MIXER_MAX_SLOTS) {
        slotCount = RT_MIXER_MAX_SLOTS;
    }

    const uint32_t current = atomic_load_explicit(&mix->activeSet, memory_order_relaxed);
    const uint32_t target = current == 0 ? 1 : 0;

    // Two publishes in quick succession could otherwise overwrite the set an in-flight
    // IO cycle is still reading. Wait (off the real-time thread) until the IO thread has
    // moved on to the current set, with a short timeout in case it is not ticking.
    if (atomic_load_explicit(&mix->enabled, memory_order_relaxed)) {
        for (int attempt = 0; attempt < 50; ++attempt) {
            if (atomic_load_explicit(&mix->lastUsedSet, memory_order_acquire) == current) {
                break;
            }
            usleep(100);
        }
    }

    if (slots != NULL && slotCount > 0) {
        memcpy(mix->slots[target], slots, (size_t)slotCount * sizeof(RTTapSlot));
    }
    atomic_store_explicit(&mix->slotCounts[target], slotCount, memory_order_relaxed);
    atomic_store_explicit(&mix->expectedInputChannels, expectedInputChannels, memory_order_relaxed);

    // Release so the IO thread sees the slot writes before the swap.
    atomic_store_explicit(&mix->activeSet, target, memory_order_release);
}

void RTMixer_DeviceMixSetSampleRate(RTDeviceMix *mix, double sampleRate) {
    if (sampleRate <= 0.0) {
        return;
    }
    atomic_store_explicit(&mix->sampleRate, sampleRate, memory_order_relaxed);
}

void RTMixer_DeviceMixSetEnabled(RTDeviceMix *mix, bool enabled) {
    if (!enabled) {
        atomic_store_explicit(&mix->lastHostTime, 0, memory_order_relaxed);
    }
    atomic_store_explicit(&mix->enabled, enabled, memory_order_relaxed);
}

void RTMixer_DeviceMixResetStats(RTDeviceMix *mix) {
    memset(&mix->stats, 0, sizeof(RTDeviceMixStats));
    atomic_store_explicit(&mix->lastHostTime, 0, memory_order_relaxed);
}

void RTMixer_DeviceMixNoteOverload(RTDeviceMix *mix) {
    atomic_fetch_add_explicit(&mix->stats.overloadCount, 1, memory_order_relaxed);
}

void RTMixer_DeviceMixNoteIOStopped(RTDeviceMix *mix) {
    atomic_fetch_add_explicit(&mix->stats.ioStoppedCount, 1, memory_order_relaxed);
}

void RTMixer_DeviceMixSnapshot(const RTDeviceMix *mix, RTDeviceMixSnapshot *outSnapshot) {
    const RTDeviceMixStats *stats = &mix->stats;
    outSnapshot->ioCycles = atomic_load_explicit(&stats->ioCycles, memory_order_relaxed);
    outSnapshot->silentCycles = atomic_load_explicit(&stats->silentCycles, memory_order_relaxed);
    outSnapshot->emptyInputCycles =
        atomic_load_explicit(&stats->emptyInputCycles, memory_order_relaxed);
    outSnapshot->clipCycles = atomic_load_explicit(&stats->clipCycles, memory_order_relaxed);
    outSnapshot->dropoutCount = atomic_load_explicit(&stats->dropoutCount, memory_order_relaxed);
    outSnapshot->overloadCount = atomic_load_explicit(&stats->overloadCount, memory_order_relaxed);
    outSnapshot->ioStoppedCount =
        atomic_load_explicit(&stats->ioStoppedCount, memory_order_relaxed);
    outSnapshot->maxGapNanos = atomic_load_explicit(&stats->maxGapNanos, memory_order_relaxed);
    outSnapshot->lastProcessNanos =
        atomic_load_explicit(&stats->lastProcessNanos, memory_order_relaxed);
    outSnapshot->maxProcessNanos =
        atomic_load_explicit(&stats->maxProcessNanos, memory_order_relaxed);
    outSnapshot->lastFrameCount = atomic_load_explicit(&stats->lastFrameCount, memory_order_relaxed);
    outSnapshot->lastInputChannels =
        atomic_load_explicit(&stats->lastInputChannels, memory_order_relaxed);
    outSnapshot->lastOutputChannels =
        atomic_load_explicit(&stats->lastOutputChannels, memory_order_relaxed);

    const uint32_t active = atomic_load_explicit(&mix->activeSet, memory_order_acquire);
    outSnapshot->publishedSlotCount =
        atomic_load_explicit(&mix->slotCounts[active], memory_order_relaxed);
    outSnapshot->expectedInputChannels =
        atomic_load_explicit(&mix->expectedInputChannels, memory_order_relaxed);
    outSnapshot->enabled = atomic_load_explicit(&mix->enabled, memory_order_relaxed);
}

//==================================================================================
#pragma mark - Real-time path

static inline uint64_t RTHostTicksToNanos(const RTDeviceMix *mix, uint64_t ticks) {
    if (mix->timebaseDenom == 0) {
        return ticks;
    }
    // Split to keep the multiply from overflowing on large tick deltas.
    const uint64_t whole = ticks / mix->timebaseDenom;
    const uint64_t remainder = ticks % mix->timebaseDenom;
    return whole * mix->timebaseNumer
        + (remainder * mix->timebaseNumer) / mix->timebaseDenom;
}

static inline void RTUpdateMax(_Atomic uint64_t *slot, uint64_t value) {
    uint64_t current = atomic_load_explicit(slot, memory_order_relaxed);
    while (value > current) {
        if (atomic_compare_exchange_weak_explicit(
                slot, &current, value, memory_order_relaxed, memory_order_relaxed)) {
            return;
        }
    }
}

/// Zeroes every output buffer and resolves up to two writable destination channels.
static uint32_t RTPrepareOutput(
    AudioBufferList *output,
    RTOutputTarget targets[2],
    uint32_t *outTotalChannels,
    uint32_t *outFrameCount
) {
    uint32_t targetCount = 0;
    uint32_t totalChannels = 0;
    uint32_t frameCount = UINT32_MAX;

    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        const AudioBuffer buffer = output->mBuffers[b];
        if (buffer.mData == NULL || buffer.mDataByteSize == 0) {
            continue;
        }
        memset(buffer.mData, 0, buffer.mDataByteSize);

        const uint32_t channels = buffer.mNumberChannels;
        if (channels == 0) {
            continue;
        }
        totalChannels += channels;

        const uint32_t frames =
            buffer.mDataByteSize / ((uint32_t)sizeof(float) * channels);
        if (frames < frameCount) {
            frameCount = frames;
        }

        float *data = (float *)buffer.mData;
        for (uint32_t c = 0; c < channels && targetCount < 2; ++c) {
            targets[targetCount].base = data + c;
            targets[targetCount].stride = channels;
            targetCount += 1;
        }
    }

    *outTotalChannels = totalChannels;
    *outFrameCount = frameCount == UINT32_MAX ? 0 : frameCount;
    return targetCount;
}

/// Accumulates one tap into the resolved output targets and records its peak.
static void RTMixSlot(
    const RTTapSlot *slot,
    const AudioBufferList *input,
    const RTOutputTarget *targets,
    uint32_t targetCount,
    uint32_t frameCount
) {
    if (slot->channel == NULL || slot->channelCount == 0) {
        return;
    }
    if (slot->bufferIndex >= input->mNumberBuffers) {
        return;
    }

    const AudioBuffer buffer = input->mBuffers[slot->bufferIndex];
    if (buffer.mData == NULL || buffer.mDataByteSize == 0 || buffer.mNumberChannels == 0) {
        return;
    }

    const uint32_t inStride = buffer.mNumberChannels;
    if (slot->channelOffset + slot->channelCount > inStride) {
        return;
    }

    const uint32_t availableFrames =
        buffer.mDataByteSize / ((uint32_t)sizeof(float) * inStride);
    const uint32_t frames = frameCount < availableFrames ? frameCount : availableFrames;
    if (frames == 0) {
        return;
    }

    const float gain = RTMixerChannel_GetGain(slot->channel);
    if (gain == 0.0f) {
        RTMixerChannel_SetPeak(slot->channel, 0.0f);
        return;
    }

    const float *in = (const float *)buffer.mData + slot->channelOffset;
    const bool stereoSource = slot->channelCount >= 2;
    float peak = 0.0f;

    if (targetCount >= 2) {
        float *left = targets[0].base;
        float *right = targets[1].base;
        const uint32_t leftStride = targets[0].stride;
        const uint32_t rightStride = targets[1].stride;

        for (uint32_t f = 0; f < frames; ++f) {
            const float *frame = in + (size_t)f * inStride;
            const float l = frame[0] * gain;
            const float r = (stereoSource ? frame[1] : frame[0]) * gain;
            left[(size_t)f * leftStride] += l;
            right[(size_t)f * rightStride] += r;

            const float absL = fabsf(l);
            const float absR = fabsf(r);
            if (absL > peak) { peak = absL; }
            if (absR > peak) { peak = absR; }
        }
    } else {
        float *mono = targets[0].base;
        const uint32_t monoStride = targets[0].stride;

        for (uint32_t f = 0; f < frames; ++f) {
            const float *frame = in + (size_t)f * inStride;
            const float mixed = stereoSource
                ? (frame[0] + frame[1]) * 0.5f * gain
                : frame[0] * gain;
            mono[(size_t)f * monoStride] += mixed;

            const float absMixed = fabsf(mixed);
            if (absMixed > peak) { peak = absMixed; }
        }
    }

    RTMixerChannel_SetPeak(slot->channel, peak);
}

/// Hard-clips the summed output so several loud taps cannot wrap around.
static bool RTClampTargets(
    const RTOutputTarget *targets,
    uint32_t targetCount,
    uint32_t frameCount
) {
    bool clipped = false;
    for (uint32_t t = 0; t < targetCount; ++t) {
        float *base = targets[t].base;
        const uint32_t stride = targets[t].stride;
        for (uint32_t f = 0; f < frameCount; ++f) {
            const size_t index = (size_t)f * stride;
            const float value = base[index];
            if (value > 1.0f) {
                base[index] = 1.0f;
                clipped = true;
            } else if (value < -1.0f) {
                base[index] = -1.0f;
                clipped = true;
            }
        }
    }
    return clipped;
}

OSStatus RTMixer_DeviceIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData
) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;

    RTDeviceMix *mix = (RTDeviceMix *)inClientData;
    if (mix == NULL || outOutputData == NULL) {
        return noErr;
    }

    const uint64_t startTicks = mach_absolute_time();

    RTOutputTarget targets[2];
    uint32_t outputChannels = 0;
    uint32_t frameCount = 0;
    const uint32_t targetCount =
        RTPrepareOutput(outOutputData, targets, &outputChannels, &frameCount);

    atomic_fetch_add_explicit(&mix->stats.ioCycles, 1, memory_order_relaxed);
    atomic_store_explicit(&mix->stats.lastFrameCount, frameCount, memory_order_relaxed);
    atomic_store_explicit(&mix->stats.lastOutputChannels, outputChannels, memory_order_relaxed);

    // Cycle-to-cycle spacing is the objective dropout signal.
    if ((inOutputTime->mFlags & kAudioTimeStampHostTimeValid) != 0 && frameCount > 0) {
        const uint64_t hostTime = inOutputTime->mHostTime;
        const uint64_t previous =
            atomic_exchange_explicit(&mix->lastHostTime, hostTime, memory_order_relaxed);
        if (previous != 0 && hostTime > previous) {
            const uint64_t gapNanos = RTHostTicksToNanos(mix, hostTime - previous);
            const double sampleRate =
                atomic_load_explicit(&mix->sampleRate, memory_order_relaxed);
            if (sampleRate > 0.0) {
                const double expectedNanos = ((double)frameCount / sampleRate) * 1.0e9;
                if ((double)gapNanos > expectedNanos * RT_MIXER_DROPOUT_FACTOR) {
                    atomic_fetch_add_explicit(
                        &mix->stats.dropoutCount, 1, memory_order_relaxed);
                    RTUpdateMax(&mix->stats.maxGapNanos, gapNanos);
                }
            }
        }
    }

    if (!atomic_load_explicit(&mix->enabled, memory_order_relaxed)) {
        return noErr;
    }
    if (targetCount == 0 || frameCount == 0) {
        return noErr;
    }

    if (inInputData == NULL || inInputData->mNumberBuffers == 0) {
        atomic_fetch_add_explicit(&mix->stats.emptyInputCycles, 1, memory_order_relaxed);
        return noErr;
    }

    uint32_t inputChannels = 0;
    for (UInt32 b = 0; b < inInputData->mNumberBuffers; ++b) {
        inputChannels += inInputData->mBuffers[b].mNumberChannels;
    }
    atomic_store_explicit(&mix->stats.lastInputChannels, inputChannels, memory_order_relaxed);

    const uint32_t activeSet = atomic_load_explicit(&mix->activeSet, memory_order_acquire);
    const uint32_t slotCount =
        atomic_load_explicit(&mix->slotCounts[activeSet], memory_order_relaxed);
    const uint32_t expectedInputChannels =
        atomic_load_explicit(&mix->expectedInputChannels, memory_order_relaxed);

    if (slotCount == 0) {
        atomic_store_explicit(&mix->lastUsedSet, activeSet, memory_order_release);
        return noErr;
    }

    // The HAL's layout change and our map swap are not atomic with each other; stay
    // silent for the cycle rather than reading the wrong channels.
    if (expectedInputChannels != 0 && inputChannels != expectedInputChannels) {
        atomic_fetch_add_explicit(&mix->stats.silentCycles, 1, memory_order_relaxed);
        atomic_store_explicit(&mix->lastUsedSet, activeSet, memory_order_release);
        return noErr;
    }

    const RTTapSlot *slots = mix->slots[activeSet];
    for (uint32_t s = 0; s < slotCount; ++s) {
        RTMixSlot(&slots[s], inInputData, targets, targetCount, frameCount);
    }
    atomic_store_explicit(&mix->lastUsedSet, activeSet, memory_order_release);

    if (RTClampTargets(targets, targetCount, frameCount)) {
        atomic_fetch_add_explicit(&mix->stats.clipCycles, 1, memory_order_relaxed);
    }

    const uint64_t elapsedNanos = RTHostTicksToNanos(mix, mach_absolute_time() - startTicks);
    atomic_store_explicit(&mix->stats.lastProcessNanos, elapsedNanos, memory_order_relaxed);
    RTUpdateMax(&mix->stats.maxProcessNanos, elapsedNanos);

    return noErr;
}
