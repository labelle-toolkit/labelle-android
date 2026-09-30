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
//!   1. Chains the activity's `onDestroy` callback: the glue's own
//!      `onDestroy` runs first (it waits for the backend's `android_main` to
//!      return), then the process ends with `_exit(0)`.
//!   2. `ANativeActivity_finish(activity)`: posts to the UI thread, which calls
//!      `Activity.finish()`. The usual lifecycle follows (PAUSE, TERM_WINDOW,
//!      STOP, DESTROY), so the backend tears down exactly as it does when the
//!      user backs out.
//!
//! ## Calling contract (why the `onDestroy` write is race-free)
//!
//! `finish` MUST be called from the android_native_app_glue **app thread**
//! (the thread running `android_main`), **while the activity has its window**
//! — i.e. after the glue delivered APP_CMD_INIT_WINDOW and before the caller
//! has processed APP_CMD_TERM_WINDOW. The bgfx shell's call site (after a
//! frame, only while it owns a live surface) satisfies this.
//!
//! Step 1 writes `callbacks->onDestroy`, which the UI thread reads when the
//! activity is destroyed. The contract orders that write before the read:
//!
//!   * `NativeActivity.onDestroy` (UI thread) destroys the surface BEFORE it
//!     calls the native `onDestroy` (`onSurfaceDestroyedNative`, then
//!     `unloadNativeCode`). Any window the activity has is therefore torn down
//!     first, on the same thread.
//!   * The glue's `onNativeWindowDestroyed` (`android_app_set_window(NULL)`)
//!     posts APP_CMD_TERM_WINDOW and blocks on the glue mutex/condvar until
//!     the app thread has processed it (`android_app_post_exec_cmd` sets
//!     `window = NULL` and broadcasts under that mutex).
//!   * The app thread only processes TERM_WINDOW after `finish` returned
//!     (program order), so the writes happen-before the unlock, which
//!     happens-before the UI thread leaving `onNativeWindowDestroyed`, which
//!     precedes its read of `callbacks->onDestroy`.
//!
//! So while the caller holds the window, no destruction can be concurrently
//! reading the slot. A caller on another thread, or one without a window,
//! gets no such ordering: don't. (A UI-thread install at `onCreate` would not
//! need the contract, but `ANativeActivity_onCreate` belongs to the backend's
//! glue, not to this package.)
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
//! Only the first successful call in a process does anything; later calls
//! return `false` without touching the activity.
const is_android = @import("root.zig").is_android;

/// `jni/activity_finish.c`. Declared unconditionally (extern decls are only
/// linked when referenced); only the Android branch references it.
extern "c" fn labelle_android_finish_activity(activity: *anyopaque) c_int;

/// Process-wide once-guard. Only ever touched through `request`'s atomics.
var requested: bool = false;

/// Finish `activity` and end the process once it has been destroyed. See the
/// file doc for the calling contract (glue app thread, window held). Returns
/// true when this call requested the finish; false for a null activity, a
/// repeated call, or off Android (where it is a no-op).
pub fn finish(activity: ?*anyopaque) bool {
    if (comptime !is_android) return false;
    return request(&requested, activity, jniFinish);
}

fn jniFinish(activity: *anyopaque) bool {
    return labelle_android_finish_activity(activity) != 0;
}

/// The once-guard, split from the JNI half so a HOST test can drive it.
///
///   * null `activity` → false, guard untouched (a later real call still runs).
///   * guard already taken → false, `doFinish` not called.
///   * otherwise take the guard with one cmpxchg, then call `doFinish`. If it
///     reports that nothing was done (no callbacks table), release the guard
///     so a later call can still finish.
fn request(flag: *bool, activity: ?*anyopaque, comptime doFinish: fn (*anyopaque) bool) bool {
    const a = activity orelse return false;
    if (@cmpxchgStrong(bool, flag, false, true, .acq_rel, .acquire) != null) return false;
    if (doFinish(a)) return true;
    @atomicStore(bool, flag, false, .release);
    return false;
}

test "finish is a no-op off Android" {
    const testing = @import("std").testing;
    if (comptime is_android) return error.SkipZigTest;
    var dummy: u8 = 0;
    try testing.expect(!finish(null));
    try testing.expect(!finish(@ptrCast(&dummy)));
}

const TestFinish = struct {
    var calls: u32 = 0;
    var result: bool = true;
    fn call(_: *anyopaque) bool {
        calls += 1;
        return result;
    }
};

test "request: first real call finishes once; repeats and null never reach the JNI half" {
    const testing = @import("std").testing;
    var flag = false;
    var dummy: u8 = 0;
    TestFinish.calls = 0;
    TestFinish.result = true;

    try testing.expect(!request(&flag, null, TestFinish.call));
    try testing.expectEqual(@as(u32, 0), TestFinish.calls);
    try testing.expect(!flag); // null does not take the guard

    try testing.expect(request(&flag, @ptrCast(&dummy), TestFinish.call));
    try testing.expectEqual(@as(u32, 1), TestFinish.calls);
    try testing.expect(flag);

    try testing.expect(!request(&flag, @ptrCast(&dummy), TestFinish.call));
    try testing.expectEqual(@as(u32, 1), TestFinish.calls); // not called again
}

test "request: a finish that did nothing releases the guard for a later call" {
    const testing = @import("std").testing;
    var flag = false;
    var dummy: u8 = 0;
    TestFinish.calls = 0;
    TestFinish.result = false;

    try testing.expect(!request(&flag, @ptrCast(&dummy), TestFinish.call));
    try testing.expectEqual(@as(u32, 1), TestFinish.calls);
    try testing.expect(!flag);

    TestFinish.result = true;
    try testing.expect(request(&flag, @ptrCast(&dummy), TestFinish.call));
    try testing.expectEqual(@as(u32, 2), TestFinish.calls);
    try testing.expect(flag);
}
