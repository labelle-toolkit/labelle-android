//! `labelle_android.video` — MediaCodec video + audio-track decode
//! (labelle-bgfx#149 phase 1d; Flying-Platform/flying-platform-labelle#549).
//!
//! Four files moved from labelle-bgfx's `src/video/`:
//!
//!   * `video/decoder.zig`     — `VideoDecoder`: AMediaExtractor + AMediaCodec
//!                                → AImageReader (YUV_420_888) on a worker thread,
//!                                a ring of tightened Y/U/V planes for the
//!                                backend's GPU-YUV upload. Android-only; an
//!                                `Unsupported` stub elsewhere.
//!   * `video/audio_track.zig` — `decodeTrack`: the mp4's audio track → 48 kHz
//!                                stereo i16 `Pcm` for the backend's mixer.
//!                                Android-only; `error.Unsupported` elsewhere.
//!   * `video/yuv.zig`         — CPU YUV 4:2:0 → RGBA8 (BT.601). Pure Zig,
//!                                host-tested; the desktop ffmpeg decoder uses
//!                                it too.
//!   * `video/planes.zig`      — row de-pad / NV12 de-interleave for the GPU
//!                                plane-upload path. Pure Zig, host-tested; the
//!                                decoder's worker thread AND the desktop
//!                                decoder/player use it.
//!
//! `yuv`/`planes` live here (not in each backend) because the decoder's judder
//! fix tightens planes on ITS worker thread, so the helpers are part of the
//! service; keeping bgfx's desktop copies would be the duplication #149 exists
//! to remove. Consumers link `libmediandk` through this module (`build.zig`).
const decoder = @import("video/decoder.zig");
const audio_track = @import("video/audio_track.zig");

pub const yuv = @import("video/yuv.zig");
pub const planes = @import("video/planes.zig");

/// The MediaCodec H.264 decoder (`openFd` / `deinit` / frame ring). Real on
/// Android, `Unsupported` stub elsewhere.
pub const VideoDecoder = decoder.VideoDecoder;
/// `VideoDecoder`'s error set.
pub const Error = decoder.Error;

/// Decoded 48 kHz stereo i16 PCM (`samples` interleaved, caller frees via
/// `deinit`).
pub const Pcm = audio_track.Pcm;
/// `decodeTrack`'s error set.
pub const AudioError = audio_track.Error;
/// Decode the file's audio track (`fd`, `offset`, `length`) to 48 kHz stereo
/// i16. Caller owns the samples.
pub const decodeTrack = audio_track.decodeTrack;

test {
    // Explicit refs: `yuv`/`planes` carry the host tests; the two decoder
    // files carry none today but are referenced so a future test is collected
    // (the toolkit's "lazy re-export hides tests" lesson).
    _ = yuv;
    _ = planes;
    _ = decoder;
    _ = audio_track;
}

test "the decoder entry points are analyzed (host: stubs; Android compile-check: the MediaCodec externs)" {
    // The decoders are comptime-gated, so nothing in the module graph
    // references their bodies on its own and `zig build test
    // -Dtarget=aarch64-linux-android` would emit objects without ever
    // resolving one `AMediaCodec_*` extern. Taking the functions' addresses
    // (the `std.testing.refAllDecls` idiom) forces their analysis for whichever
    // target is being compiled — the `Unsupported` stubs here on the host,
    // the real AMediaExtractor / AMediaCodec / AImageReader bindings on Android.
    _ = &VideoDecoder.openFd;
    _ = &VideoDecoder.width;
    _ = &VideoDecoder.height;
    _ = &VideoDecoder.decodeFrame;
    _ = &VideoDecoder.decodeFramePlanes;
    _ = &VideoDecoder.deinit;
    _ = &decodeTrack;
    var pcm: Pcm = .{ .samples = &.{}, .frames = 0 };
    pcm.deinit(std.testing.allocator);
}

const std = @import("std");
