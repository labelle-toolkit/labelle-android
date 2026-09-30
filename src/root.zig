//! labelle-android — the ONE module root (`labelle_android`).
//!
//! Shared Android platform services the labelle backends (bgfx, sokol) used
//! to carry as per-backend copies (labelle-bgfx#149 phase 1):
//!
//!   * `launch_intent` / `intent_env` — launch-intent `LABELLE_*` extras →
//!     process environment (labelle-bgfx#139, labelle-sokol#25).
//!   * `debuggable` — is the RUNNING apk `android:debuggable`?
//!     (labelle-assembler#737; gates the knob file and the screenshot extras.)
//!   * `relayout` — force a stuck 1x1 restored window to relayout
//!     (labelle-bgfx#127).
//!   * `aaudio` — the AAudio output device (labelle-bgfx#306): the
//!     `labelle-audio` `DeviceSink` a backend's mixer drives on Android.
//!   * `immersive` — hide the status and navigation bars (immersive-sticky),
//!     moved from labelle-engine `src/android.zig` (labelle-engine#902).
//!   * `video` — the MediaCodec H.264 decoder + audio-track decode
//!     (`VideoDecoder`, `decodeTrack`) and the pure `yuv`/`planes` helpers the
//!     desktop decoders share (FP#549; links `libmediandk`).
//!   * `renderer` — resolve the renderer at launch and export
//!     `LABELLE_BGFX_RENDERER` (labelle-android#27, labelle-bgfx#172);
//!     `crash_guard` is its D11 Vulkan crash guard (labelle-android#28).
//!   * `activity` — finish the running activity when the game quits, then
//!     end the process (moca-tecnologia/flying-platform-labelle#979).
//!
//! Every file is reached from here by relative import inside this module.
//! Consumers `@import("labelle_android")` and pass the running
//! `ANativeActivity*` as an opaque pointer; the JNI walks live in
//! `src/jni/*.c` and read `->vm` / `->clazz` through the NDK's own header.
const builtin = @import("builtin");

/// True on Android (arm64/x86_64 `.android`, arm/x86 `.androideabi`).
pub const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

/// The only Android ABIs the toolkit builds, packages and ships (labelle CLI
/// `AbiArch`, the bgfx/sokol `-Dandroid_arch=arm64|x86_64` hooks): 32-bit
/// `armeabi-v7a` / `x86` are not supported. `aaudio`'s lock-free counters
/// are 64-bit atomics, which 32-bit ARM cannot lower, so fail here with a
/// clear message instead of an atomics error deep in `aaudio.zig`
/// (labelle-android#10).
pub const unsupported_abi_message =
    "labelle-android supports 64-bit Android only (arm64-v8a = aarch64-linux-android, " ++
    "x86_64 = x86_64-linux-android); 32-bit armeabi-v7a / x86 are not supported";

comptime {
    if (is_android and builtin.target.ptrBitWidth() != 64) @compileError(unsupported_abi_message);
}

pub const intent_env = @import("intent_env.zig");
pub const launch_intent = @import("launch_intent.zig");
pub const debuggable = @import("debuggable.zig");
pub const relayout = @import("relayout.zig");
pub const aaudio = @import("aaudio.zig");
pub const video = @import("video.zig");
pub const immersive = @import("immersive.zig");
pub const renderer = @import("renderer.zig");
pub const crash_guard = @import("crash_guard.zig");
pub const activity = @import("activity.zig");

test {
    // Explicit refs: a lazily-referenced file's tests are otherwise never
    // discovered (the toolkit's "lazy re-export hides tests" lesson).
    _ = intent_env;
    _ = launch_intent;
    _ = debuggable;
    _ = relayout;
    _ = aaudio;
    _ = video;
    _ = immersive;
    _ = renderer;
    _ = crash_guard;
    _ = activity;
}
