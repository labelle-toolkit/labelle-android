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
//!   * `classifyDequeue` / `outFrames48k` — pure helpers for the drain
//!     decisions and the (u64-widened) frame-count arithmetic; host-tested.

const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;

const OUT_RATE: u32 = 48000;
const OUT_CHANNELS: u32 = 2;
/// 5 min cap on the decoded, post-resample output.
const MAX_FRAMES: usize = 5 * 60 * OUT_RATE;
/// Cap on the accumulated SOURCE-rate samples (all channels). Loose: it only
/// bounds memory while decoding; `finish` applies the exact `MAX_FRAMES` cap.
const MAX_RAW_SAMPLES: usize = MAX_FRAMES * 4;
comptime {
    // `outFrames48k` takes a u32 frame count; the raw cap keeps every segment's
    // frame count representable.
    std.debug.assert(MAX_RAW_SAMPLES <= std.math.maxInt(u32));
}

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

/// Classify a `AMediaCodec_dequeue{Input,Output}Buffer` result. Any negative
/// value that is not one of the three `AMEDIACODEC_INFO_*` constants is a
/// real codec error (`AMEDIA_ERROR_*` are ≤ -10000): the codec will never
/// produce EOS after one, so the drive loop must fail instead of polling on.
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
        extern fn AMediaCodec_queueInputBuffer(*Codec, usize, u32, usize, u64, u32) i32;
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
        @memcpy(mime_buf[0..span.len], span);
        mime_buf[span.len] = 0;
        mime_len = span.len;
        found = true;
        break;
    }
    if (!found) return error.NoAudioTrack;
    const mime: [*:0]const u8 = mime_buf[0..mime_len :0].ptr;
    if (X.AMediaExtractor_selectTrack(ex, track) != OK) return error.DecodeInit;

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
    defer acc.deinit(allocator);
    var input_done = false;
    // Ends ONLY on the output buffer carrying FLAG_EOS, a codec error, or the
    // deadline. After input EOS is queued, `TRY_AGAIN_LATER` merely means no
    // output surfaced within this poll: the decoder still owes the delayed tail
    // of the track (and a short or slow-to-start decode owes all of it).
    while (true) {
        if (X.monotonicNs() - t_start > DECODE_DEADLINE_NS) {
            std.log.err("video: audio decode overran {d} s without output EOS — giving up", .{@divTrunc(DECODE_DEADLINE_NS, std.time.ns_per_s)});
            return error.DecodeFailed;
        }
        if (!input_done) {
            const in_idx = X.AMediaCodec_dequeueInputBuffer(codec, POLL_US);
            if (in_idx >= 0) {
                const idx: usize = @intCast(in_idx);
                var cap: usize = 0;
                if (X.AMediaCodec_getInputBuffer(codec, idx, &cap)) |buf| {
                    const got = X.AMediaExtractor_readSampleData(ex, buf, cap);
                    if (got < 0) {
                        _ = X.AMediaCodec_queueInputBuffer(codec, idx, 0, 0, 0, FLAG_EOS);
                        input_done = true;
                    } else {
                        _ = X.AMediaCodec_queueInputBuffer(codec, idx, 0, @intCast(got), 0, 0);
                        _ = X.AMediaExtractor_advance(ex);
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
                _ = X.AMediaCodec_releaseOutputBuffer(codec, idx, false);
                if (info.flags & FLAG_EOS != 0) break;
            },
            .format_changed => {
                // The decoded layout may differ from the container's track
                // metadata (HE-AAC SBR doubles the rate, parametric stereo
                // widens mono): group and resample by what the codec emits.
                if (X.AMediaCodec_getOutputFormat(codec)) |fmt| {
                    defer X.AMediaFormat_delete(fmt);
                    var rate: i32 = @intCast(acc.rate);
                    var ch: i32 = @intCast(acc.ch);
                    _ = X.AMediaFormat_getInt32(fmt, KEY_RATE, &rate);
                    _ = X.AMediaFormat_getInt32(fmt, KEY_CH, &ch);
                    const new_rate: u32 = @intCast(@max(rate, 1));
                    const new_ch: u32 = @intCast(@max(ch, 1));
                    std.log.info("video: audio output format {d} Hz, {d} ch (track metadata {d} Hz, {d} ch)", .{ new_rate, new_ch, @max(src_rate, 1), @max(src_ch, 1) });
                    acc.setFormat(allocator, new_rate, new_ch) catch return error.OutOfMemory;
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
/// 48 kHz and capped at `MAX_FRAMES`. The product is formed in u64: on the
/// 32-bit Android ABIs `usize` is 32 bits and `in_frames * 48000` wraps after
/// only 89 478 frames (~2 s of audio), trapping in checked builds and sizing
/// the output wrong in unchecked ones. The u32 parameter makes the widening
/// the helper's job (a 32-bit product would trap the host test below).
fn outFrames48k(in_frames: u32, src_rate: u32) usize {
    const wide = (@as(u64, in_frames) * @as(u64, OUT_RATE)) / @as(u64, @max(src_rate, 1));
    return @intCast(@min(wide, @as(u64, MAX_FRAMES)));
}

/// Collects the codec's interleaved PCM_16 output buffers as they are emitted.
/// Each buffer is grouped under the output format in force when it arrived,
/// so a mid-stream `setFormat` (from `OUTPUT_FORMAT_CHANGED`) starts a new
/// segment instead of misreading earlier samples. `finish` resamples every
/// segment to 48 kHz stereo, in order, into one `Pcm`.
const PcmAccumulator = struct {
    const Segment = struct { rate: u32, ch: u32, start: usize, end: usize };

    raw: std.ArrayList(i16) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    /// Current output format (applies to samples from `seg_start` on).
    rate: u32,
    ch: u32,
    seg_start: usize = 0,

    fn init(rate: u32, ch: u32) PcmAccumulator {
        return .{ .rate = @max(rate, 1), .ch = @max(ch, 1) };
    }

    fn deinit(self: *PcmAccumulator, allocator: std.mem.Allocator) void {
        self.raw.deinit(allocator);
        self.segments.deinit(allocator);
    }

    /// The codec's output format from here on. A change closes the open
    /// segment (if it holds samples); the same values are a no-op.
    fn setFormat(self: *PcmAccumulator, allocator: std.mem.Allocator, rate: u32, ch: u32) std.mem.Allocator.Error!void {
        const r = @max(rate, 1);
        const c = @max(ch, 1);
        if (r == self.rate and c == self.ch) return;
        try self.closeSegment(allocator);
        self.rate = r;
        self.ch = c;
    }

    /// Append one output buffer's bytes: little-endian i16, read unaligned
    /// (`bytesAsSlice(i16, …)` would need i16 alignment the codec's ByteBuffer
    /// does not guarantee). A trailing odd byte is dropped; past
    /// `MAX_RAW_SAMPLES` the excess is dropped.
    fn push(self: *PcmAccumulator, allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!void {
        const room = MAX_RAW_SAMPLES - self.raw.items.len;
        const count = @min(bytes.len / 2, room);
        try self.raw.ensureUnusedCapacity(allocator, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            self.raw.appendAssumeCapacity(std.mem.readInt(i16, bytes[i * 2 ..][0..2], .little));
        }
    }

    fn closeSegment(self: *PcmAccumulator, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.raw.items.len > self.seg_start) {
            try self.segments.append(allocator, .{ .rate = self.rate, .ch = self.ch, .start = self.seg_start, .end = self.raw.items.len });
        }
        self.seg_start = self.raw.items.len;
    }

    fn segmentOutFrames(s: Segment) usize {
        // `MAX_RAW_SAMPLES <= maxInt(u32)` (asserted at comptime) keeps the
        // frame count representable.
        return outFrames48k(@intCast((s.end - s.start) / s.ch), s.rate);
    }

    /// Resample every segment to 48 kHz stereo (capped at `MAX_FRAMES` in
    /// total). Caller owns the samples. `NoAudioTrack` when nothing decoded.
    fn finish(self: *PcmAccumulator, allocator: std.mem.Allocator) Error!Pcm {
        self.closeSegment(allocator) catch return error.OutOfMemory;
        var total: usize = 0;
        for (self.segments.items) |s| total = @min(total +| segmentOutFrames(s), MAX_FRAMES);
        if (total == 0) return error.NoAudioTrack;
        const out = allocator.alloc(i16, total * OUT_CHANNELS) catch return error.OutOfMemory;
        var written: usize = 0;
        for (self.segments.items) |s| {
            if (written == total) break;
            const frames = @min(segmentOutFrames(s), total - written);
            if (frames == 0) continue;
            resampleInto(out[written * OUT_CHANNELS ..][0 .. frames * OUT_CHANNELS], self.raw.items[s.start..s.end], s.rate, s.ch);
            written += frames;
        }
        return .{ .samples = out, .frames = @intCast(total) };
    }
};

/// Linear-resample interleaved i16 PCM (`src_rate`, `src_ch`) to 48 kHz stereo
/// into `out` (`out.len / 2` frames; at most `outFrames48k` of them, so every
/// source index stays in range). The mixer plays at the device rate without
/// resampling, so this matches the desktop ffmpeg `-ar 48000 -ac 2` path.
fn resampleInto(out: []i16, src: []const i16, src_rate: u32, src_ch: u32) void {
    const in_frames = src.len / src_ch;
    const out_frames = out.len / OUT_CHANNELS;
    std.debug.assert(in_frames > 0);
    var i: usize = 0;
    while (i < out_frames) : (i += 1) {
        // Source position (fractional) for this output frame.
        const pos = (@as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(src_rate))) / @as(f64, @floatFromInt(OUT_RATE));
        const idx0: usize = @min(@as(usize, @intFromFloat(pos)), in_frames - 1);
        const idx1: usize = @min(idx0 + 1, in_frames - 1);
        const frac: f32 = @floatCast(pos - @as(f64, @floatFromInt(idx0)));
        // Left + right (duplicate mono; take first two channels otherwise).
        const l = lerpSample(src, idx0, idx1, 0, src_ch, frac);
        const r = if (src_ch >= 2) lerpSample(src, idx0, idx1, 1, src_ch, frac) else l;
        out[i * 2 + 0] = l;
        out[i * 2 + 1] = r;
    }
}

inline fn lerpSample(src: []const i16, idx0: usize, idx1: usize, ch: usize, src_ch: u32, frac: f32) i16 {
    const a: f32 = @floatFromInt(src[idx0 * src_ch + ch]);
    const b: f32 = @floatFromInt(src[idx1 * src_ch + ch]);
    return @intFromFloat(std.math.clamp(a + (b - a) * frac, -32768.0, 32767.0));
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
    try testing.expectEqual(@as(usize, 108_843), outFrames48k(in_frames, 44_100));
    // The largest 32-bit-sized input the helper accepts.
    try testing.expectEqual(MAX_FRAMES, outFrames48k(std.math.maxInt(u32), 44_100));
    // Ordinary cases: identity at 48 kHz; halving/doubling.
    try testing.expectEqual(@as(usize, 480), outFrames48k(480, 48_000));
    try testing.expectEqual(@as(usize, 480), outFrames48k(240, 24_000));
    try testing.expectEqual(@as(usize, 240), outFrames48k(480, 96_000));
    // A zero rate is treated as 1 (the caller already clamps ≥ 1).
    try testing.expectEqual(MAX_FRAMES, outFrames48k(std.math.maxInt(u32), 0));
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
    try acc.setFormat(a, 48_000, 2);
    try testing.expectEqual(@as(usize, 1), acc.segments.items.len);
    try acc.setFormat(a, 48_000, 2); // same values: no new segment
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
    try acc.setFormat(a, 48_000, 2); // the one every decode emits before its first buffer
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
    resampleInto(&out, &src, 24_000, 1);
    const expect = [_]i16{ 0, 0, 50, 50, 100, 100, 150, 150, 200, 200, 250, 250, 300, 300, 300, 300 };
    try testing.expectEqualSlices(i16, &expect, &out);
}
