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
const std = @import("std");
const is_android = @import("root.zig").is_android;

/// Declared unconditionally (extern decls are only linked when referenced) so
/// the non-Android path below folds away without a comptime block around it.
extern "c" fn labelle_android_app_is_debuggable(activity: ?*const anyopaque) c_int;

/// The process-wide cache's three states. `unknown` = no real answer yet.
pub const State = enum(u8) { unknown = 0, no = 1, yes = 2 };

/// Cache: the flag cannot change for the life of the process, and every
/// activity of the process is the same package, so the first answer holds
/// for all of them.
///
/// Accessed ONLY through `@atomicLoad` / `@cmpxchgStrong` (`resolve`):
/// `isDebuggable` is callable from any thread and two first calls may race
/// (bgfx's glue thread vs. the UI thread). Memory ordering: the byte itself
/// is the whole payload — nothing else is published alongside it — so
/// `.monotonic` would already be race-free; `.acquire` on the read and
/// `.acq_rel` on the settling cmpxchg are the conventional once-init pairing,
/// keep any later reader from observing the JNI walk's side effects out of
/// order, and cost nothing on a byte.
var state: State = .unknown;

/// Fails CLOSED: no activity, no VM, or any JNI failure answers `false`. A
/// verification aid that cannot prove it is allowed must stay off. `activity`
/// is the running `ANativeActivity*` (opaque; the C side reads `->vm` /
/// `->clazz`). Callable from any thread: the JNI half attaches the calling
/// thread if it is not already, and detaches only what it attached.
pub fn isDebuggable(activity: ?*const anyopaque) bool {
    // `comptime` so the extern is not even referenced off Android, where the C
    // TU compiles to an empty object and the symbol does not exist.
    if (comptime !is_android) return false;
    return resolve(&state, activity, jniAnswer);
}

/// The real answer: the JNI walk in `jni/debuggable.c`. Only ever referenced
/// from the Android branch of `isDebuggable`, so never analysed on the host.
fn jniAnswer(activity: *const anyopaque) bool {
    return labelle_android_app_is_debuggable(activity) != 0;
}

/// The cache mechanism, split from the JNI answer so a HOST test can drive it
/// with a fake `answer` (the JNI walk only exists on Android).
///
///   * `st` already settled → that answer, `answer` is not called.
///   * null `activity` (asked too early) → false and NOT cached: the next
///     call with a real activity still asks. Only a REAL answer settles `st`.
///   * otherwise ask once and settle `st` with a single cmpxchg from
///     `unknown`. If another thread settled it first (both raced past the
///     load), THEIR answer stands and is what this call returns too, so every
///     caller after the first store sees the same value — even when one of
///     the racing JNI walks failed (fail-closed `false`) and the other did not.
fn resolve(st: *State, activity: ?*const anyopaque, comptime answer: fn (*const anyopaque) bool) bool {
    switch (@atomicLoad(State, st, .acquire)) {
        .no => return false,
        .yes => return true,
        .unknown => {},
    }
    const a = activity orelse return false; // asked too early: not cached
    const mine: State = if (answer(a)) .yes else .no;
    if (@cmpxchgStrong(State, st, .unknown, mine, .acq_rel, .acquire)) |theirs| {
        return theirs == .yes;
    }
    return mine == .yes;
}

test "isDebuggable is false off Android, whatever the pointer" {
    if (comptime is_android) return error.SkipZigTest;
    try std.testing.expect(!isDebuggable(null));
    try std.testing.expect(!isDebuggable(@ptrFromInt(0x1000)));
    try std.testing.expect(@atomicLoad(State, &state, .acquire) == .unknown);
}

// Host test double for `resolve`: counts the calls and answers a scripted
// value, so the tests can assert WHICH path answered (the cache, the fake, or
// the null fallback) rather than just the value.
const Fake = struct {
    var calls: usize = 0;
    var says: bool = true;
    /// The state `hijack` writes into mid-answer, simulating another thread's
    /// store landing while this thread is inside its JNI walk.
    var hijack: ?*State = null;

    fn answer(_: *const anyopaque) bool {
        // Atomic: the concurrency test calls this from several threads.
        _ = @atomicRmw(usize, &calls, .Add, 1, .monotonic);
        if (hijack) |h| @atomicStore(State, h, .no, .release);
        return says;
    }
    fn reset() void {
        calls = 0;
        says = true;
        hijack = null;
    }
};

const some_activity: *const anyopaque = @ptrFromInt(0x1000);

test "resolve: a null activity answers false and is NOT cached" {
    Fake.reset();
    var st: State = .unknown;
    try std.testing.expect(!resolve(&st, null, Fake.answer));
    try std.testing.expectEqual(State.unknown, st);
    try std.testing.expectEqual(@as(usize, 0), Fake.calls);
    // The next call with a real activity still asks.
    try std.testing.expect(resolve(&st, some_activity, Fake.answer));
    try std.testing.expectEqual(State.yes, st);
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
}

test "resolve: only a real answer settles the cache, and then nobody asks again" {
    Fake.reset();
    var st: State = .unknown;
    try std.testing.expect(resolve(&st, some_activity, Fake.answer));
    try std.testing.expectEqual(State.yes, st);
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    // Cached path: even a null activity now gets the cached `true` (the null
    // fallback would say false), and the fake is not consulted.
    try std.testing.expect(resolve(&st, null, Fake.answer));
    try std.testing.expect(resolve(&st, some_activity, Fake.answer));
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
}

test "resolve: a fail-closed false is cached too" {
    Fake.reset();
    Fake.says = false;
    var st: State = .unknown;
    try std.testing.expect(!resolve(&st, some_activity, Fake.answer));
    try std.testing.expectEqual(State.no, st);
    Fake.says = true; // a later "true" must not be consulted: the cache holds
    try std.testing.expect(!resolve(&st, some_activity, Fake.answer));
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
}

test "resolve: when another thread settles the cache first, its answer stands for everyone" {
    Fake.reset();
    var st: State = .unknown;
    // Our JNI walk says `true`, but "another thread" stores `no` while we are
    // inside it: the cmpxchg loses, and we adopt the landed answer instead of
    // returning ours, so this call and every later one agree.
    Fake.hijack = &st;
    try std.testing.expect(!resolve(&st, some_activity, Fake.answer));
    try std.testing.expectEqual(State.no, st);
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    Fake.hijack = null;
    try std.testing.expect(!resolve(&st, some_activity, Fake.answer));
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
}

test "resolve: concurrent first calls all agree and the cache settles once" {
    Fake.reset();
    var st: State = .unknown;
    const Worker = struct {
        fn run(s: *State, out: *bool) void {
            out.* = resolve(s, some_activity, Fake.answer);
        }
    };
    var results: [8]bool = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, &results) |*t, *r| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &st, r });
    for (threads) |t| t.join();
    for (results) |r| try std.testing.expect(r);
    try std.testing.expectEqual(State.yes, st);
    // Several workers may have raced past the load and asked; at least one
    // did, and once settled nobody asks again.
    const before = Fake.calls;
    try std.testing.expect(before >= 1);
    try std.testing.expect(resolve(&st, some_activity, Fake.answer));
    try std.testing.expectEqual(before, Fake.calls);
}
