//! Finish the running activity when the game quits
//! (moca-tecnologia/flying-platform-labelle#979).
//!
//! `game.quit()` only flips the engine's `running` flag; the backend's frame
//! loop forwards that to `window.requestQuit()`. On desktop that closes the
//! window and the process ends. On Android a NativeActivity is not closed by
//! its native code returning: the backend's shell loop runs until the
//! framework destroys the activity. `finish` asks for that.
//!
//! ## What `finish` does
//!
//!   1. `ANativeActivity_finish(activity)`. The NDK documents it as callable
//!      from any thread: it posts to the UI thread, which calls
//!      `Activity.finish()`. The usual lifecycle follows (PAUSE, TERM_WINDOW,
//!      STOP, DESTROY), so the backend tears down exactly as it does when the
//!      user backs out.
//!   2. It chains the activity's `onDestroy` callback: the glue's own
//!      `onDestroy` runs first (it waits for the backend's `android_main` to
//!      return), then the process ends with `_exit(0)`.
//!
//! ## Why the process ends
//!
//! The engine is a process global that outlives an activity instance
//! (labelle-bgfx#143: a relaunch into a cached process restores the running
//! game rather than booting a new one). After a quit its `running` flag stays
//! false, so the next launch would restore a quit game and finish at once: the
//! app would look like it cannot start. Ending the process makes the next
//! launch a cold start, which is what quitting means on desktop too. sokol's
//! Android backend does the same (`exit(0)` at the end of its `onDestroy`).
//!
//! `_exit`, not `exit`: the engine's worker threads (asset loading, audio)
//! are still running, and `exit` would run C++ static destructors under them.
//! Nothing needs flushing — logging goes straight to logcat.
//!
//! ## Where to call it
//!
//! From the backend's shell, once it sees the game's quit request, with the
//! running `ANativeActivity*` (opaque here). Any thread. Only the first call in
//! a process does anything; later calls return `false`.
const is_android = @import("root.zig").is_android;

/// `jni/activity_finish.c`. Declared unconditionally (extern decls are only
/// linked when referenced); only the Android branch references it.
extern "c" fn labelle_android_finish_activity(activity: ?*anyopaque) c_int;

/// Finish `activity` and end the process once it has been destroyed (see the
/// file doc). Returns true when this call requested the finish; false for a
/// null activity, a repeated call, or off Android (where it is a no-op).
pub fn finish(activity: ?*anyopaque) bool {
    if (comptime !is_android) return false;
    return labelle_android_finish_activity(activity) != 0;
}

test "finish is a no-op off Android" {
    const testing = @import("std").testing;
    if (comptime is_android) return error.SkipZigTest;
    var dummy: u8 = 0;
    try testing.expect(!finish(null));
    try testing.expect(!finish(@ptrCast(&dummy)));
}
