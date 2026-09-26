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
//! open / start) warn **once per failure episode**: every later open attempt
//! retries silently until a stream is observed running (or the stream
//! disconnects), which starts a new episode that may warn once more.
//!
//! ## The control thread
//! The mixer only calls `ensureStarted` from the game thread's `load*` /
//! `play*` entry points — there is no periodic tick. So neither disconnect
//! recovery nor the "stream started" observation may depend on a *future*
//! `ensureStarted` (a long track after the last `play*` would stay silent
//! forever after a route change), and neither may block the game thread. Both
//! belong to a tiny **control thread** the device owns:
//!
//!   * spawned once, on the first `ensureStarted` that opens + starts a
//!     stream; joined by `stop` (which also lets a later `ensureStarted`
//!     spawn a fresh one);
//!   * sleeps on a futex-backed event (`wake_seq`) and is woken by exactly two
//!     sources — AAudio's **error callback** (raises `disconnected`, wakes) and
//!     the **data callback** the first time it runs after a start (raises
//!     `started_observed`, wakes) — plus `stop` (raises `quit`, wakes);
//!   * on each wake, under `mutex`: a `started_observed` stream gets the
//!     `android: AAudio stream started (…)` marker exactly once per start; a
//!     `disconnected` stream is stopped, closed and reopened by the same
//!     `openAndStart` routine `ensureStarted` uses, logging `android: AAudio
//!     stream disconnected; reopening (result N)`. A failed reopen is an
//!     ordinary setup failure (one warning per episode) and the thread simply
//!     waits for the next wake — a later `ensureStarted` retries the open.
//!
//! ## Disconnection recovery
//! Android disconnects an output stream on a route change (headset unplugged,
//! Bluetooth sink switched, …): the data callback stops for good and the
//! stream must be closed and reopened. AAudio reports this through the error
//! callback, which per the NDK contract must NOT stop/close/reopen the stream
//! itself. So `errorCallback` only records the result, raises the atomic
//! `disconnected` flag and wakes the control thread, which does the rest with
//! no game-thread involvement.
//!
//! ## The "stream started" marker
//! `AAudioStream_requestStart` only *accepts* the request: an `AAUDIO_OK`
//! means the client state is STARTING, not that the device is running. The
//! marker is emitted only after the stream's data callback has actually run,
//! i.e. the audio server pulled its first buffer from the engine mixer: the
//! device is driving the mixer, which is what the marker attests. Note it is
//! NOT the client-state STARTED flip: on the SM-T505's legacy AudioTrack path
//! the first pull is the track pre-fill, measured 1 ms after `requestStart`
//! returned and ~150 ms BEFORE AAudio's own `setState 3 → 4` line (MMAP
//! streams pull only once running). `ensureStarted` never waits for any of
//! it (no `AAudioStream_waitForStateChange` anywhere: it blocked the game
//! thread up to 250 ms on that legacy path).
//!
//! ## Threading
//!   * `mutex` (an `Io.Mutex`) guards the stream handle and the per-stream
//!     control state (`warned_setup`, `marker_owed`) between the game thread
//!     (`ensureStarted` / `stop`) and the control thread (`service`). The
//!     game-thread calls are never concurrent with each other (labelle-audio's
//!     `Mixer.ensureInit` contract).
//!   * The two AAudio callbacks take NO lock, allocate nothing and never log:
//!     the data callback (real-time thread) mixes, bumps `frames_mixed` and,
//!     once per start, flips `started_observed` + one futex wake; the error
//!     callback stores `disconnect_result`, flips `disconnected` + one wake.
//!   * `mix_fn` is written before a stream opens and only read by that
//!     stream's data callback; `control` (the thread handle) is game-thread
//!     only.
//!   * Zig 0.16 routes every blocking primitive through an `Io`. The
//!     `DeviceSink` surface carries none, so the device sleeps/locks through
//!     `std.Io.Threaded.global_single_threaded`, whose futex ops are the plain
//!     OS futex (they ignore the instance) — all the device needs.
//!
//! Only reference `ensureStarted` / `stop` from an Android build: the AAudio
//! externs resolve nowhere else (a consumer selects this module behind a
//! comptime `is_android` switch). The device logic itself is generic over the
//! `Api` namespace that carries the externs (`Device(NdkApi)` is the real
//! device), so the host tests below drive the same code — control thread
//! included — against `FakeApi`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

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

// AAudio C ABI (subset). aaudio_result_t AAUDIO_OK == 0.
const AAudioStreamBuilder = opaque {};
const AAudioStream = opaque {};
const AAUDIO_OK: i32 = 0;
const AAUDIO_FORMAT_PCM_I16: i32 = 1;
const AAUDIO_CALLBACK_RESULT_CONTINUE: i32 = 0;
/// `AAUDIO_ERROR_BASE (-900) + 1`: the device went away (route change).
const AAUDIO_ERROR_DISCONNECTED: i32 = -899;
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

    fn warn(comptime fmt: []const u8, args: anytype) void {
        std.log.warn(fmt, args);
    }
    fn info(comptime fmt: []const u8, args: anytype) void {
        std.log.info(fmt, args);
    }
};

/// The `Io` the device blocks through (see "Threading" above).
fn ioOf() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// The device state machine, generic over the AAudio `Api` (see `NdkApi`).
/// One instantiation = one global device (container-level `var`s), matching
/// the free-function `DeviceSink` surface.
fn Device(comptime Api: type) type {
    return struct {
        // ── Guarded by `mutex` (game thread ⇄ control thread) ─────────────
        var mutex: Io.Mutex = .init;
        var stream: ?*AAudioStream = null;
        /// One warning per setup-failure episode; an episode ends when a
        /// stream is observed running.
        var warned_setup: bool = false;
        /// The current stream's "started" marker has not been logged yet.
        var marker_owed: bool = false;

        // ── Game-thread only ──────────────────────────────────────────────
        var control: ?std.Thread = null;
        /// One warning if the control thread cannot be spawned.
        var warned_control: bool = false;

        // ── Written before a stream opens; read by its data callback ──────
        var mix_fn: ?MixFn = null;

        // ── Atomics: callbacks / `stop` → control thread ──────────────────
        var frames_mixed: std.atomic.Value(u64) = .init(0);
        /// Raised by `errorCallback` (AAudio's error thread); consumed — and
        /// cleared after the dead stream is closed — by the control thread.
        var disconnected: std.atomic.Value(bool) = .init(false);
        /// The `aaudio_result_t` the error callback received (for the log line).
        var disconnect_result: std.atomic.Value(i32) = .init(0);
        /// Raised by the first `dataCallback` run after each start; cleared
        /// before every start and on close.
        var started_observed: std.atomic.Value(bool) = .init(false);
        /// `stop` asks the control thread to exit.
        var quit: std.atomic.Value(bool) = .init(false);
        /// The control thread's event word: bumped by every wake source; the
        /// thread futex-waits on the value it last observed.
        var wake_seq: std.atomic.Value(u32) = .init(0);
        /// Set by the control thread as it returns (so `stop` can be checked
        /// to have really joined it).
        var control_exited: std.atomic.Value(bool) = .init(false);

        /// Wake the control thread: bump the event word, then one futex wake.
        /// Lock-free and allocation-free (a single non-blocking syscall) —
        /// safe from both AAudio callbacks.
        fn wake() void {
            _ = wake_seq.fetchAdd(1, .release);
            ioOf().futexWake(u32, &wake_seq.raw, 1);
        }

        /// Audio-thread data callback: reinterpret AAudio's buffer as
        /// interleaved stereo i16 and let the engine mixer fill it. Runs on a
        /// real-time thread — no allocation, no logging, no lock: the mix
        /// call (the mixer takes its own lock), an atomic bump, and — on the
        /// first run after a start only — one futex wake for the marker.
        fn dataCallback(_: ?*AAudioStream, _: ?*anyopaque, audio_data: ?*anyopaque, num_frames: i32) callconv(.c) i32 {
            const frames: u32 = @intCast(@max(num_frames, 0));
            const samples: usize = @as(usize, frames) * @as(usize, @intCast(DEVICE_CHANNELS));
            const out: [*]i16 = @ptrCast(@alignCast(audio_data));
            // Shared device-sink contract: stereo device → `channels = 2`,
            // buffer is `frames * 2` interleaved i16; the mixer recovers
            // frames from `out.len`.
            if (mix_fn) |m| m(out[0..samples], 2) else @memset(out[0..samples], 0);
            _ = frames_mixed.fetchAdd(frames, .monotonic);
            if (!started_observed.load(.monotonic)) {
                // The server pulled its first buffer (the mixer is being
                // driven). Only the run that flips the flag wakes the control
                // thread.
                if (started_observed.cmpxchgStrong(false, true, .release, .monotonic) == null) wake();
            }
            return AAUDIO_CALLBACK_RESULT_CONTINUE;
        }

        /// AAudio error callback (its own thread). The NDK forbids stopping,
        /// closing or reopening the stream from here, so it only records the
        /// result, raises the flag and wakes the control thread. Any error
        /// (not just `AAUDIO_ERROR_DISCONNECTED`) leaves the stream unusable,
        /// so every one is treated as a disconnect. Never logs, never locks.
        fn errorCallback(_: ?*AAudioStream, _: ?*anyopaque, result: i32) callconv(.c) void {
            disconnect_result.store(result, .monotonic);
            disconnected.store(true, .release);
            wake();
        }

        /// Lazily open + start the AAudio output stream, wiring `mix` as the
        /// callback, and spawn the control thread that owns recovery and the
        /// started marker. Idempotent; never blocks on the audio server (it
        /// only *requests* the start); no-ops gracefully (one warning per
        /// failure episode) when AAudio is unavailable. A stream that is live
        /// — or disconnected and not yet reopened by the control thread — is
        /// left alone; a stream whose reopen failed is retried here.
        pub fn ensureStarted(mix: MixFn) void {
            const io = ioOf();
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
            if (stream != null) return;
            mix_fn = mix;
            if (!openAndStart()) return;
            spawnControl();
        }

        /// Open + start a stream (caller holds `mutex`). Shared by the first
        /// start and every reopen. `true` when a stream is now running its
        /// start request; `false` after a setup failure (warned once per
        /// episode).
        fn openAndStart() bool {
            var builder: ?*AAudioStreamBuilder = null;
            if (Api.createStreamBuilder(&builder) != AAUDIO_OK) {
                setupFailed("android: AAudio stream builder unavailable; audio output disabled", .{});
                return false;
            }
            const b = builder orelse {
                setupFailed("android: AAudio stream builder unavailable; audio output disabled", .{});
                return false;
            };
            defer Api.builderDelete(b);

            Api.builderSetFormat(b, AAUDIO_FORMAT_PCM_I16);
            Api.builderSetChannelCount(b, DEVICE_CHANNELS);
            Api.builderSetSampleRate(b, DEVICE_RATE);
            Api.builderSetDataCallback(b, &dataCallback, null);
            Api.builderSetErrorCallback(b, &errorCallback, null);

            var s: ?*AAudioStream = null;
            const open_result = Api.builderOpenStream(b, &s);
            if (open_result != AAUDIO_OK) {
                setupFailed("android: AAudio stream open failed (result {d}); audio output disabled", .{open_result});
                return false;
            }
            const opened = s orelse {
                setupFailed("android: AAudio stream open returned no stream; audio output disabled", .{});
                return false;
            };
            // Armed BEFORE the start request: the data callback may run as
            // soon as the request is accepted.
            started_observed.store(false, .release);
            const start_result = Api.streamRequestStart(opened);
            if (start_result != AAUDIO_OK) {
                _ = Api.streamClose(opened);
                setupFailed("android: AAudio stream start failed (result {d}); audio output disabled", .{start_result});
                return false;
            }
            stream = opened;
            marker_owed = true;
            return true;
        }

        /// Spawn the control thread once (game thread; caller holds `mutex`,
        /// which the new thread simply blocks on until we return). A spawn
        /// failure is warned once: the stream still plays, but disconnects
        /// are not recovered and the marker is never logged.
        fn spawnControl() void {
            if (control != null) return;
            control_exited.store(false, .release);
            control = std.Thread.spawn(.{}, controlMain, .{}) catch |err| {
                if (!warned_control) {
                    warned_control = true;
                    Api.warn("android: AAudio control thread unavailable ({s}); disconnect recovery disabled", .{@errorName(err)});
                }
                return;
            };
        }

        /// The control thread. Sleeps on `wake_seq`; every wake runs one
        /// `service` pass. A bump between the `seen` load and the futex wait
        /// makes the wait return immediately, so no wake is ever lost;
        /// spurious returns just re-run `service`, which is idempotent.
        fn controlMain() void {
            defer control_exited.store(true, .release);
            const io = ioOf();
            while (true) {
                const seen = wake_seq.load(.acquire);
                if (quit.load(.acquire)) return;
                service();
                io.futexWaitUncancelable(u32, &wake_seq.raw, seen);
            }
        }

        /// One control pass, under `mutex`: log the started marker for a
        /// stream observed running (once per start), then recover a
        /// disconnected stream. Marker first, so a stream that ran and then
        /// died gets its lines in chronological order.
        fn service() void {
            const io = ioOf();
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
            if (marker_owed and started_observed.load(.acquire)) {
                marker_owed = false;
                // A running stream ends the failure episode.
                warned_setup = false;
                Api.info("android: AAudio stream started ({d} Hz, {d} ch, i16)", .{ DEVICE_RATE, DEVICE_CHANNELS });
            }
            if (disconnected.load(.acquire)) {
                if (stream) |s| {
                    Api.warn("android: AAudio stream disconnected; reopening (result {d})", .{disconnect_result.load(.monotonic)});
                    closeStream(s);
                    // A disconnect ends the previous episode: the reopen may
                    // warn once. If it fails, wait for the next wake — a later
                    // `ensureStarted` retries the open.
                    warned_setup = false;
                    _ = openAndStart();
                } else {
                    disconnected.store(false, .release);
                }
            }
        }

        /// Warn once per failure episode; later failures in the same episode
        /// are silent (the callers keep retrying). Caller holds `mutex`.
        fn setupFailed(comptime fmt: []const u8, args: anytype) void {
            if (warned_setup) return;
            warned_setup = true;
            Api.warn(fmt, args);
        }

        /// Stop + close `s` (synchronous: no callback of this stream runs
        /// after `close` returns), then clear the per-stream state. Caller
        /// holds `mutex`.
        fn closeStream(s: *AAudioStream) void {
            _ = Api.streamRequestStop(s);
            _ = Api.streamClose(s);
            stream = null;
            marker_owed = false;
            started_observed.store(false, .release);
            disconnected.store(false, .release);
        }

        /// Stop the device: join the control thread (so no service pass is
        /// in flight or pending), then stop + close the stream. Idempotent; a
        /// later `ensureStarted` starts over, control thread included.
        pub fn stop() void {
            if (control) |t| {
                quit.store(true, .release);
                wake();
                t.join();
                control = null;
                quit.store(false, .release);
            }
            const io = ioOf();
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
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
            warned_control = false;
            control_exited.store(false, .release);
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
    // of the whole control path, both callbacks and the control thread
    // against the real externs.
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
    _ = &Real.controlMain;
    _ = &Real.service;
    _ = &Real.spawnControl;
}

/// Scripted stand-in for libaaudio: the host tests drive `Device(FakeApi)`
/// through the same state machine the Android build runs against `NdkApi`,
/// real control thread included. Results are scripted per call site; every
/// AAudio call and log line is counted (atomically: the control thread bumps
/// them while the test thread reads), and the two callbacks the device
/// registers are captured so a test can play the AAudio threads.
const FakeApi = struct {
    const Counter = std.atomic.Value(u32);

    var create_builder_result: i32 = AAUDIO_OK;
    var open_result: i32 = AAUDIO_OK;
    var start_result: i32 = AAUDIO_OK;

    var open_attempts: Counter = .init(0);
    var opens: Counter = .init(0);
    var starts: Counter = .init(0);
    var stops: Counter = .init(0);
    var closes: Counter = .init(0);
    var builder_deletes: Counter = .init(0);
    var warns: Counter = .init(0);
    var infos: Counter = .init(0);
    /// Written before the matching counter bump (release) and read after
    /// observing it (acquire); every writer holds the device mutex.
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
        open_attempts.store(0, .release);
        opens.store(0, .release);
        starts.store(0, .release);
        stops.store(0, .release);
        closes.store(0, .release);
        builder_deletes.store(0, .release);
        warns.store(0, .release);
        infos.store(0, .release);
        last_warn = "";
        last_info = "";
        data_cb = null;
        error_cb = null;
        last_stream = null;
    }

    fn bump(c: *Counter) void {
        _ = c.fetchAdd(1, .release);
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
        bump(&open_attempts);
        if (open_result != AAUDIO_OK) return open_result;
        const n = opens.load(.acquire);
        const s: *AAudioStream = @ptrCast(&stream_storage[n % stream_storage.len]);
        last_stream = s;
        out.* = s;
        bump(&opens);
        return AAUDIO_OK;
    }
    fn builderDelete(_: *AAudioStreamBuilder) void {
        bump(&builder_deletes);
    }
    fn streamRequestStart(_: *AAudioStream) i32 {
        bump(&starts);
        return start_result;
    }
    fn streamRequestStop(_: *AAudioStream) i32 {
        bump(&stops);
        return AAUDIO_OK;
    }
    fn streamClose(_: *AAudioStream) i32 {
        bump(&closes);
        return AAUDIO_OK;
    }
    fn warn(comptime fmt: []const u8, _: anytype) void {
        last_warn = fmt;
        bump(&warns);
    }
    fn info(comptime fmt: []const u8, _: anytype) void {
        last_info = fmt;
        bump(&infos);
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

fn count(c: *const FakeApi.Counter) u32 {
    return c.load(.acquire);
}

fn nowMs() i64 {
    return Io.Clock.now(.awake, ioOf()).toMilliseconds();
}

/// Wait (bounded, 2 s) for the control thread to bring `c` to `want`.
fn waitCount(c: *const FakeApi.Counter, want: u32) !void {
    const deadline = nowMs() + 2000;
    while (count(c) != want) {
        if (nowMs() > deadline) {
            std.debug.print("waitCount: wanted {d}, still {d}\n", .{ want, count(c) });
            return error.ControlThreadTimeout;
        }
        std.Thread.yield() catch {};
    }
}

/// Give the control thread a slice of real time to do something it must NOT
/// do (a bounded settle, ~20 ms), then let the caller assert nothing moved.
fn settle() void {
    const deadline = nowMs() + 20;
    while (nowMs() < deadline) std.Thread.yield() catch {};
}

/// Play AAudio's real-time thread: 4 frames of stereo → 8 interleaved i16.
fn fireDataCallback() i32 {
    var buf: [8]i16 = @splat(0);
    return FakeApi.data_cb.?(FakeApi.last_stream, null, @ptrCast(&buf), 4);
}

test "ensureStarted opens + starts once, wires both callbacks, the data callback drives the mixer; stop joins the control thread" {
    freshFake();
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix); // idempotent
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.opens));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.starts));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.builder_deletes));
    try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.warns));
    try std.testing.expect(FakeApi.error_cb != null);
    try std.testing.expect(Fake.control != null);

    var buf: [8]i16 = @splat(0);
    const rc = FakeApi.data_cb.?(FakeApi.last_stream, null, @ptrCast(&buf), 4);
    try std.testing.expectEqual(AAUDIO_CALLBACK_RESULT_CONTINUE, rc);
    try std.testing.expectEqual(@as(u32, 1), TestMix.calls);
    try std.testing.expectEqual(@as(u8, 2), TestMix.last_channels);
    try std.testing.expectEqual(@as(usize, 8), TestMix.last_len);
    try std.testing.expectEqual(@as(i16, 7), buf[7]);
    try std.testing.expectEqual(@as(u64, 4), Fake.framesMixed());
    // The first callback run hands "started" to the control thread, which
    // logs the marker.
    try waitCount(&FakeApi.infos, 1);
    try std.testing.expectEqualStrings(marker_fmt, FakeApi.last_info);

    Fake.stop();
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.stops));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.closes));
    try std.testing.expect(Fake.control == null);
    try std.testing.expect(Fake.control_exited.load(.acquire));
    Fake.stop(); // idempotent
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.closes));
}

test "disconnect: the error callback only flags + wakes; the control thread reopens with NO further ensureStarted" {
    freshFake();
    Fake.ensureStarted(&TestMix.mix);
    const first = FakeApi.last_stream;
    _ = fireDataCallback();
    try waitCount(&FakeApi.infos, 1);

    // Hold the device mutex while AAudio's error thread reports the route
    // change: the control thread wakes but cannot service yet, so whatever
    // is observed here was done by the callback itself — which must be
    // nothing but the flag.
    {
        const io = ioOf();
        Fake.mutex.lockUncancelable(io);
        defer Fake.mutex.unlock(io);
        FakeApi.error_cb.?(first, null, AAUDIO_ERROR_DISCONNECTED);
        settle();
        try std.testing.expect(Fake.disconnected.load(.acquire));
        try std.testing.expectEqual(AAUDIO_ERROR_DISCONNECTED, Fake.disconnect_result.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.stops));
        try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.closes));
        try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.warns));
        try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.opens));
    }

    // Released: the control thread stops+closes the dead stream, logs ONE
    // "disconnected; reopening" line and opens a NEW stream — the game
    // thread never called ensureStarted again.
    try waitCount(&FakeApi.opens, 2);
    try waitCount(&FakeApi.warns, 1);
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.stops));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.closes));
    try std.testing.expectEqual(@as(u32, 2), count(&FakeApi.starts));
    try std.testing.expect(FakeApi.last_stream != first);
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream disconnected; reopening"));
    try std.testing.expect(!Fake.disconnected.load(.acquire));
    // The new stream's marker waits for ITS data callback.
    settle();
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.infos));
    _ = fireDataCallback();
    try waitCount(&FakeApi.infos, 2);

    // Flag consumed: a later ensureStarted leaves the new stream alone.
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 2), count(&FakeApi.opens));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.closes));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.warns));
}

test "disconnect whose reopen fails: one warning, the control thread waits (no spin), a later ensureStarted retries" {
    freshFake();
    Fake.ensureStarted(&TestMix.mix);
    _ = fireDataCallback();
    try waitCount(&FakeApi.infos, 1);

    FakeApi.open_result = -1;
    FakeApi.error_cb.?(FakeApi.last_stream, null, AAUDIO_ERROR_DISCONNECTED);
    // "disconnected; reopening" + ONE open-failure warning.
    try waitCount(&FakeApi.warns, 2);
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.closes));
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream open failed"));
    try std.testing.expectEqual(@as(u32, 2), count(&FakeApi.open_attempts));
    // No spin: the control thread made exactly one attempt and went back to
    // sleep.
    settle();
    try std.testing.expectEqual(@as(u32, 2), count(&FakeApi.open_attempts));
    try std.testing.expect(Fake.stream == null);

    // The game thread's later entry points retry, silently — one attempt
    // per call.
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 5), count(&FakeApi.open_attempts));
    try std.testing.expectEqual(@as(u32, 2), count(&FakeApi.warns));

    // The route comes back: reopen succeeds, the marker follows its data
    // callback, and the SAME control thread keeps serving.
    FakeApi.open_result = AAUDIO_OK;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 2), count(&FakeApi.opens));
    _ = fireDataCallback();
    try waitCount(&FakeApi.infos, 2);
    try std.testing.expectEqual(@as(u32, 2), count(&FakeApi.warns));
    try std.testing.expect(!Fake.control_exited.load(.acquire));
}

test "setup failures warn once per episode; an observed start resets the episode" {
    freshFake();

    // Builder unavailable: warn once, then silent retries. No stream → no
    // control thread yet.
    FakeApi.create_builder_result = -1;
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.warns));
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream builder unavailable"));
    try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.opens));
    try std.testing.expect(Fake.control == null);

    // Same episode, a different failure kind: still silent (one warning per
    // episode, not per kind).
    FakeApi.create_builder_result = AAUDIO_OK;
    FakeApi.start_result = -1;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.warns));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.opens));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.closes)); // the un-startable stream is closed
    try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.infos));
    try std.testing.expect(Fake.control == null);

    // Success (the stream is observed running) ends the episode...
    FakeApi.start_result = AAUDIO_OK;
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expect(Fake.control != null);
    _ = fireDataCallback();
    try waitCount(&FakeApi.infos, 1);
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.warns));

    // ...so after an explicit stop, a fresh failure warns once more.
    Fake.stop();
    FakeApi.open_result = -1;
    Fake.ensureStarted(&TestMix.mix);
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 2), count(&FakeApi.warns));
    try std.testing.expect(std.mem.startsWith(u8, FakeApi.last_warn, "android: AAudio stream open failed"));
}

test "the started marker is logged only after the data callback runs, never on requestStart alone" {
    freshFake();

    // requestStart accepted; the server has not pulled a buffer yet: no
    // marker, the stream is kept, the marker is owed.
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.starts));
    settle();
    try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.infos));
    try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.warns));
    try std.testing.expect(Fake.marker_owed);

    // Still nothing on a later entry point: no marker, no reopen.
    Fake.ensureStarted(&TestMix.mix);
    settle();
    try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.infos));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.opens));

    // The stream's data callback runs: the marker is emitted exactly once,
    // by the control thread, no matter how many more callbacks or entry
    // points follow.
    _ = fireDataCallback();
    try waitCount(&FakeApi.infos, 1);
    try std.testing.expectEqualStrings(marker_fmt, FakeApi.last_info);
    _ = fireDataCallback();
    _ = fireDataCallback();
    Fake.ensureStarted(&TestMix.mix);
    settle();
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.infos));
    try std.testing.expect(!Fake.marker_owed);
    try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.warns));
}

test "stop joins the control thread and leaves no pending work; a later ensureStarted spawns a fresh one" {
    freshFake();
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expect(Fake.control != null);
    try std.testing.expect(!Fake.control_exited.load(.acquire));

    // Raise both wake sources right before the stop, without giving the
    // thread the mutex: stop must still join it and close the stream itself.
    {
        const io = ioOf();
        Fake.mutex.lockUncancelable(io);
        defer Fake.mutex.unlock(io);
        _ = fireDataCallback();
        FakeApi.error_cb.?(FakeApi.last_stream, null, AAUDIO_ERROR_DISCONNECTED);
    }
    Fake.stop();
    try std.testing.expect(Fake.control == null);
    try std.testing.expect(Fake.control_exited.load(.acquire));
    try std.testing.expect(!Fake.quit.load(.acquire));
    try std.testing.expect(Fake.stream == null);
    try std.testing.expect(!Fake.marker_owed);
    try std.testing.expect(!Fake.disconnected.load(.acquire));
    try std.testing.expect(!Fake.started_observed.load(.acquire));
    // Exactly one stop+close (ours or the thread's, never both), and nothing
    // moves afterwards: the thread is gone.
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.closes));
    const opens_after_stop = count(&FakeApi.opens);
    settle();
    try std.testing.expectEqual(opens_after_stop, count(&FakeApi.opens));
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.closes));

    // Start over: a new stream and a new control thread that serves it.
    Fake.ensureStarted(&TestMix.mix);
    try std.testing.expect(Fake.control != null);
    try std.testing.expect(!Fake.control_exited.load(.acquire));
    const infos_before = count(&FakeApi.infos);
    _ = fireDataCallback();
    try waitCount(&FakeApi.infos, infos_before + 1);
    Fake.stop();
    try std.testing.expect(Fake.control_exited.load(.acquire));
}

test "ensureStarted returns without blocking on the audio server (no state wait, start only requested)" {
    freshFake();
    // The fake never reports STARTED on its own (no data callback fires), the
    // situation in which the old game-thread wait paid its full 250 ms bound.
    const t0 = nowMs();
    Fake.ensureStarted(&TestMix.mix);
    const elapsed = nowMs() - t0;
    try std.testing.expect(elapsed < 100);
    try std.testing.expectEqual(@as(u32, 1), count(&FakeApi.starts));
    try std.testing.expect(Fake.stream != null);
    // Nothing in the Api contract can wait on the server: the device only
    // requests, and observes STARTED through the data callback.
    comptime std.debug.assert(!@hasDecl(NdkApi, "streamWaitForStateChange"));
    comptime std.debug.assert(!@hasDecl(FakeApi, "streamWaitForStateChange"));
    settle();
    try std.testing.expectEqual(@as(u32, 0), count(&FakeApi.infos));
}
