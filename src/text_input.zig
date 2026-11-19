//! The on-screen keyboard (moca-tecnologia/flying-platform-labelle, Trello
//! Lbx7cvMN: the tablet's save-name field could not be typed into).
//!
//! Android 14+ only shows the keyboard for a view that is a text editor, and
//! NativeActivity's content view is not one: `ANativeActivity_showSoftInput`
//! is ignored ("view is not served"). The packager launches
//! `labelle.android.LabelleActivity` instead (`java/`), which adds a hidden
//! text-editor view. `setVisible` shows or hides the keyboard through it, and
//! what the keyboard types arrives through `poll` as code points and
//! backspaces, since a keyboard commits text, not key events. Key events (a
//! hardware keyboard, the keyboard's Done sent as Enter) keep arriving on the
//! native input queue as before. The JNI side is `jni/text_input.c`.
//!
//! An APK packaged before LabelleActivity has the stock NativeActivity:
//! `setVisible` then returns false, and the caller falls back to
//! `ANativeActivity_showSoftInput` (enough before Android 14).
const std = @import("std");
const is_android = @import("root.zig").is_android;

extern "c" fn labelle_android_set_text_input(activity: ?*const anyopaque, show: c_int) c_int;
extern "c" fn labelle_android_text_input_poll(out: [*]i32, max: c_int) c_int;

/// A `poll` entry: one character erased before the cursor.
pub const backspace: i32 = -1;

/// Show (true) or hide the keyboard. Any thread (the C side attaches to the
/// VM for the call). `activity` is the running `ANativeActivity*`. False when
/// it is not a LabelleActivity, or off Android: nothing was asked.
pub fn setVisible(activity: ?*const anyopaque, show: bool) bool {
    if (comptime !is_android) return false;
    const a = activity orelse return false;
    return labelle_android_set_text_input(a, @intFromBool(show)) != 0;
}

/// What the keyboard typed since the last call, oldest first, into `buf`:
/// Unicode code points, and `backspace` for each character erased.
pub fn poll(buf: []i32) []const i32 {
    if (comptime !is_android) return buf[0..0];
    const n = labelle_android_text_input_poll(buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
    return buf[0..@intCast(n)];
}

test "off Android the keyboard is never shown and nothing is typed" {
    if (comptime is_android) return error.SkipZigTest;
    try std.testing.expect(!setVisible(null, true));
    var buf: [4]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), poll(&buf).len);
}
