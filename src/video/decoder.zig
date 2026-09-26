//! Android H.264 decoder via the NDK Media APIs — Path A Half 2, Android target
//! (Flying-Platform/flying-platform-labelle#549). Moved verbatim from
//! labelle-bgfx `src/video/android.zig` (labelle-bgfx#149 phase 1d); reached
//! by consumers as `labelle_android.video.VideoDecoder`.
//!
//! Uses `AMediaExtractor` (demux the mp4 container) + `AMediaCodec` (hardware
//! H.264 decode) rendering into an **`AImageReader` (YUV_420_888)**, then reads
//! the frame's Y/U/V planes via `AImage` and converts to RGBA8 (`yuv.zig`)
//! for the backend's dynamic texture (`updateTexture`, Half 1) — the same sink
//! the desktop ffmpeg pipe feeds.
//!
//! Why ImageReader and not raw ByteBuffer: real devices emit a wide range of
//! `AMediaCodec` color formats — planar, semi-planar, and especially
//! `COLOR_FormatYUV420Flexible` / proprietary *tiled* layouts that aren't
//! CPU-readable as-is. Rendering into a YUV_420_888 `AImageReader` normalizes
//! all of them into Y/U/V planes with explicit row/pixel strides, so one
//! `yuv.yuv420ToRgba` converts every device. (A ByteBuffer/NV12-only path
//! worked on the emulator but would black-screen many real handsets.)
//!
//! These are pure C NDK APIs (no JNI/Java), so they're called from Zig via
//! `extern`. The decoder is **comptime-gated to the Android ABI**: off Android
//! it resolves to an `Unsupported` stub so host/desktop builds never reference
//! the NDK symbols.
//!
//! Verified on-device: originally through a standalone NativeActivity harness
//! (a Pixel-7 API-34 emulator, arm64 — extract → AMediaCodec → AImage
//! YUV_420_888 → RGBA, RESULT PASS), since retired in favour of the real
//! consumer path (a labelle game's intro clip on a physical tablet through
//! `labelle run --platform=android`; labelle-cli#405). AMediaCodec needs a real
//! app process for its Binder/JVM context, so a bare `adb shell` binary cannot
//! get past codec creation — only an APK proves this file. The host-testable
//! colour conversion lives in `yuv.zig`, the plane tightening in `planes.zig`.
//!
//! Colour (labelle-android#3 round 2): the codec's `OUTPUT_FORMAT_CHANGED`
//! carries `color-standard` / `color-range` / `color-transfer` (API 28+; absent
//! on older devices or untagged streams). `refreshFormat` retains them as a
//! `ColorSpace`, every ring frame is stamped with the one in force when it was
//! decoded, `decodeFrame` converts with the matching `yuv.Matrix` (BT.709 vs
//! BT.601, full vs limited), and `colorSpace()` exposes it to the GPU-YUV
//! consumer. bgfx's `fs_yuv` still hard-codes BT.601 limited — selecting the
//! GPU matrix from this metadata is labelle-bgfx#155.
//!
//! Crop: the `AImage` crop rect is honoured — validated against the frame's
//! dimensions and the plane sizes, then copied from its origin; an
//! inconsistent crop rejects the frame (logged once) instead of asserting or
//! reading out of bounds (`resolveCrop` / `planeHolds`, host-tested).
//!
//! Known follow-ups (next slices):
//!   - on a real handset (vs the emulator) confirm a Flexible/tiled clip; the
//!     plane-stride path is built for it but only emulator-verified so far.

const std = @import("std");
const builtin = @import("builtin");
const yuv = @import("yuv.zig");
const planes = @import("planes.zig");

extern fn close(c_int) c_int;
extern fn usleep(usec: u32) c_int; // worker idle backoff (bionic)

const is_android = builtin.abi == .android or builtin.abi == .androideabi;

/// Public decoder type. Real implementation on Android; a stub elsewhere so the
/// engine compiles on every backend/target.
pub const VideoDecoder = if (is_android) AndroidVideoDecoder else UnsupportedDecoder;

/// The decoded stream's colour metadata, from the codec's output format
/// (`color-standard` / `color-range` / `color-transfer`, the `MediaFormat`
/// integer constants; API 28+). `.unspecified` when the key is absent — an
/// untagged stream, an older device, or a codec that does not report it.
/// Read it with `VideoDecoder.colorSpace()`: after a `decodeFrame` /
/// `decodeFramePlanes` it is the colour space of the frame just returned.
pub const ColorSpace = struct {
    pub const Standard = enum { unspecified, bt709, bt601_pal, bt601_ntsc, bt2020, other };
    pub const Range = enum { unspecified, full, limited };
    pub const Transfer = enum { unspecified, linear, sdr_video, st2084, hlg, other };

    standard: Standard = .unspecified,
    range: Range = .unspecified,
    transfer: Transfer = .unspecified,

    /// From the raw `MediaFormat` values (`null` = key absent):
    /// COLOR_STANDARD_BT709 = 1, BT601_PAL = 2, BT601_NTSC = 4, BT2020 = 6;
    /// COLOR_RANGE_FULL = 1, LIMITED = 2; COLOR_TRANSFER_LINEAR = 1,
    /// SDR_VIDEO = 3, ST2084 = 6, HLG = 7.
    pub fn fromFormat(standard: ?i32, range: ?i32, transfer: ?i32) ColorSpace {
        return .{
            .standard = if (standard) |s| switch (s) {
                1 => .bt709,
                2 => .bt601_pal,
                4 => .bt601_ntsc,
                6 => .bt2020,
                else => .other,
            } else .unspecified,
            .range = if (range) |r| switch (r) {
                1 => .full,
                2 => .limited,
                else => .unspecified,
            } else .unspecified,
            .transfer = if (transfer) |t| switch (t) {
                1 => .linear,
                3 => .sdr_video,
                6 => .st2084,
                7 => .hlg,
                else => .other,
            } else .unspecified,
        };
    }

    /// The CPU conversion matrix for a stream of `height` rows. BT.709 for
    /// `.bt709` (and `.bt2020`, whose Y'CbCr coefficients are far closer to
    /// 709 than 601 — a proper 2020 matrix is not carried); BT.601 for the
    /// two 601 standards. An UNSPECIFIED standard follows the ffmpeg /
    /// Chromium convention: HD (≥ 720 rows) is BT.709, SD is BT.601. Range
    /// defaults to limited (what every MediaCodec decoder emits unless the
    /// stream says full).
    pub fn matrix(self: ColorSpace, height: u32) yuv.Matrix {
        const hd = switch (self.standard) {
            .bt709, .bt2020 => true,
            .bt601_pal, .bt601_ntsc => false,
            .unspecified, .other => height >= 720,
        };
        const full = self.range == .full;
        return if (hd) (if (full) .bt709_full else .bt709_limited) else (if (full) .bt601_full else .bt601_limited);
    }
};

/// `AImageCropRect` (NdkImage.h): right/bottom are EXCLUSIVE, so the crop is
/// `(right − left) × (bottom − top)`.
const CropRect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const CropError = error{ NegativeOrigin, Inverted, SmallerThanFrame };
/// Why an AImage could not be read into a ring slot (`readPlanes`).
const ReadError = CropError || error{ NoPlanes, PlaneData, PlaneTooSmall };

/// The origin to copy a `w × h` frame from inside an image whose crop rect is
/// `crop`. An all-zero rect means "no crop reported" (`AImage_getCropRect`
/// failed or the producer set none): the full frame at the origin. A crop at
/// least `w × h` is copied from its top-left (the padded coded size, e.g.
/// 1088 rows for a 1080 stream, is the common case: the crop IS `w × h`); a
/// crop smaller than the frame in either axis, a negative origin or an
/// inverted rect is inconsistent with the track's dimensions — the caller
/// rejects the frame rather than sampling padding or reading past a plane.
fn resolveCrop(crop: CropRect, w: u32, h: u32) CropError!struct { left: u32, top: u32 } {
    if (crop.left == 0 and crop.top == 0 and crop.right == 0 and crop.bottom == 0) return .{ .left = 0, .top = 0 };
    if (crop.left < 0 or crop.top < 0) return error.NegativeOrigin;
    if (crop.right <= crop.left or crop.bottom <= crop.top) return error.Inverted;
    const cw: u32 = @intCast(crop.right - crop.left);
    const ch: u32 = @intCast(crop.bottom - crop.top);
    if (cw < w or ch < h) return error.SmallerThanFrame;
    return .{ .left = @intCast(crop.left), .top = @intCast(crop.top) };
}

/// Does a plane of `len` bytes hold every sample of a `w × h` copy that
/// starts `off` bytes in with the given strides? The bottom-right sample is
/// the last byte read (`planes.tightenPlane` asserts the same bound; this is
/// the checked version so a bad crop is rejected, not trapped on).
fn planeHolds(len: usize, row_stride: u32, pixel_stride: u32, off: usize, w: u32, h: u32) bool {
    if (w == 0 or h == 0) return off <= len;
    const last = off + @as(usize, h - 1) * row_stride + @as(usize, w - 1) * pixel_stride;
    return last < len;
}

// ── Worker end-of-stream bookkeeping (pure; host-tested) ─────────────────

/// What the feed loop does after `AMediaCodec_queueInputBuffer` returned
/// `status` for a sample (`eos = false`) or for the input-EOS marker.
const InputQueueStep = enum {
    /// Sample accepted: advance the extractor to the next one.
    advance,
    /// EOS marker accepted: input is done, keep draining output.
    input_eos,
    /// The codec refused the buffer: end the stream (`terminalCodecError`).
    end_stream,
};

/// Classify a `queueInputBuffer` result. ANY non-OK status is terminal, on
/// the FIRST failure (unlike `audio_track.InputQueue`, which retries a
/// bounded number of times under a 30 s deadline):
///   - a refused buffer stays client-owned and is never handed back, so a
///     bounded retry burns one input buffer per attempt — with fewer input
///     buffers in the codec's pool than the retry bound (4 is common) the
///     dequeue would return TRY_AGAIN forever before the bound is reached;
///   - the video worker has no overall deadline to fall back on;
///   - the index is freshly dequeued and the size within its capacity, so
///     a refusal is a codec state error, not a transient condition.
/// Before this, a refused sample only `break`-ed the feed loop and the worker
/// re-fed forever with `input_done`/`eof_seen` false: a play-once clip never
/// ended (labelle-android#3 round 3). The EOS marker is covered the same way.
fn inputQueueStep(status: i32, eos: bool) InputQueueStep {
    if (status != 0) return .end_stream; // != AMEDIA_OK
    return if (eos) .input_eos else .advance;
}

/// Mark the stream ended: no more input, codec drained. Returns true only on
/// the transition, so the caller logs a terminal error once (a stream already
/// ending — normal EOS or an earlier error — is left alone).
fn endStream(input_done: *bool, eof_seen: *bool) bool {
    if (eof_seen.*) return false;
    input_done.* = true;
    eof_seen.* = true;
    return true;
}

/// `eof()`'s predicate: the codec is done AND every buffered frame — in the
/// ring and still in the surface handoff (`pending`) — has been presented.
fn streamFinished(eof_seen: bool, ring_count: usize, pending: usize) bool {
    return eof_seen and ring_count == 0 and pending == 0;
}

/// Decoded-frame ring size — the jitter cushion (~130 ms at 30 fps). Bounds
/// the ring AND the surface handoff: the worker renders only while
/// `ring_count + pending < RING_SIZE`, so `pending ≤ RING_SIZE` always.
const RING_SIZE = 4;

/// What the feed loop does with the result of `AMediaCodec_getInputBuffer`
/// for a freshly dequeued input index.
const InputBufferStep = enum { fill, end_stream };

/// A null input buffer is TERMINAL, exactly like a refused
/// `queueInputBuffer` (`inputQueueStep`): the dequeued index stays
/// client-owned and is never handed back, so skipping it (the old `break`)
/// leaked one input buffer per attempt until `dequeueInputBuffer` returned
/// TRY_AGAIN forever — `input_done`/`eof_seen` stayed false and a play-once
/// clip never ended (labelle-android#5).
fn inputBufferStep(have_buffer: bool) InputBufferStep {
    return if (have_buffer) .fill else .end_stream;
}

/// Frames released to the reader's surface (render=true) but not yet
/// acquired — the async surface handoff — each with the colour space in force
/// when it was RELEASED. Stamping the colour at acquire instead (the old
/// `st.color` read in `publishOne`) gave frames released before an
/// `OUTPUT_FORMAT_CHANGED` but acquired after it the NEW format's matrix.
/// FIFO: the reader is acquired in order (`acquireNextImage`).
const Handoff = struct {
    colors: [RING_SIZE]ColorSpace = @splat(.{}),
    head: usize = 0,
    count: usize = 0,

    fn push(self: *Handoff, color: ColorSpace) void {
        std.debug.assert(self.count < RING_SIZE); // the render loop's bound
        self.colors[(self.head + self.count) % RING_SIZE] = color;
        self.count += 1;
    }

    /// The oldest in-flight frame's colour; null when nothing is pending.
    fn pop(self: *Handoff) ?ColorSpace {
        if (self.count == 0) return null;
        const c = self.colors[self.head];
        self.head = (self.head + 1) % RING_SIZE;
        self.count -= 1;
        return c;
    }

    /// The dry-drain failsafe: the pending frames will never surface.
    fn writeOff(self: *Handoff) void {
        self.head = 0;
        self.count = 0;
    }
};

/// Apply one output buffer the worker has released (zero-size, or rendered
/// with an OK status) to the shared end-of-stream state. The caller holds the
/// mutex for the WHOLE call: the frame's `pending` count and `eof_seen` move
/// in ONE critical section. Some decoders tag the LAST FRAME itself
/// `FLAG_EOS` (`info.size > 0`); setting `eof_seen` under one lock and
/// bumping `pending` under a later one let a render thread checking `eof()`
/// in between see `eof_seen` with an empty ring and `pending == 0`, and end
/// the clip one frame early (labelle-android#5).
fn recordRelease(handoff: *Handoff, eof_seen: *bool, has_frame: bool, eos: bool, color: ColorSpace) void {
    if (has_frame) handoff.push(color);
    if (eos) eof_seen.* = true;
}

/// Idle-iteration bounds for the dry-drain write-off (each idle iteration
/// sleeps ≥ 2 ms): ~100 ms after EOS (the clip is over; only the hand-off
/// waits), ~2 s before it.
const WRITE_OFF_AFTER_EOS: u32 = 50;
const WRITE_OFF_BEFORE_EOS: u32 = 1000;

/// After how many consecutive idle worker iterations are the pending handoff
/// frames written off as DROPPED by the reader (a release with no acquire,
/// ever)? Null when the state is not a stall.
///   - After EOS: a lost frame pins `pending` > 0 and holds `eof()` false.
///   - Before EOS, once the cushion is full (`ring_count + pending ≥
///     RING_SIZE`): the worker neither feeds nor dequeues output, so the EOS
///     buffer is never dequeued and `eof_seen` never set — gating on it alone
///     froze the stream for good after a few drops (Codex on #3). The bound
///     is LONG here: on the SM-T505 frames released during the intro's
///     startup GPU stall (a 409 ms frame) surfaced > 100 ms late, and a
///     100 ms write-off mistook them for drops (each premature write-off
///     then resurfaced as a stale `pending` at EOS). A true pre-EOS drop is a
///     permanent freeze, so a 2 s recovery still fixes it.
/// Never while the RING is full: that is the render thread not consuming
/// (a paused game), not a lost frame.
fn handoffWriteOffAfter(eof_seen: bool, ring_count: usize, pending: usize) ?u32 {
    if (pending == 0 or ring_count >= RING_SIZE) return null;
    if (eof_seen) return WRITE_OFF_AFTER_EOS;
    if (ring_count + pending >= RING_SIZE) return WRITE_OFF_BEFORE_EOS;
    return null;
}

pub const Error = error{
    Unsupported,
    NoVideoTrack,
    UnsupportedColorFormat,
    DecoderInit,
    MissingDimensions,
    OutOfMemory,
};

/// Off-Android stub — keeps the call sites compiling on host/desktop/wasm.
const UnsupportedDecoder = struct {
    pub fn openFd(_: std.mem.Allocator, _: c_int, _: i64, _: i64) Error!UnsupportedDecoder {
        return error.Unsupported;
    }
    pub fn width(_: *const UnsupportedDecoder) u32 {
        return 0;
    }
    pub fn height(_: *const UnsupportedDecoder) u32 {
        return 0;
    }
    pub fn decodeFrame(_: *UnsupportedDecoder, _: []u8) ?f64 {
        return null;
    }
    pub fn decodeFramePlanes(_: *UnsupportedDecoder, _: []u8, _: []u8, _: []u8) ?f64 {
        return null;
    }
    pub fn colorSpace(_: *const UnsupportedDecoder) ColorSpace {
        return .{};
    }
    pub fn deinit(_: *UnsupportedDecoder) void {}
};

// ── NDK Media C ABI (subset) ─────────────────────────────────────────────
// Declared inside the Android impl so the externs are only analyzed when the
// Android type is actually instantiated (host builds pick the stub).

const AndroidVideoDecoder = struct {
    const Extractor = opaque {};
    const Codec = opaque {};
    const Format = opaque {};
    const ImageReader = opaque {};
    const Image = opaque {};
    const Window = opaque {};

    const BufferInfo = extern struct {
        offset: i32,
        size: i32,
        presentation_time_us: i64,
        flags: u32,
    };

    // media_status_t: AMEDIA_OK == 0.
    extern fn AMediaExtractor_new() ?*Extractor;
    extern fn AMediaExtractor_setDataSourceFd(*Extractor, fd: c_int, offset: i64, length: i64) i32;
    extern fn AMediaExtractor_getTrackCount(*Extractor) usize;
    extern fn AMediaExtractor_getTrackFormat(*Extractor, idx: usize) ?*Format;
    extern fn AMediaExtractor_selectTrack(*Extractor, idx: usize) i32;
    extern fn AMediaExtractor_readSampleData(*Extractor, buf: [*]u8, capacity: usize) isize;
    extern fn AMediaExtractor_getSampleTime(*Extractor) i64;
    extern fn AMediaExtractor_advance(*Extractor) bool;
    extern fn AMediaExtractor_delete(*Extractor) void;

    extern fn AMediaFormat_getString(*Format, name: [*:0]const u8, out: *[*:0]const u8) bool;
    extern fn AMediaFormat_getInt32(*Format, name: [*:0]const u8, out: *i32) bool;
    extern fn AMediaFormat_delete(*Format) void;

    extern fn AMediaCodec_createDecoderByType(mime: [*:0]const u8) ?*Codec;
    extern fn AMediaCodec_createCodecByName(name: [*:0]const u8) ?*Codec;
    extern fn AMediaCodec_configure(*Codec, fmt: *Format, surface: ?*anyopaque, crypto: ?*anyopaque, flags: u32) i32;
    extern fn AMediaCodec_start(*Codec) i32;
    extern fn AMediaCodec_stop(*Codec) i32;
    extern fn AMediaCodec_delete(*Codec) void;
    extern fn AMediaCodec_dequeueInputBuffer(*Codec, timeout_us: i64) isize;
    extern fn AMediaCodec_getInputBuffer(*Codec, idx: usize, out_size: *usize) ?[*]u8;
    // `offset` is `_off_t_compat` (NdkMediaCodec.h), static-asserted there to
    // be `long`-sized: i64 on the 64-bit ABIs, i32 on the 32-bit ones.
    extern fn AMediaCodec_queueInputBuffer(*Codec, idx: usize, offset: c_long, size: usize, time_us: u64, flags: u32) i32;
    extern fn AMediaCodec_dequeueOutputBuffer(*Codec, info: *BufferInfo, timeout_us: i64) isize;
    extern fn AMediaCodec_getOutputBuffer(*Codec, idx: usize, out_size: *usize) ?[*]u8;
    extern fn AMediaCodec_getOutputFormat(*Codec) ?*Format;
    extern fn AMediaCodec_releaseOutputBuffer(*Codec, idx: usize, render: bool) i32;

    // NDK ImageReader / Image (media/NdkImageReader.h, NdkImage.h). The decoder
    // renders into the reader's surface; `AImage` then exposes whatever the
    // device produced as YUV_420_888 Y/U/V planes with row + pixel strides — so
    // any vendor / `COLOR_FormatYUV420Flexible` / tiled layout reads uniformly.
    // This is the robustness fix vs the old ByteBuffer/NV12-only path.
    extern fn AImageReader_new(width: i32, height: i32, format: i32, max_images: i32, reader: *?*ImageReader) i32;
    // API 26+: like AImageReader_new but with explicit AHardwareBuffer usage
    // flags. We need CPU_READ_OFTEN: the plain constructor allocates the gralloc
    // buffers with default usage (CPU_READ_RARELY → UNCACHED CPU mapping), and
    // byte-wise reads of uncached memory made the per-frame plane copy take
    // 30–80 ms on-device (measured) — the video judder. CPU_READ_OFTEN maps the
    // buffers cacheable, making the same copy ~milliseconds.
    extern fn AImageReader_newWithUsage(width: i32, height: i32, format: i32, usage: u64, max_images: i32, reader: *?*ImageReader) i32;
    extern fn AImageReader_getWindow(*ImageReader, window: *?*Window) i32;
    extern fn AImageReader_acquireLatestImage(*ImageReader, image: *?*Image) i32;
    // FIFO acquire (oldest un-acquired) — feed-ahead consumes the reader in order.
    extern fn AImageReader_acquireNextImage(*ImageReader, image: *?*Image) i32;
    extern fn AImageReader_delete(*ImageReader) void;
    extern fn AImage_getNumberOfPlanes(*const Image, num: *i32) i32;
    extern fn AImage_getPlaneData(*const Image, plane: i32, data: *?[*]u8, len: *i32) i32;
    extern fn AImage_getPlaneRowStride(*const Image, plane: i32, stride: *i32) i32;
    extern fn AImage_getPlanePixelStride(*const Image, plane: i32, stride: *i32) i32;
    extern fn AImage_getCropRect(*const Image, rect: *CropRect) i32;
    extern fn AImage_getTimestamp(*const Image, ts: *i64) i32;
    extern fn AImage_delete(*Image) void;

    const AMEDIA_OK: i32 = 0;
    const FLAG_EOS: u32 = 4; // AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM
    const INFO_TRY_AGAIN: isize = -1;
    const INFO_FORMAT_CHANGED: isize = -2;
    const INFO_BUFFERS_CHANGED: isize = -3;
    /// `media_status_t` errors are `AMEDIA_ERROR_BASE - n` (NdkMediaError.h).
    /// A dequeue returning at or below this is a CODEC ERROR, not one of the
    /// `INFO_*` "nothing yet" codes above — see `terminalCodecError`.
    const AMEDIA_ERROR_BASE: isize = -10000;
    const FORMAT_YUV_420_888: i32 = 0x23; // AIMAGE_FORMAT_YUV_420_888

    // AMediaFormat keys. The colour keys are the API-28 `AMEDIAFORMAT_KEY_COLOR_*`
    // string values, spelled out so the binary has no link dependency on the
    // API-28 symbols: on an older device `getInt32` simply reports them absent.
    const KEY_MIME: [*:0]const u8 = "mime";
    const KEY_WIDTH: [*:0]const u8 = "width";
    const KEY_HEIGHT: [*:0]const u8 = "height";
    const KEY_COLOR_STANDARD: [*:0]const u8 = "color-standard";
    const KEY_COLOR_RANGE: [*:0]const u8 = "color-range";
    const KEY_COLOR_TRANSFER: [*:0]const u8 = "color-transfer";

    // Decoded-frame ring buffer — the jitter cushion that decouples decoding from
    // presentation. A WORKER THREAD fills it: feed the codec, render output into
    // the ImageReader, then copy each frame's planes into a ring slot of ordinary
    // (cached) heap buffers. The copy is the expensive step — CPU reads of the
    // codec's gralloc buffers measured ~20–80 ms/frame on-device (effectively
    // uncached memory regardless of CPU_READ_OFTEN) — so it MUST happen off the
    // render thread; on it, every advanced frame blew the 16.6 ms budget and
    // judddered. The render thread (`decodeFramePlanes`) just memcpys a ready
    // slot out of cached RAM (~1–2 ms).
    // `RING_SIZE` (file scope) is the decoded-frame cushion.
    // Reader slots: frames rendered but not yet acquired by the worker, plus
    // headroom. The worker acquires (and releases) promptly, so this stays small.
    const READER_MAX_IMAGES = 8;

    /// One decoded frame in ordinary heap memory (tight planes, worker-filled).
    const Frame = struct {
        y: []u8, // w*h (row-tightened luma)
        u: []u8, // cw*ch (tight, de-interleaved chroma)
        v: []u8, // cw*ch
        pts: f64 = 0, // presentation timestamp, seconds
        color: ColorSpace = .{}, // the output format's colour keys when decoded
    };

    /// Heap-allocated shared state. The outer `AndroidVideoDecoder` is moved by
    /// value (into the Player, into the backend's slot array), so the worker
    /// thread must reference stable heap memory, never the outer struct.
    ///
    /// Threading contract: `extractor`/`codec`/`reader`/`input_done` are
    /// worker-only after `openFd` returns. `ring_head`/`ring_count`/`handoff`/
    /// `eof_seen` are shared and guarded by `mutex`. Slot CONTENT is safely accessed
    /// unlocked by exactly one side at a time: the worker writes only the tail
    /// slot (invisible until `ring_count` is bumped), the render thread reads
    /// only the head slot (the worker can't touch it while `ring_count` ≥ 1,
    /// since tail ≠ head until the pop completes).
    const State = struct {
        extractor: *Extractor,
        codec: *Codec,
        reader: *ImageReader,
        // The decoder OWNS this fd (handed over by `backend.zig` from
        // `AAsset_openFileDescriptor64`): closed in `deinit`. backend.zig must
        // NOT close it.
        fd: c_int,
        w: u32,
        h: u32,
        allocator: std.mem.Allocator,
        input_done: bool, // worker-only
        // Zig 0.16's std.atomic.Mutex is a try/unlock spinlock; `lock` below
        // spins. Fine here: every critical section is a few counter updates.
        mutex: std.atomic.Mutex,
        ring: [RING_SIZE]Frame,
        ring_head: usize, // oldest ready frame (render thread pops here)
        ring_count: usize, // ready frames in the ring
        // Frames released to the reader's surface (render=true) but not yet
        // acquired — the async surface handoff can lag a release by a beat.
        // `handoff.count` is "pending". Bounding the render loop on
        // `ring_count + pending` (not just ring_count) keeps the worker from
        // rendering more frames than the cushion can hold when acquires lag,
        // which would overflow the reader and DROP frames; `eof()` also
        // counts it so the last frames of a clip aren't cut while still in
        // the handoff. Each entry carries its release-time colour space.
        handoff: Handoff,
        // Output-side end-of-stream: set (under mutex) when AMediaCodec tags an
        // output buffer FLAG_EOS. `eof()` combines it with an empty ring so every
        // buffered frame is presented before the game hands off.
        eof_seen: bool,
        // The codec's CURRENT output colour keys (worker writes on every
        // OUTPUT_FORMAT_CHANGED; stamped onto each frame at publish) and the
        // colour space of the frame most recently popped by the render thread
        // — `colorSpace()`. Both under `mutex`.
        color: ColorSpace,
        last_color: ColorSpace,
        // Worker-only: the crop rect / read failure last logged, so each is
        // reported once (per change), not per frame.
        logged_crop: ?CropRect,
        logged_read_err: ?ReadError,
        running: std.atomic.Value(bool),
        thread: ?std.Thread,
    };

    st: *State,

    /// Blocking lock over Zig 0.16's try-only `std.atomic.Mutex`. Contention is
    /// rare and critical sections are a few instructions, so spinning is cheap.
    fn lock(m: *std.atomic.Mutex) void {
        while (!m.tryLock()) std.atomic.spinLoopHint();
    }

    /// Open a video stream from a file descriptor (the APK asset fd from
    /// `AAsset_openFileDescriptor`, with its offset/length). Selects the first
    /// `video/*` track and configures a hardware decoder in ByteBuffer mode.
    pub fn openFd(a: std.mem.Allocator, fd: c_int, offset: i64, length: i64) Error!AndroidVideoDecoder {
        // Ownership transfers here: the decoder now owns `fd`. On any error path
        // close it (the returned struct never gets built); on success the field
        // takes over and `deinit` closes it. backend.zig must not close it.
        errdefer _ = close(fd);
        const ex = AMediaExtractor_new() orelse return error.DecoderInit;
        errdefer AMediaExtractor_delete(ex);
        if (AMediaExtractor_setDataSourceFd(ex, fd, offset, length) != AMEDIA_OK)
            return error.DecoderInit;

        const n = AMediaExtractor_getTrackCount(ex);
        var track: usize = 0;
        var found = false;
        // The mime string from AMediaFormat_getString is owned by the format
        // and freed by AMediaFormat_delete — copy it out before the format dies,
        // or createDecoderByType reads a dangling pointer.
        var mime_buf: [64]u8 = undefined;
        var mime_len: usize = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        while (track < n) : (track += 1) {
            const fmt = AMediaExtractor_getTrackFormat(ex, track) orelse continue;
            defer AMediaFormat_delete(fmt);
            var m: [*:0]const u8 = undefined;
            if (!AMediaFormat_getString(fmt, KEY_MIME, &m)) continue;
            const span = std.mem.span(m);
            if (!std.mem.startsWith(u8, span, "video/")) continue;
            if (span.len + 1 > mime_buf.len) continue;
            // Require real dimensions: a missing width/height key would leave
            // w/h at 0, giving a 1×1 ImageReader and a zero-sized texture.
            if (!AMediaFormat_getInt32(fmt, KEY_WIDTH, &w)) return error.MissingDimensions;
            if (!AMediaFormat_getInt32(fmt, KEY_HEIGHT, &h)) return error.MissingDimensions;
            @memcpy(mime_buf[0..span.len], span);
            mime_buf[span.len] = 0;
            mime_len = span.len;
            found = true;
            break;
        }
        if (!found) return error.NoVideoTrack;
        const mime: [*:0]const u8 = mime_buf[0..mime_len :0].ptr;
        if (AMediaExtractor_selectTrack(ex, track) != AMEDIA_OK) return error.DecoderInit;

        // Output to a YUV_420_888 ImageReader (format-agnostic, CPU-readable).
        // maxImages = READER_MAX_IMAGES so we can HOLD a RING_SIZE cushion of
        // acquired frames while leaving the decoder free slots to render ahead.
        //
        // CPU_READ_OFTEN is load-bearing: it makes gralloc map the buffers
        // CACHEABLE for the CPU. The plain constructor's default (CPU_READ_RARELY,
        // uncached) made the per-frame plane copy take 30–80 ms on-device — the
        // source of the video judder. Fall back to the plain constructor if the
        // usage combination is unsupported (some codec/gralloc pairings reject it).
        const AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN: u64 = 3;
        var reader_opt: ?*ImageReader = null;
        if (AImageReader_newWithUsage(@max(w, 1), @max(h, 1), FORMAT_YUV_420_888, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN, READER_MAX_IMAGES, &reader_opt) != AMEDIA_OK or reader_opt == null) {
            reader_opt = null;
            if (AImageReader_new(@max(w, 1), @max(h, 1), FORMAT_YUV_420_888, READER_MAX_IMAGES, &reader_opt) != AMEDIA_OK)
                return error.DecoderInit;
        }
        const reader = reader_opt orelse return error.DecoderInit;
        errdefer AImageReader_delete(reader);
        var window_opt: ?*Window = null;
        if (AImageReader_getWindow(reader, &window_opt) != AMEDIA_OK) return error.DecoderInit;
        const window = window_opt orelse return error.DecoderInit;

        const cfg_fmt = AMediaExtractor_getTrackFormat(ex, track) orelse return error.DecoderInit;
        defer AMediaFormat_delete(cfg_fmt);
        const codec = startDecoder(mime, cfg_fmt, window) orelse return error.DecoderInit;
        errdefer AMediaCodec_delete(codec);

        const uw: u32 = @intCast(@max(w, 0));
        const uh: u32 = @intCast(@max(h, 0));
        const st = a.create(State) catch return error.DecoderInit;
        errdefer a.destroy(st);
        const ring = allocRing(a, uw, uh) orelse return error.DecoderInit;
        st.* = .{
            .extractor = ex,
            .codec = codec,
            .reader = reader,
            .fd = fd,
            .w = uw,
            .h = uh,
            .allocator = a,
            .input_done = false,
            .mutex = .unlocked,
            .ring = ring,
            .ring_head = 0,
            .ring_count = 0,
            .handoff = .{},
            .eof_seen = false,
            .color = .{},
            .last_color = .{},
            .logged_crop = null,
            .logged_read_err = null,
            .running = std.atomic.Value(bool).init(true),
            .thread = null,
        };
        st.thread = std.Thread.spawn(.{}, workerMain, .{st}) catch {
            freeRing(a, st.ring);
            return error.DecoderInit;
        };
        return .{ .st = st };
    }

    /// Create, configure and start a decoder for `mime` rendering into
    /// `window`, trying candidates in order until one starts — the device's
    /// default (hardware) decoder first, then the platform software decoders
    /// by name. Null when none starts.
    ///
    /// The fallback is load-bearing, not defensive: some vendor OMX decoders
    /// refuse to be configured against an `AImageReader` consumer at all.
    /// MediaTek's `OMX.MTK.VIDEO.DECODER.AVC` answers `BadParameter` to every
    /// output buffer count the framework proposes and `start` fails with
    /// "Failed to allocate buffers after transitioning to IDLE" (labelle-bgfx#95;
    /// the same `-22` is on record for ExoPlayer on stock MediaTek firmware,
    /// google/ExoPlayer#10285). The system Gallery plays the same clip on the
    /// same device, so it is the decoder/consumer pairing, not the file — and
    /// `c2.android.avc.decoder` decodes 1080p24 in real time there with this
    /// reader unchanged. Software decode is the whole intro on such devices;
    /// without it the clip never plays anywhere on them.
    ///
    /// `debug.labelle.video.force_sw=1` (a system property) skips the hardware
    /// candidate so the software path can be exercised on devices whose
    /// hardware decoder works — the fallback must be TESTED, not trusted.
    fn startDecoder(mime: [*:0]const u8, cfg_fmt: *Format, window: *Window) ?*Codec {
        const force_sw = forceSoftwareDecoder();
        if (force_sw) std.log.warn("video: {s} forcing the software decoder", .{FORCE_SW_PROP});

        if (!force_sw) {
            if (tryStart(AMediaCodec_createDecoderByType(mime), cfg_fmt, window)) |c| return c;
            std.log.warn("video: the device's default decoder for {s} failed to configure/start — trying software decoders", .{mime});
        }
        for (softwareDecoderNames(mime)) |name| {
            if (tryStart(AMediaCodec_createCodecByName(name), cfg_fmt, window)) |c| {
                std.log.info("video: decoding {s} with {s}", .{ mime, name });
                return c;
            }
        }
        std.log.err("video: no decoder for {s} could be started", .{mime});
        return null;
    }

    /// Configure + start one candidate; on failure the codec is deleted and
    /// null returned so the caller moves on to the next.
    fn tryStart(codec_opt: ?*Codec, cfg_fmt: *Format, window: *Window) ?*Codec {
        const codec = codec_opt orelse return null;
        // Render into the ImageReader's surface (decoder normalizes its vendor
        // format to YUV_420_888 by the time AImage exposes the planes).
        if (AMediaCodec_configure(codec, cfg_fmt, @ptrCast(window), null, 0) != AMEDIA_OK) {
            AMediaCodec_delete(codec);
            return null;
        }
        if (AMediaCodec_start(codec) != AMEDIA_OK) {
            AMediaCodec_delete(codec);
            return null;
        }
        return codec;
    }

    /// Platform software decoders for a MIME type, newest first: the Codec2
    /// names (Android 10+, `media.swcodec`) then the OMX names older devices
    /// ship. Unknown types have no software fallback.
    fn softwareDecoderNames(mime: [*:0]const u8) []const [*:0]const u8 {
        const m = std.mem.span(mime);
        if (std.mem.eql(u8, m, "video/avc")) return &.{ "c2.android.avc.decoder", "OMX.google.h264.decoder" };
        if (std.mem.eql(u8, m, "video/hevc")) return &.{ "c2.android.hevc.decoder", "OMX.google.hevc.decoder" };
        if (std.mem.eql(u8, m, "video/x-vnd.on2.vp9")) return &.{ "c2.android.vp9.decoder", "OMX.google.vp9.decoder" };
        if (std.mem.eql(u8, m, "video/x-vnd.on2.vp8")) return &.{ "c2.android.vp8.decoder", "OMX.google.vp8.decoder" };
        return &.{};
    }

    const FORCE_SW_PROP = "debug.labelle.video.force_sw";
    // bionic: `int __system_property_get(const char *name, char *value)`;
    // `value` must hold PROP_VALUE_MAX (92) bytes. Returns the value length,
    // 0 when unset.
    extern fn __system_property_get(name: [*:0]const u8, value: [*]u8) c_int;

    fn forceSoftwareDecoder() bool {
        var buf: [92]u8 = undefined;
        const n = __system_property_get(FORCE_SW_PROP, &buf);
        if (n <= 0) return false;
        const v = buf[0..@intCast(n)];
        return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }

    /// Allocate the ring's tight plane buffers (Y = w*h, U/V = cw*ch per slot).
    /// Null on OOM, freeing anything already allocated.
    fn allocRing(a: std.mem.Allocator, w: u32, h: u32) ?[RING_SIZE]Frame {
        const cw = planes.chromaWidth(w);
        const ch = planes.chromaHeight(h);
        var ring: [RING_SIZE]Frame = undefined;
        var done: usize = 0;
        while (done < RING_SIZE) : (done += 1) {
            const y = a.alloc(u8, @as(usize, w) * h) catch break;
            const u = a.alloc(u8, @as(usize, cw) * ch) catch {
                a.free(y);
                break;
            };
            const v = a.alloc(u8, @as(usize, cw) * ch) catch {
                a.free(u);
                a.free(y);
                break;
            };
            ring[done] = .{ .y = y, .u = u, .v = v };
        }
        if (done < RING_SIZE) {
            for (ring[0..done]) |f| {
                a.free(f.y);
                a.free(f.u);
                a.free(f.v);
            }
            return null;
        }
        return ring;
    }

    fn freeRing(a: std.mem.Allocator, ring: [RING_SIZE]Frame) void {
        for (ring) |f| {
            a.free(f.y);
            a.free(f.u);
            a.free(f.v);
        }
    }

    pub fn width(self: *const AndroidVideoDecoder) u32 {
        return self.st.w;
    }
    pub fn height(self: *const AndroidVideoDecoder) u32 {
        return self.st.h;
    }

    /// True once the decoder has drained the stream (an output buffer carried
    /// FLAG_EOS). The player reads this via `@hasDecl` to mark a play-once clip
    /// ended, so the engine emits `engine__video_finished` and the game hands
    /// off. Without it, Android intros played forever (no auto-advance).
    pub fn eof(self: *const AndroidVideoDecoder) bool {
        const st = self.st;
        lock(&st.mutex);
        defer st.mutex.unlock();
        // Finished only once the codec drained AND every buffered frame — in
        // the ring AND still in the surface handoff (`pending`) — has been
        // presented, so a clip's last frames aren't cut.
        return streamFinished(st.eof_seen, st.ring_count, st.handoff.count);
    }

    /// Ready frames currently in the ring (thread-safe read).
    fn ringCount(st: *State) usize {
        lock(&st.mutex);
        defer st.mutex.unlock();
        return st.ring_count;
    }

    /// Frames the cushion is on the hook for: ready in the ring plus released
    /// to the reader but not yet acquired (thread-safe read).
    fn cushionLoad(st: *State) usize {
        lock(&st.mutex);
        defer st.mutex.unlock();
        return st.ring_count + st.handoff.count;
    }

    /// Try to move ONE rendered frame from the reader into the ring: acquire
    /// (FIFO), copy its planes into the tail slot, publish by bumping
    /// `ring_count`. The tail slot is invisible to the render thread until the
    /// bump, so the (slow) copy runs unlocked. Returns false when nothing was
    /// ready to acquire or the ring is full. A frame whose plane read fails is
    /// still consumed (better a skipped frame than a stuck `pending`).
    fn publishOne(st: *State) bool {
        {
            lock(&st.mutex);
            defer st.mutex.unlock();
            if (st.handoff.count == 0 or st.ring_count >= RING_SIZE) return false;
        }
        var img_opt: ?*Image = null;
        if (AImageReader_acquireNextImage(st.reader, &img_opt) != AMEDIA_OK) return false;
        const img = img_opt orelse return false;
        defer AImage_delete(img);
        lock(&st.mutex);
        const tail = (st.ring_head + st.ring_count) % RING_SIZE;
        st.mutex.unlock();
        const slot = &st.ring[tail];
        const filled = fillPlanes(st, img, slot.y, slot.u, slot.v);
        if (filled) slot.pts = imageTimestamp(img);
        lock(&st.mutex);
        // The colour the frame was RELEASED under (`Handoff`), not the
        // codec's current one.
        const released_color = st.handoff.pop() orelse st.color;
        if (filled) {
            slot.color = released_color;
            st.ring_count += 1;
        }
        st.mutex.unlock();
        return true;
    }

    /// Worker thread: keeps the codec fed and the ring full, entirely off the
    /// render thread. Each iteration feeds input, then moves ready output into
    /// ring slots — including the expensive gralloc→RAM plane copy (~20–80 ms/
    /// frame on-device: the codec's buffers are effectively uncached for the CPU,
    /// which is WHY this work can't live on the render thread). The ring bounds
    /// look-ahead: input is fed and output rendered only while there's room, so
    /// a full ring back-pressures the codec (output buffers fill → input stalls →
    /// extractor stops) instead of overflowing the reader and dropping frames.
    /// All codec dequeues are non-blocking; idle iterations back off with a short
    /// sleep. Exits when `running` clears (deinit joins).
    fn workerMain(st: *State) void {
        // Consecutive fully-idle iterations after EOS with frames still
        // "pending" — see the failsafe at the bottom of the loop.
        var pending_dry: u32 = 0;
        while (st.running.load(.acquire)) {
            var did_work = false;

            // -- Feed input while the cushion has room. The codec self-regulates:
            // once its input buffers are all queued, dequeueInputBuffer returns
            // <0 and we stop. The extractor advances / input EOS is marked only
            // on a successful queue; a refused queue (sample or EOS marker)
            // ends the stream — `inputQueueStep` says why a retry can't work.
            while (!st.input_done and cushionLoad(st) < RING_SIZE) {
                const in_idx = AMediaCodec_dequeueInputBuffer(st.codec, 0);
                if (in_idx <= AMEDIA_ERROR_BASE) {
                    terminalCodecError(st, "input dequeue", in_idx);
                    break;
                }
                if (in_idx < 0) break; // no free input buffer right now
                const idx: usize = @intCast(in_idx);
                var cap: usize = 0;
                const buf_opt = AMediaCodec_getInputBuffer(st.codec, idx, &cap);
                const buf = switch (inputBufferStep(buf_opt != null)) {
                    .fill => buf_opt.?,
                    .end_stream => {
                        terminalCodecError(st, "null input buffer (index)", in_idx);
                        break;
                    },
                };
                const n = AMediaExtractor_readSampleData(st.extractor, buf, cap);
                const eos = n < 0;
                const status = if (eos)
                    AMediaCodec_queueInputBuffer(st.codec, idx, 0, 0, 0, FLAG_EOS)
                else blk: {
                    // Tag the sample with the extractor's current presentation
                    // time (clamped ≥ 0) for PTS accuracy — read BEFORE advance.
                    const sample_us = AMediaExtractor_getSampleTime(st.extractor);
                    const time_us: u64 = @intCast(@max(sample_us, 0));
                    break :blk AMediaCodec_queueInputBuffer(st.codec, idx, 0, @intCast(n), time_us, 0);
                };
                switch (inputQueueStep(status, eos)) {
                    .advance => {
                        _ = AMediaExtractor_advance(st.extractor);
                        did_work = true;
                    },
                    .input_eos => st.input_done = true,
                    .end_stream => {
                        terminalCodecError(st, if (eos) "input EOS queue" else "input queue", status);
                        break;
                    },
                }
            }

            // -- Publish frames that finished the async surface handoff on a
            // previous iteration (their release preceded the acquire being
            // ready). Runs even when the codec has no new output, so the last
            // frames of a clip can't sit unacquired in the reader.
            while (publishOne(st)) did_work = true;

            // -- Render decoded output toward the reader, ONE frame per
            // iteration, ONLY while the cushion (ring + pending handoffs) has
            // room. Rendering only what we can hold is load-bearing: draining
            // ALL decoded output but consuming at ~playback rate overflowed the
            // reader and DROPPED ~85% of frames — the survivors were sparse and
            // the video crawled at ~5 fps. Leaving un-rendered output in the
            // codec back-pressures it instead. `pending` (not just ring_count)
            // bounds the loop so lagging acquires can't let renders run ahead.
            while (cushionLoad(st) < RING_SIZE) {
                var info: BufferInfo = undefined;
                const out_idx = AMediaCodec_dequeueOutputBuffer(st.codec, &info, 0);
                if (out_idx == INFO_FORMAT_CHANGED) {
                    refreshFormat(st);
                    continue;
                }
                if (out_idx <= AMEDIA_ERROR_BASE) {
                    terminalCodecError(st, "output dequeue", out_idx);
                    break;
                }
                if (out_idx < 0) break; // no decoded output ready right now
                const eos = info.flags & FLAG_EOS != 0;
                // Only a non-empty buffer produces a frame in the reader (the
                // EOS carrier is typically zero-size); render and count it as
                // pending only then, or `pending` would never drain and `eof()`
                // would never fire.
                const has_frame = info.size > 0;
                const rc = AMediaCodec_releaseOutputBuffer(st.codec, @intCast(out_idx), has_frame);
                if (has_frame and rc != AMEDIA_OK) {
                    // The frame was NOT handed to the reader, so it must not
                    // be counted as pending: RING_SIZE such failures would
                    // fill the cushion, stop every further dequeue (the EOS
                    // carrier included) and — with `eof_seen` still false —
                    // starve the dry-drain failsafe: a play-once clip stuck
                    // forever. A codec/surface that refuses a render is done;
                    // end the stream like any other codec error (the ring
                    // still plays out, then `eof()` fires).
                    terminalCodecError(st, "output release", rc);
                    break;
                }
                // `pending` and `eof_seen` in ONE critical section — an EOS
                // tag on the last frame must not be visible before that
                // frame is counted (`recordRelease`).
                lock(&st.mutex);
                recordRelease(&st.handoff, &st.eof_seen, has_frame, eos, st.color);
                st.mutex.unlock();
                if (!has_frame) continue;
                did_work = true;
                // Common case: the frame is already acquirable — publish now.
                _ = publishOne(st);
            }

            // Failsafe: `pending` expects every released frame to become
            // acquirable, but the reader's BufferQueue MAY drop frames
            // internally (async/mailbox semantics under load) — a release with
            // no matching acquire, ever. After EOS that would pin `pending` > 0
            // and hold `eof()` false forever: the intro freezes on its last
            // frame and never hands off (observed on-device). Before EOS,
            // enough drops fill the cushion and stop every output dequeue, so
            // EOS is never reached either. If ~100 ms (after EOS) / ~2 s
            // (before it) of drain attempts surface nothing, the remaining
            // pending frames are gone — write them off so the stream moves
            // again (`handoffWriteOffAfter`).
            if (!did_work) {
                var bound: ?u32 = null;
                {
                    lock(&st.mutex);
                    defer st.mutex.unlock();
                    bound = handoffWriteOffAfter(st.eof_seen, st.ring_count, st.handoff.count);
                }
                if (bound) |limit| {
                    pending_dry += 1;
                    if (pending_dry >= limit) { // consecutive dry drains
                        lock(&st.mutex);
                        const lost = st.handoff.count;
                        st.handoff.writeOff();
                        const at_eos = st.eof_seen;
                        st.mutex.unlock();
                        std.log.warn("video: {d} released frame(s) never surfaced from the reader — written off ({s})", .{ lost, if (at_eos) "after EOS" else "cushion stalled before EOS" });
                        pending_dry = 0;
                    }
                } else pending_dry = 0;
                _ = usleep(2000); // idle: back off briefly
            } else pending_dry = 0;
        }
    }

    /// A codec that reports an ERROR from a dequeue is done: it will never
    /// produce EOS, so treating the error as "nothing yet" (what `< 0` alone
    /// does) would spin here forever with `eof()` false — the clip freezes on
    /// its last frame and a play-once video never finishes. End the stream
    /// instead: what is already in the ring still plays out, then `eof()`
    /// fires and the engine hands off exactly as on a normal end of clip.
    ///
    /// `pending` is left alone: it counts frames already RELEASED to the
    /// reader, not frames the codec still owes, so they can still be acquired
    /// and shown. Any that never surface are written off by the worker's
    /// dry-drain failsafe once `eof_seen` is set, the same as after a normal EOS.
    /// Also the terminal path for a failed `releaseOutputBuffer(render=true)`
    /// a refused `queueInputBuffer` (`inputQueueStep`) and a null
    /// `getInputBuffer` (`inputBufferStep`).
    fn terminalCodecError(st: *State, what: []const u8, code: anytype) void {
        lock(&st.mutex);
        defer st.mutex.unlock();
        // Only the transition logs: a stream already ending (EOS or an
        // earlier error) is left alone.
        if (endStream(&st.input_done, &st.eof_seen))
            std.log.err("video: codec error {d} on {s} — ending the stream", .{ code, what });
    }

    fn imageTimestamp(img: *Image) f64 {
        var ts_ns: i64 = 0;
        _ = AImage_getTimestamp(img, &ts_ns);
        return @as(f64, @floatFromInt(ts_ns)) / 1_000_000_000.0; // PTS seconds
    }

    /// Pop the oldest ready frame under the mutex. Returns a pointer to the head
    /// slot WITHOUT advancing it — call `popDone` after copying the content out.
    /// Safe: the worker never writes the head slot while `ring_count` ≥ 1.
    fn popPeek(st: *State) ?*const Frame {
        lock(&st.mutex);
        defer st.mutex.unlock();
        if (st.ring_count == 0) return null;
        return &st.ring[st.ring_head];
    }

    /// Advance the head after copying it out; `color` (the popped frame's)
    /// becomes what `colorSpace()` reports.
    fn popDone(st: *State, color: ColorSpace) void {
        lock(&st.mutex);
        defer st.mutex.unlock();
        st.ring_head = (st.ring_head + 1) % RING_SIZE;
        st.ring_count -= 1;
        st.last_color = color;
    }

    /// CPU fallback path: pop the oldest ready frame and convert its (already
    /// tight) YUV planes to RGBA8 into `out` (width*height*4 bytes). Returns the
    /// frame PTS in seconds, or null if no frame is ready yet.
    pub fn decodeFrame(self: *AndroidVideoDecoder, out: []u8) ?f64 {
        const st = self.st;
        if (out.len != @as(usize, st.w) * st.h * 4) return null;
        const cw = planes.chromaWidth(st.w);
        const slot = popPeek(st) orelse return null;
        // Ring planes are tight: luma stride w / pixel 1; chroma stride cw / 1.
        // The matrix follows the frame's colour keys (BT.709 vs BT.601, full
        // vs limited) — `ColorSpace.matrix`.
        yuv.yuv420ToRgbaMatrix(slot.color.matrix(st.h), slot.y, st.w, 1, slot.u, slot.v, cw, 1, st.w, st.h, out);
        const pts = slot.pts;
        popDone(st, slot.color);
        return pts;
    }

    /// The colour space of the frame most recently returned by `decodeFrame`
    /// / `decodeFramePlanes` (before the first: what the codec has reported
    /// so far, `.unspecified` until its first OUTPUT_FORMAT_CHANGED). The
    /// GPU-YUV consumer selects its shader matrix from this (labelle-bgfx#155;
    /// bgfx's `fs_yuv` is BT.601 limited until then).
    pub fn colorSpace(self: *const AndroidVideoDecoder) ColorSpace {
        const st = self.st;
        lock(&st.mutex);
        defer st.mutex.unlock();
        return st.last_color;
    }

    /// GPU-YUV path: pop the oldest ready frame and memcpy its tight Y/U/V planes
    /// into the caller's plane buffers — `y` is w*h, `u`/`v` are cw*ch. Returns
    /// the frame PTS in seconds, or null if no frame is ready yet. The planes were
    /// tightened by the worker into ordinary cached RAM, so this is a fast copy
    /// (~1–2 ms) — the slow gralloc read happens off-thread.
    pub fn decodeFramePlanes(self: *AndroidVideoDecoder, y: []u8, u: []u8, v: []u8) ?f64 {
        const st = self.st;
        const cw = planes.chromaWidth(st.w);
        const ch = planes.chromaHeight(st.h);
        if (y.len != @as(usize, st.w) * st.h) return null;
        if (u.len != @as(usize, cw) * ch or v.len != @as(usize, cw) * ch) return null;
        const slot = popPeek(st) orelse return null;
        @memcpy(y, slot.y);
        @memcpy(u, slot.u);
        @memcpy(v, slot.v);
        const pts = slot.pts;
        popDone(st, slot.color);
        return pts;
    }

    /// An output-format change is emitted once before the first frame (and
    /// again if the decoded layout changes). It retains the COLOUR keys —
    /// `color-standard` / `color-range` / `color-transfer` — as the current
    /// `ColorSpace`, stamped onto every frame published from here on: the CPU
    /// `decodeFrame` selects its matrix from it and `colorSpace()` hands it to
    /// the GPU-YUV consumer (labelle-bgfx#155). Absent keys (untagged stream,
    /// pre-API-28 device) leave the fields `.unspecified`, which `matrix`
    /// resolves by height.
    ///
    /// We deliberately do NOT re-read width/height here. `openFd` already
    /// sized `w`/`h` (and thus the ImageReader) from the track's display
    /// dimensions, and `Player.init` allocated its texture + `pixels` buffer
    /// from `width()`/`height()` before any frame is decoded. Mutating the dims
    /// now — to the aligned/coded size (e.g. 1080 → 1088) OR to a crop rect that
    /// differs from the open dims — would desync that buffer, so `decodeFrame`'s
    /// `out.len != w*h*4` guard would then reject every frame (black screen).
    /// The coded-size padding is handled per frame by the AImage crop rect
    /// (`readPlanes`) instead.
    fn refreshFormat(st: *State) void {
        const fmt = AMediaCodec_getOutputFormat(st.codec) orelse return;
        defer AMediaFormat_delete(fmt);
        var standard: i32 = 0;
        var range: i32 = 0;
        var transfer: i32 = 0;
        const color = ColorSpace.fromFormat(
            if (AMediaFormat_getInt32(fmt, KEY_COLOR_STANDARD, &standard)) standard else null,
            if (AMediaFormat_getInt32(fmt, KEY_COLOR_RANGE, &range)) range else null,
            if (AMediaFormat_getInt32(fmt, KEY_COLOR_TRANSFER, &transfer)) transfer else null,
        );
        var fw: i32 = 0;
        var fh: i32 = 0;
        _ = AMediaFormat_getInt32(fmt, KEY_WIDTH, &fw);
        _ = AMediaFormat_getInt32(fmt, KEY_HEIGHT, &fh);
        std.log.info("video: output color standard={s} range={s} transfer={s} (raw {d}/{d}/{d}; format {d}x{d}, track {d}x{d}) → CPU matrix {s}", .{
            @tagName(color.standard),
            @tagName(color.range),
            @tagName(color.transfer),
            standard,
            range,
            transfer,
            fw,
            fh,
            st.w,
            st.h,
            matrixName(color.matrix(st.h)),
        });
        lock(&st.mutex);
        defer st.mutex.unlock();
        st.color = color;
        if (st.ring_count == 0) st.last_color = color; // nothing popped yet: report the stream's
    }

    fn matrixName(m: yuv.Matrix) []const u8 {
        const hd = m.rv == yuv.Matrix.bt709_limited.rv or m.rv == yuv.Matrix.bt709_full.rv;
        const full = m.y_off == 0;
        return if (hd) (if (full) "bt709_full" else "bt709_limited") else (if (full) "bt601_full" else "bt601_limited");
    }

    /// The three crop-offset, stride-described plane slices of a YUV_420_888
    /// AImage, ready for either the CPU convert (`yuv.yuv420ToRgba`) or the GPU
    /// plane tighten (`planes.tightenPlane`). `u`/`v` may alias one interleaved
    /// buffer (NV12, `uv_pixel_stride == 2`) or be separate (I420, `== 1`).
    /// Each slice starts at the crop origin and is verified to hold every
    /// sample of the `w × h` (luma) / `cw × ch` (chroma) copy.
    const ImagePlanes = struct {
        y: []const u8,
        u: []const u8,
        v: []const u8,
        y_row_stride: u32,
        y_pixel_stride: u32,
        uv_row_stride: u32,
        uv_pixel_stride: u32,
        crop: CropRect,
    };

    /// Read the Y/U/V plane pointers, strides, and crop rect from a
    /// YUV_420_888 AImage for a `w × h` frame. Format-agnostic (planar /
    /// semi-planar / vendor Flexible all expose the same plane+stride model).
    /// Errors on an API failure, an inconsistent crop (`resolveCrop`) or a
    /// plane too small for the crop-offset copy (`planeHolds`) — the frame is
    /// rejected rather than sampling padding or reading out of bounds.
    fn readPlanes(img: *const Image, w: u32, h: u32) ReadError!ImagePlanes {
        var num: i32 = 0;
        if (AImage_getNumberOfPlanes(img, &num) != AMEDIA_OK or num < 3) return error.NoPlanes;

        var yd: ?[*]u8 = null;
        var ud: ?[*]u8 = null;
        var vd: ?[*]u8 = null;
        var yl: i32 = 0;
        var ul: i32 = 0;
        var vl: i32 = 0;
        if (AImage_getPlaneData(img, 0, &yd, &yl) != AMEDIA_OK) return error.PlaneData;
        if (AImage_getPlaneData(img, 1, &ud, &ul) != AMEDIA_OK) return error.PlaneData;
        if (AImage_getPlaneData(img, 2, &vd, &vl) != AMEDIA_OK) return error.PlaneData;
        const yp = yd orelse return error.PlaneData;
        const up = ud orelse return error.PlaneData;
        const vp = vd orelse return error.PlaneData;
        if (yl <= 0 or ul <= 0 or vl <= 0) return error.PlaneData;

        var y_row: i32 = 0;
        var uv_row: i32 = 0;
        var y_px: i32 = 0;
        var uv_px: i32 = 0;
        _ = AImage_getPlaneRowStride(img, 0, &y_row);
        _ = AImage_getPlaneRowStride(img, 1, &uv_row);
        _ = AImage_getPlanePixelStride(img, 0, &y_px);
        _ = AImage_getPlanePixelStride(img, 1, &uv_px);
        const ys: u32 = @intCast(@max(y_row, 1));
        const yx: u32 = @intCast(@max(y_px, 1));
        const us: u32 = @intCast(@max(uv_row, 1));
        const ux: u32 = @intCast(@max(uv_px, 1));

        // Crop rect: the buffer may be padded beyond the display frame (e.g.
        // 1080 → 1088 rows), and the valid region may not start at the origin.
        // Offset each plane to the crop's top-left and copy `w × h` from there
        // — the crop must hold at least that (see `resolveCrop`). A failed
        // `getCropRect` leaves the all-zero rect = no crop.
        var crop: CropRect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (AImage_getCropRect(img, &crop) != AMEDIA_OK) crop = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const origin = try resolveCrop(crop, w, h);
        const cw = planes.chromaWidth(w);
        const ch = planes.chromaHeight(h);
        const y_off: usize = @as(usize, origin.top) * ys + @as(usize, origin.left) * yx;
        const uv_off: usize = @as(usize, origin.top / 2) * us + @as(usize, origin.left / 2) * ux;
        const yl_u: usize = @intCast(yl);
        const ul_u: usize = @intCast(ul);
        const vl_u: usize = @intCast(vl);
        if (!planeHolds(yl_u, ys, yx, y_off, w, h)) return error.PlaneTooSmall;
        if (!planeHolds(ul_u, us, ux, uv_off, cw, ch)) return error.PlaneTooSmall;
        if (!planeHolds(vl_u, us, ux, uv_off, cw, ch)) return error.PlaneTooSmall;

        return .{
            .y = yp[y_off..yl_u],
            .u = up[uv_off..ul_u],
            .v = vp[uv_off..vl_u],
            .y_row_stride = ys,
            .y_pixel_stride = yx,
            .uv_row_stride = us,
            .uv_pixel_stride = ux,
            .crop = crop,
        };
    }

    /// Copy the AImage's Y/U/V planes into tight per-plane buffers (row-
    /// tightening Y; row-tightening AND de-interleaving U/V for the NV12
    /// `pixel_stride == 2` case). Runs on the WORKER thread — reads of the
    /// image's gralloc memory are slow (~10–30 ms/frame even vectorized) and
    /// must not touch the render thread. False (frame skipped) when the image
    /// cannot be read consistently; the crop rect and any read error are
    /// logged once per change, not per frame.
    fn fillPlanes(st: *State, img: *Image, y_dst: []u8, u_dst: []u8, v_dst: []u8) bool {
        const p = readPlanes(img, st.w, st.h) catch |e| {
            const already_logged = if (st.logged_read_err) |prev| prev == e else false;
            if (!already_logged) {
                st.logged_read_err = e;
                std.log.err("video: image rejected ({s}) for the {d}x{d} frame — skipping until it changes", .{ @errorName(e), st.w, st.h });
            }
            return false;
        };
        if (st.logged_crop == null or !std.meta.eql(st.logged_crop.?, p.crop)) {
            st.logged_crop = p.crop;
            std.log.info("video: image crop l={d} t={d} r={d} b={d} for the {d}x{d} frame (Y row stride {d} px {d}; UV row stride {d} px {d}; plane bytes {d}/{d}/{d})", .{
                p.crop.left, p.crop.top, p.crop.right, p.crop.bottom, st.w, st.h, p.y_row_stride, p.y_pixel_stride, p.uv_row_stride, p.uv_pixel_stride, p.y.len, p.u.len, p.v.len,
            });
        }
        const cw = planes.chromaWidth(st.w);
        const ch = planes.chromaHeight(st.h);
        planes.tightenPlane(p.y, p.y_row_stride, p.y_pixel_stride, st.w, st.h, y_dst);
        planes.tightenPlane(p.u, p.uv_row_stride, p.uv_pixel_stride, cw, ch, u_dst);
        planes.tightenPlane(p.v, p.uv_row_stride, p.uv_pixel_stride, cw, ch, v_dst);
        return true;
    }

    pub fn deinit(self: *AndroidVideoDecoder) void {
        const st = self.st;
        // Stop the worker first — it owns the codec/extractor/reader while alive.
        st.running.store(false, .release);
        if (st.thread) |t| t.join();
        _ = AMediaCodec_stop(st.codec);
        AMediaCodec_delete(st.codec);
        AImageReader_delete(st.reader);
        AMediaExtractor_delete(st.extractor);
        // The decoder owns the asset fd (see the State field comment); release
        // it so loop/replay can't leak descriptors. backend.zig must not close it.
        _ = close(st.fd);
        freeRing(st.allocator, st.ring);
        st.allocator.destroy(st);
    }
};

// ── Tests (host-runnable — the pure colour / crop / end-of-stream helpers) ─

const testing = std.testing;

test "ColorSpace.fromFormat: the MediaFormat constants; absent keys stay unspecified" {
    const hd = ColorSpace.fromFormat(1, 2, 3);
    try testing.expectEqual(ColorSpace.Standard.bt709, hd.standard);
    try testing.expectEqual(ColorSpace.Range.limited, hd.range);
    try testing.expectEqual(ColorSpace.Transfer.sdr_video, hd.transfer);
    try testing.expectEqual(ColorSpace.Standard.bt601_pal, ColorSpace.fromFormat(2, null, null).standard);
    try testing.expectEqual(ColorSpace.Standard.bt601_ntsc, ColorSpace.fromFormat(4, null, null).standard);
    try testing.expectEqual(ColorSpace.Standard.bt2020, ColorSpace.fromFormat(6, 1, 6).standard);
    try testing.expectEqual(ColorSpace.Range.full, ColorSpace.fromFormat(6, 1, 6).range);
    try testing.expectEqual(ColorSpace.Transfer.st2084, ColorSpace.fromFormat(6, 1, 6).transfer);
    try testing.expectEqual(ColorSpace.Transfer.hlg, ColorSpace.fromFormat(null, null, 7).transfer);
    try testing.expectEqual(ColorSpace.Standard.other, ColorSpace.fromFormat(99, 99, 99).standard);
    try testing.expectEqual(ColorSpace.Range.unspecified, ColorSpace.fromFormat(99, 99, 99).range);
    try testing.expectEqual(ColorSpace{}, ColorSpace.fromFormat(null, null, null));
}

test "ColorSpace.matrix: standard + range pick the matrix; unspecified follows HD/SD by height" {
    const M = yuv.Matrix;
    try testing.expectEqual(M.bt709_limited, (ColorSpace{ .standard = .bt709, .range = .limited }).matrix(1080));
    try testing.expectEqual(M.bt709_full, (ColorSpace{ .standard = .bt709, .range = .full }).matrix(1080));
    try testing.expectEqual(M.bt601_limited, (ColorSpace{ .standard = .bt601_ntsc }).matrix(1080)); // tagged 601 wins over height
    try testing.expectEqual(M.bt601_full, (ColorSpace{ .standard = .bt601_pal, .range = .full }).matrix(480));
    try testing.expectEqual(M.bt709_limited, (ColorSpace{ .standard = .bt2020 }).matrix(2160));
    // Untagged: the ffmpeg/Chromium convention.
    try testing.expectEqual(M.bt709_limited, (ColorSpace{}).matrix(1080));
    try testing.expectEqual(M.bt709_limited, (ColorSpace{}).matrix(720));
    try testing.expectEqual(M.bt601_limited, (ColorSpace{}).matrix(576));
    try testing.expectEqual(M.bt601_full, (ColorSpace{ .range = .full }).matrix(480));
}

test "resolveCrop: no rect = origin; a crop covering the frame copies from its origin; inconsistent crops error" {
    const none = CropRect{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    try testing.expectEqual(@as(u32, 0), (try resolveCrop(none, 1920, 1080)).top);
    // The common padded case: 1920x1088 buffer, crop = the 1920x1080 frame.
    const coded = CropRect{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };
    try testing.expectEqual(@as(u32, 0), (try resolveCrop(coded, 1920, 1080)).left);
    // An offset crop: copy from (8, 4).
    const offset = CropRect{ .left = 8, .top = 4, .right = 1928, .bottom = 1084 };
    const o = try resolveCrop(offset, 1920, 1080);
    try testing.expectEqual(@as(u32, 8), o.left);
    try testing.expectEqual(@as(u32, 4), o.top);
    // A crop LARGER than the frame is fine (the top-left w×h is taken).
    _ = try resolveCrop(.{ .left = 0, .top = 0, .right = 1920, .bottom = 1088 }, 1920, 1080);
    // Smaller than the frame in either axis, inverted, or negative: rejected.
    try testing.expectError(error.SmallerThanFrame, resolveCrop(.{ .left = 0, .top = 0, .right = 1918, .bottom = 1080 }, 1920, 1080));
    try testing.expectError(error.SmallerThanFrame, resolveCrop(.{ .left = 8, .top = 0, .right = 1920, .bottom = 1080 }, 1920, 1080));
    try testing.expectError(error.Inverted, resolveCrop(.{ .left = 10, .top = 0, .right = 10, .bottom = 1080 }, 1920, 1080));
    try testing.expectError(error.Inverted, resolveCrop(.{ .left = 0, .top = 100, .right = 1920, .bottom = 50 }, 1920, 1080));
    try testing.expectError(error.NegativeOrigin, resolveCrop(.{ .left = -8, .top = 0, .right = 1912, .bottom = 1080 }, 1920, 1080));
}

test "planeHolds: the bottom-right sample must lie inside the plane (the check that replaces the assert)" {
    // Tight 4x2 luma plane: exactly 8 bytes hold it; 7 do not.
    try testing.expect(planeHolds(8, 4, 1, 0, 4, 2));
    try testing.expect(!planeHolds(7, 4, 1, 0, 4, 2));
    // Row-padded (stride 6): last sample at 1*6 + 3 = 9 → needs 10 bytes.
    try testing.expect(planeHolds(10, 6, 1, 0, 4, 2));
    try testing.expect(!planeHolds(9, 6, 1, 0, 4, 2));
    // A crop origin offset shifts the requirement: the finding's OOB case —
    // an offset crop whose final row exceeds the shortened plane slice.
    const off: usize = 2 * 6 + 1; // origin (1, 2) in a stride-6 plane
    try testing.expect(planeHolds(off + 10, 6, 1, off, 4, 2));
    try testing.expect(!planeHolds(off + 9, 6, 1, off, 4, 2));
    // NV12 chroma (pixel stride 2): 2x1 chroma needs bytes 0..3 → len 3.
    try testing.expect(planeHolds(3, 4, 2, 0, 2, 1));
    try testing.expect(!planeHolds(2, 4, 2, 0, 2, 1));
    // Degenerate sizes read nothing.
    try testing.expect(planeHolds(0, 4, 1, 0, 0, 0));
}

test "inputQueueStep: a refused queue (sample or EOS marker) ends the stream on the first failure, and eof() then fires" {
    // Success paths never touch the end-of-stream flags.
    try testing.expectEqual(InputQueueStep.advance, inputQueueStep(0, false));
    try testing.expectEqual(InputQueueStep.input_eos, inputQueueStep(0, true));

    // Mechanism: a refused sample is NOT a retry / skip (the old `break`
    // re-fed forever) — it takes the terminal branch, first time.
    try testing.expectEqual(InputQueueStep.end_stream, inputQueueStep(-10000, false)); // AMEDIA_ERROR_UNKNOWN
    try testing.expectEqual(InputQueueStep.end_stream, inputQueueStep(-10000, true));

    // The terminal branch (`terminalCodecError` → `endStream`) flips the
    // worker's flags, which is what makes `eof()` true once the ring drains.
    var input_done = false;
    var eof_seen = false;
    try testing.expect(!streamFinished(eof_seen, 0, 0)); // the old hang: never true
    try testing.expect(endStream(&input_done, &eof_seen)); // transition → logs once
    try testing.expect(input_done); // the feed loop stops (`while (!st.input_done ...)`)
    try testing.expect(eof_seen);
    try testing.expect(!streamFinished(eof_seen, 1, 0)); // buffered frames still play out
    try testing.expect(!streamFinished(eof_seen, 0, 1));
    try testing.expect(streamFinished(eof_seen, 0, 0));

    // A later error on an already-ending stream is not a new transition.
    try testing.expect(!endStream(&input_done, &eof_seen));
}

test "inputBufferStep: a null input buffer ends the stream (same terminal path as a refused queue)" {
    try testing.expectEqual(InputBufferStep.fill, inputBufferStep(true));
    // Mechanism (#5): null is NOT a skip-and-retry (the old `break` leaked
    // the dequeued index each time) — it is terminal, first time.
    try testing.expectEqual(InputBufferStep.end_stream, inputBufferStep(false));
    // …and the terminal path makes `eof()` reachable, as for a refused queue.
    var input_done = false;
    var eof_seen = false;
    try testing.expect(endStream(&input_done, &eof_seen));
    try testing.expect(input_done and eof_seen);
    try testing.expect(streamFinished(eof_seen, 0, 0));
}

test "recordRelease: an EOS-tagged LAST FRAME is counted pending in the same step that sets eof_seen" {
    var h: Handoff = .{};
    var eof_seen = false;
    // The frame-carrying EOS buffer (`info.size > 0`, FLAG_EOS).
    recordRelease(&h, &eof_seen, true, true, .{});
    // Mechanism (#5): one call (one critical section) moves BOTH — there is
    // no state with `eof_seen` set and the frame not yet pending.
    try testing.expect(eof_seen);
    try testing.expectEqual(@as(usize, 1), h.count);
    try testing.expect(!streamFinished(eof_seen, 0, h.count)); // not one frame early
    // The old two-step order exposed exactly this state to `eof()`:
    try testing.expect(streamFinished(true, 0, 0));
    // Once the frame is acquired (and then presented), eof() fires.
    _ = h.pop();
    try testing.expect(streamFinished(eof_seen, 0, h.count));

    // Zero-size EOS carrier: no frame counted, eof_seen set.
    var h2: Handoff = .{};
    var eof2 = false;
    recordRelease(&h2, &eof2, false, true, .{});
    try testing.expect(eof2);
    try testing.expectEqual(@as(usize, 0), h2.count);
    // Ordinary frame: counted, eof untouched.
    recordRelease(&h2, &eof2, true, false, .{});
    try testing.expectEqual(@as(usize, 1), h2.count);
}

test "Handoff: each pending frame keeps the colour it was released under (FIFO)" {
    var h: Handoff = .{};
    const old: ColorSpace = .{ .standard = .bt601_ntsc };
    const new: ColorSpace = .{ .standard = .bt709, .range = .full };
    var eof_seen = false;
    recordRelease(&h, &eof_seen, true, false, old);
    recordRelease(&h, &eof_seen, true, false, old);
    // OUTPUT_FORMAT_CHANGED lands while both are still in the handoff…
    recordRelease(&h, &eof_seen, true, false, new);
    // …the pre-change frames still come out with the OLD colour.
    try testing.expectEqual(old, h.pop().?);
    try testing.expectEqual(old, h.pop().?);
    try testing.expectEqual(new, h.pop().?);
    try testing.expectEqual(@as(?ColorSpace, null), h.pop());
    // Wraps around the ring.
    var i: usize = 0;
    while (i < 3 * RING_SIZE) : (i += 1) {
        const c: ColorSpace = if (i % 2 == 0) old else new;
        h.push(c);
        try testing.expectEqual(c, h.pop().?);
    }
    h.push(new);
    h.writeOff();
    try testing.expectEqual(@as(usize, 0), h.count);
    try testing.expectEqual(@as(?ColorSpace, null), h.pop());
}

test "handoffWriteOffAfter: dropped frames that fill the cushion BEFORE EOS are written off, on a long bound" {
    // Nothing pending: never a stall.
    try testing.expectEqual(@as(?u32, null), handoffWriteOffAfter(true, 0, 0));
    try testing.expectEqual(@as(?u32, null), handoffWriteOffAfter(false, 0, 0));
    // After EOS any pending frame that never surfaces is a stall (~100 ms, as before).
    try testing.expectEqual(@as(?u32, WRITE_OFF_AFTER_EOS), handoffWriteOffAfter(true, 0, 1));
    try testing.expectEqual(@as(?u32, WRITE_OFF_AFTER_EOS), handoffWriteOffAfter(true, 2, 1));
    // Mechanism (Codex on #3): before EOS, a cushion filled by lost handoffs
    // stops every output dequeue — EOS can never arrive, so this is a stall
    // too (the old `eof_seen and pending > 0` gate never fired here)…
    try testing.expectEqual(@as(?u32, WRITE_OFF_BEFORE_EOS), handoffWriteOffAfter(false, 0, RING_SIZE));
    try testing.expectEqual(@as(?u32, WRITE_OFF_BEFORE_EOS), handoffWriteOffAfter(false, 1, RING_SIZE - 1));
    // …on a bound far longer than after EOS: late (not lost) frames
    // during a startup GPU stall must not be written off (seen on-device).
    try testing.expect(WRITE_OFF_BEFORE_EOS >= 10 * WRITE_OFF_AFTER_EOS);
    // Before EOS with cushion room left the worker still dequeues output.
    try testing.expectEqual(@as(?u32, null), handoffWriteOffAfter(false, 1, 1));
    // A full RING is the render thread not consuming — never a stall.
    try testing.expectEqual(@as(?u32, null), handoffWriteOffAfter(false, RING_SIZE, 0));
    try testing.expectEqual(@as(?u32, null), handoffWriteOffAfter(true, RING_SIZE, 0));
}
