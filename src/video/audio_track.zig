//! Android audio-track decoder — Path A Half 2 audio (FP#549). Moved from
//! labelle-bgfx `src/video/android_audio.zig` (labelle-bgfx#149 phase 1d);
//! reached by consumers as `labelle_android.video.decodeTrack`.
//!
//! Decodes the mp4's audio track (AAC etc.) via `AMediaExtractor` +
//! `AMediaCodec` (ByteBuffer PCM_16 output), then resamples to the mixer's
//! 48 kHz stereo format. The result is fed to the backend's audio mixer (bgfx:
//! `audio.loadMusicFromPcm`) and played in lockstep with the video (the
//! VideoPlayer's audio hooks). Pairs with the AAudio output device (`aaudio`,
//! labelle-bgfx#306).
//!
//! For a short intro we decode the whole track up front (same as the desktop
//! ffmpeg→WAV path), which keeps it simple and avoids a streaming feed into the
//! mixer. comptime-gated to Android; an `Unsupported` stub elsewhere.
//!
//! Split (labelle-android#3 review):
//!   * `decodeTrackAndroid` — the MediaCodec drive loop (Android-only). Feeds
//!     input, drains output until the buffer carrying `FLAG_END_OF_STREAM`, and
//!     tracks the codec's ACTUAL PCM layout via `OUTPUT_FORMAT_CHANGED`.
//!   * `PcmAccumulator` — pure: collects the codec's PCM_16 output buffers,
//!     each tagged with the output format current when it was emitted, and
//!     resamples every format segment to 48 kHz stereo at `finish`. Host-tested
//!     with a fake buffer sequence including a mid-stream rate/channel change.
//!     It also places the PCM on the media timeline from the track's first
//!     presentation time (`setStartOffsetUs`: silence for a late start, a
//!     trimmed head for an early one; labelle-android#8).
//!   * `Downmix` — pure: the per-channel stereo gains for the segment's layout
//!     (the format's `channel-mask`, else the count's default): BS.775-style
//!     5.1/7.1/… → stereo with the LFE dropped, normalised against clipping;
//!     mono duplicated, stereo untouched (labelle-android#8).
//!   * `classifyDequeue` / `afterOutputBuffer` / `outFrames48k` — pure
//!     helpers for the drain decisions (incl. stopping once the output cap is
//!     full, labelle-android#5) and the (u64-widened) frame-count arithmetic;
//!     host-tested.

const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;

const OUT_RATE: u32 = 48000;
const OUT_CHANNELS: u32 = 2;
/// 5 min cap on the decoded, post-resample output. The raw (source-rate)
/// accumulation is bounded in OUTPUT-frame units from the active format
/// (`PcmAccumulator.rawRoom`), so a 5.1 or 96 kHz source reaches the same
/// 5 min of output as a stereo 44.1 kHz one — a fixed raw-sample cap
/// (`MAX_FRAMES * 4`, the earlier rule) truncated 48 kHz 5.1 after 200 s.
const MAX_FRAMES: usize = 5 * 60 * OUT_RATE;

/// How many times a `AMediaCodec_queueInputBuffer` failure is retried (with
/// a fresh input buffer, the extractor NOT advanced) before the decode fails.
/// A codec that refuses its input is not going to produce EOS; without the
/// bound the loop would poll to the 30 s deadline. See `InputQueue`.
const MAX_INPUT_QUEUE_FAILURES: u32 = 8;

/// Wall-clock bound on the WHOLE decode (feeding input + draining to output
/// EOS), measured from codec start on the monotonic clock. A codec that never
/// produces EOS (or never returns a buffer) would otherwise hang the caller
/// forever, since `TRY_AGAIN_LATER` after input EOS is not "done". 30 s is
/// far above any real decode: the 5-min output cap is ~3 s of hardware AAC
/// decode and well under 30 s on a software decoder, and every idle poll
/// blocks at most 5 ms inside the codec, so the deadline is checked at
/// ≥ 100 Hz.
const DECODE_DEADLINE_NS: i64 = 30 * std.time.ns_per_s;

pub const Pcm = struct {
    samples: []i16, // interleaved stereo @ 48 kHz
    frames: u32,
    pub fn deinit(self: *Pcm, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
};

/// `DecodeFailed`: the codec reported an error from a dequeue, or the decode
/// overran `DECODE_DEADLINE_NS` (logged with the reason).
pub const Error = error{ Unsupported, NoAudioTrack, DecodeInit, DecodeFailed, OutOfMemory };

/// Decode the file's audio track to 48 kHz stereo i16. Caller owns the samples.
pub const decodeTrack = if (is_android) decodeTrackAndroid else decodeTrackStub;

fn decodeTrackStub(_: std.mem.Allocator, _: c_int, _: i64, _: i64) Error!Pcm {
    return error.Unsupported;
}

// ── MediaCodec dequeue results (NdkMediaCodec.h) ──────────────────────────

/// `AMEDIACODEC_INFO_TRY_AGAIN_LATER`: no buffer within the poll timeout.
const INFO_TRY_AGAIN_LATER: isize = -1;
/// `AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED`: read `getOutputFormat` before
/// the next buffer. Emitted once before the first output buffer and again
/// whenever the decoded layout changes (HE-AAC SBR / parametric stereo yield a
/// rate or channel count that differs from the container's track metadata).
const INFO_OUTPUT_FORMAT_CHANGED: isize = -2;
/// `AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED`: informational (no-op since API
/// 21 with `getOutputBuffer`); keep draining.
const INFO_OUTPUT_BUFFERS_CHANGED: isize = -3;

const DequeueResult = enum { buffer, try_again, format_changed, buffers_changed, codec_error };

/// Tracks `AMediaCodec_queueInputBuffer` results (pure; host-tested). A
/// failed queue leaves the codec WITHOUT that packet: the drive loop must
/// neither mark input EOS (the EOS would never be queued and the decode
/// would wait out its deadline) nor advance the extractor (the sample would
/// be silently dropped). `onQueue` says whether to proceed, retry the same
/// packet with the next input buffer, or give up after
/// `MAX_INPUT_QUEUE_FAILURES` consecutive failures.
const InputQueue = struct {
    const Outcome = enum { queued, retry, failed };
    failures: u32 = 0,

    fn onQueue(self: *InputQueue, status: i32) Outcome {
        if (status == 0) { // AMEDIA_OK
            self.failures = 0;
            return .queued;
        }
        self.failures += 1;
        return if (self.failures >= MAX_INPUT_QUEUE_FAILURES) .failed else .retry;
    }
};

/// What the drive loop does after releasing one output buffer (pure;
/// host-tested; labelle-android#5).
const OutputStep = enum {
    /// Keep feeding input and draining output.
    drain,
    /// Stop decoding and `finish` with the accumulated PCM.
    finish,
    /// The codec refused the release: give up (`DecodeFailed`).
    fail,
};

/// `release_status` is `AMediaCodec_releaseOutputBuffer`'s result, `eos`
/// whether the buffer carried `FLAG_END_OF_STREAM`, `cap_full` whether the
/// accumulator's output cap is reached (`PcmAccumulator.full`).
///   - Output EOS or a full cap FINISHES. Past the cap `push` drops every
///     sample, so draining on to EOS decodes the rest of the track for
///     nothing: a track far longer than the cap then overran
///     `DECODE_DEADLINE_NS` and lost ALL its audio instead of keeping the
///     capped first 5 min. A refused release on that last buffer is moot.
///   - Otherwise a refused release FAILS at once: the buffer never returns to
///     the codec, and a few such losses exhaust its output pool so the loop
///     would only poll on to the deadline.
fn afterOutputBuffer(release_status: i32, eos: bool, cap_full: bool) OutputStep {
    if (eos or cap_full) return .finish;
    if (release_status != 0) return .fail; // != AMEDIA_OK
    return .drain;
}

/// Classify a `AMediaCodec_dequeue{Input,Output}Buffer` result. Any negative
/// value that is not one of the three `AMEDIACODEC_INFO_*` constants is a
/// real codec error (`AMEDIA_ERROR_*` are ≤ -10000): the codec will never
/// produce EOS after one, so the drive loop must fail instead of polling on.
/// What the drive loop does when the decode deadline passes (pure;
/// host-tested). A track with a negative start offset spends decode time on
/// PCM the trim discards — however long the lead, only decode time, never
/// memory — so a pathological pre-roll (an hour before media time 0) may
/// outlast the deadline: it FINISHES with whatever was kept after time 0
/// (`finish` → `NoAudioTrack` when the trim never completed). Any other
/// overrun is a codec that never reached EOS: it FAILS as before.
const DeadlineStep = enum { finish, fail };
fn afterDeadline(acc: *const PcmAccumulator) DeadlineStep {
    return if (acc.lead < 0) .finish else .fail;
}

fn classifyDequeue(r: isize) DequeueResult {
    if (r >= 0) return .buffer;
    return switch (r) {
        INFO_TRY_AGAIN_LATER => .try_again,
        INFO_OUTPUT_FORMAT_CHANGED => .format_changed,
        INFO_OUTPUT_BUFFERS_CHANGED => .buffers_changed,
        else => .codec_error,
    };
}

fn decodeTrackAndroid(allocator: std.mem.Allocator, fd: c_int, offset: i64, length: i64) Error!Pcm {
    const Extractor = opaque {};
    const Codec = opaque {};
    const Format = opaque {};
    const BufferInfo = extern struct { offset: i32, size: i32, presentation_time_us: i64, flags: u32 };
    // bionic `struct timespec`: `time_t` is `long` on every Android ABI.
    const Timespec = extern struct { sec: c_long, nsec: c_long };

    const X = struct {
        extern fn AMediaExtractor_new() ?*Extractor;
        extern fn AMediaExtractor_setDataSourceFd(*Extractor, c_int, i64, i64) i32;
        extern fn AMediaExtractor_getTrackCount(*Extractor) usize;
        extern fn AMediaExtractor_getTrackFormat(*Extractor, usize) ?*Format;
        extern fn AMediaExtractor_selectTrack(*Extractor, usize) i32;
        extern fn AMediaExtractor_readSampleData(*Extractor, [*]u8, usize) isize;
        extern fn AMediaExtractor_advance(*Extractor) bool;
        extern fn AMediaExtractor_getSampleTime(*Extractor) i64;
        extern fn AMediaExtractor_delete(*Extractor) void;
        extern fn AMediaFormat_getString(*Format, [*:0]const u8, *[*:0]const u8) bool;
        extern fn AMediaFormat_getInt32(*Format, [*:0]const u8, *i32) bool;
        extern fn AMediaFormat_delete(*Format) void;
        extern fn AMediaCodec_createDecoderByType([*:0]const u8) ?*Codec;
        extern fn AMediaCodec_configure(*Codec, *Format, ?*anyopaque, ?*anyopaque, u32) i32;
        extern fn AMediaCodec_start(*Codec) i32;
        extern fn AMediaCodec_stop(*Codec) i32;
        extern fn AMediaCodec_delete(*Codec) void;
        extern fn AMediaCodec_dequeueInputBuffer(*Codec, i64) isize;
        extern fn AMediaCodec_getInputBuffer(*Codec, usize, *usize) ?[*]u8;
        // `offset` is `_off_t_compat` (NdkMediaCodec.h): `long`-sized.
        extern fn AMediaCodec_queueInputBuffer(*Codec, usize, c_long, usize, u64, u32) i32;
        extern fn AMediaCodec_dequeueOutputBuffer(*Codec, *BufferInfo, i64) isize;
        extern fn AMediaCodec_getOutputBuffer(*Codec, usize, *usize) ?[*]u8;
        extern fn AMediaCodec_getOutputFormat(*Codec) ?*Format;
        extern fn AMediaCodec_releaseOutputBuffer(*Codec, usize, bool) i32;
        // The decode deadline's clock (bionic; `CLOCK_MONOTONIC` = 1 on
        // Linux). Zig 0.16's `std.Io.Clock` needs an `Io` the decoder has no
        // access to, so the libc call is bound directly (as `decoder.zig`
        // binds `usleep`).
        extern fn clock_gettime(clk: i32, ts: *Timespec) c_int;
        fn monotonicNs() i64 {
            var ts: Timespec = .{ .sec = 0, .nsec = 0 };
            _ = clock_gettime(1, &ts);
            return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
        }
    };
    const OK: i32 = 0;
    const FLAG_EOS: u32 = 4; // AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM
    const POLL_US: i64 = 5000; // max block per dequeue when nothing is ready
    const KEY_MIME: [*:0]const u8 = "mime";
    const KEY_RATE: [*:0]const u8 = "sample-rate"; // AMEDIAFORMAT_KEY_SAMPLE_RATE
    const KEY_CH: [*:0]const u8 = "channel-count"; // AMEDIAFORMAT_KEY_CHANNEL_COUNT
    const KEY_MASK: [*:0]const u8 = "channel-mask"; // AMEDIAFORMAT_KEY_CHANNEL_MASK

    const ex = X.AMediaExtractor_new() orelse return error.DecodeInit;
    defer X.AMediaExtractor_delete(ex);
    if (X.AMediaExtractor_setDataSourceFd(ex, fd, offset, length) != OK) return error.DecodeInit;

    // Find the first audio track + its source rate/channels.
    const n = X.AMediaExtractor_getTrackCount(ex);
    var track: usize = 0;
    var found = false;
    var mime_buf: [64]u8 = undefined;
    var mime_len: usize = 0;
    var src_rate: i32 = OUT_RATE;
    var src_ch: i32 = 2;
    var src_mask: i32 = 0; // 0 = not reported: `Downmix` falls back to the count's default layout
    while (track < n) : (track += 1) {
        const fmt = X.AMediaExtractor_getTrackFormat(ex, track) orelse continue;
        defer X.AMediaFormat_delete(fmt);
        var m: [*:0]const u8 = undefined;
        if (!X.AMediaFormat_getString(fmt, KEY_MIME, &m)) continue;
        const span = std.mem.span(m);
        if (!std.mem.startsWith(u8, span, "audio/")) continue;
        if (span.len + 1 > mime_buf.len) continue;
        _ = X.AMediaFormat_getInt32(fmt, KEY_RATE, &src_rate);
        _ = X.AMediaFormat_getInt32(fmt, KEY_CH, &src_ch);
        _ = X.AMediaFormat_getInt32(fmt, KEY_MASK, &src_mask);
        @memcpy(mime_buf[0..span.len], span);
        mime_buf[span.len] = 0;
        mime_len = span.len;
        found = true;
        break;
    }
    if (!found) return error.NoAudioTrack;
    const mime: [*:0]const u8 = mime_buf[0..mime_len :0].ptr;
    if (X.AMediaExtractor_selectTrack(ex, track) != OK) return error.DecodeInit;
    // The audio track's first presentation time (labelle-android#8). The
    // player clocks from media time 0 and presents every video frame at its
    // own absolute PTS, so PCM frame 0 must be media time 0: a track starting
    // late is padded with silence, one starting early (negative PTS: encoder
    // priming kept by an edit list) is trimmed. -1 = no sample (empty track).
    const first_us = X.AMediaExtractor_getSampleTime(ex);

    const codec = X.AMediaCodec_createDecoderByType(mime) orelse return error.DecodeInit;
    defer {
        _ = X.AMediaCodec_stop(codec);
        X.AMediaCodec_delete(codec);
    }
    const cfg = X.AMediaExtractor_getTrackFormat(ex, track) orelse return error.DecodeInit;
    defer X.AMediaFormat_delete(cfg);
    if (X.AMediaCodec_configure(codec, cfg, null, null, 0) != OK) return error.DecodeInit;
    if (X.AMediaCodec_start(codec) != OK) return error.DecodeInit;
    const t_start = X.monotonicNs();

    // Accumulate decoded interleaved PCM_16, tagged with the codec's CURRENT
    // output format. The track metadata seeds it; `OUTPUT_FORMAT_CHANGED`
    // overrides it with what the decoder actually emits.
    var acc = PcmAccumulator.init(@intCast(@max(src_rate, 1)), @intCast(@max(src_ch, 1)));
    acc.mask = @bitCast(src_mask);
    defer acc.deinit(allocator);
    if (first_us != -1) {
        acc.setStartOffsetUs(first_us);
        std.log.info("video: audio track starts at {d} us — {s} {d} frames @ 48 kHz", .{
            first_us,
            if (acc.lead >= 0) "padding" else "skipping",
            @abs(acc.lead),
        });
    }
    var input_done = false;
    var input_queue: InputQueue = .{};
    // Ends ONLY on the output buffer carrying FLAG_EOS, a full output cap
    // (`afterOutputBuffer`), a codec error, or the deadline. After input EOS is queued, `TRY_AGAIN_LATER` merely means no
    // output surfaced within this poll: the decoder still owes the delayed tail
    // of the track (and a short or slow-to-start decode owes all of it).
    while (true) {
        if (X.monotonicNs() - t_start > DECODE_DEADLINE_NS) switch (afterDeadline(&acc)) {
            // A long pre-roll (negative start offset) is decoded and
            // discarded before anything is kept: an hour-long lead can
            // outlast the deadline. Give up with what was kept after media
            // time 0 (`NoAudioTrack` if the trim never finished).
            .finish => {
                std.log.warn("video: audio decode overran {d} s while skipping a {d}-frame pre-roll — keeping what was decoded", .{ @divTrunc(DECODE_DEADLINE_NS, std.time.ns_per_s), @abs(acc.lead) });
                break;
            },
            .fail => {
                std.log.err("video: audio decode overran {d} s without output EOS — giving up", .{@divTrunc(DECODE_DEADLINE_NS, std.time.ns_per_s)});
                return error.DecodeFailed;
            },
        };
        if (!input_done) {
            const in_idx = X.AMediaCodec_dequeueInputBuffer(codec, POLL_US);
            if (in_idx >= 0) {
                const idx: usize = @intCast(in_idx);
                var cap: usize = 0;
                if (X.AMediaCodec_getInputBuffer(codec, idx, &cap)) |buf| {
                    // `readSampleData` does not advance: a packet whose queue
                    // fails is re-read into the next input buffer. State
                    // (input EOS / the extractor position) moves only on a
                    // successful queue — `InputQueue`.
                    const got = X.AMediaExtractor_readSampleData(ex, buf, cap);
                    const eos = got < 0;
                    // The packet's own PTS (clamped ≥ 0, read BEFORE advance,
                    // as the video decoder does): the codec's output
                    // timestamps then mean something. The PCM's placement
                    // comes from `first_us` above, not from these.
                    const time_us: u64 = @intCast(@max(X.AMediaExtractor_getSampleTime(ex), 0));
                    const status = if (eos)
                        X.AMediaCodec_queueInputBuffer(codec, idx, 0, 0, time_us, FLAG_EOS)
                    else
                        X.AMediaCodec_queueInputBuffer(codec, idx, 0, @intCast(got), time_us, 0);
                    switch (input_queue.onQueue(status)) {
                        .queued => if (eos) {
                            input_done = true;
                        } else {
                            _ = X.AMediaExtractor_advance(ex);
                        },
                        .retry => std.log.warn("video: audio codec refused an input buffer ({d}); retrying the packet", .{status}),
                        .failed => {
                            std.log.err("video: audio codec refused {d} consecutive input buffers (last {d}) — giving up", .{ MAX_INPUT_QUEUE_FAILURES, status });
                            return error.DecodeFailed;
                        },
                    }
                }
            } else if (classifyDequeue(in_idx) == .codec_error) {
                std.log.err("video: audio codec error {d} on input dequeue", .{in_idx});
                return error.DecodeFailed;
            }
        }
        var info: BufferInfo = undefined;
        const out_idx = X.AMediaCodec_dequeueOutputBuffer(codec, &info, POLL_US);
        switch (classifyDequeue(out_idx)) {
            .buffer => {
                const idx: usize = @intCast(out_idx);
                var size: usize = 0;
                if (X.AMediaCodec_getOutputBuffer(codec, idx, &size)) |buf| {
                    const start: usize = @min(@as(usize, @intCast(@max(info.offset, 0))), size);
                    const end: usize = @min(start + @as(usize, @intCast(@max(info.size, 0))), size);
                    acc.push(allocator, buf[start..end]) catch return error.OutOfMemory;
                }
                const rc = X.AMediaCodec_releaseOutputBuffer(codec, idx, false);
                switch (afterOutputBuffer(rc, info.flags & FLAG_EOS != 0, acc.full())) {
                    .drain => {},
                    // Output EOS, or the output cap is full: finish with what
                    // is accumulated. Past the cap every further sample is
                    // dropped, so decoding the rest of a long track would only
                    // spend the deadline (and lose ALL the audio on overrun).
                    // Leaving before EOS is safe: the `defer` stops the codec.
                    .finish => break,
                    .fail => {
                        std.log.err("video: audio codec refused an output buffer release ({d}) — giving up", .{rc});
                        return error.DecodeFailed;
                    },
                }
            },
            .format_changed => {
                // The decoded layout may differ from the container's track
                // metadata (HE-AAC SBR doubles the rate, parametric stereo
                // widens mono): group and resample by what the codec emits.
                if (X.AMediaCodec_getOutputFormat(codec)) |fmt| {
                    defer X.AMediaFormat_delete(fmt);
                    var rate: i32 = @intCast(acc.rate);
                    var ch: i32 = @intCast(acc.ch);
                    // A mask is per-format: one the new format omits is NOT
                    // carried over from the old (it may describe another count).
                    var mask: i32 = 0;
                    _ = X.AMediaFormat_getInt32(fmt, KEY_RATE, &rate);
                    _ = X.AMediaFormat_getInt32(fmt, KEY_CH, &ch);
                    _ = X.AMediaFormat_getInt32(fmt, KEY_MASK, &mask);
                    const new_rate: u32 = @intCast(@max(rate, 1));
                    const new_ch: u32 = @intCast(@max(ch, 1));
                    const new_mask: u32 = @bitCast(mask);
                    std.log.info("video: audio output format {d} Hz, {d} ch, mask 0x{x} → stereo {s} (track metadata {d} Hz, {d} ch)", .{
                        new_rate,
                        new_ch,
                        new_mask,
                        @tagName(Downmix.forLayout(new_ch, new_mask).kind),
                        @max(src_rate, 1),
                        @max(src_ch, 1),
                    });
                    acc.setFormat(allocator, new_rate, new_ch, new_mask) catch return error.OutOfMemory;
                }
            },
            .try_again, .buffers_changed => {}, // keep draining, before AND after input EOS
            .codec_error => {
                std.log.err("video: audio codec error {d} on output dequeue", .{out_idx});
                return error.DecodeFailed;
            },
        }
    }

    return acc.finish(allocator);
}

// ── Pure PCM accumulation + resampling (host-tested) ──────────────────────

/// Output frames for `in_frames` source frames at `src_rate`, resampled to
/// 48 kHz and capped at `max_frames`. The product is formed in u64: on the
/// 32-bit Android ABIs `usize` is 32 bits and `in_frames * 48000` wraps after
/// only 89 478 frames (~2 s of audio), trapping in checked builds and sizing
/// the output wrong in unchecked ones.
fn outFrames48k(in_frames: u64, src_rate: u32, max_frames: usize) usize {
    return @intCast(@min(out48k(in_frames, src_rate), @as(u64, max_frames)));
}

/// `in_frames` source frames at `src_rate` as 48 kHz frames, rounded down,
/// in u64 (see `outFrames48k`).
fn out48k(in_frames: u64, src_rate: u32) u64 {
    return (in_frames *| OUT_RATE) / @max(src_rate, 1);
}

/// Source frames at `src_rate` that resample to `out_frames` at 48 kHz —
/// rounded UP so the last output frame has its source sample. u64 throughout:
/// the 5-min cap plus a 5-min trim at a high rate (`2 · MAX_FRAMES ·
/// 192 kHz` ≈ 5.5e12) is far past u32. Saturating: the trim is uncapped (a
/// metadata start time near `minInt(i64)` µs is ~4.4e17 frames), and a
/// saturated count only means "more than will ever be decoded".
fn srcFramesCeil(out_frames: u64, src_rate: u32) u64 {
    return ((out_frames *| @max(src_rate, 1)) +| (OUT_RATE - 1)) / OUT_RATE;
}

/// Source frames at `src_rate` the first `out_frames` 48 kHz output frames
/// have fully moved past — rounded DOWN: output frame `out_frames` still
/// interpolates from source frame `srcFramesFloor(out_frames)`, so only the
/// frames before it can be discarded. u64 like `srcFramesCeil`.
fn srcFramesFloor(out_frames: u64, src_rate: u32) u64 {
    return (out_frames *| @max(src_rate, 1)) / OUT_RATE;
}

/// Signed 48 kHz output-frame lead for an audio track whose first sample is
/// at `first_us` on the media timeline: positive = frames of silence to
/// prepend, negative = decoded frames to drop. Rounded to the nearest frame
/// (half away from zero) in i128, so no metadata value can overflow.
fn leadFrames(first_us: i64) i64 {
    const num: i128 = @as(i128, first_us) * OUT_RATE;
    const half: i128 = if (num >= 0) 500_000 else -500_000;
    const frames = @divTrunc(num + half, 1_000_000);
    return @intCast(std.math.clamp(frames, std.math.minInt(i64), std.math.maxInt(i64)));
}

/// Collects the codec's interleaved PCM_16 output buffers as they are emitted.
/// Each buffer is grouped under the output format in force when it arrived,
/// so a mid-stream `setFormat` (from `OUTPUT_FORMAT_CHANGED`) starts a new
/// segment instead of misreading earlier samples. `finish` resamples every
/// segment to 48 kHz stereo — downmixing its channel layout (`Downmix`) — in
/// order, into one `Pcm`, after the start-offset lead (`setStartOffsetUs`):
/// silence for a track that starts late, a trimmed head for one that starts
/// early (labelle-android#8).
///
/// The accumulation is bounded in OUTPUT frames (`max_frames`, `MAX_FRAMES`
/// in production, small in tests): the closed segments' kept output frames
/// plus the open segment's projection at its rate/channels. A source needing
/// more than four raw samples per output frame (5.1, 96 kHz…) therefore
/// still fills the advertised 5 min instead of stopping early. Padded
/// silence counts against the cap. Trimmed frames are decoded but NEVER
/// retained: `push` discards them as they arrive, so the retained PCM stays
/// within the cap however long the trim. The cap bounds KEPT output only, so
/// the trim itself is uncapped: a track starting 301 s early that runs 10 min
/// still keeps the audio after media time 0. A very long lead costs decode
/// time, which the drive loop's deadline bounds (`afterDeadline`).
const PcmAccumulator = struct {
    /// A closed segment's retained samples `raw[start..end]` (source frame
    /// `src_off` onward) and the output frames it contributes: frames
    /// `first .. first + keep` of the segment's own 48 kHz timeline.
    const Segment = struct { rate: u32, ch: u32, mask: u32, start: usize, end: usize, src_off: u64, first: u64, keep: usize };

    raw: std.ArrayList(i16) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    /// Current output format (applies to samples from `seg_start` on).
    rate: u32,
    ch: u32,
    /// The format's `channel-mask` (Android `AudioFormat.CHANNEL_OUT_*`
    /// bits), 0 when not reported. See `Downmix.forLayout`.
    mask: u32 = 0,
    /// Where the open segment's RETAINED samples start in `raw`.
    seg_start: usize = 0,
    /// Samples the open segment has accepted (discarded trim included).
    seg_in: u64 = 0,
    /// Leading samples of the open segment discarded by the trim.
    seg_src_off: u64 = 0,
    /// KEPT output frames the closed segments will produce.
    closed_out: usize = 0,
    /// Output-frame cap (`MAX_FRAMES`; tests shrink it).
    max_frames: usize = MAX_FRAMES,
    /// Start-offset lead in 48 kHz output frames (`leadFrames`): > 0 pads
    /// silence before the first decoded frame, < 0 drops decoded frames.
    lead: i64 = 0,
    /// Output frames still to trim at the open segment's start.
    skip_left: u64 = 0,

    fn init(rate: u32, ch: u32) PcmAccumulator {
        return .{ .rate = @max(rate, 1), .ch = @max(ch, 1) };
    }

    /// The audio track's first presentation time on the media (= video)
    /// timeline. Set before the first `push` (and after `max_frames`). The
    /// trim is NOT bounded by the cap (which bounds kept output, not how much
    /// pre-zero audio may be discarded): trimmed PCM is discarded as it
    /// arrives, so any lead costs decode time only.
    fn setStartOffsetUs(self: *PcmAccumulator, first_us: i64) void {
        self.lead = leadFrames(first_us);
        self.skip_left = if (self.lead < 0) @abs(self.lead) else 0;
    }

    /// Silence frames `finish` prepends (never more than the whole cap).
    fn padFrames(self: *const PcmAccumulator) usize {
        if (self.lead <= 0) return 0;
        return @intCast(@min(@as(u64, @intCast(self.lead)), @as(u64, self.max_frames)));
    }

    /// Decoded 48 kHz frames the lead drops from the head (uncapped, u64).
    fn skipFrames(self: *const PcmAccumulator) u64 {
        if (self.lead >= 0) return 0;
        return @abs(self.lead);
    }

    /// KEPT output frames that fit: the cap less the padded silence.
    fn budget(self: *const PcmAccumulator) usize {
        return self.max_frames - self.padFrames();
    }

    /// The open segment's source samples still to be trimmed at `in`
    /// accepted samples: every sample before the first source frame the
    /// first kept output frame interpolates from. Monotonic in `in`, a
    /// whole number of frames, and ≤ `in`.
    fn trimTarget(self: *const PcmAccumulator, in: u64) u64 {
        const seg_skip = @min(self.skip_left, out48k(in / self.ch, self.rate));
        return srcFramesFloor(seg_skip, self.rate) * self.ch;
    }

    /// Samples (all channels, trimmed ones included) the OPEN segment may
    /// still accept before the output cap is reached, at the current
    /// rate/channels: enough source to finish the trim plus the cap's
    /// remaining output.
    fn rawRoom(self: *const PcmAccumulator) usize {
        const out_left: u64 = self.budget() -| self.closed_out;
        if (out_left == 0) return 0;
        const seg_cap = srcFramesCeil(self.skip_left +| out_left, self.rate) *| self.ch;
        return @intCast(@min(seg_cap -| self.seg_in, std.math.maxInt(usize)));
    }

    /// The output cap is reached: every further `push` would be dropped, so
    /// the drive loop stops decoding (`afterOutputBuffer`).
    fn full(self: *const PcmAccumulator) bool {
        return self.rawRoom() == 0;
    }

    fn deinit(self: *PcmAccumulator, allocator: std.mem.Allocator) void {
        self.raw.deinit(allocator);
        self.segments.deinit(allocator);
    }

    /// The codec's output format from here on (`mask` 0 = not reported). A
    /// change closes the open segment (if it holds samples); the same values
    /// are a no-op.
    fn setFormat(self: *PcmAccumulator, allocator: std.mem.Allocator, rate: u32, ch: u32, mask: u32) std.mem.Allocator.Error!void {
        const r = @max(rate, 1);
        const c = @max(ch, 1);
        if (r == self.rate and c == self.ch and mask == self.mask) return;
        try self.closeSegment(allocator);
        self.rate = r;
        self.ch = c;
        self.mask = mask;
    }

    /// Append one output buffer's bytes: little-endian i16, read unaligned
    /// (`bytesAsSlice(i16, …)` would need i16 alignment the codec's ByteBuffer
    /// does not guarantee). A trailing odd byte is dropped; past the output
    /// cap (`rawRoom`) the excess is dropped. Samples the start-offset trim
    /// covers are discarded here — the ones already retained from earlier
    /// buffers first, then the new buffer's head is never appended — so
    /// trimmed PCM never accumulates.
    fn push(self: *PcmAccumulator, allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
        const count = @min(bytes.len / 2, self.rawRoom());
        const new_in = self.seg_in + count;
        const target = self.trimTarget(new_in);
        // Retained samples of earlier buffers the trim now covers.
        const retained = self.seg_in - self.seg_src_off;
        const drop_old: usize = @intCast(@min(target -| self.seg_src_off, retained));
        if (drop_old > 0) {
            const seg = self.raw.items[self.seg_start..];
            std.mem.copyForwards(i16, seg, seg[drop_old..]);
            self.raw.shrinkRetainingCapacity(self.raw.items.len - drop_old);
        }
        // This buffer's samples the trim covers (index seg_in + i < target).
        const drop_new: usize = @intCast(@min(target -| self.seg_in, count));
        self.seg_src_off += drop_old + drop_new; // = target
        self.seg_in = new_in;
        try self.raw.ensureUnusedCapacity(allocator, count - drop_new);
        var i: usize = drop_new;
        while (i < count) : (i += 1) {
            self.raw.appendAssumeCapacity(std.mem.readInt(i16, bytes[i * 2 ..][0..2], .little));
        }
    }

    fn closeSegment(self: *PcmAccumulator, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.seg_in > 0) {
            const seg_out = out48k(self.seg_in / self.ch, self.rate);
            const seg_skip = @min(self.skip_left, seg_out);
            const keep: usize = @intCast(@min(seg_out - seg_skip, @as(u64, self.budget() -| self.closed_out)));
            if (keep > 0) {
                try self.segments.append(allocator, .{
                    .rate = self.rate,
                    .ch = self.ch,
                    .mask = self.mask,
                    .start = self.seg_start,
                    .end = self.raw.items.len,
                    .src_off = self.seg_src_off / self.ch,
                    .first = seg_skip,
                    .keep = keep,
                });
                self.closed_out += keep;
            } else {
                // Wholly trimmed (or past the cap): nothing to keep.
                self.raw.shrinkRetainingCapacity(self.seg_start);
            }
            self.skip_left -= seg_skip;
        }
        self.seg_start = self.raw.items.len;
        self.seg_in = 0;
        self.seg_src_off = 0;
    }

    /// Resample + downmix every segment to 48 kHz stereo after the lead
    /// (silence prepended or the head dropped), capped at `max_frames` in
    /// total. Caller owns the samples. `NoAudioTrack` when nothing decoded
    /// survives the trim.
    fn finish(self: *PcmAccumulator, allocator: std.mem.Allocator) Error!Pcm {
        self.closeSegment(allocator) catch return error.OutOfMemory;
        if (self.closed_out == 0) return error.NoAudioTrack;
        const pad = self.padFrames();
        const total = pad + self.closed_out; // ≤ max_frames by `budget`
        const out = allocator.alloc(i16, total * OUT_CHANNELS) catch return error.OutOfMemory;
        @memset(out[0 .. pad * OUT_CHANNELS], 0);
        var written: usize = pad; // output frames filled (silence included)
        for (self.segments.items) |s| {
            resampleInto(out[written * OUT_CHANNELS ..][0 .. s.keep * OUT_CHANNELS], self.raw.items[s.start..s.end], s.rate, s.ch, Downmix.forLayout(s.ch, s.mask), s.first, s.src_off);
            written += s.keep;
        }
        std.debug.assert(written == total);
        return .{ .samples = out, .frames = @intCast(total) };
    }
};

/// Android `AudioFormat.CHANNEL_OUT_*` speaker bits (the `channel-mask` a
/// MediaCodec output format carries). Interleaved PCM holds the mask's
/// channels in ascending bit order.
const Speaker = struct {
    const FL: u32 = 0x4;
    const FR: u32 = 0x8;
    const FC: u32 = 0x10;
    const LFE: u32 = 0x20;
    const BL: u32 = 0x40;
    const BR: u32 = 0x80;
    const FLC: u32 = 0x100;
    const FRC: u32 = 0x200;
    const BC: u32 = 0x400;
    const SL: u32 = 0x800;
    const SR: u32 = 0x1000;
    const TC: u32 = 0x2000;
    const TFL: u32 = 0x4000;
    const TFC: u32 = 0x8000;
    const TFR: u32 = 0x10000;
    const TBL: u32 = 0x20000;
    const TBC: u32 = 0x40000;
    const TBR: u32 = 0x80000;
    const TSL: u32 = 0x100000;
    const TSR: u32 = 0x200000;
    const BFL: u32 = 0x400000;
    const BFC: u32 = 0x800000;
    const BFR: u32 = 0x1000000;
    const LFE2: u32 = 0x2000000;
    const FWL: u32 = 0x4000000;
    const FWR: u32 = 0x8000000;
    /// Every bit above (bits 0–1 are not speakers).
    const ALL: u32 = 0xFFFFFFC;

    const left = FL | BL | FLC | SL | TFL | TBL | TSL | BFL | FWL;
    const right = FR | BR | FRC | SR | TFR | TBR | TSR | BFR | FWR;
    const centre = FC | BC | TC | TFC | TBC | BFC;
    const lfe = LFE | LFE2;

    /// The layout MediaCodec means by a bare channel count (the
    /// `AudioFormat` defaults: 5.1 = FL FR FC LFE BL BR, 7.1 adds SL SR,
    /// and 3 channels are 2.1 = FL FR LFE, whose LFE the downmix drops, so
    /// L/R pass through un-normalised). 0 for a count with no standard
    /// layout.
    fn defaultMask(ch: u32) u32 {
        return switch (ch) {
            1 => FC,
            2 => FL | FR,
            3 => FL | FR | LFE, // 2.1 (`CHANNEL_OUT_2POINT1`), not 3.0
            4 => FL | FR | BL | BR, // quad
            5 => FL | FR | FC | BL | BR, // 5.0
            6 => FL | FR | FC | LFE | BL | BR, // 5.1
            7 => FL | FR | FC | LFE | BL | BR | BC, // 6.1
            8 => FL | FR | FC | LFE | BL | BR | SL | SR, // 7.1
            else => 0,
        };
    }
};

/// Per-channel stereo gains for one source layout (ITU-R BS.775-style):
/// front L/R pass straight through, every centre channel (FC, BC, the top /
/// bottom centres) goes to both sides at −3 dB (0.7071), every other
/// left/right channel (surrounds, sides, wides, heights) to its own side at
/// −3 dB, and the LFE is dropped. The gains are then normalised by the larger
/// side's sum so a full-scale signal on every channel cannot clip — 5.1:
/// L' = (L + 0.7071·C + 0.7071·Ls) / 2.4142. Mono duplicates, stereo is the
/// identity (both sums are 1, no normalisation).
const Downmix = struct {
    /// Channels a layout can weight; a larger count keeps channels 0/1 only.
    const MAX_CH = 32;
    const MINUS_3DB: f32 = 0.70710678;
    const Kind = enum { mono, stereo, mask, count_default, first_two };

    l: [MAX_CH]f32 = @splat(0),
    r: [MAX_CH]f32 = @splat(0),
    kind: Kind,

    /// `mask` is used when it is a speaker mask with exactly `ch` speakers;
    /// otherwise the count's default layout; otherwise (a count > 8 with no
    /// usable mask) channels 0 and 1 as L/R.
    fn forLayout(ch: u32, mask: u32) Downmix {
        if (ch <= 1) {
            var d: Downmix = .{ .kind = .mono };
            d.l[0] = 1;
            d.r[0] = 1;
            return d;
        }
        const mask_ok = mask != 0 and mask & ~Speaker.ALL == 0 and @popCount(mask) == ch;
        const layout = if (mask_ok) mask else Speaker.defaultMask(ch);
        if (layout == 0 or ch > MAX_CH) {
            var d: Downmix = .{ .kind = .first_two };
            d.l[0] = 1;
            d.r[1] = 1;
            return d;
        }
        var d: Downmix = .{ .kind = if (layout == Speaker.FL | Speaker.FR) .stereo else if (mask_ok) .mask else .count_default };
        var i: usize = 0;
        var bits = layout;
        while (bits != 0) : (i += 1) {
            const bit = bits & (~bits + 1); // lowest set bit = channel i
            bits &= bits - 1;
            if (bit == Speaker.FL) {
                d.l[i] = 1;
            } else if (bit == Speaker.FR) {
                d.r[i] = 1;
            } else if (bit & Speaker.centre != 0) {
                d.l[i] = MINUS_3DB;
                d.r[i] = MINUS_3DB;
            } else if (bit & Speaker.left != 0) {
                d.l[i] = MINUS_3DB;
            } else if (bit & Speaker.right != 0) {
                d.r[i] = MINUS_3DB;
            } // LFE: dropped (0, 0)
        }
        var sum_l: f32 = 0;
        var sum_r: f32 = 0;
        for (d.l, d.r) |gl, gr| {
            sum_l += gl;
            sum_r += gr;
        }
        const norm = 1.0 / @max(1.0, sum_l, sum_r);
        for (&d.l, &d.r) |*gl, *gr| {
            gl.* *= norm;
            gr.* *= norm;
        }
        return d;
    }

    /// One source frame's stereo pair (unrounded).
    inline fn frame(self: *const Downmix, src: []const i16, idx: usize, src_ch: usize) [2]f32 {
        var l: f32 = 0;
        var r: f32 = 0;
        const n = @min(src_ch, MAX_CH);
        for (src[idx * src_ch ..][0..n], 0..) |v, c| {
            const x: f32 = @floatFromInt(v);
            l += x * self.l[c];
            r += x * self.r[c];
        }
        return .{ l, r };
    }
};

/// Linear-resample interleaved i16 PCM (`src_rate`, the layout `dm` weights)
/// to 48 kHz stereo into `out` (`out.len / 2` frames). Output frame `i` is
/// the segment's frame `first + i` — `first` > 0 when the start-offset lead
/// trims the head — and `first + out frames` is at most `outFrames48k`, so
/// every source index stays in range. `src` holds the segment's source
/// frames from `src_off` on (the trimmed head was discarded while decoding;
/// `PcmAccumulator.trimTarget`). The mixer plays at the device rate
/// without resampling, so this matches the desktop ffmpeg `-ar 48000 -ac 2`
/// path.
fn resampleInto(out: []i16, src: []const i16, src_rate: u32, src_ch: u32, dm: Downmix, first: u64, src_off: u64) void {
    const in_frames = src.len / src_ch;
    const out_frames = out.len / OUT_CHANNELS;
    std.debug.assert(in_frames > 0);
    const last: u64 = src_off + in_frames - 1; // last source frame held, absolute
    var i: usize = 0;
    while (i < out_frames) : (i += 1) {
        // Source position (fractional, on the segment's whole source
        // timeline) for this output frame.
        const pos = (@as(f64, @floatFromInt(first + i)) * @as(f64, @floatFromInt(src_rate))) / @as(f64, @floatFromInt(OUT_RATE));
        const abs0: u64 = @min(@as(u64, @intFromFloat(pos)), last);
        // `src` starts at source frame `src_off`: the trim discarded only
        // frames before the first kept output frame's `floor(pos)`.
        const idx0: usize = @intCast(abs0 -| src_off);
        const idx1: usize = @min(idx0 + 1, in_frames - 1);
        const frac: f32 = @floatCast(pos - @as(f64, @floatFromInt(abs0)));
        // Downmix both neighbours, then interpolate (linear: same result as
        // interpolating each channel first).
        const a = dm.frame(src, idx0, src_ch);
        const b = dm.frame(src, idx1, src_ch);
        out[i * 2 + 0] = toI16(a[0] + (b[0] - a[0]) * frac);
        out[i * 2 + 1] = toI16(a[1] + (b[1] - a[1]) * frac);
    }
}

inline fn toI16(x: f32) i16 {
    return @intFromFloat(std.math.clamp(@round(x), -32768.0, 32767.0));
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Little-endian i16 bytes for `frames` frames of `ch` channels, each frame
/// `pattern` (one value per channel).
fn pcmBytes(allocator: std.mem.Allocator, frames: usize, pattern: []const i16) ![]u8 {
    const bytes = try allocator.alloc(u8, frames * pattern.len * 2);
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        for (pattern, 0..) |v, c| std.mem.writeInt(i16, bytes[(f * pattern.len + c) * 2 ..][0..2], v, .little);
    }
    return bytes;
}

test "classifyDequeue: the three INFO_* results are not errors; any other negative is" {
    try testing.expectEqual(DequeueResult.buffer, classifyDequeue(0));
    try testing.expectEqual(DequeueResult.buffer, classifyDequeue(7));
    try testing.expectEqual(DequeueResult.try_again, classifyDequeue(-1));
    try testing.expectEqual(DequeueResult.format_changed, classifyDequeue(-2));
    try testing.expectEqual(DequeueResult.buffers_changed, classifyDequeue(-3));
    try testing.expectEqual(DequeueResult.codec_error, classifyDequeue(-4));
    try testing.expectEqual(DequeueResult.codec_error, classifyDequeue(-10000)); // AMEDIA_ERROR_UNKNOWN
    try testing.expectEqual(DequeueResult.codec_error, classifyDequeue(-10006)); // AMEDIA_ERROR_END_OF_STREAM
}

test "outFrames48k: the frame product is widened to u64 (overflows u32) and capped" {
    // 100 000 frames × 48 000 = 4.8e9 > maxInt(u32): a u32 product would trap
    // here (Debug) or wrap to 505 032 704 / 44 100 = 11 452 (unchecked).
    const in_frames: u32 = 100_000;
    try testing.expect(@as(u64, in_frames) * OUT_RATE > std.math.maxInt(u32));
    try testing.expectEqual(@as(usize, 108_843), outFrames48k(in_frames, 44_100, MAX_FRAMES));
    // The largest 32-bit-sized input the helper accepts.
    try testing.expectEqual(MAX_FRAMES, outFrames48k(std.math.maxInt(u32), 44_100, MAX_FRAMES));
    // Ordinary cases: identity at 48 kHz; halving/doubling.
    try testing.expectEqual(@as(usize, 480), outFrames48k(480, 48_000, MAX_FRAMES));
    try testing.expectEqual(@as(usize, 480), outFrames48k(240, 24_000, MAX_FRAMES));
    try testing.expectEqual(@as(usize, 240), outFrames48k(480, 96_000, MAX_FRAMES));
    // A zero rate is treated as 1 (the caller already clamps ≥ 1).
    try testing.expectEqual(MAX_FRAMES, outFrames48k(std.math.maxInt(u32), 0, MAX_FRAMES));
}

test "srcFramesCeil/Floor: source frames for an output length, rounded up / down" {
    try testing.expectEqual(@as(u64, 480), srcFramesCeil(480, 48_000));
    try testing.expectEqual(@as(u64, 441), srcFramesCeil(480, 44_100));
    try testing.expectEqual(@as(u64, 1), srcFramesCeil(1, 44_100)); // rounds up, never 0 for a non-empty output
    try testing.expectEqual(@as(u64, 0), srcFramesFloor(1, 44_100));
    try testing.expectEqual(@as(u64, 960), srcFramesCeil(480, 96_000));
    try testing.expectEqual(@as(u64, 13_230_000), srcFramesCeil(MAX_FRAMES, 44_100)); // 5 min @ 44.1 kHz
    try testing.expectEqual(@as(u64, 13_230_000), srcFramesFloor(MAX_FRAMES, 44_100));
}

test "sample-count helpers: the 32-bit-overflowing products are formed in u64" {
    // The largest accepted trim (a whole cap) plus the cap, at 192 kHz: the
    // frame × rate product is ~5.5e12, far past a 32-bit `usize` (Android
    // armeabi-v7a), and the resulting sample count × 8 channels too.
    const out: u64 = 2 * MAX_FRAMES;
    try testing.expect(out * 192_000 > std.math.maxInt(u32));
    try testing.expectEqual(u64, @TypeOf(srcFramesCeil(out, 192_000)));
    try testing.expectEqual(@as(u64, 115_200_000), srcFramesCeil(out, 192_000));
    try testing.expectEqual(@as(u64, 115_200_000), srcFramesFloor(out, 192_000));
    try testing.expectEqual(@as(u64, 28_800_000), out48k(115_200_000, 192_000));
    // `trimTarget` at the same sizes (8 ch, 192 kHz, a whole-cap trim).
    var acc = PcmAccumulator.init(192_000, 8);
    acc.setStartOffsetUs(-300_000_000); // a whole-cap trim
    try testing.expectEqual(@as(u64, MAX_FRAMES), acc.skip_left);
    try testing.expectEqual(@as(u64, 57_600_000 * 8), acc.trimTarget(115_200_000 * 8));
    // `rawRoom` saturates to usize instead of overflowing on 32-bit targets.
    const room: u64 = acc.rawRoom();
    try testing.expectEqual(@min(@as(u64, 115_200_000 * 8), std.math.maxInt(usize)), room);
}

test "PcmAccumulator: a 48 kHz 6-channel source fills the whole output cap (the fixed raw cap truncated it)" {
    // A 5.1 source needs 6 raw samples per output frame; the earlier
    // `MAX_FRAMES * 4` raw cap therefore stopped at 2/3 of the advertised
    // output. Shrunk cap: 480 output frames (10 ms) — the arithmetic is
    // identical at 5 min, without a 170 MB test.
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 6);
    defer acc.deinit(a);
    acc.max_frames = 480;
    try testing.expectEqual(@as(usize, 480 * 6), acc.rawRoom());
    // Feed 600 frames (more than the cap) as a fake buffer sequence: every
    // speaker 7 (so the normalised downmix is exactly 7 per side) and a loud
    // LFE the downmix drops.
    const pattern = [_]i16{ 7, 7, 7, 1000, 7, 7 };
    const seq = try pcmBytes(a, 600, &pattern);
    defer a.free(seq);
    var off: usize = 0;
    while (off < seq.len) : (off += 1024) try acc.push(a, seq[off..@min(off + 1024, seq.len)]);
    try testing.expectEqual(@as(usize, 480 * 6), acc.raw.items.len); // 320 × 6 under the old rule
    try testing.expectEqual(@as(usize, 0), acc.rawRoom());
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 480), pcm.frames);
    var f: usize = 0;
    while (f < 480) : (f += 1) {
        try testing.expectEqual(@as(i16, 7), pcm.samples[f * 2 + 0]);
        try testing.expectEqual(@as(i16, 7), pcm.samples[f * 2 + 1]);
    }
}

test "PcmAccumulator: the output cap spans segments — a high-rate segment after a stereo one still reaches it" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    acc.max_frames = 1000;
    const seg_a = try pcmBytes(a, 400, &.{ 1, 1 }); // 400 output frames
    defer a.free(seg_a);
    try acc.push(a, seg_a);
    try acc.setFormat(a, 96_000, 6, 0); // 600 output frames left = 1200 source frames × 6 ch
    try testing.expectEqual(@as(usize, 400), acc.closed_out);
    try testing.expectEqual(@as(usize, 1200 * 6), acc.rawRoom());
    const seg_b = try pcmBytes(a, 1500, &.{ 2, 2, 2, 0, 2, 2 }); // more than fits; downmixes to 2/2
    defer a.free(seg_b);
    try acc.push(a, seg_b);
    try testing.expectEqual(@as(usize, 400 * 2 + 1200 * 6), acc.raw.items.len);
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 1000), pcm.frames);
    try testing.expectEqual(@as(i16, 1), pcm.samples[399 * 2]);
    try testing.expectEqual(@as(i16, 2), pcm.samples[400 * 2]);
    try testing.expectEqual(@as(i16, 2), pcm.samples[999 * 2 + 1]);
}

test "afterOutputBuffer: a full output cap finishes BEFORE output EOS (no decode to the deadline)" {
    // Ordinary buffer with room left: keep draining.
    try testing.expectEqual(OutputStep.drain, afterOutputBuffer(0, false, false));
    // Output EOS finishes, as before.
    try testing.expectEqual(OutputStep.finish, afterOutputBuffer(0, true, false));
    // Mechanism (#5): the cap alone ends the decode — no FLAG_EOS needed, so
    // a track far longer than the cap no longer decodes on to the deadline.
    try testing.expectEqual(OutputStep.finish, afterOutputBuffer(0, false, true));
    // A refused release mid-track fails at once (no poll to the deadline)…
    try testing.expectEqual(OutputStep.fail, afterOutputBuffer(-10000, false, false));
    // …but not on the last buffer the decode needs anyway.
    try testing.expectEqual(OutputStep.finish, afterOutputBuffer(-10000, true, false));
    try testing.expectEqual(OutputStep.finish, afterOutputBuffer(-10000, false, true));
}

test "PcmAccumulator.full: flips exactly when the cap is reached, and drives the loop's finish" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    acc.max_frames = 100;
    const buf = try pcmBytes(a, 60, &.{ 3, -3 });
    defer a.free(buf);
    try acc.push(a, buf); // 60 of 100 frames
    try testing.expect(!acc.full());
    try testing.expectEqual(OutputStep.drain, afterOutputBuffer(0, false, acc.full()));
    try acc.push(a, buf); // 40 more fit, 20 dropped
    try testing.expect(acc.full());
    try testing.expectEqual(OutputStep.finish, afterOutputBuffer(0, false, acc.full()));
    // Finishing without EOS keeps the capped PCM (the open segment is closed
    // and resampled by `finish`).
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 100), pcm.frames);
    try testing.expectEqual(@as(i16, 3), pcm.samples[99 * 2]);
}

test "PcmAccumulator.full: a cap filled by CLOSED segments is full with an empty open segment" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    acc.max_frames = 50;
    const buf = try pcmBytes(a, 50, &.{ 1, 1 });
    defer a.free(buf);
    try acc.push(a, buf);
    try acc.setFormat(a, 44_100, 1, 0); // closes the segment at the cap
    try testing.expect(acc.full());
}

test "InputQueue: a failed queueInputBuffer retries the packet, then fails after the bound; success resets" {
    var q: InputQueue = .{};
    try testing.expectEqual(InputQueue.Outcome.queued, q.onQueue(0));
    var i: u32 = 1;
    while (i < MAX_INPUT_QUEUE_FAILURES) : (i += 1) {
        try testing.expectEqual(InputQueue.Outcome.retry, q.onQueue(-10000)); // AMEDIA_ERROR_UNKNOWN
    }
    try testing.expectEqual(InputQueue.Outcome.failed, q.onQueue(-10001));
    // One success clears the count: a transient refusal never accumulates
    // across the whole track.
    q = .{};
    try testing.expectEqual(InputQueue.Outcome.retry, q.onQueue(-10000));
    try testing.expectEqual(InputQueue.Outcome.queued, q.onQueue(0));
    try testing.expectEqual(@as(u32, 0), q.failures);
}

test "PcmAccumulator: a mid-stream rate/channel change re-groups the following buffers" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(24_000, 1); // the container's track metadata
    defer acc.deinit(a);

    // Segment A: 240 mono frames @ 24 kHz of a constant 1000 → 480 stereo frames.
    const seg_a = try pcmBytes(a, 240, &.{1000});
    defer a.free(seg_a);
    try acc.push(a, seg_a[0..100]); // buffers split arbitrarily (even byte counts)
    try acc.push(a, seg_a[100..]);

    // OUTPUT_FORMAT_CHANGED: the decoder now emits 48 kHz stereo.
    try acc.setFormat(a, 48_000, 2, 0);
    try testing.expectEqual(@as(usize, 1), acc.segments.items.len);
    try acc.setFormat(a, 48_000, 2, 0); // same values: no new segment
    try testing.expectEqual(@as(usize, 1), acc.segments.items.len);

    // Segment B: 100 stereo frames @ 48 kHz, L=2000 R=-2000 → 100 frames as-is.
    const seg_b = try pcmBytes(a, 100, &.{ 2000, -2000 });
    defer a.free(seg_b);
    try acc.push(a, seg_b);

    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 580), pcm.frames);
    try testing.expectEqual(@as(usize, 580 * 2), pcm.samples.len);
    for (pcm.samples[0 .. 480 * 2]) |s| try testing.expectEqual(@as(i16, 1000), s);
    var f: usize = 480;
    while (f < 580) : (f += 1) {
        try testing.expectEqual(@as(i16, 2000), pcm.samples[f * 2 + 0]);
        try testing.expectEqual(@as(i16, -2000), pcm.samples[f * 2 + 1]);
    }
}

test "PcmAccumulator: WITHOUT the format change the same bytes are misread (the bug the handler fixes)" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(24_000, 1);
    defer acc.deinit(a);
    const seg_a = try pcmBytes(a, 240, &.{1000});
    defer a.free(seg_a);
    const seg_b = try pcmBytes(a, 100, &.{ 2000, -2000 });
    defer a.free(seg_b);
    try acc.push(a, seg_a);
    try acc.push(a, seg_b); // stereo 48 kHz bytes grouped as mono 24 kHz
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    // 440 "mono" frames @ 24 kHz → 880 frames, not the 580 the stream holds.
    try testing.expectEqual(@as(u32, 880), pcm.frames);
}

test "PcmAccumulator: a format change before any sample opens no empty segment" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(44_100, 2);
    defer acc.deinit(a);
    try acc.setFormat(a, 48_000, 2, 0); // the one every decode emits before its first buffer
    try testing.expectEqual(@as(usize, 0), acc.segments.items.len);
    const seg = try pcmBytes(a, 48, &.{ 5, -5 });
    defer a.free(seg);
    try acc.push(a, seg);
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 48), pcm.frames);
    try testing.expectEqual(@as(i16, 5), pcm.samples[0]);
    try testing.expectEqual(@as(i16, -5), pcm.samples[1]);
}

test "PcmAccumulator: empty and odd-length buffers; nothing decoded is NoAudioTrack" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    try acc.push(a, &.{}); // a zero-size buffer (valid before EOS) is a no-op
    try testing.expectError(error.NoAudioTrack, acc.finish(a));
    try acc.push(a, &.{ 1, 0, 2, 0, 3, 0, 4, 0, 9 }); // trailing odd byte dropped
    try testing.expectEqual(@as(usize, 4), acc.raw.items.len);
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 2), pcm.frames);
    try testing.expectEqualSlices(i16, &.{ 1, 2, 3, 4 }, pcm.samples);
}

test "resampleInto: mono is duplicated to both channels and a ramp is interpolated" {
    // 4 mono frames @ 24 kHz: 0, 100, 200, 300 → 8 stereo frames @ 48 kHz.
    const src = [_]i16{ 0, 100, 200, 300 };
    var out: [8 * 2]i16 = undefined;
    resampleInto(&out, &src, 24_000, 1, Downmix.forLayout(1, 0), 0, 0);
    const expect = [_]i16{ 0, 0, 50, 50, 100, 100, 150, 150, 200, 200, 250, 250, 300, 300, 300, 300 };
    try testing.expectEqualSlices(i16, &expect, &out);
}

// ── labelle-android#8: channel downmix + start-offset alignment ───────────

/// `(a + k·b + k·c) / (1 + 2k)` rounded — the normalised BS.775 side mix
/// written out independently of `Downmix`, so the tests check the formula,
/// not the implementation against itself.
fn bs775Side(front: f64, centre: f64, surround: f64) i16 {
    const k: f64 = 0.70710678;
    return @intFromFloat(@round((front + k * centre + k * surround) / (1.0 + 2.0 * k)));
}

/// One frame of a 48 kHz `ch`-channel buffer through the accumulator (the
/// production seam: push → finish → resample/downmix).
fn mixOneFrame(ch: u32, mask: u32, frame: []const i16) ![2]i16 {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, ch);
    defer acc.deinit(a);
    try acc.setFormat(a, 48_000, ch, mask);
    const bytes = try pcmBytes(a, 4, frame);
    defer a.free(bytes);
    try acc.push(a, bytes);
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 4), pcm.frames);
    return .{ pcm.samples[0], pcm.samples[1] };
}

test "downmix 5.1: L' = L + 0.707·C + 0.707·Ls, R' likewise, LFE dropped, normalised by 1 + 2·0.707" {
    // FL FR FC LFE BL BR — MediaCodec's 5.1 order for a bare count of 6.
    const frame = [_]i16{ 10_000, 2_000, 4_000, 30_000, 1_000, -3_000 };
    try testing.expectEqual(Downmix.Kind.count_default, Downmix.forLayout(6, 0).kind);
    const lr = try mixOneFrame(6, 0, &frame);
    try testing.expectEqual(bs775Side(10_000, 4_000, 1_000), lr[0]); // 5607
    try testing.expectEqual(bs775Side(2_000, 4_000, -3_000), lr[1]); // 1121
    try testing.expectEqual(@as(i16, 5607), lr[0]);
    try testing.expectEqual(@as(i16, 1121), lr[1]);
    // Mechanism: the old path took channels 0/1 verbatim (10000 / 2000) —
    // the centre and surrounds must move both sides off that.
    try testing.expect(lr[0] != 10_000 and lr[1] != 2_000);
    // The LFE contributes nothing: a different LFE gives the same pair.
    var no_lfe = frame;
    no_lfe[3] = -32_768;
    try testing.expectEqual(lr, try mixOneFrame(6, 0, &no_lfe));
    // The same layout stated as a channel mask takes the mask path, same mix.
    const m51 = Speaker.FL | Speaker.FR | Speaker.FC | Speaker.LFE | Speaker.BL | Speaker.BR;
    try testing.expectEqual(Downmix.Kind.mask, Downmix.forLayout(6, m51).kind);
    try testing.expectEqual(lr, try mixOneFrame(6, m51, &frame));
    // 5.1(side): SL/SR in the surround slots mix identically.
    const m51_side = Speaker.FL | Speaker.FR | Speaker.FC | Speaker.LFE | Speaker.SL | Speaker.SR;
    try testing.expectEqual(lr, try mixOneFrame(6, m51_side, &frame));
}

test "downmix: normalisation keeps a signal that would clip un-normalised in range, un-clamped" {
    // FL = FC = BL = 20000: the raw BS.775 left sum is 48 284 (> 32 767, a
    // clamp would give 32767); normalised it is exactly 20000.
    const lr = try mixOneFrame(6, 0, &.{ 20_000, 0, 20_000, 0, 20_000, 0 });
    try testing.expectEqual(@as(i16, 20_000), lr[0]);
    try testing.expectEqual(bs775Side(0, 20_000, 0), lr[1]); // 5858: centre only
    // Full scale on every speaker stays at full scale (no wrap, no overshoot).
    const full = try mixOneFrame(6, 0, &.{ 32_767, 32_767, 32_767, 32_767, 32_767, 32_767 });
    try testing.expectEqual([2]i16{ 32_767, 32_767 }, full);
    const neg = try mixOneFrame(6, 0, &.{ -32_768, -32_768, -32_768, -32_768, -32_768, -32_768 });
    try testing.expectEqual([2]i16{ -32_768, -32_768 }, neg);
}

test "downmix: stereo is the identity and mono is duplicated (no normalisation)" {
    try testing.expectEqual(Downmix.Kind.stereo, Downmix.forLayout(2, 0).kind);
    try testing.expectEqual(Downmix.Kind.stereo, Downmix.forLayout(2, Speaker.FL | Speaker.FR).kind);
    try testing.expectEqual([2]i16{ 12_345, -32_768 }, try mixOneFrame(2, 0, &.{ 12_345, -32_768 }));
    try testing.expectEqual([2]i16{ 32_767, -1 }, try mixOneFrame(2, 0, &.{ 32_767, -1 }));
    try testing.expectEqual(Downmix.Kind.mono, Downmix.forLayout(1, 0).kind);
    try testing.expectEqual([2]i16{ -7_777, -7_777 }, try mixOneFrame(1, 0, &.{-7_777}));
    // Mono is duplicated even when the codec calls its one channel FC.
    try testing.expectEqual([2]i16{ 31_000, 31_000 }, try mixOneFrame(1, Speaker.FC, &.{31_000}));
}

test "downmix: every count MediaCodec reports maps to its default layout" {
    const k: f64 = 0.70710678;
    // 3 channels, no mask: 2.1 FL FR LFE (Android's CHANNEL_OUT_2POINT1),
    // not 3.0 — the LFE is dropped and L/R pass through un-attenuated.
    try testing.expectEqual(Speaker.FL | Speaker.FR | Speaker.LFE, Speaker.defaultMask(3));
    try testing.expectEqual(Downmix.Kind.count_default, Downmix.forLayout(3, 0).kind);
    try testing.expectEqual([2]i16{ 1000, 3000 }, try mixOneFrame(3, 0, &.{ 1000, 3000, 2000 }));
    try testing.expectEqual([2]i16{ 1000, 3000 }, try mixOneFrame(3, 0, &.{ 1000, 3000, -32_768 }));
    // An explicit 3.0 mask still mixes the centre in: norm 1 + k.
    const m30 = Speaker.FL | Speaker.FR | Speaker.FC;
    try testing.expectEqual([2]i16{ @intFromFloat(@round((1000 + k * 2000) / (1 + k))), @intFromFloat(@round((3000 + k * 2000) / (1 + k))) }, try mixOneFrame(3, m30, &.{ 1000, 3000, 2000 }));
    // Quad FL FR BL BR: no centre.
    try testing.expectEqual([2]i16{ @intFromFloat(@round((1000 + k * 500) / (1 + k))), @intFromFloat(@round((-1000 + k * 300) / (1 + k))) }, try mixOneFrame(4, 0, &.{ 1000, -1000, 500, 300 }));
    // 5.0 FL FR FC BL BR = 5.1 without the LFE slot.
    try testing.expectEqual([2]i16{ bs775Side(10_000, 4_000, 1_000), bs775Side(2_000, 4_000, -3_000) }, try mixOneFrame(5, 0, &.{ 10_000, 2_000, 4_000, 1_000, -3_000 }));
    // 6.1 FL FR FC LFE BL BR BC: BC to both at −3 dB; norm 1 + 3k.
    try testing.expectEqual([2]i16{ @intFromFloat(@round((900 + k * 900 + k * 900 + k * 900) / (1 + 3 * k))), @intFromFloat(@round((0 + k * 900 + 0 + k * 900) / (1 + 3 * k))) }, try mixOneFrame(7, 0, &.{ 900, 0, 900, 5000, 900, 0, 900 }));
    // 7.1 FL FR FC LFE BL BR SL SR: norm 1 + 3k.
    try testing.expectEqual([2]i16{ @intFromFloat(@round((100 + k * 200 + k * 300 + k * 400) / (1 + 3 * k))), @intFromFloat(@round((-100 + k * 200 - k * 300 - k * 400) / (1 + 3 * k))) }, try mixOneFrame(8, 0, &.{ 100, -100, 200, 9999, 300, -300, 400, -400 }));
    try testing.expectEqual(Downmix.Kind.count_default, Downmix.forLayout(8, 0).kind);
}

test "downmix: a mask that disagrees with the count falls back to the count; an unknown count keeps channels 0/1" {
    // A stereo mask on a 6-channel format: not trusted, the 5.1 default wins.
    try testing.expectEqual(Downmix.Kind.count_default, Downmix.forLayout(6, Speaker.FL | Speaker.FR).kind);
    // Non-speaker bits (0–1) make a mask unusable too.
    // (six bits set, one of them bit 0: the count's default is used instead).
    try testing.expectEqual(Downmix.Kind.count_default, Downmix.forLayout(6, 0x1 | Speaker.FL | Speaker.FR | Speaker.FC | Speaker.LFE | Speaker.BL).kind);
    // 10 channels, no mask: no standard layout — L/R from channels 0/1.
    try testing.expectEqual(Downmix.Kind.first_two, Downmix.forLayout(10, 0).kind);
    try testing.expectEqual([2]i16{ 111, 222 }, try mixOneFrame(10, 0, &.{ 111, 222, 9, 9, 9, 9, 9, 9, 9, 9 }));
    // 10 channels WITH a matching mask (7.1 + top front L/R) are mixed.
    const m = Speaker.defaultMask(8) | Speaker.TFL | Speaker.TFR;
    try testing.expectEqual(Downmix.Kind.mask, Downmix.forLayout(10, m).kind);
    const lr = try mixOneFrame(10, m, &.{ 1000, 1000, 1000, 0, 1000, 1000, 1000, 1000, 1000, 1000 });
    try testing.expectEqual([2]i16{ 1000, 1000 }, lr); // equal speakers → unity after normalisation
}

test "leadFrames: microseconds to 48 kHz frames, rounded to nearest, never overflowing" {
    try testing.expectEqual(@as(i64, 0), leadFrames(0));
    try testing.expectEqual(@as(i64, 480), leadFrames(10_000));
    try testing.expectEqual(@as(i64, -1024), leadFrames(-21_333)); // one AAC frame of priming
    try testing.expectEqual(@as(i64, 0), leadFrames(10)); // 0.48 frame
    try testing.expectEqual(@as(i64, 1), leadFrames(11)); // 0.528 frame
    try testing.expectEqual(@as(i64, -1), leadFrames(-11));
    try testing.expectEqual(@as(i64, @divTrunc(@as(i128, std.math.maxInt(i64)) * 48_000 + 500_000, 1_000_000)), @as(i128, leadFrames(std.math.maxInt(i64))));
}

/// 48 kHz stereo ramp: frame `f` is (f + 1, -(f + 1)) — every frame nonzero
/// and unique, so an alignment error of one frame is visible.
fn rampBytes(allocator: std.mem.Allocator, frames: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, frames * 4);
    for (0..frames) |f| {
        const v: i16 = @intCast(f + 1);
        std.mem.writeInt(i16, bytes[f * 4 ..][0..2], v, .little);
        std.mem.writeInt(i16, bytes[f * 4 + 2 ..][0..2], -v, .little);
    }
    return bytes;
}

test "start offset > 0: a track that starts late is padded with silence up to its first sample" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    acc.setStartOffsetUs(10_000); // first audio sample at 10 ms
    try testing.expectEqual(@as(usize, 480), acc.padFrames());
    try testing.expectEqual(@as(u64, 0), acc.skipFrames());
    const bytes = try rampBytes(a, 1000);
    defer a.free(bytes);
    try acc.push(a, bytes);
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 1480), pcm.frames);
    // Frames 0..479 silent; the first decoded frame lands at exactly 480.
    for (pcm.samples[0 .. 480 * 2]) |s| try testing.expectEqual(@as(i16, 0), s);
    try testing.expectEqual(@as(i16, 1), pcm.samples[480 * 2]);
    try testing.expectEqual(@as(i16, -1), pcm.samples[480 * 2 + 1]);
    try testing.expectEqual(@as(i16, 1000), pcm.samples[1479 * 2]);
}

test "start offset < 0: a track that starts early has its head skipped (resampled, across segments)" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    acc.setStartOffsetUs(-3_125); // 150 frames before media time 0
    try testing.expectEqual(@as(usize, 0), acc.padFrames());
    try testing.expectEqual(@as(u64, 150), acc.skipFrames());
    // Segment A: 100 stereo frames @ 48 kHz — skipped whole.
    const seg_a = try rampBytes(a, 100);
    defer a.free(seg_a);
    try acc.push(a, seg_a);
    // Segment B: a mono ramp @ 24 kHz (0, 10, 20, …) — 200 output frames, of
    // which the first 50 are the rest of the skip.
    try acc.setFormat(a, 24_000, 1, 0);
    var mono: [100]i16 = undefined;
    for (&mono, 0..) |*v, i| v.* = @intCast(i * 10);
    try acc.push(a, std.mem.sliceAsBytes(&mono));
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 150), pcm.frames); // 300 decoded − 150 skipped
    // Output frame 0 = segment B's output frame 50 = source position 25.0.
    try testing.expectEqual([2]i16{ 250, 250 }, [2]i16{ pcm.samples[0], pcm.samples[1] });
    // …and the interpolation phase carries on: frame 1 = position 25.5.
    try testing.expectEqual(@as(i16, 255), pcm.samples[2]);
}

test "start offset: padding counts against the cap, skipped frames do not; all-skipped is NoAudioTrack" {
    const a = testing.allocator;
    {
        var acc = PcmAccumulator.init(48_000, 2);
        defer acc.deinit(a);
        acc.max_frames = 1000;
        acc.setStartOffsetUs(5_000); // 240 frames of silence
        try testing.expectEqual(@as(usize, 760 * 2), acc.rawRoom());
    }
    {
        var acc = PcmAccumulator.init(48_000, 2);
        defer acc.deinit(a);
        acc.max_frames = 1000;
        acc.setStartOffsetUs(-5_000); // 240 frames decoded then dropped
        try testing.expectEqual(@as(usize, 1240 * 2), acc.rawRoom());
        const bytes = try rampBytes(a, 2000);
        defer a.free(bytes);
        try acc.push(a, bytes);
        try testing.expect(acc.full());
        var pcm = try acc.finish(a);
        defer pcm.deinit(a);
        try testing.expectEqual(@as(u32, 1000), pcm.frames); // the whole cap, after the trim
        try testing.expectEqual(@as(i16, 241), pcm.samples[0]);
    }
    {
        var acc = PcmAccumulator.init(48_000, 2);
        defer acc.deinit(a);
        acc.setStartOffsetUs(-10_000); // 480 frames to drop, only 100 decoded
        const bytes = try rampBytes(a, 100);
        defer a.free(bytes);
        try acc.push(a, bytes);
        try testing.expectError(error.NoAudioTrack, acc.finish(a));
    }
}

test "start offset: a lead past the cap still keeps the audio after time 0 (−301 s start, 10-min track, scaled)" {
    // Codex #9 round 2: a lead longer than the cap used to mark the track
    // wholly trimmed (`rawRoom` 0 → `NoAudioTrack`). Scaled ×1/1000 via
    // `max_frames`: a 300 ms cap, a track starting 301 ms early.
    const a = testing.allocator;
    const cap: usize = 300 * 48; // 14 400 frames
    const lead: u64 = 301 * 48; // 14 448 frames before media time 0
    // Long enough that a full cap's worth follows time 0.
    const track = try rampBytes(a, 30_000); // ramp: frame i = i + 1
    defer a.free(track);
    {
        var acc = PcmAccumulator.init(48_000, 2);
        defer acc.deinit(a);
        acc.max_frames = cap;
        acc.setStartOffsetUs(-301_000);
        try testing.expectEqual(lead, acc.skip_left);
        try testing.expect(!acc.full()); // mechanism: decoding continues
        var off: usize = 0;
        while (!acc.full() and off < track.len) : (off += 997 * 4) {
            try acc.push(a, track[off..@min(off + 997 * 4, track.len)]);
            // Retained PCM stays within the cap (+ the one-frame look-behind).
            try testing.expect(acc.raw.items.len <= (cap + 1) * 2);
        }
        try testing.expect(acc.full()); // the cap, not the track end, stopped it
        var pcm = try acc.finish(a);
        defer pcm.deinit(a);
        try testing.expectEqual(@as(u32, cap), pcm.frames); // exactly the cap
        // Output frame 0 is media time 0 = source frame 14 448 (value 14 449).
        try testing.expectEqual(@as(i16, lead + 1), pcm.samples[0]);
        try testing.expectEqual(@as(i16, lead + cap), pcm.samples[(cap - 1) * 2]);
    }
    {
        // The literal 10-min shape (600 ms here): 299 ms follow time 0, all kept.
        var acc = PcmAccumulator.init(48_000, 2);
        defer acc.deinit(a);
        acc.max_frames = cap;
        acc.setStartOffsetUs(-301_000);
        try acc.push(a, track[0 .. 600 * 48 * 4]);
        try testing.expect(!acc.full());
        var pcm = try acc.finish(a);
        defer pcm.deinit(a);
        try testing.expectEqual(@as(u32, 299 * 48), pcm.frames);
        try testing.expectEqual(@as(i16, lead + 1), pcm.samples[0]);
    }
    // Production cap: a −301 s lead is accepted, not wholly trimmed.
    var prod = PcmAccumulator.init(48_000, 2);
    prod.setStartOffsetUs(-301_000_000);
    try testing.expectEqual(@as(u64, 301 * 48_000), prod.skipFrames());
    try testing.expect(!prod.full());
}

test "start offset: a one-hour lead retains nothing while trimming; the deadline ends it (NoAudioTrack)" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    acc.setStartOffsetUs(-3_600_000_000); // production cap (5 min) < 1 h
    try testing.expectEqual(@as(u64, 3600 * 48_000), acc.skip_left);
    // The trim is no longer cut off: the decode keeps going…
    try testing.expect(!acc.full());
    const bytes = try rampBytes(a, 4096);
    defer a.free(bytes);
    for (0..200) |_| {
        try acc.push(a, bytes);
        // …but retains only the resampler's one-frame look-behind (before
        // round 1 the hour of trimmed PCM, ~691 MB, was held).
        try testing.expect(acc.raw.items.len <= 2);
    }
    try testing.expect(!acc.full());
    // The 30 s deadline passes mid-trim: the drive loop FINISHES (does not
    // fail) with what was kept after time 0 — nothing — so NoAudioTrack.
    try testing.expectEqual(DeadlineStep.finish, afterDeadline(&acc));
    try testing.expectError(error.NoAudioTrack, acc.finish(a));
}

test "afterDeadline: a trimming decode finishes with what was kept; any other overrun fails" {
    const a = testing.allocator;
    // No start offset / a late start: an overrun is a stuck codec.
    var none = PcmAccumulator.init(48_000, 2);
    try testing.expectEqual(DeadlineStep.fail, afterDeadline(&none));
    var late = PcmAccumulator.init(48_000, 2);
    late.setStartOffsetUs(10_000);
    try testing.expectEqual(DeadlineStep.fail, afterDeadline(&late));
    // A negative lead whose trim completed before the deadline: the kept
    // audio after time 0 survives.
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    acc.setStartOffsetUs(-3_125); // 150 frames
    const bytes = try rampBytes(a, 400);
    defer a.free(bytes);
    try acc.push(a, bytes);
    try testing.expectEqual(DeadlineStep.finish, afterDeadline(&acc));
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 250), pcm.frames);
    try testing.expectEqual(@as(i16, 151), pcm.samples[0]);
}

test "sample-count helpers saturate on an extreme (metadata) lead instead of overflowing u64" {
    var acc = PcmAccumulator.init(192_000, 8);
    acc.setStartOffsetUs(std.math.minInt(i64));
    try testing.expect(acc.skip_left > std.math.maxInt(u64) / 192_000);
    // srcFramesCeil saturated (maxInt(u64) / 48 000 frames), then clamped
    // to usize on 32-bit targets.
    const room: u64 = acc.rawRoom();
    try testing.expectEqual(@min(@as(u64, std.math.maxInt(u64) / 48_000 * 8), @as(u64, std.math.maxInt(usize))), room);
    try testing.expect(!acc.full());
}

test "start offset: a trim as long as the cap never retains more than the cap while pushing" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(44_100, 2);
    defer acc.deinit(a);
    acc.max_frames = 4800; // 100 ms
    acc.setStartOffsetUs(-100_000); // 4800 frames: the whole cap, trimmed
    const limit = (srcFramesCeil(acc.max_frames, 44_100) + 1) * 2; // cap-derived, samples
    const buf = try rampBytes(a, 997); // odd size: pushes straddle every boundary
    defer a.free(buf);
    var pushes: usize = 0;
    var max_retained: usize = 0;
    while (!acc.full()) : (pushes += 1) {
        try acc.push(a, buf);
        max_retained = @max(max_retained, acc.raw.items.len);
        try testing.expect(acc.raw.items.len <= limit);
        // While the trim is still running nothing but the resampler's
        // one-frame look-behind is held.
        if (acc.trimTarget(acc.seg_in) < srcFramesFloor(acc.skip_left, 44_100) * 2)
            try testing.expect(acc.raw.items.len <= 2 * 2);
        try testing.expect(pushes < 100);
    }
    try testing.expect(pushes >= 9); // the trim + the cap took many buffers
    try testing.expect(max_retained > 0);
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 4800), pcm.frames);
    // Output frame 0 = source position 4800 · 44.1/48 = 4410 exactly: the
    // ramp's frame 4410 (value (4410 mod 997) + 1, the buffer repeats).
    try testing.expectEqual(@as(i16, @intCast(4410 % 997 + 1)), pcm.samples[0]);
    try testing.expectEqual(-@as(i16, @intCast(4410 % 997 + 1)), pcm.samples[1]);
}

test "start offset < 0: a trim spanning many pushes and a format change lands on the right first sample" {
    const a = testing.allocator;
    var acc = PcmAccumulator.init(48_000, 2);
    defer acc.deinit(a);
    acc.setStartOffsetUs(-3_125); // 150 frames before media time 0
    // Segment A: 100 stereo frames @ 48 kHz in 7-frame pushes — trimmed whole
    // and never retained beyond the look-behind.
    const seg_a = try rampBytes(a, 100);
    defer a.free(seg_a);
    var off: usize = 0;
    while (off < seg_a.len) : (off += 7 * 4) {
        try acc.push(a, seg_a[off..@min(off + 7 * 4, seg_a.len)]);
        try testing.expect(acc.raw.items.len <= 2);
    }
    // Segment B: a mono ramp @ 24 kHz (0, 10, 20, …) in 3-frame pushes — 200
    // output frames, of which the first 50 finish the trim.
    try acc.setFormat(a, 24_000, 1, 0);
    try testing.expectEqual(@as(usize, 0), acc.raw.items.len); // A dropped whole
    try testing.expectEqual(@as(u64, 50), acc.skip_left);
    var mono: [100]i16 = undefined;
    for (&mono, 0..) |*v, i| v.* = @intCast(i * 10);
    const mb = std.mem.sliceAsBytes(&mono);
    off = 0;
    while (off < mb.len) : (off += 3 * 2) try acc.push(a, mb[off..@min(off + 3 * 2, mb.len)]);
    // Mechanism: the 25 source frames under the trim were discarded, not kept.
    try testing.expectEqual(@as(u64, 25), acc.seg_src_off);
    try testing.expectEqual(@as(usize, 75), acc.raw.items.len);
    var pcm = try acc.finish(a);
    defer pcm.deinit(a);
    try testing.expectEqual(@as(u32, 150), pcm.frames);
    // Output frame 0 = segment B's output frame 50 = source position 25.0.
    try testing.expectEqual([2]i16{ 250, 250 }, [2]i16{ pcm.samples[0], pcm.samples[1] });
    try testing.expectEqual(@as(i16, 255), pcm.samples[2]); // position 25.5
    try testing.expectEqual(@as(i16, 990), pcm.samples[149 * 2]); // position 99.5 → last frame held
}
