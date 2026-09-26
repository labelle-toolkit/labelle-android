//! Force a stuck restored window to relayout (labelle-bgfx#127).
//!
//! On resume Android can hand a landscape-locked NativeActivity a restored
//! `ANativeWindow` that is 1x1 and never grows: the window manager already
//! holds the full-size frame but the resize never reaches the app's surface,
//! so no `APP_CMD_WINDOW_RESIZED` arrives and the compositor stretches a 1x1
//! buffer over the screen. Re-applying the window's own attributes
//! (`getWindow().setAttributes(getWindow().getAttributes())`) marks them
//! changed, so the next traversal relayouts and the resize then arrives
//! through the usual path. The JNI walk is `jni/window_relayout.c`.
const is_android = @import("root.zig").is_android;

extern "c" fn labelle_android_force_window_relayout(activity: ?*const anyopaque) c_int;

/// Request the relayout. MUST be called on the UI thread (it drives
/// `ViewRootImpl`), whose `JNIEnv` is already attached — the C side does not
/// attach. `activity` is the running `ANativeActivity*` (opaque). Returns true
/// when the request was issued, false on any JNI failure; comptime false off
/// Android. The caller decides WHEN (e.g. on focus gain, when the window it
/// sees is degenerate) — that check stays with the backend that owns the
/// window.
pub fn forceWindowRelayout(activity: ?*const anyopaque) bool {
    if (comptime !is_android) return false;
    const a = activity orelse return false;
    return labelle_android_force_window_relayout(a) != 0;
}

test "forceWindowRelayout is false off Android, whatever the pointer" {
    if (comptime is_android) return error.SkipZigTest;
    try @import("std").testing.expect(!forceWindowRelayout(null));
    try @import("std").testing.expect(!forceWindowRelayout(@ptrFromInt(0x1000)));
}
