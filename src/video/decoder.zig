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
//! Known follow-ups (next slices):
//!   - crop rectangle (the AImage may be padded beyond w×h on some devices).
//!   - on a real handset (vs the emulator) confirm a Flexible/tiled clip; the
//!     plane-stride path is built for it but only emulator-verified so far.
//!   - audio-track decode (this is video-only) + AAudio output device (#306).

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
    extern fn AMediaCodec_queueInputBuffer(*Codec, idx: usize, offset: u32, size: usize, time_us: u64, flags: u32) i32;
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
    const CropRect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
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

    // AMediaFormat keys.
    const KEY_MIME: [*:0]const u8 = "mime";
    const KEY_WIDTH: [*:0]const u8 = "width";
    const KEY_HEIGHT: [*:0]const u8 = "height";

    // Decoded-frame ring buffer — the jitter cushion that decouples decoding from
    // presentation. A WORKER THREAD fills it: feed the codec, render output into
    // the ImageReader, then copy each frame's planes into a ring slot of ordinary
    // (cached) heap buffers. The copy is the expensive step — CPU reads of the
    // codec's gralloc buffers measured ~20–80 ms/frame on-device (effectively
    // uncached memory regardless of CPU_READ_OFTEN) — so it MUST happen off the
    // render thread; on it, every advanced frame blew the 16.6 ms budget and
    // judddered. The render thread (`decodeFramePlanes`) just memcpys a ready
    // slot out of cached RAM (~1–2 ms).
    const RING_SIZE = 4; // decoded-frame cushion (~130 ms at 30 fps)
    // Reader slots: frames rendered but not yet acquired by the worker, plus
    // headroom. The worker acquires (and releases) promptly, so this stays small.
    const READER_MAX_IMAGES = 8;

    /// One decoded frame in ordinary heap memory (tight planes, worker-filled).
    const Frame = struct {
        y: []u8, // w*h (row-tightened luma)
        u: []u8, // cw*ch (tight, de-interleaved chroma)
        v: []u8, // cw*ch
        pts: f64 = 0, // presentation timestamp, seconds
    };

    /// Heap-allocated shared state. The outer `AndroidVideoDecoder` is moved by
    /// value (into the Player, into the backend's slot array), so the worker
    /// thread must reference stable heap memory, never the outer struct.
    ///
    /// Threading contract: `extractor`/`codec`/`reader`/`input_done` are
    /// worker-only after `openFd` returns. `ring_head`/`ring_count`/`eof_seen`
    /// are shared and guarded by `mutex`. Slot CONTENT is safely accessed
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
        // Bounding the render loop on `ring_count + pending` (not just
        // ring_count) keeps the worker from rendering more frames than the
        // cushion can hold when acquires lag, which would overflow the reader
        // and DROP frames; `eof()` also counts it so the last frames of a clip
        // aren't cut while still in the handoff.
        pending: usize,
        // Output-side end-of-stream: set (under mutex) when AMediaCodec tags an
        // output buffer FLAG_EOS. `eof()` combines it with an empty ring so every
        // buffered frame is presented before the game hands off.
        eof_seen: bool,
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
            .pending = 0,
            .eof_seen = false,
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
        return st.eof_seen and st.ring_count == 0 and st.pending == 0;
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
        return st.ring_count + st.pending;
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
            if (st.pending == 0 or st.ring_count >= RING_SIZE) return false;
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
        if (filled) st.ring_count += 1;
        if (st.pending > 0) st.pending -= 1;
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
            // <0 and we stop. State mutates only on a successful queue — a
            // failed EOS queue retries next iteration, and a failed sample queue
            // does NOT advance the extractor (the sample retries with a fresh
            // buffer rather than being silently skipped).
            while (!st.input_done and cushionLoad(st) < RING_SIZE) {
                const in_idx = AMediaCodec_dequeueInputBuffer(st.codec, 0);
                if (in_idx <= AMEDIA_ERROR_BASE) {
                    terminalCodecError(st, "input", in_idx);
                    break;
                }
                if (in_idx < 0) break; // no free input buffer right now
                const idx: usize = @intCast(in_idx);
                var cap: usize = 0;
                const buf = AMediaCodec_getInputBuffer(st.codec, idx, &cap) orelse break;
                const n = AMediaExtractor_readSampleData(st.extractor, buf, cap);
                if (n < 0) {
                    if (AMediaCodec_queueInputBuffer(st.codec, idx, 0, 0, 0, FLAG_EOS) == AMEDIA_OK)
                        st.input_done = true;
                } else {
                    // Tag the sample with the extractor's current presentation
                    // time (clamped ≥ 0) for PTS accuracy — read BEFORE advance.
                    const sample_us = AMediaExtractor_getSampleTime(st.extractor);
                    const time_us: u64 = @intCast(@max(sample_us, 0));
                    if (AMediaCodec_queueInputBuffer(st.codec, idx, 0, @intCast(n), time_us, 0) != AMEDIA_OK) break;
                    _ = AMediaExtractor_advance(st.extractor);
                    did_work = true;
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
                    terminalCodecError(st, "output", out_idx);
                    break;
                }
                if (out_idx < 0) break; // no decoded output ready right now
                if (info.flags & FLAG_EOS != 0) {
                    lock(&st.mutex);
                    st.eof_seen = true;
                    st.mutex.unlock();
                }
                // Only a non-empty buffer produces a frame in the reader (the
                // EOS carrier is typically zero-size); render and count it as
                // pending only then, or `pending` would never drain and `eof()`
                // would never fire.
                const has_frame = info.size > 0;
                _ = AMediaCodec_releaseOutputBuffer(st.codec, @intCast(out_idx), has_frame);
                if (!has_frame) continue;
                lock(&st.mutex);
                st.pending += 1;
                st.mutex.unlock();
                did_work = true;
                // Common case: the frame is already acquirable — publish now.
                _ = publishOne(st);
            }

            // Failsafe: `pending` expects every released frame to become
            // acquirable, but the reader's BufferQueue MAY drop frames
            // internally (async/mailbox semantics under load) — a release with
            // no matching acquire, ever. After EOS that would pin `pending` > 0
            // and hold `eof()` false forever: the intro freezes on its last
            // frame and never hands off (observed on-device). If the stream is
            // done and ~100 ms of drain attempts surface nothing, the remaining
            // pending frames are gone — write them off so eof() can fire. A
            // genuinely in-flight frame arrives within a couple of iterations,
            // so the timeout only triggers on true drops.
            if (!did_work) {
                var stuck = false;
                {
                    lock(&st.mutex);
                    defer st.mutex.unlock();
                    stuck = st.eof_seen and st.pending > 0;
                }
                if (stuck) {
                    pending_dry += 1;
                    if (pending_dry >= 50) { // ~100 ms of consecutive dry drains
                        lock(&st.mutex);
                        st.pending = 0;
                        st.mutex.unlock();
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
    fn terminalCodecError(st: *State, side: []const u8, code: isize) void {
        lock(&st.mutex);
        defer st.mutex.unlock();
        if (st.eof_seen) return; // already ending (EOS or an earlier error)
        std.log.err("video: codec error {d} on {s} dequeue — ending the stream", .{ code, side });
        st.input_done = true;
        st.eof_seen = true;
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

    fn popDone(st: *State) void {
        lock(&st.mutex);
        defer st.mutex.unlock();
        st.ring_head = (st.ring_head + 1) % RING_SIZE;
        st.ring_count -= 1;
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
        yuv.yuv420ToRgba(slot.y, st.w, 1, slot.u, slot.v, cw, 1, st.w, st.h, out);
        const pts = slot.pts;
        popDone(st);
        return pts;
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
        popDone(st);
        return pts;
    }

    /// An output-format change is emitted once before the first frame. We
    /// deliberately do NOT re-read width/height here.
    ///
    /// `openFd` already sized `w`/`h` (and thus the ImageReader) from the
    /// track's display dimensions, and `Player.init` allocated its texture +
    /// `pixels` buffer from `width()`/`height()` before any frame is decoded.
    /// Mutating the dims now — to the aligned/coded size (e.g. 1080 → 1088) OR to
    /// a crop rect that differs from the open dims — would desync that buffer, so
    /// `decodeFrame`'s `out.len != w*h*4` guard would then reject every frame
    /// (black screen). Keep the allocation dimensions stable; crop-accurate
    /// display, if ever needed, belongs at draw time as a source-rect crop.
    fn refreshFormat(st: *State) void {
        _ = st;
    }

    /// The three crop-offset, stride-described plane slices of a YUV_420_888
    /// AImage, ready for either the CPU convert (`yuv.yuv420ToRgba`) or the GPU
    /// plane tighten (`planes.tightenPlane`). `u`/`v` may alias one interleaved
    /// buffer (NV12, `uv_pixel_stride == 2`) or be separate (I420, `== 1`).
    const ImagePlanes = struct {
        y: []const u8,
        u: []const u8,
        v: []const u8,
        y_row_stride: u32,
        y_pixel_stride: u32,
        uv_row_stride: u32,
        uv_pixel_stride: u32,
    };

    /// Read the Y/U/V plane pointers, strides, and crop rect from a
    /// YUV_420_888 AImage. Format-agnostic (planar / semi-planar / vendor
    /// Flexible all expose the same plane+stride model). Null on any API error
    /// or out-of-range crop. Shared by `convertImage` (CPU) + `fillPlanes` (GPU).
    fn readPlanes(img: *const Image) ?ImagePlanes {
        var num: i32 = 0;
        if (AImage_getNumberOfPlanes(img, &num) != AMEDIA_OK or num < 3) return null;

        var yd: ?[*]u8 = null;
        var ud: ?[*]u8 = null;
        var vd: ?[*]u8 = null;
        var yl: i32 = 0;
        var ul: i32 = 0;
        var vl: i32 = 0;
        if (AImage_getPlaneData(img, 0, &yd, &yl) != AMEDIA_OK) return null;
        if (AImage_getPlaneData(img, 1, &ud, &ul) != AMEDIA_OK) return null;
        if (AImage_getPlaneData(img, 2, &vd, &vl) != AMEDIA_OK) return null;
        const yp = yd orelse return null;
        const up = ud orelse return null;
        const vp = vd orelse return null;
        if (yl <= 0 or ul <= 0 or vl <= 0) return null;

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
        // 1080 → 1088). Offset each plane to the crop's top-left so we sample the
        // real frame, not alignment padding. Defaults to (0,0) when absent.
        var crop: CropRect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = AImage_getCropRect(img, &crop);
        const cl: u32 = @intCast(@max(crop.left, 0));
        const ct: u32 = @intCast(@max(crop.top, 0));
        const y_off: usize = @as(usize, ct) * ys + @as(usize, cl) * yx;
        const uv_off: usize = @as(usize, ct / 2) * us + @as(usize, cl / 2) * ux;
        const yl_u: usize = @intCast(yl);
        const ul_u: usize = @intCast(ul);
        const vl_u: usize = @intCast(vl);
        if (y_off >= yl_u or uv_off >= ul_u or uv_off >= vl_u) return null;

        return .{
            .y = yp[y_off..yl_u],
            .u = up[uv_off..ul_u],
            .v = vp[uv_off..vl_u],
            .y_row_stride = ys,
            .y_pixel_stride = yx,
            .uv_row_stride = us,
            .uv_pixel_stride = ux,
        };
    }

    /// Copy the AImage's Y/U/V planes into tight per-plane buffers (row-
    /// tightening Y; row-tightening AND de-interleaving U/V for the NV12
    /// `pixel_stride == 2` case). Runs on the WORKER thread — reads of the
    /// image's gralloc memory are slow (~10–30 ms/frame even vectorized) and
    /// must not touch the render thread.
    fn fillPlanes(st: *State, img: *Image, y_dst: []u8, u_dst: []u8, v_dst: []u8) bool {
        const p = readPlanes(img) orelse return false;
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
