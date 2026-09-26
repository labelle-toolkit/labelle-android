//! Is the RUNNING apk marked `android:debuggable`? (labelle-assembler#737)
//!
//! This gates two verification channels:
//!   * the `labelle_env` knob file in the app's own data dir. `adb shell
//!     run-as <package>` — the only way to CREATE it — is granted only for a
//!     debuggable APK, but `run-as` says nothing about the runtime READ:
//!     install a debuggable build, drop a knob file, then update to a release
//!     build, and the file is still there and would still be honoured.
//!   * the `LABELLE_SCREENSHOT_*` launch-intent extras (`intent_env.zig`): the
//!     NativeActivity is exported, so any app could otherwise make a release
//!     build write a file of its choosing.
//!
//! Asking the process about its own `ApplicationInfo.FLAG_DEBUGGABLE` closes
//! both. The JNI walk is `jni/debuggable.c`.
const is_android = @import("root.zig").is_android;

/// Declared unconditionally (extern decls are only linked when referenced) so
/// the non-Android path below folds away without a comptime block around it.
extern "c" fn labelle_android_app_is_debuggable(activity: ?*const anyopaque) c_int;

/// Cache: the flag cannot change for the life of the process, and every
/// activity of the process is the same package, so the first answer holds
/// for all of them. `null` = not asked yet.
var cached: ?bool = null;

/// Fails CLOSED: no activity, no VM, or any JNI failure answers `false`. A
/// verification aid that cannot prove it is allowed must stay off. `activity`
/// is the running `ANativeActivity*` (opaque; the C side reads `->vm` /
/// `->clazz`). Callable from any thread: the JNI half attaches the calling
/// thread if it is not already, and detaches only what it attached.
pub fn isDebuggable(activity: ?*const anyopaque) bool {
    // `comptime` so the extern is not even referenced off Android, where the C
    // TU compiles to an empty object and the symbol does not exist.
    if (comptime !is_android) return false;
    if (cached) |c| return c;
    const a = activity orelse return false; // asked too early: not cached
    const r = labelle_android_app_is_debuggable(a) != 0;
    cached = r;
    return r;
}

test "isDebuggable is false off Android, whatever the pointer" {
    if (comptime is_android) return error.SkipZigTest;
    try @import("std").testing.expect(!isDebuggable(null));
    try @import("std").testing.expect(!isDebuggable(@ptrFromInt(0x1000)));
    try @import("std").testing.expect(cached == null);
}
