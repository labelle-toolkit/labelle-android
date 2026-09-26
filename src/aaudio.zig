//! Android audio output device via **AAudio** (NDK, API 26+) — labelle-bgfx#306,
//! moved here from bgfx's `audio_device_android.zig` (labelle-bgfx#149 phase 1c).
//!
//! Implements the shared `labelle-audio` `DeviceSink` control surface
//! (`ensureStarted` / `stop` / `framesMixed`) so a backend's pure-Zig mixer
//! drives it unchanged, the same way its desktop miniaudio device does. Opens a
//! PCM_I16 stereo 48 kHz output stream and wires its data callback to the
//! engine mixer, so the audio thread pulls mixed samples on demand.
//!
//! Pure C NDK API (no JNI), called via `extern`; the package links `libaaudio`
//! on Android. If the stream can't open (e.g. no audio HW), `ensureStarted`
//! no-ops gracefully (with one warning) and `framesMixed` stays 0 — the
//! device-less behaviour, but real output everywhere AAudio is available.
//!
//! Only reference `ensureStarted` / `stop` from an Android build: the AAudio
//! externs resolve nowhere else (a consumer selects this module behind a
//! comptime `is_android` switch).

const std = @import("std");

/// Signature of the mixer the device drives on the audio thread — the shared
/// `labelle-audio` device-sink callback (`out: []i16, channels: u8`). Declared
/// here structurally (function-pointer types are structural in Zig) so this
/// package does not depend on labelle-audio; the consumer asserts at comptime
/// that it equals `labelle_audio.MixCallback`. The AAudio stream is always
/// stereo, so it passes `channels = 2` and `out.len = frames * 2`.
pub const MixCallback = *const fn (out: []i16, channels: u8) void;
pub const MixFn = MixCallback;

const DEVICE_RATE: i32 = 48000;
const DEVICE_CHANNELS: i32 = 2;

// AAudio C ABI (subset). aaudio_result_t AAUDIO_OK == 0.
const AAudioStreamBuilder = opaque {};
const AAudioStream = opaque {};
const AAUDIO_OK: i32 = 0;
const AAUDIO_FORMAT_PCM_I16: i32 = 1;
const AAUDIO_CALLBACK_RESULT_CONTINUE: i32 = 0;
const DataCallback = *const fn (?*AAudioStream, ?*anyopaque, ?*anyopaque, i32) callconv(.c) i32;

extern fn AAudio_createStreamBuilder(builder: *?*AAudioStreamBuilder) i32;
extern fn AAudioStreamBuilder_setFormat(*AAudioStreamBuilder, format: i32) void;
extern fn AAudioStreamBuilder_setChannelCount(*AAudioStreamBuilder, count: i32) void;
extern fn AAudioStreamBuilder_setSampleRate(*AAudioStreamBuilder, rate: i32) void;
extern fn AAudioStreamBuilder_setDataCallback(*AAudioStreamBuilder, cb: DataCallback, user: ?*anyopaque) void;
extern fn AAudioStreamBuilder_openStream(*AAudioStreamBuilder, stream: *?*AAudioStream) i32;
extern fn AAudioStreamBuilder_delete(*AAudioStreamBuilder) void;
extern fn AAudioStream_requestStart(*AAudioStream) i32;
extern fn AAudioStream_requestStop(*AAudioStream) i32;
extern fn AAudioStream_close(*AAudioStream) i32;

var stream: ?*AAudioStream = null;
var mix_fn: ?MixFn = null;
var frames_mixed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Audio-thread data callback: reinterpret AAudio's buffer as interleaved
/// stereo i16 and let the engine mixer fill it. Runs on a real-time thread —
/// no allocation, no logging, just the mix call (the mixer takes its own lock).
fn dataCallback(_: ?*AAudioStream, _: ?*anyopaque, audio_data: ?*anyopaque, num_frames: i32) callconv(.c) i32 {
    const frames: u32 = @intCast(@max(num_frames, 0));
    const samples: usize = @as(usize, frames) * @as(usize, @intCast(DEVICE_CHANNELS));
    const out: [*]i16 = @ptrCast(@alignCast(audio_data));
    // Shared device-sink contract: stereo device → `channels = 2`, buffer is
    // `frames * 2` interleaved i16; the mixer recovers frames from `out.len`.
    if (mix_fn) |m| m(out[0..samples], 2) else @memset(out[0..samples], 0);
    _ = frames_mixed.fetchAdd(frames, .monotonic);
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

/// Lazily open + start the AAudio output stream, wiring `mix` as the callback.
/// Idempotent; no-ops gracefully (one warning) if AAudio is unavailable. Logs
/// one info line once the stream is running — the on-device marker that the
/// device is live (the callback itself never logs).
pub fn ensureStarted(mix: MixFn) void {
    if (stream != null) return;
    mix_fn = mix;

    var builder: ?*AAudioStreamBuilder = null;
    if (AAudio_createStreamBuilder(&builder) != AAUDIO_OK) {
        std.log.warn("android: AAudio stream builder unavailable; audio output disabled", .{});
        return;
    }
    const b = builder orelse return;
    defer AAudioStreamBuilder_delete(b);

    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(b, DEVICE_CHANNELS);
    AAudioStreamBuilder_setSampleRate(b, DEVICE_RATE);
    AAudioStreamBuilder_setDataCallback(b, &dataCallback, null);

    var s: ?*AAudioStream = null;
    const open_result = AAudioStreamBuilder_openStream(b, &s);
    if (open_result != AAUDIO_OK) {
        std.log.warn("android: AAudio stream open failed (result {d}); audio output disabled", .{open_result});
        return;
    }
    const opened = s orelse return;
    const start_result = AAudioStream_requestStart(opened);
    if (start_result != AAUDIO_OK) {
        std.log.warn("android: AAudio stream start failed (result {d}); audio output disabled", .{start_result});
        _ = AAudioStream_close(opened);
        return;
    }
    stream = opened;
    std.log.info("android: AAudio stream started ({d} Hz, {d} ch, i16)", .{ DEVICE_RATE, DEVICE_CHANNELS });
}

pub fn stop() void {
    if (stream) |s| {
        _ = AAudioStream_requestStop(s);
        _ = AAudioStream_close(s);
        stream = null;
    }
}

pub fn framesMixed() u64 {
    return frames_mixed.load(.monotonic);
}

test "framesMixed is 0 before any stream is opened (no AAudio symbol referenced)" {
    // Host-safe: only the atomic counter is touched; `ensureStarted`/`stop`
    // would reference the AAudio externs, which resolve only on Android.
    try std.testing.expectEqual(@as(u64, 0), framesMixed());
}
