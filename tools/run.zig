//! Install a packaged APK and launch its NativeActivity (ported from
//! labelle-cli `src/cli/android/run.zig`, development 23aa180;
//! labelle-cli#405). Used by the `deploy` hook that replaces `labelle run`
//! and by `labelle android run`. Neither builds nor packages: the APK is
//! the one the `package` hook produced.
//!
//! The launch returns once `am start` does (D7): the app keeps running on
//! the device, exactly as the CLI's own Android launch did.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const sdk = @import("sdk.zig");
const proc = @import("proc.zig");

pub const Launch = struct {
    apk: []const u8,
    package_name: []const u8,
    /// `-s <serial>`; null leaves device choice to adb (`ANDROID_SERIAL`,
    /// or the one attached device).
    device: ?[]const u8 = null,
    /// Handed to the app as `--es <name> <value>` intent extras.
    extras: []const contract.RunEnv = &.{},
};

/// The NativeActivity component of `package_name`.
pub fn activity(a: std.mem.Allocator, package_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/android.app.NativeActivity", .{package_name});
}

/// `adb [-s serial] install -r <apk>`, then `adb [-s serial] shell am start
/// -S -n <activity> [--es K V]...`. `a` should be an arena.
pub fn installAndLaunch(a: std.mem.Allocator, io: std.Io, env: *const sdk.Env, launch: Launch) !void {
    const adb = try findAdb(a, io, env);
    const prefix: []const []const u8 = if (launch.device) |serial| &.{ adb, "-s", serial } else &.{adb};

    std.debug.print("labelle-android: installing {s} on device...\n", .{launch.apk});
    {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, prefix);
        try argv.appendSlice(a, &.{ "install", "-r", launch.apk });
        const result = proc.run(a, io, argv.items, .{}) catch |err| {
            std.debug.print("labelle-android: adb install failed to start: {s}\n", .{@errorName(err)});
            return error.InstallFailed;
        };
        if (!proc.succeeded(result.term)) {
            std.debug.print("labelle-android: adb install failed: {s}{s}\n", .{ result.stdout, result.stderr });
            return error.InstallFailed;
        }
    }

    const component = try activity(a, launch.package_name);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, prefix);
    try argv.appendSlice(a, try amStartArgs(a, component, launch.extras));
    std.debug.print("labelle-android: launching...\n", .{});
    for (launch.extras) |kv| std.debug.print("labelle-android: intent extra {s}={s}\n", .{ kv.name, kv.value });
    const result = proc.run(a, io, argv.items, .{}) catch |err| {
        std.debug.print("labelle-android: adb launch failed to start: {s}\n", .{@errorName(err)});
        return error.LaunchFailed;
    };
    if (!proc.succeeded(result.term)) {
        std.debug.print("labelle-android: launch failed: {s}{s}\n", .{ result.stdout, result.stderr });
        return error.LaunchFailed;
    }
    // `am start` reports an unknown component on stdout with exit 0.
    if (std.mem.indexOf(u8, result.stdout, "Error:") != null) {
        std.debug.print("labelle-android: launch failed: {s}\n", .{result.stdout});
        return error.LaunchFailed;
    }
    std.debug.print("labelle-android: app launched on device\n", .{});
}

/// The `adb` arguments that launch the NativeActivity:
/// `shell am start -S -n <activity> [--es <key> <value>]...`, one string
/// extra per `LABELLE_*` run option (cli#397). The Android runtime turns the
/// extras back into env vars before the game starts (labelle-android's
/// `intent_extras`); a runtime without that support ignores them. No extras
/// → the bare launch, so a previous run's options can never leak into this
/// one.
///
/// `-S` force-stops the app first, extras or not: the NativeActivity never
/// reads a new intent, so a plain `am start` on a running app only brings it
/// to the front and drops the extras (labelle-bgfx#140), and a stale running
/// app would also mask a freshly installed build.
///
/// `adb shell` joins its argv with spaces and hands the result to the
/// device's `sh`, so every value is single-quoted (`shellQuote`). Names are
/// contract-validated `[A-Za-z_][A-Za-z0-9_]*` and need no quoting.
pub fn amStartArgs(a: std.mem.Allocator, component: []const u8, extras: []const contract.RunEnv) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "shell", "am", "start", "-S", "-n", component });
    for (extras) |kv| {
        try args.appendSlice(a, &.{ "--es", kv.name, try shellQuote(a, kv.value) });
    }
    return args.items;
}

/// POSIX-`sh` single-quote `value`: wrap it in `'...'` and spell each
/// embedded `'` as `'\''`. Nothing is special inside single quotes, so the
/// remote shell yields `value` byte-for-byte.
pub fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

/// `adb` under the SDK's platform-tools, else on PATH, whether or not an
/// SDK home is set (a minimal SDK with a Homebrew/apt `adb` is common).
pub fn findAdb(a: std.mem.Allocator, io: std.Io, env: *const sdk.Env) ![]const u8 {
    if (sdk.findSdkHome(env)) |home| {
        if (try sdk.findAdbUnder(a, io, env, home)) |adb| return adb;
    }
    if (try sdk.findOnPath(a, io, env, "adb")) |adb| return adb;
    std.debug.print("labelle-android: adb not found: set ANDROID_HOME or add adb to PATH\n", .{});
    return error.AdbNotFound;
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn expectArgs(expected: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectEqualStrings(e, g);
}

const component_under_test = "com.example.game/android.app.NativeActivity";

test "amStartArgs: no run options → the bare launch, no extras" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try amStartArgs(arena.allocator(), component_under_test, &.{});
    try expectArgs(&.{ "shell", "am", "start", "-S", "-n", component_under_test }, got);
}

test "amStartArgs: every run.env pair becomes one quoted --es extra, in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // What the CLI puts in `run.env` for `--scene=big_colony --profile
    // --screenshot=/sdcard/shot.png --after=2.5s` (runner.appendRunOptionEnv).
    const env = [_]contract.RunEnv{
        .{ .name = "LABELLE_SCENE", .value = "big_colony" },
        .{ .name = "LABELLE_PROFILE", .value = "1" },
        .{ .name = "LABELLE_SCREENSHOT_PATH", .value = "/sdcard/shot.png" },
        .{ .name = "LABELLE_SCREENSHOT_AFTER_SEC", .value = "2.500" },
    };
    const got = try amStartArgs(arena.allocator(), component_under_test, &env);
    try expectArgs(&.{
        "shell", "am",                      "start",              "-S",   "-n",                           component_under_test,
        "--es",  "LABELLE_SCENE",           "'big_colony'",       "--es", "LABELLE_PROFILE",              "'1'",
        "--es",  "LABELLE_SCREENSHOT_PATH", "'/sdcard/shot.png'", "--es", "LABELLE_SCREENSHOT_AFTER_SEC", "'2.500'",
    }, got);
}

test "shellQuote: shell-unsafe values are single-quoted" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "big_colony", "'big_colony'" },
        .{ "my scene", "'my scene'" },
        .{ "x; reboot", "'x; reboot'" },
        .{ "$(id) `id` $HOME", "'$(id) `id` $HOME'" },
        .{ "it's", "'it'\\''s'" },
        .{ "", "''" },
    };
    for (cases) |c| {
        const got = try shellQuote(a, c[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "shellQuote: a real sh reads every quoted value back verbatim" {
    // `adb shell` joins argv with spaces and runs it through the device's
    // `sh`; reproduce that join against the host's POSIX sh.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const values = [_][]const u8{ "my scene", "x; echo INJECTED", "$(echo INJECTED)", "`echo INJECTED`", "it's \"q\"", "a\\b|c&d>e" };
    for (values) |v| {
        const quoted = try shellQuote(a, v);
        defer a.free(quoted);
        const script = try std.fmt.allocPrint(a, "printf '[%s]' {s}", .{quoted});
        defer a.free(script);
        const result = try proc.run(a, std.testing.io, &.{ "/bin/sh", "-c", script }, .{});
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        try std.testing.expect(proc.succeeded(result.term));
        const want = try std.fmt.allocPrint(a, "[{s}]", .{v});
        defer a.free(want);
        try std.testing.expectEqualStrings(want, result.stdout);
    }
}

test "findAdb: platform-tools first; no SDK and no PATH is AdbNotFound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var env = sdk.Env.init(a);
    try std.testing.expectError(error.AdbNotFound, findAdb(a, std.testing.io, &env));
    const name = if (builtin.os.tag == .windows) "adb.exe" else "adb";
    try tmp.dir.createDirPath(std.testing.io, "platform-tools");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ "platform-tools", name }), .data = "" });
    try env.put("ANDROID_HOME", root);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "platform-tools", name }), try findAdb(a, std.testing.io, &env));
}

test "findAdb: an SDK home without platform-tools/adb falls back to PATH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const name = if (builtin.os.tag == .windows) "adb.exe" else "adb";
    // A fake SDK with platform-tools/ but no adb in it...
    try tmp.dir.createDirPath(std.testing.io, "sdk/platform-tools");
    // ...and an adb on a fake PATH.
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ "bin", name }), .data = "" });
    var env = sdk.Env.init(a);
    try env.put("ANDROID_HOME", try std.fs.path.join(a, &.{ root, "sdk" }));
    try std.testing.expectError(error.AdbNotFound, findAdb(a, std.testing.io, &env));
    try env.put("PATH", try std.fs.path.join(a, &.{ root, "bin" }));
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "bin", name }), try findAdb(a, std.testing.io, &env));
}
