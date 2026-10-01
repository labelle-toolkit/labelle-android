//! Open a bundled APK asset as a file descriptor (labelle-bgfx#168).
//!
//! The fd-based decoders here (`video.decodeTrack`, `video.VideoDecoder`)
//! read an asset in place inside the APK: `AAsset_openFileDescriptor64` gives
//! a dup'd descriptor of the APK plus the asset's byte range. `openFd` is that
//! route, so a backend never declares the `AAsset*` externs itself or reads
//! the `ANativeActivity` layout. The asset manager is read by field name in
//! `jni/asset_fd.c`, through the NDK's own header.
//!
//! The asset must be STORED (uncompressed) in the APK: the NDK refuses a
//! descriptor for a compressed entry. The android provider stores assets that
//! way.
//!
//! Callable from any thread: the NDK's `AAssetManager` is thread-safe, and the
//! `AAsset` is opened and closed inside the one call.
const std = @import("std");
const is_android = @import("root.zig").is_android;

/// `jni/asset_fd.c`. Declared unconditionally (extern decls are only linked
/// when referenced); only the Android branch references it. Returns the fd,
/// or -1 when the activity has no asset manager, the asset is missing, or it
/// is compressed.
extern "c" fn labelle_android_open_asset_fd(activity: *anyopaque, name: [*:0]const u8, start: *i64, len: *i64) c_int;

/// Longest asset name `openFd` accepts, in bytes (the NUL is added here).
pub const max_name_len = 255;

/// An asset's bytes inside the APK: read `len` bytes from `start` on `fd`.
pub const AssetFd = struct {
    fd: c_int,
    start: i64,
    len: i64,

    /// The caller owns the descriptor. `video.decodeTrack` reads it
    /// synchronously and leaves it open, so close it after the decode.
    pub fn close(self: AssetFd) void {
        _ = std.c.close(self.fd);
    }
};

/// Open the asset `name` (relative to the APK's `assets/`, e.g.
/// `"music/theme.mp3"`) of the running `activity` (the `ANativeActivity*`,
/// opaque). Null for a null activity, an empty or over-long name, a missing
/// or compressed asset, and off Android.
pub fn openFd(activity: ?*anyopaque, name: []const u8) ?AssetFd {
    if (comptime !is_android) return null;
    return open(activity, name, labelle_android_open_asset_fd);
}

const OpenFn = fn (*anyopaque, [*:0]const u8, *i64, *i64) callconv(.c) c_int;

/// The name checks and NUL-termination, split from the JNI half so a HOST
/// test can drive them with a fake `doOpen`.
fn open(activity: ?*anyopaque, name: []const u8, comptime doOpen: OpenFn) ?AssetFd {
    const a = activity orelse return null;
    if (name.len == 0 or name.len > max_name_len) return null;
    var buf: [max_name_len + 1]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    var start: i64 = 0;
    var len: i64 = 0;
    const fd = doOpen(a, buf[0..name.len :0].ptr, &start, &len);
    if (fd < 0) return null;
    return .{ .fd = fd, .start = start, .len = len };
}

test "openFd analyses on every target" {
    // Takes its address so the Android compile-check (`-Dtarget=aarch64-linux-android`)
    // type-checks the JNI branch, which no runtime test there reaches.
    _ = &openFd;
}

test "openFd is null off Android" {
    if (comptime is_android) return error.SkipZigTest;
    var dummy: u8 = 0;
    try std.testing.expect(openFd(null, "music/theme.mp3") == null);
    try std.testing.expect(openFd(@ptrCast(&dummy), "music/theme.mp3") == null);
}

const FakeOpen = struct {
    var calls: u32 = 0;
    var last_name: [max_name_len + 1]u8 = undefined;
    var fd: c_int = 7;

    fn call(_: *anyopaque, name: [*:0]const u8, start: *i64, len: *i64) callconv(.c) c_int {
        calls += 1;
        const n = std.mem.span(name);
        @memcpy(last_name[0..n.len], n);
        last_name[n.len] = 0;
        start.* = 1024;
        len.* = 4096;
        return fd;
    }
};

test "open: passes the name NUL-terminated and returns the fd and range" {
    var dummy: u8 = 0;
    FakeOpen.calls = 0;
    FakeOpen.fd = 7;
    const got = open(@ptrCast(&dummy), "music/theme.mp3", FakeOpen.call).?;
    try std.testing.expectEqual(@as(u32, 1), FakeOpen.calls);
    try std.testing.expectEqualStrings("music/theme.mp3", std.mem.sliceTo(&FakeOpen.last_name, 0));
    try std.testing.expectEqual(@as(c_int, 7), got.fd);
    try std.testing.expectEqual(@as(i64, 1024), got.start);
    try std.testing.expectEqual(@as(i64, 4096), got.len);
}

test "open: a failed open is null" {
    var dummy: u8 = 0;
    FakeOpen.fd = -1;
    try std.testing.expect(open(@ptrCast(&dummy), "music/missing.mp3", FakeOpen.call) == null);
}

test "open: null activity, empty and over-long names never reach the JNI half" {
    var dummy: u8 = 0;
    FakeOpen.calls = 0;
    FakeOpen.fd = 7;
    try std.testing.expect(open(null, "music/theme.mp3", FakeOpen.call) == null);
    try std.testing.expect(open(@ptrCast(&dummy), "", FakeOpen.call) == null);
    try std.testing.expect(open(@ptrCast(&dummy), "m" ** (max_name_len + 1), FakeOpen.call) == null);
    try std.testing.expectEqual(@as(u32, 0), FakeOpen.calls);
    // The longest accepted name still fits with its NUL.
    try std.testing.expect(open(@ptrCast(&dummy), "m" ** max_name_len, FakeOpen.call) != null);
}
