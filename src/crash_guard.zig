//! Vulkan crash guard (labelle-android#28; labelle-bgfx#172 D11).
//!
//! If the game crashes (or is killed) while starting on Vulkan, the next
//! launch starts on GLES, so a bad Vulkan driver cannot brick the game.
//!
//! Two marker files, each containing `<versionCode> <setting>`, in the app's
//! `Context.getNoBackupFilesDir()` (`<data>/no_backup`), which Android Auto
//! Backup and device-to-device transfer never copy: a crash on one device's
//! GPU must not disable Vulkan on another. If that JNI lookup fails, the
//! glue falls back to `ANativeActivity.internalDataPath` (logged once).
//!
//!   * `.labelle_vulkan_start`: written by `beginVulkanStart`, just before a
//!     Vulkan start (the resolved renderer is `vulkan`).
//!   * `.labelle_vulkan_disabled`: written when a launch finds a
//!     `.labelle_vulkan_start` left by a process that is gone, i.e. a Vulkan
//!     start that never reached "stable".
//!
//! Both are written atomically (`<name>.tmp` + `rename`), so a failed or
//! partial write never leaves a malformed marker behind.
//!
//! Rules:
//!   * Stable: a detached thread polls (every `poll_interval_ns`, 500 ms)
//!     and deletes `.labelle_vulkan_start` once BOTH hold: at least
//!     `stable_min_frames` (120) frames presented SINCE THIS START, and at
//!     least `stable_after_ns` (10 s) since `beginVulkanStart`. The frame
//!     count is labelle-bgfx's generic `labelle_bgfx_frames_presented()`
//!     export (labelle-toolkit/labelle-bgfx#182; reset to 0 on every
//!     successful `bgfx.init`, +1 per `bgfx.frame()`), looked up at RUNTIME
//!     with `dlsym(RTLD_DEFAULT, ...)`: no build dependency on labelle-bgfx.
//!     `beginStart` records the counter as a per-start baseline, so frames a
//!     previous Activity of the same process presented never count; a value
//!     below the baseline means bgfx re-initialised, and counting restarts
//!     from 0. A Vulkan init that hangs never presents a frame, so the mark
//!     is never cleared and the next launch uses GLES.
//!     If the symbol is missing (another backend, or an older labelle-bgfx)
//!     the rule falls back to time only (10 s), logged once per process.
//!   * Same process: a start mark THIS process wrote and still owns
//!     (`StartState.owned`) is not a crash: an Activity relaunched in the
//!     same process supersedes it (new generation, new mark) instead.
//!   * Disabled: while `.labelle_vulkan_disabled` exists and its stamp
//!     matches the current `versionCode` and setting, `vulkanDisabled`
//!     returns true and `renderer.decide` picks `gles` (source
//!     `crash-guard`).
//!   * Reset: each marker whose stamp does NOT match (a successfully read
//!     new app version or changed `renderer` setting) is deleted on its own,
//!     so Vulkan is tried again; a marker that still matches is kept and
//!     applied. A value that could not be READ never counts as a change.
//!   * Intent override: `renderer.decide` asks the debuggable-only intent
//!     extra BEFORE the guard, so it wins (see the test at the bottom). The
//!     guard itself stays ACTIVE in debuggable builds: only an explicit
//!     extra bypasses it.
//!   * Fails CLOSED: if the disabled mark cannot be written, or the stable
//!     timer cannot be started, the start mark is KEPT, so the next launch
//!     is still guarded (it finds the mark again and goes to GLES). A
//!     malformed marker is treated as a match for the current stamp. If the
//!     start mark cannot be written at all, `renderer.resolve` runs this
//!     launch on GLES (unless the intent override asked for Vulkan).
//!
//! By design, anything that ends the process before the start is stable
//! counts as an incomplete start, including a developer's early force-stop
//! (e.g. `am start -S` within 10 s of the previous launch): the next launch runs
//! on GLES. To bypass the guard while iterating, launch a debuggable build
//! with `--es LABELLE_BGFX_RENDERER vulkan` (the intent override).
//!
//! The PURE half (`checkObserved`, `beginStart`, `settle`) takes an injected
//! filesystem, clock and frame source and is host-tested; the Android glue
//! below it uses libc and the JNI helpers in `jni/renderer_query.c`.
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

/// What this launch could OBSERVE of the current stamp. A null field is a
/// READ FAILURE (JNI error), not a value: it can never count as a change,
/// so it never resets the guard (Codex review of labelle-android#33,
/// labelle-bgfx#172 comment 5904915798). An ABSENT `labelle.renderer` key is
/// a successful read and arrives here as the default `gles`.
pub const Observed = struct {
    version_code: ?i64,
    setting: ?[]const u8,

    pub fn of(stamp: Stamp) Observed {
        return .{ .version_code = stamp.version_code, .setting = stamp.setting };
    }
    /// The full stamp, when both halves were read.
    pub fn full(self: Observed) ?Stamp {
        return .{ .version_code = self.version_code orelse return null, .setting = self.setting orelse return null };
    }
};

const Match = enum { same, changed, unknown };

/// `changed` only on a SUCCESSFULLY read, different value; a failed read of
/// either half otherwise gives `unknown`.
fn compare(recorded: Stamp, now: Observed) Match {
    if (now.version_code) |v| if (v != recorded.version_code) return .changed;
    if (now.setting) |x| if (!std.mem.eql(u8, x, recorded.setting)) return .changed;
    return if (now.full() == null) .unknown else .same;
}

/// The launch-time check of a NEW process (fresh `StartState`) with a fully
/// read stamp (see `checkObserved`).
pub fn checkAtLaunch(fs: anytype, current: Stamp) bool {
    var fresh: StartState = .{};
    return checkObserved(fs, Observed.of(current), &fresh);
}

/// The launch-time check. `fs` provides:
///   * `read(name: []const u8, buf: []u8) ?[]const u8` (null = absent or
///     unreadable)
///   * `write(name: []const u8, bytes: []const u8) bool`
///   * `rename(from: []const u8, to: []const u8) bool` (replaces `to`)
///   * `delete(name: []const u8) void` (absent is fine)
///
/// Returns true when this launch must not use Vulkan. Each marker is judged
/// on its own stamp (`compare`):
///   * `.labelle_vulkan_disabled`: same → guarded; changed → deleted (only
///     it); unknown (a value could not be read) → kept, guarded; malformed →
///     guarded and rewritten with the current stamp (fail closed).
///   * `.labelle_vulkan_start`, unless this process owns it
///     (`state.owned`: a same-process relaunch, not a crash): same (or
///     malformed) → a crashed start: write the disabled mark, then drop the
///     start mark, guarded; if that write fails the start mark is KEPT, so
///     the next launch is still guarded; changed → deleted (only it);
///     unknown → kept, guarded.
/// Runs under `state.lock`, like `beginStart` and `settle`'s unlink.
pub fn checkObserved(fs: anytype, current: Observed, state: *StartState) bool {
    state.acquire();
    defer state.release();
    var guarded = false;
    var buf: [stamp_cap]u8 = undefined;
    if (fs.read(disabled_file, &buf)) |bytes| {
        if (Stamp.parse(bytes)) |s| switch (compare(s, current)) {
            .same, .unknown => guarded = true,
            .changed => fs.delete(disabled_file),
        } else {
            // Malformed: never a reset (that could lose a kept start mark).
            // Fail closed and repair it for the current stamp.
            std.log.warn("android: crash guard: malformed {s}; keeping the guard", .{disabled_file});
            guarded = true;
            if (current.full()) |cur| _ = writeStamp(fs, disabled_file, cur);
        }
    }
    if (!state.owned) if (fs.read(start_file, &buf)) |bytes| {
        const parsed = Stamp.parse(bytes);
        const m: Match = if (parsed) |s| compare(s, current) else .same;
        switch (m) {
            .same => {
                // A start that never became stable, left by a process that is
                // gone (not this one: `state.owned` is false).
                guarded = true;
                if (current.full()) |cur| {
                    if (writeStamp(fs, disabled_file, cur)) {
                        fs.delete(start_file);
                    } else {
                        // Fail closed: keep the start mark so the NEXT launch
                        // is still guarded. This launch is off Vulkan anyway.
                        std.log.warn("android: crash guard: could not write {s}; keeping {s}", .{ disabled_file, start_file });
                    }
                }
            },
            .unknown => guarded = true,
            .changed => fs.delete(start_file),
        }
    };
    return guarded;
}

/// Write `<name>.tmp`, then rename it over `name`: a failed or partial write
/// never leaves a malformed `name` (the tmp is removed on failure).
fn writeAtomic(fs: anytype, name: []const u8, bytes: []const u8) bool {
    var tmp_buf: [64]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch return false;
    if (!fs.write(tmp, bytes) or !fs.rename(tmp, name)) {
        fs.delete(tmp);
        return false;
    }
    return true;
}

fn writeStamp(fs: anytype, name: []const u8, stamp: Stamp) bool {
    var out: [stamp_cap]u8 = undefined;
    const text = stamp.format(&out) orelse return false;
    return writeAtomic(fs, name, text);
}

/// Write `.labelle_vulkan_start` (atomically; called just before a Vulkan
/// start).
pub fn markStart(fs: anytype, current: Stamp) bool {
    return writeStamp(fs, start_file, current);
}

/// The start mark's ownership, shared by `checkObserved`, `beginStart` and
/// every stable thread of the process. `lock` serialises the steps that
/// must not interleave:
///   * `beginStart`: { generation += 1; write the start mark; owned = true }
///   * `settle`'s final step: { generation still == mine?; unlink the mark;
///     owned = false }
///   * `checkObserved`: { read `owned`; judge the markers }
/// so an old stable thread can never unlink a mark a newer launch just
/// wrote (Codex review of labelle-android#33, labelle-bgfx#172 comment
/// 5904658178), and a same-process relaunch never mistakes this process's
/// own live mark for a crash. The frame counter and the clock are read
/// OUTSIDE the lock.
///
/// `std.atomic.Mutex` spun on `tryLock` (Zig 0.16 has no `std.Thread.Mutex`,
/// and `std.Io.Mutex` needs an `Io`): the critical sections are a few
/// syscalls on tiny files and contention needs two activity launches in
/// the same instant, so a spin is fine.
pub const StartState = struct {
    lock: std.atomic.Mutex = .unlocked,
    /// Written only under `lock`; read without it (atomically) only for the
    /// stable loop's early exit, which is advisory.
    generation: u32 = 0,
    /// Under `lock`: the start mark on disk was written by THIS process and
    /// its stable thread has not cleared it yet.
    owned: bool = false,

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

/// `beginVulkanStart`'s pure half. Reads the frame counter as this start's
/// baseline (`src.framesPresented()`, outside the lock); under `state.lock`
/// bumps the generation and writes the start mark; then starts the stable
/// thread via `spawner.spawn(mine: u32, baseline: ?u64) !void`.
///
/// Returns false when the start mark could NOT be written: the caller then
/// must not start Vulkan unguarded (`renderer.afterStart` → GLES). If only
/// the thread cannot start, the mark is KEPT and this returns true: Vulkan
/// runs, and the next launch is guarded (fail closed).
pub fn beginStart(fs: anytype, current: Stamp, state: *StartState, src: anytype, spawner: anytype) bool {
    const baseline = src.framesPresented();
    state.acquire();
    const mine = state.generation +% 1;
    @atomicStore(u32, &state.generation, mine, .release);
    const written = markStart(fs, current);
    if (written) state.owned = true;
    state.release();
    if (!written) {
        std.log.warn("android: crash guard: could not write {s}", .{start_file});
        return false;
    }
    spawner.spawn(mine, baseline) catch |err| {
        std.log.warn("android: crash guard: could not start the stable timer ({s}); keeping {s}, so the next launch uses gles", .{ @errorName(err), start_file });
    };
    return true;
}

/// Frames presented since this start: the counter minus `baseline.*`. A
/// counter BELOW the baseline means bgfx re-initialised (labelle-bgfx#182
/// resets it on every successful init): the baseline drops to 0 for good.
fn framesSince(raw: u64, baseline: *?u64) u64 {
    const b = baseline.* orelse return raw;
    if (raw < b) {
        baseline.* = 0;
        return raw;
    }
    return raw - b;
}

/// The stable thread. Polls every `poll_interval_ns` and deletes the start
/// mark once `stable_after_ns` has passed since it started AND at least
/// `stable_min_frames` frames were presented since `baseline` (the counter
/// at `beginStart`; see `framesSince`). A newer `beginStart` (another
/// activity launch in the same process) takes the mark over: this thread
/// then stops without deleting. The final check-and-unlink runs under
/// `state.lock`, so it cannot interleave with a newer `beginStart`.
///
/// Injected:
///   * `clock.now() u64` (monotonic ns) and `clock.sleep(ns) !void`; a fake
///     returns an error to model the process dying mid-sleep.
///   * `src.framesPresented() ?u64`: null = the labelle-bgfx symbol is
///     missing → time-only rule; then `src.noteTimeOnly()` is called once
///     (the glue logs once per process).
pub fn settle(fs: anytype, clock: anytype, src: anytype, state: *StartState, mine: u32, baseline: ?u64) void {
    const t0 = clock.now();
    var noted = false;
    var base = baseline;
    // Advisory early exit; the authoritative check is under the lock below.
    while (state.peek() == mine) {
        const raw = src.framesPresented();
        if (raw == null and !noted) {
            noted = true;
            src.noteTimeOnly();
        }
        const elapsed = clock.now() -% t0;
        const enough_frames = if (raw) |r| framesSince(r, &base) >= stable_min_frames else true;
        if (elapsed >= stable_after_ns and enough_frames) {
            state.acquire();
            defer state.release();
            if (state.generation == mine) {
                fs.delete(start_file);
                state.owned = false;
            }
            return;
        }
        clock.sleep(poll_interval_ns) catch return;
    }
}

// ── Android glue ────────────────────────────────────────────────────────

// `jni/renderer_query.c`.
extern "c" fn labelle_android_internal_data_path(activity: ?*const anyopaque) ?[*:0]const u8;
extern "c" fn labelle_android_no_backup_dir(activity: ?*const anyopaque, buf: [*]u8, buf_cap: usize) c_int;
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
extern "c" fn rename(from: [*:0]const u8, to: [*:0]const u8) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

/// Marker files under a copied directory path (a value type, so the
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
    pub fn rename(self: *const LibcFs, from: []const u8, to: []const u8) bool {
        var pf: [600]u8 = undefined;
        var pt: [600]u8 = undefined;
        const f = self.full(from, &pf) orelse return false;
        const t = self.full(to, &pt) orelse return false;
        return rename_c(f.ptr, t.ptr) == 0;
    }
    pub fn delete(self: *const LibcFs, name: []const u8) void {
        var p: [600]u8 = undefined;
        _ = unlink((self.full(name, &p) orelse return).ptr);
    }
};
const rename_c = rename;

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
/// process (an update kills it). -1 = not read yet. Only a SUCCESSFUL read
/// is cached, so a transient JNI failure is retried on the next call.
var version_cache: std.atomic.Value(i64) = .init(-1);
var version_failure_logged: std.atomic.Value(bool) = .init(false);

/// The app's versionCode, or null when the JNI read failed (never a
/// synthetic value: a fake 0 would look like a version change and reset the
/// guard).
fn versionCode(activity: *const anyopaque) ?i64 {
    const cached = version_cache.load(.acquire);
    if (cached >= 0) return cached;
    var v: c_longlong = 0;
    if (labelle_android_version_code(activity, &v) != 0 or v < 0) {
        if (logOnce(&version_failure_logged)) {
            std.log.warn("android: crash guard: could not read the app's versionCode; keeping the guard's marks as they are", .{});
        }
        return null;
    }
    version_cache.store(v, .release);
    return v;
}

var no_backup_failure_logged: std.atomic.Value(bool) = .init(false);

/// The markers' directory: `getNoBackupFilesDir()` (never backed up or
/// transferred), else `internalDataPath` with a one-time warning.
fn libcFs(activity: *const anyopaque) ?LibcFs {
    var nb: [512]u8 = undefined;
    const n = labelle_android_no_backup_dir(activity, &nb, nb.len);
    if (n > 0) {
        if (LibcFs.init(nb[0..@intCast(n)])) |fs| return fs;
    }
    if (logOnce(&no_backup_failure_logged)) {
        std.log.warn("android: crash guard: could not get noBackupFilesDir; using internalDataPath (Auto Backup may copy the crash-guard markers)", .{});
    }
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
/// `auto`), or null when the meta-data could not be READ (then, like a
/// failed versionCode read, the marks are preserved: see `checkObserved`).
/// Off Android, or with no activity or data dir: false.
pub fn vulkanDisabled(activity: ?*const anyopaque, setting: ?[]const u8) bool {
    if (comptime !is_android) return false;
    const a = activity orelse return false;
    var fs = libcFs(a) orelse return false;
    return checkObserved(&fs, .{ .version_code = versionCode(a), .setting = setting }, &start_state);
}

/// Called by `renderer.resolve` once Vulkan is chosen, before bgfx starts:
/// write `.labelle_vulkan_start` and start the detached stable thread
/// (120 frames and 10 s, or 10 s alone without labelle-bgfx#182).
/// `setting` null = the meta-data could not be read. A start mark needs the
/// full stamp, so with either half unreadable no mark is written (logged).
/// Returns whether the start mark was recorded; when it was not,
/// `renderer.afterStart` keeps this launch off Vulkan (fail closed).
pub fn beginVulkanStart(activity: ?*const anyopaque, setting: ?[]const u8) bool {
    if (comptime !is_android) return true;
    const a = activity orelse return false;
    const fs = libcFs(a) orelse return false;
    const obs: Observed = .{ .version_code = versionCode(a), .setting = setting };
    const stamp = obs.full() orelse {
        std.log.warn("android: crash guard: versionCode or {s} unreadable; cannot record this Vulkan start", .{"labelle.renderer"});
        return false;
    };
    return beginStart(&fs, stamp, &start_state, DlsymFrames{}, ThreadSpawner{ .fs = fs });
}

/// Spawns the detached stable-timer thread with its own copy of the fs.
const ThreadSpawner = struct {
    fs: LibcFs,
    pub fn spawn(self: ThreadSpawner, mine: u32, baseline: ?u64) std.Thread.SpawnError!void {
        const t = try std.Thread.spawn(.{}, stableThread, .{ self.fs, mine, baseline });
        t.detach();
    }
};

fn stableThread(fs: LibcFs, mine: u32, baseline: ?u64) void {
    settle(&fs, LibcClock{}, DlsymFrames{}, &start_state, mine, baseline);
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// In-memory marker files (and their `.tmp` siblings), persisting across
/// "launches" like storage does.
const FakeFs = struct {
    start: ?[]const u8 = null,
    disabled: ?[]const u8 = null,
    start_tmp: ?[]const u8 = null,
    disabled_tmp: ?[]const u8 = null,
    bufs: [4][stamp_cap]u8 = undefined,
    /// Every write fails without touching anything.
    fail_writes: bool = false,
    /// Every write stores HALF the bytes, then reports failure (ENOSPC).
    partial_writes: bool = false,

    fn slot(self: *FakeFs, name: []const u8) struct { *?[]const u8, []u8 } {
        if (std.mem.eql(u8, name, start_file)) return .{ &self.start, &self.bufs[0] };
        if (std.mem.eql(u8, name, disabled_file)) return .{ &self.disabled, &self.bufs[1] };
        if (std.mem.eql(u8, name, start_file ++ ".tmp")) return .{ &self.start_tmp, &self.bufs[2] };
        if (std.mem.eql(u8, name, disabled_file ++ ".tmp")) return .{ &self.disabled_tmp, &self.bufs[3] };
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
        const n = if (self.partial_writes) bytes.len / 2 else bytes.len;
        @memcpy(s[1][0..n], bytes[0..n]);
        s[0].* = s[1][0..n];
        return !self.partial_writes;
    }
    pub fn rename(self: *FakeFs, from: []const u8, to: []const u8) bool {
        const f = self.slot(from);
        const v = f[0].* orelse return false;
        const t = self.slot(to);
        @memcpy(t[1][0..v.len], v);
        t[0].* = t[1][0..v.len];
        f[0].* = null;
        return true;
    }
    pub fn delete(self: *FakeFs, name: []const u8) void {
        self.slot(name)[0].* = null;
    }
    fn set(self: *FakeFs, name: []const u8, bytes: []const u8) void {
        const s = self.slot(name);
        @memcpy(s[1][0..bytes.len], bytes);
        s[0].* = s[1][0..bytes.len];
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

/// labelle-bgfx#182's counter as a function of the fake clock:
/// `before_init` until `init_done_ns` (null = init never finishes, i.e.
/// hangs; `before_init` > 0 = a previous Activity's frames), then from 0 at
/// `fps` frames per second (the reset on a successful init). `missing` = the
/// symbol is not exported.
const FakeFrames = struct {
    clock: *FakeClock,
    fps: u64 = 60,
    init_done_ns: ?u64 = 0,
    before_init: u64 = 0,
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
            _ = beginStart(r.fs, r.stamp, r.state, NoFrames{}, NoSpawner{});
        };
        if (self.missing) return null;
        const done = self.init_done_ns orelse return self.before_init;
        if (self.clock.now_ns < done) return self.before_init;
        return (self.clock.now_ns - done) * self.fps / std.time.ns_per_s;
    }
    pub fn noteTimeOnly(self: *FakeFrames) void {
        self.notes += 1;
    }
};

const NoSpawner = struct {
    pub fn spawn(_: NoSpawner, _: u32, _: ?u64) error{}!void {}
};

/// A frame source with no counter (for `beginStart`'s baseline read).
const NoFrames = struct {
    pub fn framesPresented(_: NoFrames) ?u64 {
        return null;
    }
    pub fn noteTimeOnly(_: NoFrames) void {}
};

/// `checkObserved` as a NEW process (fresh in-process state).
fn checkNew(fs: anytype, obs: Observed) bool {
    var fresh: StartState = .{};
    return checkObserved(fs, obs, &fresh);
}

const v1_vulkan: Stamp = .{ .version_code = 1, .setting = "vulkan" };
const v2_vulkan: Stamp = .{ .version_code = 2, .setting = "vulkan" };

/// One Vulkan launch: check the guard; if clear, mark the start and run the
/// stable thread on `clock` with a healthy 60 fps renderer.
fn launchVulkan(fs: *FakeFs, clock: *FakeClock, state: *StartState, stamp: Stamp) bool {
    if (checkAtLaunch(fs, stamp)) return false;
    var got: ?u32 = null;
    _ = beginStart(fs, stamp, state, NoFrames{}, RecordingSpawner{ .got = &got });
    var frames: FakeFrames = .{ .clock = clock };
    if (got) |mine| settle(fs, clock, &frames, state, mine, null);
    return true;
}

const RecordingSpawner = struct {
    got: *?u32,
    baseline: ?*?u64 = null,
    pub fn spawn(self: RecordingSpawner, mine: u32, baseline: ?u64) error{}!void {
        self.got.* = mine;
        if (self.baseline) |b| b.* = baseline;
    }
};

/// Mark a start and run only the stable thread; returns the frame fake.
fn runSettle(fs: *FakeFs, clock: *FakeClock, frames: *FakeFrames) void {
    var state: StartState = .{};
    _ = beginStart(fs, v1_vulkan, &state, NoFrames{}, NoSpawner{});
    settle(fs, clock, frames, &state, state.generation, null);
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
        pub fn spawn(self: @This(), _: u32, _: ?u64) error{SystemResources}!void {
            self.calls.* += 1;
            return error.SystemResources;
        }
    };
    var fs: FakeFs = .{};
    var state: StartState = .{};
    var calls: usize = 0;
    try testing.expect(beginStart(&fs, v1_vulkan, &state, NoFrames{}, FailingSpawner{ .calls = &calls })); // mark written
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
    try testing.expect(beginStart(&fs, v1_vulkan, &state, NoFrames{}, RecordingSpawner{ .got = &got }));
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
    _ = beginStart(&fs, v1_vulkan, &state, NoFrames{}, NoSpawner{});
    const first = state.generation;
    var clock: FakeClock = .{};
    // A second beginStart lands on the 3rd poll, well before 10 s.
    var frames: FakeFrames = .{ .clock = &clock, .restart = .{ .at_call = 3, .fs = &fs, .state = &state, .stamp = v2_vulkan } };
    settle(&fs, &clock, &frames, &state, first, null);
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
    _ = beginStart(&fs, v1_vulkan, &state, NoFrames{}, NoSpawner{});
    const first = state.generation;
    var clock: FakeClock = .{};
    var frames: FakeFrames = .{ .clock = &clock, .restart = .{ .at_call = 21, .fs = &fs, .state = &state, .stamp = v2_vulkan } };
    settle(&fs, &clock, &frames, &state, first, null);
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
    _ = beginStart(&fs, v1_vulkan, &state, NoFrames{}, NoSpawner{});
    try testing.expect(state.lock.tryLock()); // beginStart released it...
    try testing.expect(!state.lock.tryLock()); // ...and it is exclusive
    state.release();
    settle(&fs, &clock, &frames, &state, state.generation, null);
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

test "a malformed marker is never a reset: fail closed, repaired for the current stamp" {
    var fs: FakeFs = .{};
    fs.set(disabled_file, "garbage");
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);

    var fs2: FakeFs = .{};
    fs2.set(start_file, "");
    try testing.expect(checkAtLaunch(&fs2, v1_vulkan)); // an unfinished start
    try testing.expect(fs2.start == null);
    try testing.expectEqualStrings("1 vulkan", fs2.disabled.?);
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
    try testing.expect(beginVulkanStart(@ptrFromInt(0x1000), "vulkan"));
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

/// One launch through `renderer.decide` with the guard wired as the glue
/// wires it: the meta-data read's outcome (`renderer.MetaRead`) and a
/// versionCode read that may fail (null).
const LaunchQuery = struct {
    const renderer = @import("renderer.zig");
    fs: *FakeFs,
    meta: renderer.MetaRead,
    version: ?i64,

    pub fn intentExtra(_: *@This()) ?[]const u8 {
        return null;
    }
    pub fn debuggable(_: *@This()) bool {
        return false;
    }
    pub fn vulkanDisabled(self: *@This()) bool {
        return checkNew(self.fs, .{ .version_code = self.version, .setting = self.meta.guardSetting() });
    }
    pub fn metaData(self: *@This()) ?[]const u8 {
        return self.meta.metaData();
    }
    pub fn hasVulkan(_: *@This()) bool {
        return true;
    }

    fn run(fs: *FakeFs, meta: renderer.MetaRead, version: ?i64) renderer.Decision {
        var q: LaunchQuery = .{ .fs = fs, .meta = meta, .version = version };
        return renderer.decide(&q);
    }
};

test "a failed meta-data read preserves the marks; the next good read is still guarded" {
    const R = LaunchQuery.renderer;
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vulkan");
    fs.set(start_file, "1 vulkan"); // a leftover start mark too

    // Launch with a JNI read error: gles for this launch, marks untouched.
    const d1 = LaunchQuery.run(&fs, .read_error, 1);
    try testing.expectEqual(R.Renderer.gles, d1.renderer);
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);
    try testing.expectEqualStrings("1 vulkan", fs.start.?);

    // Next launch reads the ORIGINAL setting: still disabled by the guard.
    const d2 = LaunchQuery.run(&fs, .{ .value = "vulkan" }, 1);
    try testing.expectEqual(R.Renderer.gles, d2.renderer);
    try testing.expectEqual(R.Source.crash_guard, d2.source);
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);
}

test "a failed meta-data read also keeps a pending start mark for the next good read" {
    const R = LaunchQuery.renderer;
    var fs: FakeFs = .{};
    fs.set(start_file, "1 auto"); // crashed on an auto-chosen Vulkan
    _ = LaunchQuery.run(&fs, .read_error, 1);
    try testing.expectEqualStrings("1 auto", fs.start.?);
    try testing.expect(fs.disabled == null);
    const d = LaunchQuery.run(&fs, .{ .value = "auto" }, 1);
    try testing.expectEqual(R.Source.crash_guard, d.source);
    try testing.expectEqualStrings("1 auto", fs.disabled.?);
}

test "a failed versionCode read preserves the marks; the next good read is still guarded" {
    const R = LaunchQuery.renderer;
    var fs: FakeFs = .{};
    fs.set(disabled_file, "42 vulkan");

    // versionCode unreadable: guarded this launch, marks untouched.
    const d1 = LaunchQuery.run(&fs, .{ .value = "vulkan" }, null);
    try testing.expectEqual(R.Renderer.gles, d1.renderer);
    try testing.expectEqual(R.Source.crash_guard, d1.source);
    try testing.expectEqualStrings("42 vulkan", fs.disabled.?);

    const d2 = LaunchQuery.run(&fs, .{ .value = "vulkan" }, 42);
    try testing.expectEqual(R.Source.crash_guard, d2.source);
    try testing.expectEqualStrings("42 vulkan", fs.disabled.?);

    // Same for a pending start mark.
    var fs2: FakeFs = .{};
    fs2.set(start_file, "42 vulkan");
    try testing.expect(checkNew(&fs2, .{ .version_code = null, .setting = "vulkan" }));
    try testing.expectEqualStrings("42 vulkan", fs2.start.?);
    try testing.expect(fs2.disabled == null);
    const d3 = LaunchQuery.run(&fs2, .{ .value = "vulkan" }, 42);
    try testing.expectEqual(R.Source.crash_guard, d3.source);
    try testing.expectEqualStrings("42 vulkan", fs2.disabled.?);
}

test "an observed change still resets even when the OTHER half is unreadable" {
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vulkan");
    // A successfully read new version, setting unreadable: a real change.
    try testing.expect(!checkNew(&fs, .{ .version_code = 2, .setting = null }));
    try testing.expect(fs.disabled == null);
    fs.set(disabled_file, "1 vulkan");
    // A successfully read different setting, version unreadable.
    try testing.expect(!checkNew(&fs, .{ .version_code = null, .setting = "gles" }));
    try testing.expect(fs.disabled == null);
}

test "an absent key is a successful read of the default gles: a real change vs a vulkan stamp" {
    const R = LaunchQuery.renderer;
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vulkan");
    fs.set(start_file, "1 vulkan");
    const d = LaunchQuery.run(&fs, .absent, 1);
    try testing.expectEqual(R.Renderer.gles, d.renderer);
    try testing.expectEqual(R.Source.setting, d.source); // not the guard
    try testing.expect(fs.disabled == null and fs.start == null); // reset
}

// ── Codex bot findings on labelle-android#33 (final round) ─────────────

test "same-process relaunch before stable supersedes its own mark (no disable)" {
    var fs: FakeFs = .{};
    var state: StartState = .{}; // ONE process
    try testing.expect(!checkObserved(&fs, Observed.of(v1_vulkan), &state));
    try testing.expect(beginStart(&fs, v1_vulkan, &state, NoFrames{}, NoSpawner{}));
    const first = state.generation;
    try testing.expect(state.owned);

    // The Activity is relaunched in the same process 3 s later: its own live
    // mark is not a crash.
    try testing.expect(!checkObserved(&fs, Observed.of(v1_vulkan), &state));
    try testing.expect(fs.disabled == null);
    try testing.expectEqualStrings("1 vulkan", fs.start.?);
    // It supersedes: new generation, new mark.
    try testing.expect(beginStart(&fs, v1_vulkan, &state, NoFrames{}, NoSpawner{}));
    try testing.expectEqual(first + 1, state.generation);

    // The old timer, even when stable, cannot delete the new mark.
    var clock: FakeClock = .{};
    var frames: FakeFrames = .{ .clock = &clock };
    settle(&fs, &clock, &frames, &state, first, null);
    try testing.expectEqualStrings("1 vulkan", fs.start.?);
    try testing.expect(state.owned);
    // The new one can, and gives up ownership.
    var clock2: FakeClock = .{};
    var frames2: FakeFrames = .{ .clock = &clock2 };
    settle(&fs, &clock2, &frames2, &state, first + 1, null);
    try testing.expect(fs.start == null);
    try testing.expect(!state.owned);
}

test "a mark left by a different (dead) process is still a crash" {
    var fs: FakeFs = .{};
    var dead: StartState = .{};
    try testing.expect(beginStart(&fs, v1_vulkan, &dead, NoFrames{}, NoSpawner{}));
    // The process dies; a NEW process (fresh state) launches.
    var next: StartState = .{};
    try testing.expect(checkObserved(&fs, Observed.of(v1_vulkan), &next));
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);
    try testing.expect(fs.start == null);
}

test "frame baseline: a hung new start is not cleared by the previous Activity's frames" {
    var fs: FakeFs = .{};
    var state: StartState = .{};
    var clock: FakeClock = .{ .dies_at_ns = 60 * std.time.ns_per_s };
    // The previous Activity presented 600 frames; the new init hangs, so the
    // counter stays at 600 (never reset).
    var frames: FakeFrames = .{ .clock = &clock, .init_done_ns = null, .before_init = 600 };
    var got: ?u32 = null;
    var baseline: ?u64 = null;
    try testing.expect(beginStart(&fs, v1_vulkan, &state, &frames, RecordingSpawner{ .got = &got, .baseline = &baseline }));
    try testing.expectEqual(@as(?u64, 600), baseline);
    settle(&fs, &clock, &frames, &state, got.?, baseline);
    try testing.expect(clock.now_ns >= stable_after_ns);
    try testing.expect(fs.start != null); // not cleared: the process is killed with the mark
}

test "frame baseline: a counter reset by the new init counts from 0" {
    var fs: FakeFs = .{};
    var state: StartState = .{};
    var clock: FakeClock = .{};
    // 600 old frames; the new init completes at 1 s (counter → 0), then 60 fps.
    var frames: FakeFrames = .{ .clock = &clock, .init_done_ns = std.time.ns_per_s, .before_init = 600 };
    var got: ?u32 = null;
    var baseline: ?u64 = null;
    try testing.expect(beginStart(&fs, v1_vulkan, &state, &frames, RecordingSpawner{ .got = &got, .baseline = &baseline }));
    settle(&fs, &clock, &frames, &state, got.?, baseline);
    try testing.expect(fs.start == null);
    try testing.expectEqual(stable_after_ns, clock.now_ns); // 540 new frames by then

    // framesSince itself: under the baseline = reset (sticky), else the delta.
    var b: ?u64 = 600;
    try testing.expectEqual(@as(u64, 0), framesSince(600, &b));
    try testing.expectEqual(@as(u64, 10), framesSince(610, &b));
    try testing.expectEqual(@as(u64, 5), framesSince(5, &b));
    try testing.expectEqual(@as(?u64, 0), b);
    try testing.expectEqual(@as(u64, 700), framesSince(700, &b));
    var none: ?u64 = null;
    try testing.expectEqual(@as(u64, 42), framesSince(42, &none));
}

test "a version change deletes only the mismatching marker; a matching start mark still counts" {
    // v1 disabled (stale); an intent launch on v2 wrote a v2 start mark and
    // crashed. The next ordinary v2 launch must still be guarded.
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vulkan");
    fs.set(start_file, "2 vulkan");
    try testing.expect(checkAtLaunch(&fs, v2_vulkan));
    try testing.expectEqualStrings("2 vulkan", fs.disabled.?); // rewritten for v2
    try testing.expect(fs.start == null);

    // A stale start mark with a still-matching disabled mark: only the start
    // mark goes.
    var fs2: FakeFs = .{};
    fs2.set(disabled_file, "2 vulkan");
    fs2.set(start_file, "1 vulkan");
    try testing.expect(checkAtLaunch(&fs2, v2_vulkan));
    try testing.expectEqualStrings("2 vulkan", fs2.disabled.?);
    try testing.expect(fs2.start == null);
}

test "a malformed disabled mark keeps the guard and does not lose a kept start mark" {
    var fs: FakeFs = .{};
    fs.set(disabled_file, "1 vul"); // a partial write from an older build
    fs.set(start_file, "1 vulkan");
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?); // rewritten
    try testing.expect(checkAtLaunch(&fs, v1_vulkan)); // and stays guarded
}

test "atomic writes: a partial disabled write leaves no malformed marker" {
    var fs: FakeFs = .{};
    fs.set(start_file, "1 vulkan");
    fs.partial_writes = true; // ENOSPC mid-write
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expect(fs.disabled == null); // never a truncated marker
    try testing.expect(fs.disabled_tmp == null); // the tmp is cleaned up
    try testing.expectEqualStrings("1 vulkan", fs.start.?); // kept (fail closed)
    // Space comes back: the next launch converts it.
    fs.partial_writes = false;
    try testing.expect(checkAtLaunch(&fs, v1_vulkan));
    try testing.expectEqualStrings("1 vulkan", fs.disabled.?);
    try testing.expect(fs.start == null);
}

test "a start mark that cannot be written falls back to gles (unless the intent asked)" {
    const R = @import("renderer.zig");
    var fs: FakeFs = .{};
    var state: StartState = .{};
    fs.partial_writes = true;
    var calls: usize = 0;
    const CountingSpawner = struct {
        calls: *usize,
        pub fn spawn(self: @This(), _: u32, _: ?u64) error{}!void {
            self.calls.* += 1;
        }
    };
    const recorded = beginStart(&fs, v1_vulkan, &state, NoFrames{}, CountingSpawner{ .calls = &calls });
    try testing.expect(!recorded);
    try testing.expect(fs.start == null and fs.start_tmp == null);
    try testing.expectEqual(@as(usize, 0), calls); // no timer for no mark
    try testing.expect(!state.owned);

    const d = R.afterStart(.{ .renderer = .vulkan, .source = .setting }, recorded);
    try testing.expectEqual(R.Renderer.gles, d.renderer);
    try testing.expectEqual(R.Source.crash_guard_unrecorded, d.source);
    const a = R.afterStart(.{ .renderer = .vulkan, .source = .auto }, recorded);
    try testing.expectEqual(R.Renderer.gles, a.renderer);
    // The intent override keeps Vulkan; a recorded start changes nothing.
    const i = R.afterStart(.{ .renderer = .vulkan, .source = .intent }, recorded);
    try testing.expectEqual(R.Renderer.vulkan, i.renderer);
    const ok = R.afterStart(.{ .renderer = .vulkan, .source = .setting }, true);
    try testing.expectEqual(R.Renderer.vulkan, ok.renderer);
    try testing.expectEqual(R.Source.setting, ok.source);
}
