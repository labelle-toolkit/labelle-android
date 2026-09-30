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
//!   * Stable: a detached thread polls (every `poll_interval_ns`, 500 ms)
//!     and deletes `.labelle_vulkan_start` once BOTH hold: at least
//!     `stable_min_frames` (120) frames presented, and at least
//!     `stable_after_ns` (10 s) since `beginVulkanStart`. The frame count is
//!     labelle-bgfx's generic `labelle_bgfx_frames_presented()` export
//!     (labelle-toolkit/labelle-bgfx#182; reset to 0 on every successful
//!     `bgfx.init`, +1 per `bgfx.frame()`), looked up at RUNTIME with
//!     `dlsym(RTLD_DEFAULT, ...)`: no build dependency on labelle-bgfx. A
//!     Vulkan init that hangs never presents a frame, so the mark is never
//!     cleared and the next launch uses GLES.
//!     If the symbol is missing (another backend, or an older labelle-bgfx)
//!     the rule falls back to time only (10 s), logged once per process.
//!   * Disabled: while `.labelle_vulkan_disabled` exists and its stamp
//!     matches the current `versionCode` and setting, `vulkanDisabled`
//!     returns true and `renderer.decide` picks `gles` (source
//!     `crash-guard`).
//!   * Reset: a stamp that does NOT match (a new app version or a changed
//!     `renderer` setting) deletes both files, so Vulkan is tried again. An
//!     unreadable stamp resets too.
//!   * Intent override: `renderer.decide` asks the debuggable-only intent
//!     extra BEFORE the guard, so it wins (see the test at the bottom). The
//!     guard itself stays ACTIVE in debuggable builds: only an explicit
//!     extra bypasses it.
//!   * Fails CLOSED: if the disabled mark cannot be written, or the stable
//!     timer cannot be started, the start mark is KEPT, so the next launch
//!     is still guarded (it finds the mark again and goes to GLES).
//!
//! By design, anything that ends the process before the start is stable
//! counts as an incomplete start, including a developer's early force-stop
//! (e.g. `am start -S` within 10 s of the previous launch): the next launch runs
//! on GLES. To bypass the guard while iterating, launch a debuggable build
//! with `--es LABELLE_BGFX_RENDERER vulkan` (the intent override).
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
/// How many frames must have been presented (labelle-bgfx#182's counter)
/// before the start counts as stable.
pub const stable_min_frames: u64 = 120;
/// How often the stable thread re-checks.
pub const poll_interval_ns: u64 = 500 * std.time.ns_per_ms;

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
///      start mark, true; otherwise reset. If the write fails, the start
///      mark is KEPT (fail closed): the next launch finds it again and is
///      still guarded.
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
            const written = if (current.format(&out)) |text| fs.write(disabled_file, text) else false;
            if (written) {
                fs.delete(start_file);
            } else {
                // Fail closed: keep the start mark so the NEXT launch is
                // still guarded. This launch is off Vulkan either way.
                std.log.warn("android: crash guard: could not write {s}; keeping {s}", .{ disabled_file, start_file });
            }
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

/// The start mark's ownership, shared by `beginStart` and every stable
/// thread of the process. `lock` serialises the two steps that must not
/// interleave:
///   * `beginStart`: { generation += 1; write the start mark }
///   * `settle`'s final step: { generation still == mine?; unlink the mark }
/// so an old stable thread can never unlink a mark a newer launch just
/// wrote (Codex review of labelle-android#33, labelle-bgfx#172 comment
/// 5904658178). The frame counter and the clock are read OUTSIDE the lock.
///
/// `std.atomic.Mutex` spun on `tryLock` (Zig 0.16 has no `std.Thread.Mutex`,
/// and `std.Io.Mutex` needs an `Io`): both critical sections are a few
/// syscalls on a tiny file and contention needs two activity launches in
/// the same instant, so a spin is fine.
pub const StartState = struct {
    lock: std.atomic.Mutex = .unlocked,
    /// Written only under `lock`; read without it (atomically) only for the
    /// stable loop's early exit, which is advisory.
    generation: u32 = 0,

    fn acquire(self: *StartState) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
    fn release(self: *StartState) void {
        self.lock.unlock();
    }
    fn peek(self: *const StartState) u32 {
        return @atomicLoad(u32, &self.generation, .acquire);
    }
};

/// `beginVulkanStart`'s pure half: under `state.lock`, bump the generation
/// and write the start mark; then start the stable thread via
/// `spawner.spawn(mine: u32) !void`. Fails CLOSED: if the thread cannot
/// start, the mark is KEPT, so the next launch runs on GLES rather than an
/// unguarded Vulkan start being forgotten.
pub fn beginStart(fs: anytype, current: Stamp, state: *StartState, spawner: anytype) void {
    state.acquire();
    const mine = state.generation +% 1;
    @atomicStore(u32, &state.generation, mine, .release);
    const written = markStart(fs, current);
    state.release();
    if (!written) {
        std.log.warn("android: crash guard: could not write {s}", .{start_file});
        return;
    }
    spawner.spawn(mine) catch |err| {
        std.log.warn("android: crash guard: could not start the stable timer ({s}); keeping {s}, so the next launch uses gles", .{ @errorName(err), start_file });
    };
}

/// The stable thread. Polls every `poll_interval_ns` and deletes the start
/// mark once `stable_after_ns` has passed since it started AND
/// `src.framesPresented()` is at least `stable_min_frames`. A newer
/// `beginStart` (another activity launch in the same process) takes the mark
/// over: this thread then stops without deleting. The final check-and-unlink
/// runs under `state.lock`, so it cannot interleave with a newer
/// `beginStart`'s bump-and-write.
///
/// Injected:
///   * `clock.now() u64` (monotonic ns) and `clock.sleep(ns) !void`; a fake
///     returns an error to model the process dying mid-sleep.
///   * `src.framesPresented() ?u64`: null = the labelle-bgfx symbol is
///     missing → time-only rule; then `src.noteTimeOnly()` is called once
///     (the glue logs once per process).
pub fn settle(fs: anytype, clock: anytype, src: anytype, state: *StartState, mine: u32) void {
    const t0 = clock.now();
    var noted = false;
    // Advisory early exit; the authoritative check is under the lock below.
    while (state.peek() == mine) {
        const frames = src.framesPresented();
        if (frames == null and !noted) {
            noted = true;
            src.noteTimeOnly();
        }
        const elapsed = clock.now() -% t0;
        const enough_frames = if (frames) |f| f >= stable_min_frames else true;
        if (elapsed >= stable_after_ns and enough_frames) {
            state.acquire();
            defer state.release();
            if (state.generation == mine) fs.delete(start_file);
            return;
        }
        clock.sleep(poll_interval_ns) catch return;
    }
}

// ── Android glue ────────────────────────────────────────────────────────

// `jni/renderer_query.c`.
extern "c" fn labelle_android_internal_data_path(activity: ?*const anyopaque) ?[*:0]const u8;
extern "c" fn labelle_android_version_code(activity: ?*const anyopaque, out: *c_longlong) c_int;
extern "c" fn labelle_android_frames_presented(out: *u64) c_int;
extern "c" fn labelle_android_monotonic_ns() u64;
// libc.
const FILE = opaque {};
extern "c" fn fopen(name: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn unlink(name: [*:0]const u8) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

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
    pub fn now(_: LibcClock) u64 {
        return labelle_android_monotonic_ns();
    }
    pub fn sleep(_: LibcClock, ns: u64) error{}!void {
        // A signal may cut it short; the poll loop re-checks either way.
        _ = usleep(@intCast(@min(ns / std.time.ns_per_us, 1_000_000)));
    }
};

/// Set once the time-only fallback has been logged (once per process).
var time_only_logged: std.atomic.Value(bool) = .init(false);

/// labelle-bgfx#182's frame counter via `dlsym` (`jni/renderer_query.c`).
const DlsymFrames = struct {
    pub fn framesPresented(_: DlsymFrames) ?u64 {
        var n: u64 = 0;
        return if (labelle_android_frames_presented(&n) != 0) n else null;
    }
    pub fn noteTimeOnly(_: DlsymFrames) void {
        if (logOnce(&time_only_logged)) {
            std.log.warn("crash guard: labelle_bgfx_frames_presented not found; using the time-only stable rule", .{});
        }
    }
};

/// True for exactly one caller over the flag's lifetime.
fn logOnce(flag: *std.atomic.Value(bool)) bool {
    return !flag.swap(true, .acq_rel);
}

/// The process's start-mark ownership (see `StartState`).
var start_state: StartState = .{};

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
/// write `.labelle_vulkan_start` and start the detached stable thread
/// (120 frames and 10 s, or 10 s alone without labelle-bgfx#182).
pub fn beginVulkanStart(activity: ?*const anyopaque, setting: []const u8) void {
    if (comptime !is_android) return;
    const a = activity orelse return;
    const fs = libcFs(a) orelse return;
    beginStart(&fs, .{ .version_code = versionCode(a), .setting = setting }, &start_state, ThreadSpawner{ .fs = fs });
}

/// Spawns the detached stable-timer thread with its own copy of the fs.
const ThreadSpawner = struct {
    fs: LibcFs,
    pub fn spawn(self: ThreadSpawner, mine: u32) std.Thread.SpawnError!void {
        const t = try std.Thread.spawn(.{}, stableThread, .{ self.fs, mine });
        t.detach();
    }
};

fn stableThread(fs: LibcFs, mine: u32) void {
    settle(&fs, LibcClock{}, DlsymFrames{}, &start_state, mine);
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

    pub fn now(self: *FakeClock) u64 {
        return self.now_ns;
    }
    pub fn sleep(self: *FakeClock, ns: u64) error{ProcessDied}!void {
        if (self.dies_at_ns) |d| if (self.now_ns + ns >= d) {
            self.now_ns = d;
            return error.ProcessDied;
        };
        self.now_ns += ns;
        self.slept_ns += ns;
    }
};

/// labelle-bgfx#182's counter as a function of the fake clock: 0 until
/// `init_done_ns` (null = init never finishes, i.e. hangs), then `fps`
/// frames per second. `missing` = the symbol is not exported.
const FakeFrames = struct {
    clock: *FakeClock,
    fps: u64 = 60,
    init_done_ns: ?u64 = 0,
    missing: bool = false,
    notes: usize = 0,
    calls: usize = 0,
    /// Run a real `beginStart` (a newer launch in the same process: new
    /// generation + new mark) inside the Nth `framesPresented` call, i.e.
    /// after `settle`'s loop-entry check and before its stable decision.
    restart: ?struct { at_call: usize, fs: *FakeFs, state: *StartState, stamp: Stamp } = null,

    pub fn framesPresented(self: *FakeFrames) ?u64 {
        self.calls += 1;
        if (self.restart) |r| if (self.calls == r.at_call) {
            beginStart(r.fs, r.stamp, r.state, NoSpawner{});
        };
        if (self.missing) return null;
        const done = self.init_done_ns orelse return 0;
        if (self.clock.now_ns < done) return 0;
        return (self.clock.now_ns - done) * self.fps / std.time.ns_per_s;
    }
    pub fn noteTimeOnly(self: *FakeFrames) void {
        self.notes += 1;
    }
};

const NoSpawner = struct {
    pub fn spawn(_: NoSpawner, _: u32) error{}!void {}
};

const v1_vulkan: Stamp = .{ .version_code = 1, .setting = "vulkan" };
const v2_vulkan: Stamp = .{ .version_code = 2, .setting = "vulkan" };

/// One Vulkan launch: check the guard; if clear, mark the start and run the
/// stable thread on `clock` with a healthy 60 fps renderer.
fn launchVulkan(fs: *FakeFs, clock: *FakeClock, state: *StartState, stamp: Stamp) bool {
    if (checkAtLaunch(fs, stamp)) return false;
    var got: ?u32 = null;
    beginStart(fs, stamp, state, RecordingSpawner{ .got = &got });
    var frames: FakeFrames = .{ .clock = clock };
    if (got) |mine| settle(fs, clock, &frames, state, mine);
    return true;
}

const RecordingSpawner = struct {
    got: *?u32,
    pub fn spawn(self: RecordingSpawner, mine: u32) error{}!void {
        self.got.* = mine;
    }
};

/// Mark a start and run only the stable thread; returns the frame fake.
fn runSettle(fs: *FakeFs, clock: *FakeClock, frames: *FakeFrames) void {
    var state: StartState = .{};
    beginStart(fs, v1_vulkan, &state, NoSpawner{});
    settle(fs, clock, frames, &state, state.generation);
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
    var state: StartState = .{};
    var clock: FakeClock = .{ .dies_at_ns = stable_after_ns - 1 };
    try testing.expect(launchVulkan(&fs, &clock, &state, v1_vulkan));
    // The thread never saw 10 s, so the mark survived the "crash".
    try testing.expect(clock.slept_ns < stable_after_ns);
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

test "a failed disabled write keeps the start mark (fail closed): still guarded next launch" {
    var fs: FakeFs = .{};
    fs.set(start_file, "1 vulkan");
    fs.fail_writes = true;
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.disabled == null);
    try testing.expectEqualStrings("1 vulkan", fs.start.?); // kept
    // Next launch: still guarded by the kept start mark...
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expectEqualStrings("1 vulkan", fs.start.?);
    // ...and once writes work again, it converts to the disabled mark.
    fs.fail_writes = false;
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.start == null);
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);
}

test "a stable timer that cannot start keeps the start mark (fail closed)" {
    const FailingSpawner = struct {
        calls: *usize,
        pub fn spawn(self: @This(), _: u32) error{SystemResources}!void {
            self.calls.* += 1;
            return error.SystemResources;
        }
    };
    var fs: FakeFs = .{};
    var state: StartState = .{};
    var calls: usize = 0;
    beginStart(&fs, v1_vulkan, &state, FailingSpawner{ .calls = &calls });
    try testing.expectEqual(@as(usize, 1), calls);
    try testing.expectEqualStrings("1 vulkan", fs.start.?); // kept
    // The next launch treats it as an incomplete start: gles.
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);
}

test "beginStart: mark written, timer spawned with the new generation" {
    var fs: FakeFs = .{};
    var state: StartState = .{ .generation = 4 };
    var got: ?u32 = null;
    beginStart(&fs, v1_vulkan, &state, RecordingSpawner{ .got = &got });
    try testing.expectEqual(@as(?u32, 5), got);
    try testing.expectEqualStrings("1 vulkan", fs.start.?);
}

test "surviving 10 s (with frames) clears the mark; the next launch tries Vulkan again" {
    var fs: FakeFs = .{};
    var state: StartState = .{};
    var clock: FakeClock = .{};
    try testing.expect(launchVulkan(&fs, &clock, &state, v1_vulkan));
    try testing.expectEqual(stable_after_ns, clock.now_ns);
    try testing.expect(fs.start == null and fs.disabled == null);
    try testing.expect(!checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.disabled == null);
}

test "a superseded stable timer leaves the newer start mark alone" {
    var fs: FakeFs = .{};
    var state: StartState = .{};
    beginStart(&fs, v1_vulkan, &state, NoSpawner{});
    const first = state.generation;
    var clock: FakeClock = .{};
    // A second beginStart lands on the 3rd poll, well before 10 s.
    var frames: FakeFrames = .{ .clock = &clock, .restart = .{ .at_call = 3, .fs = &fs, .state = &state, .stamp = v2_vulkan } };
    settle(&fs, &clock, &frames, &state, first);
    try testing.expectEqual(@as(usize, 3), frames.calls); // it polled...
    try testing.expect(clock.now_ns < stable_after_ns); // ...stopped early...
    try testing.expectEqualStrings("2 vulkan", fs.start.?); // ...and left the new mark
}

test "race: a newer start landing at the very poll that would clear keeps its mark" {
    // Codex review (labelle-bgfx#172 comment 5904658178). Poll 21 is t = 10 s
    // (500 ms polls from 0) with 600 frames at 60 fps, so it is the poll
    // whose stable decision says "clear". The newer beginStart runs inside
    // that poll, AFTER the loop-entry generation check. Without the locked
    // re-check the old thread unlinks the new launch's mark (this test then
    // fails: fs.start == null).
    var fs: FakeFs = .{};
    var state: StartState = .{};
    beginStart(&fs, v1_vulkan, &state, NoSpawner{});
    const first = state.generation;
    var clock: FakeClock = .{};
    var frames: FakeFrames = .{ .clock = &clock, .restart = .{ .at_call = 21, .fs = &fs, .state = &state, .stamp = v2_vulkan } };
    settle(&fs, &clock, &frames, &state, first);
    try testing.expectEqual(@as(usize, 21), frames.calls);
    try testing.expectEqual(stable_after_ns, clock.now_ns); // it reached the stable branch
    try testing.expectEqual(first + 1, state.generation);
    try testing.expect(fs.start != null); // the new mark survived...
    try testing.expectEqualStrings("2 vulkan", fs.start.?); // ...and it IS the new one
    try testing.expect(state.lock.tryLock()); // settle released the lock
    state.release();
}

test "the stable thread's own clear still works under the lock" {
    var fs: FakeFs = .{};
    var clock: FakeClock = .{};
    var frames: FakeFrames = .{ .clock = &clock };
    var state: StartState = .{};
    beginStart(&fs, v1_vulkan, &state, NoSpawner{});
    try testing.expect(state.lock.tryLock()); // beginStart released it...
    try testing.expect(!state.lock.tryLock()); // ...and it is exclusive
    state.release();
    settle(&fs, &clock, &frames, &state, state.generation);
    try testing.expect(fs.start == null);
    try testing.expect(state.lock.tryLock());
    state.release();
}

test "stable: 120 frames but under 10 s -> not cleared" {
    var fs: FakeFs = .{};
    var clock: FakeClock = .{ .dies_at_ns = stable_after_ns - 1 };
    var frames: FakeFrames = .{ .clock = &clock, .fps = 1000 };
    runSettle(&fs, &clock, &frames);
    try testing.expect(frames.framesPresented().? >= stable_min_frames); // frames were there
    try testing.expect(fs.start != null);
    try testing.expectEqual(@as(usize, 0), frames.notes);
}

test "stable: 10 s but under 120 frames (a hung init) -> not cleared" {
    var fs: FakeFs = .{};
    // Init never finishes; the player kills it after a minute.
    var clock: FakeClock = .{ .dies_at_ns = 60 * std.time.ns_per_s };
    var frames: FakeFrames = .{ .clock = &clock, .init_done_ns = null };
    runSettle(&fs, &clock, &frames);
    try testing.expect(clock.now_ns >= stable_after_ns);
    try testing.expect(fs.start != null);

    // Init finished but only a few frames (a stall after the first frames).
    var fs2: FakeFs = .{};
    var clock2: FakeClock = .{ .dies_at_ns = 60 * std.time.ns_per_s };
    var frames2: FakeFrames = .{ .clock = &clock2, .fps = 1, .init_done_ns = 0 };
    runSettle(&fs2, &clock2, &frames2);
    try testing.expect(frames2.framesPresented().? < stable_min_frames);
    try testing.expect(fs2.start != null);
}

test "stable: both 120 frames and 10 s -> cleared, at whichever comes last" {
    // Frames first (60 fps: 120 at 2 s), then time: cleared at 10 s.
    var fs: FakeFs = .{};
    var clock: FakeClock = .{};
    var frames: FakeFrames = .{ .clock = &clock };
    runSettle(&fs, &clock, &frames);
    try testing.expect(fs.start == null);
    try testing.expectEqual(stable_after_ns, clock.now_ns);

    // Time first (slow init: frames start at 9 s, 20 fps → 120 at 15 s).
    var fs2: FakeFs = .{};
    var clock2: FakeClock = .{};
    var frames2: FakeFrames = .{ .clock = &clock2, .fps = 20, .init_done_ns = 9 * std.time.ns_per_s };
    runSettle(&fs2, &clock2, &frames2);
    try testing.expect(fs2.start == null);
    try testing.expectEqual(15 * std.time.ns_per_s, clock2.now_ns);
}

test "stable: missing symbol -> time-only rule, noted once" {
    var fs: FakeFs = .{};
    var clock: FakeClock = .{};
    var frames: FakeFrames = .{ .clock = &clock, .missing = true };
    runSettle(&fs, &clock, &frames);
    try testing.expect(fs.start == null);
    try testing.expectEqual(stable_after_ns, clock.now_ns);
    try testing.expect(frames.calls > 1); // polled many times...
    try testing.expectEqual(@as(usize, 1), frames.notes); // ...noted once

    // Before 10 s it is still not cleared.
    var fs2: FakeFs = .{};
    var clock2: FakeClock = .{ .dies_at_ns = stable_after_ns - 1 };
    var frames2: FakeFrames = .{ .clock = &clock2, .missing = true };
    runSettle(&fs2, &clock2, &frames2);
    try testing.expect(fs2.start != null);
}

test "logOnce: the time-only log fires for exactly one caller per process" {
    var flag: std.atomic.Value(bool) = .init(false);
    try testing.expect(logOnce(&flag));
    try testing.expect(!logOnce(&flag));
    try testing.expect(!logOnce(&flag));
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

    // Debuggable WITHOUT the extra: the guard stays active (option c).
    var n: Q = .{ .fs = &fs, .extra = null, .is_debuggable = true };
    const g = renderer.decide(&n);
    try testing.expectEqual(renderer.Renderer.gles, g.renderer);
    try testing.expectEqual(renderer.Source.crash_guard, g.source);
    try testing.expectEqual(@as(usize, 1), n.guard_calls);

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
