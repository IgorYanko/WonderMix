#pragma once

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Upper bound on simultaneously mixed taps per output device.
#define RT_MIXER_MAX_SLOTS 32

/// Per-app gain and metering cell. Opaque so the C11 atomics never cross into Swift.
typedef struct RTMixerChannel RTMixerChannel;

RTMixerChannel * _Nullable RTMixerChannel_Create(float gain);
void RTMixerChannel_Destroy(RTMixerChannel * _Nullable channel);
void RTMixerChannel_SetGain(RTMixerChannel * _Nonnull channel, float gain);
float RTMixerChannel_GetGain(const RTMixerChannel * _Nonnull channel);
float RTMixerChannel_GetPeak(const RTMixerChannel * _Nonnull channel);

/// Where one tap's channels live inside the aggregate's input buffer list.
typedef struct RTTapSlot {
    uint32_t bufferIndex;
    uint32_t channelOffset;
    uint32_t channelCount;
    RTMixerChannel * _Nullable channel;
} RTTapSlot;

/// Mix state for one output device. Opaque; owns the real-time counters.
typedef struct RTDeviceMix RTDeviceMix;

/// Plain snapshot of the real-time counters, safe to read from Swift.
typedef struct RTDeviceMixSnapshot {
    uint64_t ioCycles;
    uint64_t silentCycles;
    uint64_t emptyInputCycles;
    uint64_t clipCycles;
    uint64_t dropoutCount;
    uint64_t overloadCount;
    uint64_t ioStoppedCount;
    uint64_t maxGapNanos;
    uint64_t lastProcessNanos;
    uint64_t maxProcessNanos;
    uint32_t lastFrameCount;
    uint32_t lastInputChannels;
    uint32_t lastOutputChannels;
    uint32_t publishedSlotCount;
    uint32_t expectedInputChannels;
    bool enabled;
} RTDeviceMixSnapshot;

RTDeviceMix * _Nullable RTMixer_DeviceMixCreate(void);
void RTMixer_DeviceMixDestroy(RTDeviceMix * _Nullable mix);

/// Publishes a new slot map. Writes the inactive set, then swaps atomically, so the
/// IO thread never observes a torn map.
void RTMixer_DeviceMixPublishSlots(
    RTDeviceMix * _Nonnull mix,
    const RTTapSlot * _Nullable slots,
    uint32_t slotCount,
    uint32_t expectedInputChannels
);

void RTMixer_DeviceMixSetSampleRate(RTDeviceMix * _Nonnull mix, double sampleRate);
void RTMixer_DeviceMixSetEnabled(RTDeviceMix * _Nonnull mix, bool enabled);
void RTMixer_DeviceMixResetStats(RTDeviceMix * _Nonnull mix);

/// Filter types for the equalizer biquads.
typedef enum RTEQFilterType {
    RT_EQ_FILTER_LOW_SHELF = 0,
    RT_EQ_FILTER_PEAKING = 1,
    RT_EQ_FILTER_HIGH_SHELF = 2
} RTEQFilterType;

/// Configuration for one equalizer band.
typedef struct RTEQBand {
    double frequency;
    double gainDb;
    double q;
    RTEQFilterType type;
} RTEQBand;

#define RT_MAX_EQ_BANDS 16

/// Updates the master equalizer settings for this device.
/// Biquad coefficients are recalculated for the device's current sample rate
/// and swapped atomically without locks or allocations.
void RTMixer_DeviceMixSetEQ(
    RTDeviceMix * _Nonnull mix,
    bool enabled,
    const RTEQBand * _Nullable bands,
    uint32_t bandCount
);

/// Configures the master peak limiter / anti-clipping stage.
void RTMixer_DeviceMixSetLimiter(
    RTDeviceMix * _Nonnull mix,
    bool enabled,
    float thresholdDb,
    float releaseMs
);

/// Called from the overload / IO-stopped property listeners, which also run on the
/// IO thread and therefore must not log.
void RTMixer_DeviceMixNoteOverload(RTDeviceMix * _Nonnull mix);
void RTMixer_DeviceMixNoteIOStopped(RTDeviceMix * _Nonnull mix);

void RTMixer_DeviceMixSnapshot(
    const RTDeviceMix * _Nonnull mix,
    RTDeviceMixSnapshot * _Nonnull outSnapshot
);

/// The IOProc itself: sums every tap of one device into its output, applying per-app
/// gain. Pass the RTDeviceMix as the IOProc client data.
OSStatus RTMixer_DeviceIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp * _Nonnull inNow,
    const AudioBufferList * _Nonnull inInputData,
    const AudioTimeStamp * _Nonnull inInputTime,
    AudioBufferList * _Nonnull outOutputData,
    const AudioTimeStamp * _Nonnull inOutputTime,
    void * _Nullable inClientData
);

#ifdef __cplusplus
}
#endif
