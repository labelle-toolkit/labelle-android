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
//! no-ops gracefully and `framesMixed` stays 0 — the device-less behaviour,
//! but real output everywhere AAudio is available. Setup failures (builder /
//! open / start / never reaching STARTED) warn **once per failure episode**:
//! every later `ensureStarted` retries silently until one succeeds (or the
//! stream disconnects), which starts a new episode that may warn once more.
//!
//! ## Disconnection recovery
//! Android disconnects an output stream on a route change (headset unplugged,
//! Bluetooth sink switched, …): the data callback stops for good and the
//! stream must be closed and reopened. AAudio reports this through the error
//! callback, which per the NDK contract must NOT stop/close/reopen the stream
//! itself. So `errorCallback` only raises an atomic `disconnected` flag, and
//! the next `ensureStarted` (the mixer's control thread) closes the dead
//! stream, logs `android: AAudio stream disconnected; reopening` and opens a
//! new one. A failed reopen is an ordinary setup failure (one warning, silent
//! retries) — it never spins.
//!
//! ## The "stream started" marker
//! `AAudioStream_requestStart` only *accepts* the request: an `AAUDIO_OK`
//! means the client state is STARTING, not that the device is running. The
//! `android: AAudio stream started (…)` marker is therefore emitted only once
//! `AAudioStream_waitForStateChange(STARTING, …)` — which refreshes the client
//! state from the audio server — reports STARTED: first inside a bounded
//! (`START_WAIT_NS`) wait right after the start request, and if that times
//! out, on the first later `ensureStarted` whose zero-timeout poll observes
//! STARTED. Any other state after STARTING means the stream died before it
//! ran: it is closed and counted as a setup failure. No path logs the marker
//! without having observed STARTED, so the on-device marker is never a false
//! positive.
//!
//! ## Threading
//! The control path (`ensureStarted` / `stop`) is single-threaded: labelle-
//! audio's `Mixer.ensureInit` calls `ensureStarted` from the game thread on
//! every entry point that can start audio and never concurrently with itself.
//! The only cross-thread traffic is (a) the real-time data callback reading
//! `mix_fn` (written before the stream opens) and bumping the atomic
//! `frames_mixed`, and (b) AAudio's error thread writing the atomic
//! `disconnected` / `disconnect_result`. `warned_setup` and
//! `start_marker_pending` are control-thread-only plain bools. Neither
//! callback ever logs.
//!
//! Only reference `ensureStarted` / `stop` from an Android build: the AAudio
//! externs resolve nowhere else (a consumer selects this module behind a
//! comptime `is_android` switch). The device logic itself is generic over the
//! `Api` namespace that carries the externs (`Device(NdkApi)` is the real
//! device), so the host tests below drive the same code against `FakeApi`.

const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;

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

/// Upper bound on the wait for STARTING → STARTED right after
/// `requestStart` (the transition is typically sub-millisecond on MMAP
/// streams, a few ms on legacy ones). Past it the stream is kept and the
/// marker is deferred to a later `ensureStarted` poll — never logged early.
const START_WAIT_NS: i64 = 50 * std.time.ns_per_ms;

// AAudio C ABI (subset). aaudio_result_t AAUDIO_OK == 0.
const AAudioStreamBuilder = opaque {};
const AAudioStream = opaque {};
const AAUDIO_OK: i32 = 0;
const AAUDIO_FORMAT_PCM_I16: i32 = 1;
const AAUDIO_CALLBACK_RESULT_CONTINUE: i32 = 0;
/// `AAUDIO_ERROR_BASE (-900) + 1`: the device went away (route change).
const AAUDIO_ERROR_DISCONNECTED: i32 = -899;
// aaudio_stream_state_t (UNINITIALIZED = 0, UNKNOWN, OPEN, STARTING, STARTED,
// PAUSING, PAUSED, FLUSHING, FLUSHED, STOPPING, STOPPED, CLOSING, CLOSED,
// DISCONNECTED).
const AAUDIO_STREAM_STATE_STARTING: i32 = 3;
const AAUDIO_STREAM_STATE_STARTED: i32 = 4;
const AAUDIO_STREAM_STATE_DISCONNECTED: i32 = 13;
const DataCallback = *const fn (?*AAudioStream, ?*anyopaque, ?*anyopaque, i32) callconv(.c) i32;
const ErrorCallback = *const fn (?*AAudioStream, ?*anyopaque, i32) callconv(.c) void;

extern fn AAudio_createStreamBuilder(builder: *?*AAudioStreamBuilder) i32;
extern fn AAudioStreamBuilder_setFormat(*AAudioStreamBuilder, format: i32) void;
extern fn AAudioStreamBuilder_setChannelCount(*AAudioStreamBuilder, count: i32) void;
extern fn AAudioStreamBuilder_setSampleRate(*AAudioStreamBuilder, rate: i32) void;
extern fn AAudioStreamBuilder_setDataCallback(*AAudioStreamBuilder, cb: DataCallback, user: ?*anyopaque) void;
extern fn AAudioStreamBuilder_setErrorCallback(*AAudioStreamBuilder, cb: ErrorCallback, user: ?*anyopaque) void;
extern fn AAudioStreamBuilder_openStream(*AAudioStreamBuilder, stream: *?*AAudioStream) i32;
extern fn AAudioStreamBuilder_delete(*AAudioStreamBuilder) void;
extern fn AAudioStream_requestStart(*AAudioStream) i32;
extern fn AAudioStream_requestStop(*AAudioStream) i32;
extern fn AAudioStream_close(*AAudioStream) i32;
extern fn AAudioStream_getState(*AAudioStream) i32;
extern fn AAudioStream_waitForStateChange(*AAudioStream, input_state: i32, next_state: ?*i32, timeout_ns: i64) i32;

/// The real libaaudio entry points + `std.log`, as the `Api` namespace
/// `Device` is instantiated with. Aliases are resolved lazily, so nothing here
/// references an AAudio symbol until an Android consumer (or the Android
/// compile-check harness below) reaches `ensureStarted` / `stop`.
const NdkApi = struct {
    const createStreamBuilder = AAudio_createStreamBuilder;
    const builderSetFormat = AAudioStreamBuilder_setFormat;
    const builderSetChannelCount = AAudioStreamBuilder_setChannelCount;
    const builderSetSampleRate = AAudioStreamBuilder_setSampleRate;
    const builderSetDataCallback = AAudioStreamBuilder_setDataCallback;
    const builderSetErrorCallback = AAudioStreamBuilder_setErrorCallback;
    const builderOpenStream = AAudioStreamBuilder_openStream;
    const builderDelete = AAudioStreamBuilder_delete;
    const streamRequestStart = AAudioStream_requestStart;
    const streamRequestStop = AAudioStream_requestStop;
    const streamClose = AAudioStream_close;
    const streamWaitForStateChange = AAudioStream_waitForStateChange;

    fn warn(comptime fmt: []const u8, args: anytype) void {
        std.log.warn(fmt, args);
    }
    fn info(comptime fmt: []const u8, args: anytype) void {
        std.log.info(fmt, args);
    }
};

/// The device state machine, generic over the AAudio `Api` (see `NdkApi`).
/// One instantiation = one global device (container-level `var`s), matching
/// the free-function `DeviceSink` surface.
fn Device(comptime Api: type) type {
    return struct {
        var stream: ?*AAudioStream = null;
        var mix_fn: ?MixFn = null;
        var frames_mixed: std.atomic.Value(u64) = .init(0);
        /// Raised by `errorCallback` (AAudio's error thread); consumed — and
        /// cleared after the dead stream is closed — by `ensureStarted`.
        var disconnected: std.atomic.Value(bool) = .init(false);
        /// The `aaudio_result_t` the error callback received (for the log line).
        var disconnect_result: std.atomic.Value(i32) = .init(0);
        /// Control-thread only: one warning per setup-failure episode.
        var warned_setup: bool = false;
        /// Control-thread only: `requestStart` was accepted but STARTED was not
        /// observed within `START_WAIT_NS`; the marker is still owed.
        var start_marker_pending: bool = false;

        /// Audio-thread data callback: reinterpret AAudio's buffer as
        /// interleaved stereo i16 and let the engine mixer fill it. Runs on a
        /// real-time thread — no allocation, no logging, just the mix call
        /// (the mixer takes its own lock).
        fn dataCallback(_: ?*AAudioStream, _: ?*anyopaque, audio_data: ?*anyopaque, num_frames: i32) callconv(.c) i32 {
            const frames: u32 = @intCast(@max(num_frames, 0));
            const samples: usize = @as(usize, frames) * @as(usize, @intCast(DEVICE_CHANNELS));
            const out: [*]i16 = @ptrCast(@alignCast(audio_data));
            // Shared device-sink contract: stereo device → `channels = 2`,
            // buffer is `frames * 2` interleaved i16; the mixer recovers
            // frames from `out.len`.
            if (mix_fn) |m| m(out[0..samples], 2) else @memset(out[0..samples], 0);
            _ = frames_mixed.fetchAdd(frames, .monotonic);
            return AAUDIO_CALLBACK_RESULT_CONTINUE;
        }

        /// AAudio error callback (its own thread). The NDK forbids stopping,
        /// closing or reopening the stream from here, so it only records the
        /// result and raises the flag; `ensureStarted` does the rest. Any
        /// error (not just `AAUDIO_ERROR_DISCONNECTED`) leaves the stream
        /// unusable, so every one is treated as a disconnect. Never logs.
        fn errorCallback(_: ?*AAudioStream, _: ?*anyopaque, result: i32) callconv(.c) void {
            disconnect_result.store(result, .monotonic);
            disconnected.store(true, .release);
        }

        /// Lazily open + start the AAudio output stream, wiring `mix` as the
        /// callback. Idempotent; recovers a disconnected stream by reopening
        /// it; no-ops gracefully (one warning per failure episode) when AAudio
        /// is unavailable. Logs the `android: AAudio stream started (…)`
        /// marker only once the stream is observed STARTED.
        pub fn ensureStarted(mix: MixFn) void {
            if (stream) |s| {
                if (!disconnected.load(.acquire)) {
                    if (start_marker_pending) settleStart(s, 0);
                    return;
                }
                Api.warn("android: AAudio stream disconnected; reopening (result {d})", .{disconnect_result.load(.monotonic)});
                closeStream(s);
                // A disconnect ends the previous episode: the reopen may warn once.
                warned_setup = false;
            }
            mix_fn = mix;

            var builder: ?*AAudioStreamBuilder = null;
            if (Api.createStreamBuilder(&builder) != AAUDIO_OK) {
                return setupFailed("android: AAudio stream builder unavailable; audio output disabled", .{});
            }
            const b = builder orelse return setupFailed("android: AAudio stream builder unavailable; audio output disabled", .{});
            defer Api.builderDelete(b);

            Api.builderSetFormat(b, AAUDIO_FORMAT_PCM_I16);
            Api.builderSetChannelCount(b, DEVICE_CHANNELS);
            Api.builderSetSampleRate(b, DEVICE_RATE);
            Api.builderSetDataCallback(b, &dataCallback, null);
            Api.builderSetErrorCallback(b, &errorCallback, null);

            var s: ?*AAudioStream = null;
            const open_result = Api.builderOpenStream(b, &s);
            if (open_result != AAUDIO_OK) {
                return setupFailed("android: AAudio stream open failed (result {d}); audio output disabled", .{open_result});
            }
            const opened = s orelse return setupFailed("android: AAudio stream open returned no stream; audio output disabled", .{});
            const start_result = Api.streamRequestStart(opened);
            if (start_result != AAUDIO_OK) {
                _ = Api.streamClose(opened);
                return setupFailed("android: AAudio stream start failed (result {d}); audio output disabled", .{start_result});
            }
            stream = opened;
            start_marker_pending = true;
            settleStart(opened, START_WAIT_NS);
        }

        /// Refresh the client state from the audio server (waiting at most
        /// `timeout_ns` while it is still STARTING) and act on it: STARTED →
        /// log the marker and close the episode; still STARTING → keep the
        /// stream, marker stays owed; anything else → the stream died before
        /// running: close it and count a setup failure.
        fn settleStart(s: *AAudioStream, timeout_ns: i64) void {
            var state: i32 = AAUDIO_STREAM_STATE_STARTING;
            _ = Api.streamWaitForStateChange(s, AAUDIO_STREAM_STATE_STARTING, &state, timeout_ns);
            switch (state) {
                AAUDIO_STREAM_STATE_STARTED => {
                    start_marker_pending = false;
                    warned_setup = false;
                    Api.info("android: AAudio stream started ({d} Hz, {d} ch, i16)", .{ DEVICE_RATE, DEVICE_CHANNELS });
                },
                AAUDIO_STREAM_STATE_STARTING => {},
                else => {
                    closeStream(s);
                    setupFailed("android: AAudio stream did not reach STARTED (state {d}); audio output disabled", .{state});
                },
            }
        }

        /// Warn once per failure episode; later failures in the same episode
        /// are silent (the caller keeps retrying on every `ensureStarted`).
        fn setupFailed(comptime fmt: []const u8, args: anytype) void {
            if (warned_setup) return;
            warned_setup = true;
            Api.warn(fmt, args);
        }

        /// Stop + close `s` (synchronous: no callback of this stream runs
        /// after `close` returns), then clear the per-stream state.
        fn closeStream(s: *AAudioStream) void {
            _ = Api.streamRequestStop(s);
            _ = Api.streamClose(s);
            stream = null;
            start_marker_pending = false;
            disconnected.store(false, .release);
        }

        pub fn stop() void {
            if (stream) |s| closeStream(s);
        }

        pub fn framesMixed() u64 {
            return frames_mixed.load(.monotonic);
        }

        /// Test-only: back to the never-started state (host tests share one
        /// `Device(FakeApi)` instantiation).
        fn resetForTest() void {
            @This().stop();
            mix_fn = null;
            frames_mixed.store(0, .monotonic);
            disconnect_result.store(0, .monotonic);
            warned_setup = false;
        }
    };
}

/// The real device. Only its `framesMixed` is reachable off Android; the
/// other decls pull in the AAudio externs.
const Real = Device(NdkApi);

pub const ensureStarted = Real.ensureStarted;
pub const stop = Real.stop;
pub const framesMixed = Real.framesMixed;

// ── Tests ─────────────────────────────────────────────────────────────────

test "framesMixed is 0 before any stream is opened (no AAudio symbol referenced)" {
    // Host-safe: only the atomic counter is touched; `ensureStarted`/`stop`
    // would reference the AAudio externs, which resolve only on Android.
    try std.testing.expectEqual(@as(u64, 0), framesMixed());
}

test "the AAudio entry points are analyzed and linked (Android compile-check; skipped on the host)" {
    // Everything after this gate is Android-only and NEVER executed: `zig
    // build test -Dtarget=aarch64-linux-android` only compiles + links the
    // test artifact. Without it the Android artifact reached `framesMixed`
    // alone (Zig analyzes function bodies lazily), so a broken `ensureStarted`
    // or an extern missing from libaaudio passed the advertised compile-check.
    // Taking the addresses (the `refAllDecls` idiom) forces analysis + codegen
    // of the whole control path and both callbacks against the real externs.
    if (comptime !is_android) return error.SkipZigTest;
    const Dummy = struct {
        fn mix(out: []i16, _: u8) void {
            @memset(out, 0);
        }
    };
    const mix: MixCallback = &Dummy.mix;
    _ = mix;
    _ = &ensureStarted;
    _ = &stop;
    _ = &framesMixed;
    _ = &Real.dataCallback;
    _ = &Real.errorCallback;
}

/// Scripted stand-in for libaaudio: the host tests drive `Device(FakeApi)`
/// through the same state machine the Android build runs against `NdkApi`.
/// Results are scripted per call site; every AAudio call and log line is
/// counted, and the two callbacks the device registers are captured so a
/// test can play the AAudio threads.
const FakeApi = struct {
    var create_builder_result: i32 = AAUDIO_OK;
    var open_result: i32 = AAUDIO_OK;
    var start_result: i32 = AAUDIO_OK;
    /// The state `streamWaitForStateChange` reports.
    var state: i32 = AAUDIO_STREAM_STATE_STARTED;

    var open_attempts: u32 = 0;
    var opens: u32 = 0;
    var starts: u32 = 0;
    var stops: u32 = 0;
    var closes: u32 = 0;
    var builder_deletes: u32 = 0;
    var warns: u32 = 0;
    var infos: u32 = 0;
    var last_warn: []const u8 = "";
    var last_info: []const u8 = "";
    var data_cb: ?DataCallback = null;
    var error_cb: ?ErrorCallback = null;
    var last_stream: ?*AAudioStream = null;

    var builder_storage: u8 = 0;
    /// Distinct addresses per open, so a reopen yields a different stream.
    var stream_storage: [8]u8 = @splat(0);

    fn reset() void {
        create_builder_result = AAUDIO_OK;
        open_result = AAUDIO_OK;
        start_result = AAUDIO_OK;
        state = AAUDIO_STREAM_STATE_STARTED;
        open_attempts = 0;
        opens = 0;
        starts = 0;
        stops = 0;
        closes = 0;
        builder_deletes = 0;
        warns = 0;
        infos = 0;
        last_warn = "";
        last_info = "";
        data_cb = null;
        error_cb = null;
        last_stream = null;
    }

    fn createStreamBuilder(out: *?*AAudioStreamBuilder) i32 {
        if (create_builder_result != AAUDIO_OK) return create_builder_result;
        out.* = @ptrCast(&builder_storage);
        return AAUDIO_OK;
    }
    fn builderSetFormat(_: *AAudioStreamBuilder, _: i32) void {}
    fn builderSetChannelCount(_: *AAudioStreamBuilder, _: i32) void {}
    fn builderSetSampleRate(_: *AAudioStreamBuilder, _: i32) void {}
    fn builderSetDataCallback(_: *AAudioStreamBuilder, cb: DataCallback, _: ?*anyopaque) void {
        data_cb = cb;
    }
    fn builderSetErrorCallback(_: *AAudioStreamBuilder, cb: ErrorCallback, _: ?*anyopaque) void {
        error_cb = cb;
    }
    fn builderOpenStream(_: *AAudioStreamBuilder, out: *?*AAudioStream) i32 {
        open_attempts += 1;
        if (open_result != AAUDIO_OK) return open_result;
        const s: *AAudioStream = @ptrCast(&stream_storage[opens % stream_storage.len]);
        opens += 1;
        last_stream = s;
        out.* = s;
        return AAUDIO_OK;
    }
    fn builderDelete(_: *AAudioStreamBuilder) void {
        builder_deletes += 1;
    }
    fn streamRequestStart(_: *AAudioStream) i32 {
        starts += 1;
        return start_result;
    }
    fn streamRequestStop(_: *AAudioStream) i32 {
        stops += 1;
        return AAUDIO_OK;
    }
    fn streamClose(_: *AAudioStream) i32 {
        closes += 1;
        return AAUDIO_OK;
    }
    fn streamWaitForStateChange(_: *AAudioStream, input_state: i32, next_state: ?*i32, _: i64) i32 {
        if (next_state) |n| n.* = state;
        // AAUDIO_ERROR_TIMEOUT when the state did not move; the device
        // decides on `next_state`, not on the result.
        return if (state == input_state) -1 else AAUDIO_OK;
    }
    fn warn(comptime fmt: []const u8, _: anytype) void {
        warns += 1;
        last_warn = fmt;
    }
    fn info(comptime fmt: []const u8, _: anytype) void {
        infos += 1;
        last_info = fmt;
    }
};

const Fake = Device(FakeApi);

const TestMix = struct {
    var calls: u32 = 0;
    var last_channels: u8 = 0;
    var last_len: usize = 0;
    fn mix(out: []i16, channels: u8) void {
        calls += 1;
        last_channels = channels;
        last_len = out.len;
        @memset(out, 7);
    }
};

fn freshFake() void {
    Fake.resetForTest();
    FakeApi.reset();
    TestMix.calls = 0;
}

const marker_fmt = "android: AAudio stream started ({d} Hz, {d} ch, i16)";

test "ensureStarted opens + starts once, wires both callbacks, and the data callback drives the mixer" {
    freshFake();
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix); // idempotent
    try std.testing.expectEqual(@as(u32, 1), FakeApi.opens);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.starts);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.builder_deletes);
    try std.testing.expectEqual(@as(u32, 0), FakeApi.warns);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.infos);
    try std.testing.expectEqualStrings(marker_fmt, FakeApi.last_info);
    try std.testing.expect(FakeApi.error_cb != null);

    // Play the real-time thread: 4 frames of stereo → 8 interleaved i16.
    var buf: [8]i16 = @splat(0);
    const rc = FakeApi.data_cb.?(FakeApi.last_stream, null, @ptrCast(&buf), 4);
    try std.testing.expectEqual(AAUDIO_CALLBACK_RESULT_CONTINUE, rc);
    try std.testing.expectEqual(@as(u32, 1), TestMix.calls);
    try std.testing.expectEqual(@as(u8, 2), TestMix.last_channels);
    try std.testing.expectEqual(@as(usize, 8), TestMix.last_len);
    try std.testing.expectEqual(@as(i16, 7), buf[7]);
    try std.testing.expectEqual(@as(u64, 4), Fake.framesMixed());

    Fake.stop();
    try std.testing.expectEqual(@as(u32, 1), FakeApi.stops);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.closes);
    Fake.stop(); // idempotent
    try std.testing.expectEqual(@as(u32, 1), FakeApi.closes);
}

test "disconnect: the error callback only raises the flag; the next ensureStarted closes and reopens" {
    freshFake();
    Fake.ensureStarted(&TestMix.mix);
    const first = FakeApi.last_stream;

    // AAudio's error thread reports the route change. Nothing may happen to
    // the stream from here — the callback must only flag it.
    FakeApi.error_cb.?(first, null, AAUDIO_ERROR_DISCONNECTED);
    try std.testing.expect(Fake.disconnected.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), FakeApi.stops);
    try std.testing.expectEqual(@as(u32, 0), FakeApi.closes);
    try std.testing.expectEqual(@as(u32, 0), FakeApi.warns);

    // The mixer's control thread recovers: stop+close the dead stream, log
    // one "disconnected; reopening" line, open a NEW stream, mark it started.
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.stops);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.closes);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.opens);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.starts);
    try std.testing.expect(FakeApi.last_stream != first);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.warns);
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream disconnected; reopening"));
    try std.testing.expectEqual(@as(u32, 2), FakeApi.infos);
    try std.testing.expect(!Fake.disconnected.load(.acquire));

    // Flag consumed: the new stream is left alone.
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.opens);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.closes);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.warns);
}

test "disconnect whose reopen fails falls into the setup-failure path (one warning, silent retries, no spin)" {
    freshFake();
    Fake.ensureStarted(&TestMix.mix);
    FakeApi.error_cb.?(FakeApi.last_stream, null, AAUDIO_ERROR_DISCONNECTED);

    FakeApi.open_result = -1;
    Fake.ensureStarted(&TestMix.mix);
    // "disconnected; reopening" + ONE open-failure warning.
    try std.testing.expectEqual(@as(u32, 1), FakeApi.closes);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.warns);
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream open failed"));
    try std.testing.expectEqual(@as(u32, 2), FakeApi.open_attempts);

    // Retries keep going, silently — one attempt per call, never a loop.
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 5), FakeApi.open_attempts);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.warns);

    // The route comes back: reopen succeeds, marker logged again.
    FakeApi.open_result = AAUDIO_OK;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.opens);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.infos);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.warns);
}

test "setup failures warn once per episode; a success resets the episode" {
    freshFake();

    // Builder unavailable: warn once, then silent retries.
    FakeApi.create_builder_result = -1;
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.warns);
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream builder unavailable"));
    try std.testing.expectEqual(@as(u32, 0), FakeApi.opens);

    // Same episode, a different failure kind: still silent (one warning per
    // episode, not per kind).
    FakeApi.create_builder_result = AAUDIO_OK;
    FakeApi.start_result = -1;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.warns);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.opens);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.closes); // the un-startable stream is closed
    try std.testing.expectEqual(@as(u32, 0), FakeApi.infos);

    // Success ends the episode...
    FakeApi.start_result = AAUDIO_OK;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.infos);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.warns);

    // ...so after an explicit stop, a fresh failure warns once more.
    Fake.stop();
    FakeApi.open_result = -1;
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.warns);
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream open failed"));
}

test "the started marker is logged only once STARTED is observed, never on requestStart alone" {
    freshFake();

    // requestStart accepted, but the stream is still STARTING after the
    // bounded wait: keep it, owe the marker.
    FakeApi.state = AAUDIO_STREAM_STATE_STARTING;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.starts);
    try std.testing.expectEqual(@as(u32, 0), FakeApi.infos);
    try std.testing.expectEqual(@as(u32, 0), FakeApi.warns);
    try std.testing.expect(Fake.start_marker_pending);

    // Still STARTING on the next poll: no marker, no reopen.
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 0), FakeApi.infos);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.opens);

    // The server reports STARTED: the marker is emitted exactly once.
    FakeApi.state = AAUDIO_STREAM_STATE_STARTED;
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.infos);
    try std.testing.expectEqualStrings(marker_fmt, FakeApi.last_info);
    try std.testing.expect(!Fake.start_marker_pending);
    try std.testing.expectEqual(@as(u32, 0), FakeApi.warns);
}

test "a stream that dies before STARTED is closed and counted as a setup failure (no marker)" {
    freshFake();
    FakeApi.state = AAUDIO_STREAM_STATE_DISCONNECTED;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 0), FakeApi.infos);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.closes);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.warns);
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream did not reach STARTED"));

    // Retried silently on the next call; a later real start logs the marker.
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 2), FakeApi.open_attempts);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.warns);
    FakeApi.state = AAUDIO_STREAM_STATE_STARTED;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), FakeApi.infos);
}
