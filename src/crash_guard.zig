//! Vulkan crash guard (labelle-android#28; labelle-bgfx#172 D11).
//!
//! If the game crashes (or is killed) while starting on Vulkan, the next
//! launch starts on GLES, so a bad Vulkan driver cannot brick the game.
//!
//! Two marker files in the app's internal data dir
//! (`ANativeActivity.internalDataPath`), each containing
//! `<versionCode> <setting>`:
//!
//!   * `.labelle_vulkan_start`: written by `beginVulkanStart`, just before a
//!     Vulkan start (the resolved renderer is `vulkan`).
//!   * `.labelle_vulkan_disabled`: written when a launch finds
//!     `.labelle_vulkan_start` still there, i.e. the previous Vulkan start
//!     never reached "stable".
//!
//! Rules:
//!   * Stable: a detached thread deletes `.labelle_vulkan_start` once the
//!     process has lived `stable_after_ns` (10 s) after `beginVulkanStart`.
//!     No labelle-bgfx signal (the generic-only rule).
//!   * Disabled: while `.labelle_vulkan_disabled` exists and its stamp
//!     matches the current `versionCode` and setting, `vulkanDisabled`
//!     returns true and `renderer.decide` picks `gles` (source
//!     `crash-guard`).
//!   * Reset: a stamp that does NOT match (a new app version or a changed
//!     `renderer` setting) deletes both files, so Vulkan is tried again. An
//!     unreadable stamp resets too.
//!   * Intent override: `renderer.decide` asks the debuggable-only intent
//!     extra BEFORE the guard, so it wins (see the test at the bottom).
//!
//! The PURE half (`checkAtLaunch`, `markStart`, `settle`) takes an injected
//! filesystem and clock and is host-tested; the Android glue below it uses
//! libc and the JNI helpers in `jni/renderer_query.c`.
const std = @import("std");
const is_android = @import("root.zig").is_android;

pub const start_file = ".labelle_vulkan_start";
pub const disabled_file = ".labelle_vulkan_disabled";
/// How long the process must live after `beginVulkanStart` before the start
/// counts as stable.
pub const stable_after_ns: u64 = 10 * std.time.ns_per_s;

/// What both marker files contain: `<versionCode> <setting>`.
pub const Stamp = struct {
    version_code: i64,
    /// The effective provider setting (`gles`, `vulkan` or `auto`).
    setting: []const u8,

    pub fn eql(a: Stamp, b: Stamp) bool {
        return a.version_code == b.version_code and std.mem.eql(u8, a.setting, b.setting);
    }

    /// `<versionCode> <setting>`, or null if it does not fit `buf`.
    pub fn format(self: Stamp, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ self.version_code, self.setting }) catch null;
    }

    /// Parse `<versionCode> <setting>` (trailing whitespace allowed). Null
    /// for anything else; `setting` borrows from `bytes`.
    pub fn parse(bytes: []const u8) ?Stamp {
        const trimmed = std.mem.trimEnd(u8, bytes, " \t\r\n");
        const sp = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;
        const version_code = std.fmt.parseInt(i64, trimmed[0..sp], 10) catch return null;
        const setting = trimmed[sp + 1 ..];
        if (setting.len == 0 or std.mem.indexOfAny(u8, setting, " \t\r\n") != null) return null;
        return .{ .version_code = version_code, .setting = setting };
    }
};

/// Room for a stamp: a 20-digit i64, a space and the longest setting.
const stamp_cap = 64;

/// The launch-time check. `fs` provides:
///   * `read(name: []const u8, buf: []u8) ?[]const u8` (null = absent or
///     unreadable)
///   * `write(name: []const u8, bytes: []const u8) bool`
///   * `delete(name: []const u8) void` (absent is fine)
///
/// Returns true when this launch must not use Vulkan. Side effects, in order:
///   1. `.labelle_vulkan_disabled` present: matching stamp → true (and a
///      leftover start mark is dropped); otherwise reset (both files go).
///   2. `.labelle_vulkan_start` present (the previous Vulkan start did not
///      complete): matching stamp → write `.labelle_vulkan_disabled`, drop the
///      start mark, true; otherwise reset.
///   3. Neither → false.
pub fn checkAtLaunch(fs: anytype, current: Stamp) bool {
    var buf: [stamp_cap]u8 = undefined;
    if (fs.read(disabled_file, &buf)) |bytes| {
        if (Stamp.parse(bytes)) |s| if (s.eql(current)) {
            fs.delete(start_file);
            return true;
        };
        reset(fs);
        return false;
    }
    if (fs.read(start_file, &buf)) |bytes| {
        if (Stamp.parse(bytes)) |s| if (s.eql(current)) {
            var out: [stamp_cap]u8 = undefined;
            if (current.format(&out)) |text| {
                if (!fs.write(disabled_file, text)) {
                    std.log.warn("android: crash guard: could not write {s}", .{disabled_file});
                }
            }
            fs.delete(start_file);
            // Disabled for THIS launch even if the write failed: the crash
            // just happened, so do not retry Vulkan right away.
            return true;
        };
        reset(fs);
        return false;
    }
    return false;
}

fn reset(fs: anytype) void {
    fs.delete(start_file);
    fs.delete(disabled_file);
}

/// Write `.labelle_vulkan_start` (called just before a Vulkan start).
pub fn markStart(fs: anytype, current: Stamp) bool {
    var out: [stamp_cap]u8 = undefined;
    const text = current.format(&out) orelse return false;
    return fs.write(start_file, text);
}

/// The stable timer: sleep `stable_after_ns`, then delete the start mark,
/// unless a newer `beginVulkanStart` (another activity launch in the same
/// process) has taken over (`generation` moved past `mine`); its own timer
/// will clear the mark. `clock.sleep(ns) !void` — a fake returns an error to
/// model the process dying mid-sleep.
pub fn settle(fs: anytype, clock: anytype, generation: *const std.atomic.Value(u32), mine: u32) void {
    clock.sleep(stable_after_ns) catch return;
    if (generation.load(.acquire) != mine) return;
    fs.delete(start_file);
}

// ── Android glue ────────────────────────────────────────────────────────

// `jni/renderer_query.c`.
extern "c" fn labelle_android_internal_data_path(activity: ?*const anyopaque) ?[*:0]const u8;
extern "c" fn labelle_android_version_code(activity: ?*const anyopaque, out: *c_longlong) c_int;
// libc.
const FILE = opaque {};
extern "c" fn fopen(name: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn unlink(name: [*:0]const u8) c_int;
extern "c" fn sleep(seconds: c_uint) c_uint;

/// Marker files under a copied `internalDataPath` (a value type, so the
/// detached stable thread owns its own copy).
const LibcFs = struct {
    dir_buf: [512]u8 = undefined,
    dir_len: usize = 0,

    fn init(dir: []const u8) ?LibcFs {
        var self: LibcFs = .{};
        if (dir.len == 0 or dir.len > self.dir_buf.len) return null;
        @memcpy(self.dir_buf[0..dir.len], dir);
        self.dir_len = dir.len;
        return self;
    }

    fn full(self: *const LibcFs, name: []const u8, buf: []u8) ?[:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ self.dir_buf[0..self.dir_len], name }) catch null;
    }

    pub fn read(self: *const LibcFs, name: []const u8, buf: []u8) ?[]const u8 {
        var p: [600]u8 = undefined;
        const f = fopen((self.full(name, &p) orelse return null).ptr, "rb") orelse return null;
        defer _ = fclose(f);
        const n = fread(buf.ptr, 1, buf.len, f);
        return buf[0..n];
    }
    pub fn write(self: *const LibcFs, name: []const u8, bytes: []const u8) bool {
        var p: [600]u8 = undefined;
        const f = fopen((self.full(name, &p) orelse return false).ptr, "wb") orelse return false;
        const ok = fwrite(bytes.ptr, 1, bytes.len, f) == bytes.len;
        return fclose(f) == 0 and ok;
    }
    pub fn delete(self: *const LibcFs, name: []const u8) void {
        var p: [600]u8 = undefined;
        _ = unlink((self.full(name, &p) orelse return).ptr);
    }
};

const LibcClock = struct {
    pub fn sleep(_: LibcClock, ns: u64) error{}!void {
        var left: c_uint = @intCast(std.math.divCeil(u64, ns, std.time.ns_per_s) catch unreachable);
        // `sleep` returns the unslept seconds when a signal interrupts it.
        while (left > 0) left = sleep_c(left);
    }
};
const sleep_c = sleep;

/// Bumped by every `beginVulkanStart`; each stable thread only clears the
/// mark if it is still the latest.
var start_generation: std.atomic.Value(u32) = .init(0);

/// Process-wide `versionCode` cache: it cannot change for the life of the
/// process (an update kills it). -1 = not asked yet.
var version_cache: std.atomic.Value(i64) = .init(-1);

fn versionCode(activity: *const anyopaque) i64 {
    const cached = version_cache.load(.acquire);
    if (cached >= 0) return cached;
    var v: c_longlong = 0;
    const got: i64 = if (labelle_android_version_code(activity, &v) == 0 and v >= 0) v else 0;
    // First store wins; only the winner logs, so the failure is logged once.
    if (version_cache.cmpxchgStrong(-1, got, .acq_rel, .acquire)) |theirs| return theirs;
    if (got == 0) std.log.warn("android: crash guard: could not read the app's versionCode; using 0", .{});
    return got;
}

fn libcFs(activity: *const anyopaque) ?LibcFs {
    const dir = labelle_android_internal_data_path(activity) orelse {
        std.log.warn("android: crash guard: no internalDataPath; guard off", .{});
        return null;
    };
    return LibcFs.init(std.mem.span(dir)) orelse {
        std.log.warn("android: crash guard: internalDataPath unusable; guard off", .{});
        return null;
    };
}

/// True when a previous launch crashed during a Vulkan start (and the app
/// version and `setting` are unchanged since), so this launch must use GLES.
/// Also applies the reset rule. `activity` is the running `ANativeActivity*`
/// (opaque); `setting` the effective provider setting (`gles`|`vulkan`|
/// `auto`). Off Android, or with no activity or data dir: false.
pub fn vulkanDisabled(activity: ?*const anyopaque, setting: []const u8) bool {
    if (comptime !is_android) return false;
    const a = activity orelse return false;
    var fs = libcFs(a) orelse return false;
    return checkAtLaunch(&fs, .{ .version_code = versionCode(a), .setting = setting });
}

/// Called by `renderer.resolve` once Vulkan is chosen, before bgfx starts:
/// write `.labelle_vulkan_start` and start the detached 10 s stable timer.
pub fn beginVulkanStart(activity: ?*const anyopaque, setting: []const u8) void {
    if (comptime !is_android) return;
    const a = activity orelse return;
    const fs = libcFs(a) orelse return;
    const mine = start_generation.fetchAdd(1, .acq_rel) + 1;
    if (!markStart(&fs, .{ .version_code = versionCode(a), .setting = setting })) {
        std.log.warn("android: crash guard: could not write {s}", .{start_file});
        return;
    }
    const t = std.Thread.spawn(.{}, stableThread, .{ fs, mine }) catch |err| {
        // No timer: the mark stays and the NEXT launch uses GLES. Safer to
        // drop the mark now and run unguarded than to disable Vulkan for a
        // start that may well succeed.
        std.log.warn("android: crash guard: could not start the stable timer ({s}); guard off for this launch", .{@errorName(err)});
        fs.delete(start_file);
        return;
    };
    t.detach();
}

fn stableThread(fs: LibcFs, mine: u32) void {
    settle(&fs, LibcClock{}, &start_generation, mine);
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// In-memory marker files, persisting across "launches" like internal
/// storage does.
const FakeFs = struct {
    start: ?[]const u8 = null,
    disabled: ?[]const u8 = null,
    start_buf: [stamp_cap]u8 = undefined,
    disabled_buf: [stamp_cap]u8 = undefined,
    fail_writes: bool = false,

    fn slot(self: *FakeFs, name: []const u8) struct { *?[]const u8, []u8 } {
        if (std.mem.eql(u8, name, start_file)) return .{ &self.start, &self.start_buf };
        if (std.mem.eql(u8, name, disabled_file)) return .{ &self.disabled, &self.disabled_buf };
        @panic("unexpected file name");
    }
    pub fn read(self: *FakeFs, name: []const u8, buf: []u8) ?[]const u8 {
        const s = self.slot(name);
        const v = s[0].* orelse return null;
        @memcpy(buf[0..v.len], v);
        return buf[0..v.len];
    }
    pub fn write(self: *FakeFs, name: []const u8, bytes: []const u8) bool {
        if (self.fail_writes) return false;
        const s = self.slot(name);
        @memcpy(s[1][0..bytes.len], bytes);
        s[0].* = s[1][0..bytes.len];
        return true;
    }
    pub fn delete(self: *FakeFs, name: []const u8) void {
        self.slot(name)[0].* = null;
    }
    fn set(self: *FakeFs, name: []const u8, bytes: []const u8) void {
        const saved = self.fail_writes;
        self.fail_writes = false;
        _ = self.write(name, bytes);
        self.fail_writes = saved;
    }
};

/// `sleep` advances a fake clock; the process "dies" at `dies_at_ns`.
const FakeClock = struct {
    now_ns: u64 = 0,
    dies_at_ns: ?u64 = null,
    slept_ns: u64 = 0,

    pub fn sleep(self: *FakeClock, ns: u64) error{ProcessDied}!void {
        if (self.dies_at_ns) |d| if (self.now_ns + ns >= d) {
            self.now_ns = d;
            return error.ProcessDied;
        };
        self.now_ns += ns;
        self.slept_ns += ns;
    }
};

const v1_vulkan: Stamp = .{ .version_code = 1, .setting = "vulkan" };

/// One Vulkan launch: check the guard; if clear, mark the start and run the
/// stable timer on `clock`.
fn launchVulkan(fs: *FakeFs, clock: *FakeClock, gen: *std.atomic.Value(u32), stamp: Stamp) bool {
    if (checkAtLaunch(fs, stamp)) return false;
    const mine = gen.fetchAdd(1, .acq_rel) + 1;
    if (!markStart(fs, stamp)) return true;
    settle(fs, clock, gen, mine);
    return true;
}

test "stamp: format and parse round-trip; junk is rejected" {
    var buf: [stamp_cap]u8 = undefined;
    const text = v1_vulkan.format(&buf).?;
    try testing.expectEqualStrings("1 vulkan", text);
    try testing.expect(Stamp.parse(text).?.eql(v1_vulkan));
    try testing.expect(Stamp.parse("42 auto\n").?.eql(.{ .version_code = 42, .setting = "auto" }));
    try testing.expect(Stamp.parse("9223372036854775807 gles").?.version_code == std.math.maxInt(i64));
    inline for (.{ "", "1", "1 ", "x vulkan", " 1 vulkan", "1 vul kan", "1\tvulkan" }) |bad| {
        try testing.expect(Stamp.parse(bad) == null);
    }
}

test "first start: nothing on disk, Vulkan allowed, start mark written" {
    var fs: FakeFs = .{};
    try testing.expect(!checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.start == null and fs.disabled == null);
    try testing.expect(markStart(&fs, v1_vulkan));
    try testing.expectEqualStrings("1 vulkan", fs.start.?);
}

test "a crash inside 10 s disables Vulkan at the next launch" {
    var fs: FakeFs = .{};
    var gen: std.atomic.Value(u32) = .init(0);
    var clock: FakeClock = .{ .dies_at_ns = stable_after_ns - 1 };
    try testing.expect(launchVulkan(&fs, &clock, &gen, v1_vulkan));
    // The timer never finished, so the mark survived the "crash".
    try testing.expectEqual(@as(u64, 0), clock.slept_ns);
    try testing.expectEqualStrings("1 vulkan", fs.start.?);

    // Next launch: the stale start becomes the disabled mark.
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.start == null);
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);
    // ...and it stays disabled on every later launch with the same stamp.
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);
}

test "a failed disabled write still keeps THIS launch off Vulkan" {
    var fs: FakeFs = .{};
    fs.set(start_file, "1 vulkan");
    fs.fail_writes = true;
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.start == null and fs.disabled == null);
}

test "surviving 10 s clears the mark; the next launch tries Vulkan again" {
    var fs: FakeFs = .{};
    var gen: std.atomic.Value(u32) = .init(0);
    var clock: FakeClock = .{};
    try testing.expect(launchVulkan(&fs, &clock, &gen, v1_vulkan));
    try testing.expectEqual(stable_after_ns, clock.slept_ns);
    try testing.expect(fs.start == null and fs.disabled == null);
    try testing.expect(!checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.disabled == null);
}

test "a superseded stable timer leaves the newer start mark alone" {
    var fs: FakeFs = .{};
    var gen: std.atomic.Value(u32) = .init(0);
    const first = gen.fetchAdd(1, .acq_rel) + 1;
    try testing.expect(markStart(&fs, v1_vulkan));
    _ = gen.fetchAdd(1, .acq_rel); // a second beginVulkanStart in the same process
    var clock: FakeClock = .{};
    settle(&fs, &clock, &gen, first);
    try testing.expectEqual(stable_after_ns, clock.slept_ns); // it did sleep...
    try testing.expect(fs.start != null); // ...but did not delete
}

test "a version bump resets both files and Vulkan is tried again" {
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vulkan");
    fs.set(start_file, "1 vulkan");
    const v2: Stamp = .{ .version_code = 2, .setting = "vulkan" };
    try testing.expect(!checkAtLaunch(&fs, v2));
    try testing.expect(fs.start == null and fs.disabled == null);

    // Same for a stale start mark alone (crashed on v1, launched on v2).
    fs.set(start_file, "1 vulkan");
    try testing.expect(!checkAtLaunch(&fs, v2));
    try testing.expect(fs.start == null and fs.disabled == null);
}

test "a changed renderer setting resets both files" {
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vulkan");
    fs.set(start_file, "1 vulkan");
    try testing.expect(!checkAtLaunch(&fs, .{ .version_code = 1, .setting = "auto" }));
    try testing.expect(fs.start == null and fs.disabled == null);

    fs.set(start_file, "1 auto");
    try testing.expect(!checkAtLaunch(&fs, .{ .version_code = 1, .setting = "gles" }));
    try testing.expect(fs.start == null and fs.disabled == null);
}

test "an unreadable stamp resets" {
    var fs: FakeFs = .{};
    fs.set(disabled_file, "garbage");
    try testing.expect(!checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.disabled == null);
    fs.set(start_file, "");
    try testing.expect(!checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.start == null);
}

test "a disabled launch drops a leftover start mark" {
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vulkan");
    fs.set(start_file, "1 vulkan");
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.start == null);
    try testing.expect(fs.disabled != null);
}

test "an intent override beats the guard (renderer.decide asks the intent first)" {
    const renderer = @import("renderer.zig");
    const Q = struct {
        fs: *FakeFs,
        extra: ?[]const u8,
        is_debuggable: bool,
        guard_calls: usize = 0,
        pub fn intentExtra(self: *@This()) ?[]const u8 {
            return self.extra;
        }
        pub fn debuggable(self: *@This()) bool {
            return self.is_debuggable;
        }
        pub fn vulkanDisabled(self: *@This()) bool {
            self.guard_calls += 1;
            return checkAtLaunch(self.fs, v1_vulkan);
        }
        pub fn metaData(_: *@This()) ?[]const u8 {
            return "vulkan";
        }
        pub fn hasVulkan(_: *@This()) bool {
            return true;
        }
    };
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vulkan");

    // Debuggable + extra: Vulkan from the intent; the guard is not consulted.
    var q: Q = .{ .fs = &fs, .extra = "vulkan", .is_debuggable = true };
    const d = renderer.decide(&q);
    try testing.expectEqual(renderer.Renderer.vulkan, d.renderer);
    try testing.expectEqual(renderer.Source.intent, d.source);
    try testing.expectEqual(@as(usize, 0), q.guard_calls);

    // Not debuggable: the extra is ignored and the guard wins.
    var r: Q = .{ .fs = &fs, .extra = "vulkan", .is_debuggable = false };
    const e = renderer.decide(&r);
    try testing.expectEqual(renderer.Renderer.gles, e.renderer);
    try testing.expectEqual(renderer.Source.crash_guard, e.source);
    try testing.expectEqual(@as(usize, 1), r.guard_calls);
}

test "the Android entry points are no-ops off Android" {
    if (comptime is_android) return error.SkipZigTest;
    try testing.expect(!vulkanDisabled(null, "vulkan"));
    try testing.expect(!vulkanDisabled(@ptrFromInt(0x1000), "vulkan"));
    beginVulkanStart(@ptrFromInt(0x1000), "vulkan");
}

test "Android: the glue is analysed (compile-check only; nothing runs)" {
    if (comptime !is_android) return error.SkipZigTest;
    // Address-of forces semantic analysis of the Android branches, their
    // externs and the JNI helpers' signatures in the NDK compile-check.
    _ = &vulkanDisabled;
    _ = &beginVulkanStart;
    _ = &stableThread;
    _ = &@import("renderer.zig").resolve;
}
