/// Launch-intent extras → environment variables: the PURE half.
///
/// The one canonical copy of what labelle-bgfx (`android_intent_env.zig`,
/// labelle-bgfx#139) and labelle-sokol (labelle-sokol#25) each carried; the
/// allow-list, the debuggable gate and the per-key decision are identical on
/// both Android backends, so they live here (labelle-bgfx#149). This is the
/// sokol superset: it keeps the failed-`setenv` retry the bgfx copy lacked.
///
/// The engine reads its run options from the environment at startup —
/// `engine.requestedScene()` (`LABELLE_SCENE`), the screenshot request
/// (`LABELLE_SCREENSHOT_PATH` / `_AFTER_SEC`) and the profiler gate
/// (`LABELLE_PROFILE`). An activity the system starts has none of them, so
/// `labelle run --platform=android` passes them as intent extras instead
/// (`am start ... --es LABELLE_SCENE X`, labelle-cli#397) and the shell copies
/// them back into the environment before the game's first `getenv`.
///
/// This file has no Android dependency so it runs as a HOST unit test; the
/// JNI read is `jni/intent_extras.c`, the driver `launch_intent.zig`.
const std = @import("std");

pub const Key = struct {
    name: [:0]const u8,
    /// Honoured only when the running apk is `android:debuggable`.
    ///
    /// The NativeActivity is exported (it has the launcher intent filter), so
    /// ANY app on the device can start it with extras. A scene choice or the
    /// profiler switch is harmless, but a screenshot path is a write: an
    /// absolute one would let another app make a release build overwrite its
    /// own private files (saves, prefs). That is exactly what the
    /// `labelle_env` knob file gates on `isDebuggable()` (labelle-assembler
    /// #737), so the extras follow the same rule.
    debuggable_only: bool,
};

/// The ALLOW-LIST. Nothing else in the intent is ever copied: an arbitrary
/// extra must not be able to set `LD_PRELOAD` or a backend knob.
pub const keys = [_]Key{
    .{ .name = "LABELLE_SCENE", .debuggable_only = false },
    .{ .name = "LABELLE_PROFILE", .debuggable_only = false },
    .{ .name = "LABELLE_SCREENSHOT_PATH", .debuggable_only = true },
    .{ .name = "LABELLE_SCREENSHOT_AFTER_SEC", .debuggable_only = true },
};

/// Is `name` one of the keys copied from the intent?
pub fn isAllowed(name: []const u8) bool {
    for (keys) |k| {
        if (std.mem.eql(u8, k.name, name)) return true;
    }
    return false;
}

pub const Action = union(enum) {
    /// `setenv(name, value, 1)`.
    set: [:0]const u8,
    /// Undo what an earlier launch of this process set: restore the value
    /// the environment had before it, or `unsetenv` if there was none.
    revert,
    /// Leave the environment alone.
    keep,
};

/// Decide what one key does, given its extra (null = absent) and whether an
/// earlier launch in this process already set it from an intent.
///
/// The `revert` case matters because Android can keep the process alive after
/// the activity is destroyed; a relaunch then reuses the old environment, and
/// a plain launch after `--scene=X` would boot X again. Only what we set is
/// undone, back to the value from the real environment (`wrap.<package>`) if
/// there was one. An empty extra counts as absent, as it does for
/// `requestedScene()`.
pub fn action(key: Key, extra: ?[:0]const u8, debuggable: bool, set_by_intent: bool) Action {
    if (extra) |v| {
        if (v.len > 0 and (!key.debuggable_only or debuggable)) return .{ .set = v };
    }
    return if (set_by_intent) .revert else .keep;
}

/// Longest pre-existing value `State` can save for a later `revert`. Longer
/// ones are never overridden (see `apply`), so they are never lost either.
pub const max_original_len = 511;

/// Which keys this process has set from an intent so far (see `action`), and
/// what each held before the first of those launches overrode it.
pub const State = struct {
    set_by_intent: [keys.len]bool = @splat(false),
    /// Length of the saved pre-intent value, or null if the key was unset.
    original_len: [keys.len]?usize = @splat(null),
    original_buf: [keys.len][max_original_len + 1]u8 = undefined,

    fn original(self: *const State, i: usize) ?[:0]const u8 {
        const len = self.original_len[i] orelse return null;
        return self.original_buf[i][0..len :0];
    }
};

/// Apply one launch's extras (`extras[i]` belongs to `keys[i]`). `env`
/// provides `get(name) ?[:0]const u8`, `set(name, value) bool`, `unset(name)
/// void` and `debuggable() bool`; the last is asked only when a
/// debuggable-only key is present, so a plain launch costs no JNI round-trip
/// for it.
pub fn apply(state: *State, extras: [keys.len]?[:0]const u8, env: anytype) void {
    var debuggable: ?bool = null;
    for (keys, extras, 0..) |key, extra, i| {
        const allowed = if (key.debuggable_only and extra != null) blk: {
            if (debuggable == null) debuggable = env.debuggable();
            break :blk debuggable.?;
        } else false;
        switch (action(key, extra, allowed, state.set_by_intent[i])) {
            .set => |v| {
                // First override in this process: save what the environment
                // had, so a later launch without the extra can put it back.
                if (!state.set_by_intent[i]) {
                    state.original_len[i] = null;
                    if (env.get(key.name)) |orig| {
                        if (orig.len > max_original_len) {
                            std.log.info("android: keeping {s} from the environment (too long to save); intent extra ignored", .{key.name});
                            continue;
                        }
                        @memcpy(state.original_buf[i][0..orig.len], orig);
                        state.original_buf[i][orig.len] = 0;
                        state.original_len[i] = orig.len;
                    }
                }
                if (env.set(key.name, v)) {
                    state.set_by_intent[i] = true;
                    std.log.info("android: {s}={s} (launch intent extra)", .{ key.name, v });
                }
            },
            .revert => {
                if (state.original(i)) |orig| {
                    if (!env.set(key.name, orig)) {
                        // Keep the ownership flag so the next launch retries
                        // the restore instead of leaving the intent value.
                        std.log.warn("android: could not restore {s}; will retry on the next launch", .{key.name});
                        continue;
                    }
                    std.log.info("android: {s} restored to {s} (set by a previous launch's intent)", .{ key.name, orig });
                } else {
                    env.unset(key.name);
                    std.log.info("android: {s} cleared (set by a previous launch's intent)", .{key.name});
                }
                state.set_by_intent[i] = false;
            },
            .keep => if (extra != null and key.debuggable_only and !allowed and extra.?.len > 0) {
                std.log.info("android: ignoring intent extra {s}: the apk is not debuggable", .{key.name});
            },
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// Fake environment: records calls instead of touching the real one.
const FakeEnv = struct {
    vars: [keys.len]?[:0]const u8 = @splat(null),
    is_debuggable: bool = false,
    debuggable_calls: usize = 0,
    /// When true, `set` fails (as a real `setenv` can on ENOMEM).
    fail_set: bool = false,

    fn index(name: [:0]const u8) usize {
        for (keys, 0..) |k, i| {
            if (std.mem.eql(u8, k.name, name)) return i;
        }
        unreachable; // apply() only ever names allow-listed keys
    }
    pub fn set(self: *FakeEnv, name: [:0]const u8, value: [:0]const u8) bool {
        if (self.fail_set) return false;
        self.vars[index(name)] = value;
        return true;
    }
    pub fn unset(self: *FakeEnv, name: [:0]const u8) void {
        self.vars[index(name)] = null;
    }
    pub fn get(self: *const FakeEnv, name: [:0]const u8) ?[:0]const u8 {
        return self.vars[index(name)];
    }
    pub fn debuggable(self: *FakeEnv) bool {
        self.debuggable_calls += 1;
        return self.is_debuggable;
    }
};

fn extrasWith(pairs: []const struct { [:0]const u8, [:0]const u8 }) [keys.len]?[:0]const u8 {
    var out: [keys.len]?[:0]const u8 = @splat(null);
    for (pairs) |p| out[FakeEnv.index(p[0])] = p[1];
    return out;
}

test "the allow-list is exactly the four run-option keys" {
    try testing.expect(isAllowed("LABELLE_SCENE"));
    try testing.expect(isAllowed("LABELLE_PROFILE"));
    try testing.expect(isAllowed("LABELLE_SCREENSHOT_PATH"));
    try testing.expect(isAllowed("LABELLE_SCREENSHOT_AFTER_SEC"));
    try testing.expectEqual(@as(usize, 4), keys.len);
    // Other labelle knobs and arbitrary env names are not copied.
    try testing.expect(!isAllowed("LABELLE_FIXED_DT"));
    try testing.expect(!isAllowed("LABELLE_BGFX_RENDERER"));
    try testing.expect(!isAllowed("LD_PRELOAD"));
    try testing.expect(!isAllowed("PATH"));
    // Exact match only: no prefix, case or whitespace slack.
    try testing.expect(!isAllowed("LABELLE_SCENE_X"));
    try testing.expect(!isAllowed("LABELLE_"));
    try testing.expect(!isAllowed("labelle_scene"));
    try testing.expect(!isAllowed(" LABELLE_SCENE"));
    try testing.expect(!isAllowed(""));
}

test "no extras (launcher icon) leaves the environment untouched" {
    var state: State = .{};
    var env: FakeEnv = .{};
    apply(&state, @splat(null), &env);
    for (env.vars) |v| try testing.expect(v == null);
    try testing.expectEqual(@as(usize, 0), env.debuggable_calls);
}

test "--scene sets LABELLE_SCENE on a release apk, without asking debuggable" {
    var state: State = .{};
    var env: FakeEnv = .{};
    apply(&state, extrasWith(&.{.{ "LABELLE_SCENE", "big_colony" }}), &env);
    try testing.expectEqualStrings("big_colony", env.get("LABELLE_SCENE").?);
    try testing.expect(env.get("LABELLE_PROFILE") == null);
    try testing.expectEqual(@as(usize, 0), env.debuggable_calls);
}

test "screenshot extras need a debuggable apk; debuggable is asked once" {
    const extras = extrasWith(&.{
        .{ "LABELLE_SCENE", "menu" },
        .{ "LABELLE_SCREENSHOT_PATH", "/data/data/x/files/prefs" },
        .{ "LABELLE_SCREENSHOT_AFTER_SEC", "2" },
    });

    var state: State = .{};
    var release: FakeEnv = .{ .is_debuggable = false };
    apply(&state, extras, &release);
    try testing.expectEqualStrings("menu", release.get("LABELLE_SCENE").?);
    try testing.expect(release.get("LABELLE_SCREENSHOT_PATH") == null);
    try testing.expect(release.get("LABELLE_SCREENSHOT_AFTER_SEC") == null);
    try testing.expectEqual(@as(usize, 1), release.debuggable_calls);

    var state2: State = .{};
    var debug: FakeEnv = .{ .is_debuggable = true };
    apply(&state2, extras, &debug);
    try testing.expectEqualStrings("/data/data/x/files/prefs", debug.get("LABELLE_SCREENSHOT_PATH").?);
    try testing.expectEqualStrings("2", debug.get("LABELLE_SCREENSHOT_AFTER_SEC").?);
    try testing.expectEqual(@as(usize, 1), debug.debuggable_calls);
}

test "an empty extra is treated as absent" {
    var state: State = .{};
    var env: FakeEnv = .{};
    apply(&state, extrasWith(&.{.{ "LABELLE_SCENE", "" }}), &env);
    try testing.expect(env.get("LABELLE_SCENE") == null);
}

test "a relaunch in the same process clears what the previous intent set" {
    var state: State = .{};
    var env: FakeEnv = .{};
    apply(&state, extrasWith(&.{ .{ "LABELLE_SCENE", "big_colony" }, .{ "LABELLE_PROFILE", "1" } }), &env);
    try testing.expectEqualStrings("big_colony", env.get("LABELLE_SCENE").?);

    // Plain relaunch: no stale scene or profiler from the last run.
    apply(&state, @splat(null), &env);
    try testing.expect(env.get("LABELLE_SCENE") == null);
    try testing.expect(env.get("LABELLE_PROFILE") == null);
    try testing.expect(!state.set_by_intent[0]);
}

test "a value from the real environment is never lost" {
    var state: State = .{};
    // Set through `wrap.<package>`, not by us.
    var env: FakeEnv = .{};
    env.vars[FakeEnv.index("LABELLE_PROFILE")] = "1";
    apply(&state, @splat(null), &env);
    try testing.expectEqualStrings("1", env.get("LABELLE_PROFILE").?);

    // An intent value does override it (the launch is the more specific ask)...
    apply(&state, extrasWith(&.{.{ "LABELLE_PROFILE", "0" }}), &env);
    try testing.expectEqualStrings("0", env.get("LABELLE_PROFILE").?);
    // ...a second override keeps the ORIGINAL saved, not the first override...
    apply(&state, extrasWith(&.{.{ "LABELLE_PROFILE", "2" }}), &env);
    try testing.expectEqualStrings("2", env.get("LABELLE_PROFILE").?);
    // ...and a launch without it restores the real value rather than unsetting.
    apply(&state, @splat(null), &env);
    try testing.expectEqualStrings("1", env.get("LABELLE_PROFILE").?);
    try testing.expect(!state.set_by_intent[FakeEnv.index("LABELLE_PROFILE")]);
}

test "a failed restore keeps ownership so the next launch retries it" {
    var state: State = .{};
    var env: FakeEnv = .{};
    env.vars[FakeEnv.index("LABELLE_PROFILE")] = "1"; // from the real environment
    apply(&state, extrasWith(&.{.{ "LABELLE_PROFILE", "0" }}), &env);
    try testing.expectEqualStrings("0", env.get("LABELLE_PROFILE").?);

    // Plain relaunch, but setenv fails: the intent value is still there and
    // the key must stay owned by the intent.
    env.fail_set = true;
    apply(&state, @splat(null), &env);
    try testing.expectEqualStrings("0", env.get("LABELLE_PROFILE").?);
    try testing.expect(state.set_by_intent[FakeEnv.index("LABELLE_PROFILE")]);

    // Next plain launch succeeds and restores the original.
    env.fail_set = false;
    apply(&state, @splat(null), &env);
    try testing.expectEqualStrings("1", env.get("LABELLE_PROFILE").?);
    try testing.expect(!state.set_by_intent[FakeEnv.index("LABELLE_PROFILE")]);
}

test "a real value too long to save is kept, not overridden" {
    var state: State = .{};
    var env: FakeEnv = .{};
    const long: [:0]const u8 = "x" ** (max_original_len + 1);
    env.vars[FakeEnv.index("LABELLE_SCENE")] = long;
    apply(&state, extrasWith(&.{.{ "LABELLE_SCENE", "menu" }}), &env);
    try testing.expectEqualStrings(long, env.get("LABELLE_SCENE").?);
    try testing.expect(!state.set_by_intent[FakeEnv.index("LABELLE_SCENE")]);
}

test "action: set / revert / keep" {
    const scene = keys[0];
    const shot = keys[2];
    try testing.expectEqualStrings("x", action(scene, "x", false, false).set);
    try testing.expectEqual(Action.keep, action(scene, null, false, false));
    try testing.expectEqual(Action.revert, action(scene, null, false, true));
    try testing.expectEqual(Action.keep, action(shot, "p", false, false));
    try testing.expectEqual(Action.revert, action(shot, "p", false, true));
    try testing.expectEqualStrings("p", action(shot, "p", true, false).set);
}
