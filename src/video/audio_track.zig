//! Android audio-track decoder — Path A Half 2 audio (FP#549). Moved verbatim
//! from labelle-bgfx `src/video/android_audio.zig` (labelle-bgfx#149 phase 1d);
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

const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;

const OUT_RATE: u32 = 48000;
const OUT_CHANNELS: u32 = 2;
const MAX_FRAMES: usize = 5 * 60 * OUT_RATE; // 5 min cap (decoded, post-resample)

pub const Pcm = struct {
    samples: []i16, // interleaved stereo @ 48 kHz
    frames: u32,
    pub fn deinit(self: *Pcm, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
};

pub const Error = error{ Unsupported, NoAudioTrack, DecodeInit, OutOfMemory };

/// Decode the file's audio track to 48 kHz stereo i16. Caller owns the samples.
pub const decodeTrack = if (is_android) decodeTrackAndroid else decodeTrackStub;

fn decodeTrackStub(_: std.mem.Allocator, _: c_int, _: i64, _: i64) Error!Pcm {
    return error.Unsupported;
}

fn decodeTrackAndroid(allocator: std.mem.Allocator, fd: c_int, offset: i64, length: i64) Error!Pcm {
    const Extractor = opaque {};
    const Codec = opaque {};
    const Format = opaque {};
    const BufferInfo = extern struct { offset: i32, size: i32, presentation_time_us: i64, flags: u32 };

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
    };
    const OK: i32 = 0;
    const FLAG_EOS: u32 = 4;
    const KEY_MIME: [*:0]const u8 = "mime";
    const KEY_RATE: [*:0]const u8 = "sample-rate";
    const KEY_CH: [*:0]const u8 = "channel-count";

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

    // Accumulate decoded interleaved PCM_16 at the source rate/channels.
    var raw: std.ArrayList(i16) = .empty;
    defer raw.deinit(allocator);
    var input_done = false;
    var output_done = false;
    while (!output_done) {
        if (!input_done) {
            const in_idx = X.AMediaCodec_dequeueInputBuffer(codec, 5000);
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
            }
        }
        var info: BufferInfo = undefined;
        const out_idx = X.AMediaCodec_dequeueOutputBuffer(codec, &info, 5000);
        if (out_idx >= 0) {
            const idx: usize = @intCast(out_idx);
            var size: usize = 0;
            if (X.AMediaCodec_getOutputBuffer(codec, idx, &size)) |buf| {
                const start: usize = @intCast(@max(info.offset, 0));
                const nbytes: usize = @intCast(@max(info.size, 0));
                // The codec output buffer may be only byte-aligned, so we can't
                // `bytesAsSlice(i16, …)` (that requires i16 alignment → UB/trap).
                // Read each little-endian sample unaligned with `readInt`.
                const sample_bytes = buf[start .. start + (nbytes & ~@as(usize, 1))];
                const sample_count = sample_bytes.len / 2;
                if (raw.items.len + sample_count <= MAX_FRAMES * 4) {
                    raw.ensureUnusedCapacity(allocator, sample_count) catch return error.OutOfMemory;
                    var bi: usize = 0;
                    // `bi + 1 < len` (not `len - 1`) avoids a usize underflow when
                    // the codec emits a zero-size buffer (valid before EOS).
                    while (bi + 1 < sample_bytes.len) : (bi += 2) {
                        const s = std.mem.readInt(i16, sample_bytes[bi..][0..2], .little);
                        raw.appendAssumeCapacity(s);
                    }
                }
            }
            _ = X.AMediaCodec_releaseOutputBuffer(codec, idx, false);
            if (info.flags & FLAG_EOS != 0) output_done = true;
        } else if (input_done) {
            // No more output coming.
            output_done = true;
        }
    }

    return resampleToStereo48k(allocator, raw.items, @intCast(@max(src_rate, 1)), @intCast(@max(src_ch, 1)));
}

/// Linear-resample interleaved i16 PCM (`src_rate`, `src_ch`) to 48 kHz stereo.
/// The mixer plays at the device rate without resampling, so this matches the
/// desktop ffmpeg `-ar 48000 -ac 2` path.
fn resampleToStereo48k(allocator: std.mem.Allocator, src: []const i16, src_rate: u32, src_ch: u32) Error!Pcm {
    if (src.len == 0 or src_ch == 0) return error.NoAudioTrack;
    const in_frames = src.len / src_ch;
    if (in_frames == 0) return error.NoAudioTrack;

    const out_frames: usize = @min(
        (in_frames * OUT_RATE) / src_rate,
        MAX_FRAMES,
    );
    const out = allocator.alloc(i16, out_frames * OUT_CHANNELS) catch return error.OutOfMemory;

    var i: usize = 0;
    while (i < out_frames) : (i += 1) {
        // Source position (fractional) for this output frame.
        const pos = (@as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(src_rate))) / @as(f64, @floatFromInt(OUT_RATE));
        const idx0: usize = @intFromFloat(pos);
        const idx1: usize = @min(idx0 + 1, in_frames - 1);
        const frac: f32 = @floatCast(pos - @as(f64, @floatFromInt(idx0)));
        // Left + right (duplicate mono; take first two channels otherwise).
        const l = lerpSample(src, idx0, idx1, 0, src_ch, frac);
        const r = if (src_ch >= 2) lerpSample(src, idx0, idx1, 1, src_ch, frac) else l;
        out[i * 2 + 0] = l;
        out[i * 2 + 1] = r;
    }
    return .{ .samples = out, .frames = @intCast(out_frames) };
}

inline fn lerpSample(src: []const i16, idx0: usize, idx1: usize, ch: usize, src_ch: u32, frac: f32) i16 {
    const a: f32 = @floatFromInt(src[idx0 * src_ch + ch]);
    const b: f32 = @floatFromInt(src[idx1 * src_ch + ch]);
    return @intFromFloat(std.math.clamp(a + (b - a) * frac, -32768.0, 32767.0));
}
