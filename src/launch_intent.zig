//! Android launch-intent `LABELLE_*` extras → process env vars — the DRIVER.
//!
//! The engine reads its `labelle run` options from environment variables at
//! startup (`LABELLE_SCENE`, `LABELLE_SCREENSHOT_PATH` /
//! `LABELLE_SCREENSHOT_AFTER_SEC`, `LABELLE_PROFILE`). An Android app the system
//! starts has no such env, so the cli (labelle-cli#397) passes them as
//! launch-intent string extras (`am start … --es LABELLE_SCENE X`) and this
//! copies the allow-listed ones back into the environment. The engine, the
//! assembler and games stay unchanged — they keep reading `getenv`.
//!
//! Three pieces (labelle-bgfx#139 / labelle-sokol#25, now shared through this
//! package, labelle-bgfx#149):
//!   * `intent_env.zig` — the PURE half: the allow-list and the per-key
//!     decision (set / revert / keep, the debuggable gate). Host-tested.
//!   * `jni/intent_extras.c` — the JNI half: `getIntent().getStringExtra`.
//!   * this file — glue: libc `setenv`/`unsetenv` and the call order. The
//!     debuggable gate is `debuggable.zig`.
//!
//! ## Where it runs
//!
//! `apply(activity)` must run ONCE per activity launch, BEFORE anything reads
//! these vars, with the running `ANativeActivity*`:
//!   * bgfx: from the top of the shell's `run(app)` on the glue's app thread
//!     (unattached to the VM — the JNI half attaches for the call). The
//!     game's first `getenv` is in `init_fn`, fired on the first INIT_WINDOW,
//!     which only that loop delivers, so the env is complete first.
//!   * sokol: from the top of the generated `sokol_main()` on the UI thread
//!     (already attached), before the render thread that runs `init` exists.

const std = @import("std");
const intent_env = @import("intent_env.zig");
const debuggable_mod = @import("debuggable.zig");
const is_android = @import("root.zig").is_android;

// `jni/intent_extras.c` — only referenced on Android, where build.zig
// compiles the C TU into this module.
extern "c" fn labelle_android_read_intent_extras(
    activity: ?*const anyopaque,
    keys: [*]const [*:0]const u8,
    count: c_int,
    buf: [*]u8,
    buf_cap: usize,
    lens: [*]c_int,
) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Survives activity relaunches in a cached process, so a plain launch can
/// clear what a previous `--scene` launch set (see `intent_env.action`).
var state: intent_env.State = .{};
/// Backing store for the extras' values. `setenv` copies them, so it is only
/// needed for the duration of `apply`.
var buf: [4096]u8 = undefined;

const LibcEnv = struct {
    activity: ?*const anyopaque,

    pub fn get(_: LibcEnv, name: [:0]const u8) ?[:0]const u8 {
        return if (getenv(name.ptr)) |v| std.mem.span(v) else null;
    }
    pub fn set(_: LibcEnv, name: [:0]const u8, value: [:0]const u8) bool {
        return setenv(name.ptr, value.ptr, 1) == 0;
    }
    pub fn unset(_: LibcEnv, name: [:0]const u8) void {
        _ = unsetenv(name.ptr);
    }
    pub fn debuggable(self: LibcEnv) bool {
        return debuggable_mod.isDebuggable(self.activity);
    }
};

/// Copy the launch intent's allow-listed `LABELLE_*` string extras into the
/// process environment. `activity` is the running `ANativeActivity*`
/// (opaque; the C side reads `->vm` / `->clazz`). Comptime no-op off
/// Android; a null activity changes nothing. A launch with no extras (the
/// launcher icon) changes nothing except clearing values a previous intent
/// set — and so does a JNI failure: the read is reported and every key is
/// treated as absent, so an earlier launch's `--scene` cannot leak into this
/// one.
pub fn apply(activity: ?*const anyopaque) void {
    if (comptime !is_android) return;
    const a = activity orelse return;

    var names: [intent_env.keys.len][*:0]const u8 = undefined;
    for (intent_env.keys, 0..) |k, i| names[i] = k.name.ptr;
    var lens: [intent_env.keys.len]c_int = undefined;
    if (labelle_android_read_intent_extras(a, &names, names.len, &buf, buf.len, &lens) == 0) {
        std.log.warn("android: could not read the launch intent; LABELLE_* extras ignored", .{});
        // Still revert what an earlier launch's intent set in this process
        // (all-absent extras only ever revert/keep, never set).
        intent_env.apply(&state, @splat(null), LibcEnv{ .activity = a });
        return;
    }
    var extras: [intent_env.keys.len]?[:0]const u8 = @splat(null);
    var off: usize = 0;
    for (lens, 0..) |len, i| {
        if (len == -2) std.log.warn("android: intent extra {s} too long or contains a NUL; ignored", .{intent_env.keys[i].name});
        if (len < 0) continue;
        const n: usize = @intCast(len);
        extras[i] = buf[off .. off + n :0];
        off += n + 1;
    }
    intent_env.apply(&state, extras, LibcEnv{ .activity = a });
}

test "apply is a no-op off Android (and never touches the externs)" {
    if (comptime is_android) return error.SkipZigTest;
    apply(null);
    apply(@ptrFromInt(0x1000));
    try std.testing.expect(!state.set_by_intent[0]);
}
