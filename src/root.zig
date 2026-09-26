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
//!
//! Every file is reached from here by relative import inside this module.
//! Consumers `@import("labelle_android")` and pass the running
//! `ANativeActivity*` as an opaque pointer; the JNI walks live in
//! `src/jni/*.c` and read `->vm` / `->clazz` through the NDK's own header.
const builtin = @import("builtin");

/// True on Android (arm64/x86_64 `.android`, arm/x86 `.androideabi`).
pub const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

pub const intent_env = @import("intent_env.zig");
pub const launch_intent = @import("launch_intent.zig");
pub const debuggable = @import("debuggable.zig");
pub const relayout = @import("relayout.zig");

test {
    // Explicit refs: a lazily-referenced file's tests are otherwise never
    // discovered (the toolkit's "lazy re-export hides tests" lesson).
    _ = intent_env;
    _ = launch_intent;
    _ = debuggable;
    _ = relayout;
}
