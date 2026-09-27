//! What each packaging hook and command does, on top of the packager
//! (`package/`), the device launch (`run.zig`) and the release upload
//! (`deploy.zig`). `main.zig` has already decoded the context, routed it and
//! validated the settings; everything here may have side effects.
//!
//! Output layout (labelle-cli#405 D10), all under the generated target
//! directory `.labelle/<backend>_android/`:
//!
//!   zig-out/lib/libgame.so          the core build's output (input)
//!   zig-out/apk/game.apk            `package` hook, after every build
//!   zig-out/apk/symbols/<abi>/      the unstripped library of a release build
//!   zig-out/apk/package.json        what game.apk was packaged from
//!   zig-out/bundle/android/         `bundle` hook (or `--output`):
//!       <package>-<versionName>.apk, its size report and symbols
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const settings_mod = @import("settings.zig");
const identity_mod = @import("project_identity.zig");
const sdk = @import("sdk.zig");
const pkg = @import("package/package.zig");
const slim = @import("package/slim.zig");
const run_mod = @import("run.zig");
const deploy_mod = @import("deploy.zig");

pub const Context = struct {
    /// The invocation's arena.
    a: std.mem.Allocator,
    io: std.Io,
    env: *const sdk.Env,
    ctx: contract.Context,
    settings: settings_mod.Settings,
    /// The raw settings file, for the package record's digest.
    settings_bytes: []const u8,
    identity: identity_mod.Identity,
};

/// `zig-out/apk` under the target directory.
pub fn apkDir(a: std.mem.Allocator, target_dir: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ target_dir, "zig-out", "apk" });
}

pub const apk_name = "game.apk";
pub const record_name = "package.json";

/// Release optimize modes ship a stripped `libgame.so` (labelle-assembler#755).
pub fn stripFor(optimize: contract.Optimize) bool {
    return optimize != .Debug;
}

/// `staging-<pid>`: generator-owned scratch, unique per process.
fn stagingName(a: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const pid: u64 = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
    return std.fmt.allocPrint(a, ".{s}-{d}", .{ prefix, pid });
}

// ── build/after: package ──────────────────────────────────────────────────

/// Package `zig-out/apk/game.apk` from this build. The previous
/// `zig-out/apk/` is deleted first, so a failure leaves no APK: an older one
/// is never presented as this build's.
pub fn packageHook(c: Context) !void {
    const target_dir = c.ctx.target_dir orelse return error.MissingTargetDir;
    const dir = try apkDir(c.a, target_dir);
    std.Io.Dir.cwd().deleteTree(c.io, dir) catch {};
    const strip = stripFor(c.ctx.optimize);
    const tools = try pkg.findTools(c.a, c.io, c.env, c.settings.target_sdk_version, strip);
    const apk = try std.fs.path.join(c.a, &.{ dir, apk_name });
    try pkg.package(c.a, c.io, c.env, .{
        .project_dir = c.ctx.project_dir.?,
        .target_dir = target_dir,
        .settings = c.settings,
        .identity = c.identity,
        .strip = strip,
    }, .{
        .apk = apk,
        .staging = try std.fs.path.join(c.a, &.{ dir, try stagingName(c.a, "staging") }),
        .symbols = try std.fs.path.join(c.a, &.{ dir, "symbols" }),
    }, tools);
    _ = slim.printSizeReport(c.a, c.io, apk);
    try writeRecord(c, dir, target_dir);
    std.debug.print("labelle-android: APK ready: {s}\n", .{apk});
}

/// What `game.apk` was packaged from. The `deploy` hook checks it, so an
/// APK that no longer matches the built library is never installed.
pub const Record = struct {
    schema: u32 = 1,
    package_name: []const u8,
    version_code: u32,
    optimize: contract.Optimize,
    so_sha256: []const u8,
    settings_sha256: []const u8,
};

fn writeRecord(c: Context, dir: []const u8, target_dir: []const u8) !void {
    const record: Record = .{
        .package_name = c.settings.package_name,
        .version_code = 1,
        .optimize = c.ctx.optimize,
        .so_sha256 = try fileSha256(c.a, c.io, try pkg.soPath(c.a, target_dir)),
        .settings_sha256 = try hexSha256(c.a, c.settings_bytes),
    };
    const json = try std.json.Stringify.valueAlloc(c.a, record, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(c.io, .{
        .sub_path = try std.fs.path.join(c.a, &.{ dir, record_name }),
        .data = try std.fmt.allocPrint(c.a, "{s}\n", .{json}),
    });
}

fn hexSha256(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(a, "{x}", .{&digest});
}

fn fileSha256(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 30));
    defer a.free(bytes);
    return hexSha256(a, bytes);
}

/// The APK under `target_dir`, checked against its package record: it
/// exists, and the library it was packaged from is the one built now.
fn checkedApk(c: Context, target_dir: []const u8) ![]const u8 {
    const dir = try apkDir(c.a, target_dir);
    const apk = try std.fs.path.join(c.a, &.{ dir, apk_name });
    std.Io.Dir.cwd().access(c.io, apk, .{}) catch {
        std.debug.print("labelle-android: no APK at {s}: run `labelle build --platform=android` first\n", .{apk});
        return error.NoBuiltApk;
    };
    const raw = std.Io.Dir.cwd().readFileAlloc(c.io, try std.fs.path.join(c.a, &.{ dir, record_name }), c.a, .limited(64 * 1024)) catch {
        std.debug.print("labelle-android: {s} has no package record: rebuild with `labelle build --platform=android`\n", .{apk});
        return error.StaleApk;
    };
    const record = std.json.parseFromSliceLeaky(Record, c.a, raw, .{}) catch return error.StaleApk;
    const so_now = fileSha256(c.a, c.io, try pkg.soPath(c.a, target_dir)) catch return error.StaleApk;
    switch (staleness(record, so_now, try hexSha256(c.a, c.settings_bytes), c.settings.package_name)) {
        .fresh => return apk,
        .library => std.debug.print("labelle-android: {s} was packaged from an older libgame.so: rebuild with `labelle build --platform=android`\n", .{apk}),
        .settings => std.debug.print("labelle-android: {s} was packaged with different providers/android.json settings (package {s}, now {s}): rebuild with `labelle build --platform=android`\n", .{ apk, record.package_name, c.settings.package_name }),
    }
    return error.StaleApk;
}

pub const Staleness = enum { fresh, library, settings };

/// Whether the APK a package record describes is still what this build
/// would package: the same `libgame.so` and the same settings file (the
/// package name, label, SDK levels, signing... the APK was made with). An
/// APK packaged under an old `package_name` would install fine and then
/// fail to launch as the new one, so the settings are checked too.
pub fn staleness(record: Record, so_sha256: []const u8, settings_sha256: []const u8, package_name: []const u8) Staleness {
    if (!std.mem.eql(u8, record.so_sha256, so_sha256)) return .library;
    if (!std.mem.eql(u8, record.settings_sha256, settings_sha256) or
        !std.mem.eql(u8, record.package_name, package_name)) return .settings;
    return .fresh;
}

// ── run/replace: deploy ───────────────────────────────────────────────────

/// Install the APK this `labelle run` just built and launch it, with the
/// run options as launch extras. Returns once `am start` does (D7).
pub fn deployHook(c: Context) !void {
    const target_dir = c.ctx.target_dir orelse return error.MissingTargetDir;
    const apk = try checkedApk(c, target_dir);
    const run = c.ctx.run orelse contract.RunContext{ .env = &.{}, .args = &.{}, .timeout_ms = null };
    if (run.args.len != 0)
        std.debug.print("labelle-android: note: {d} argument(s) after `--` ignored: a NativeActivity has no argv; use the run options (--scene, --screenshot, ...)\n", .{run.args.len});
    if (run.timeout_ms != null)
        std.debug.print("labelle-android: note: --timeout is not enforced on a device: the launch returns once the app starts\n", .{});
    try run_mod.installAndLaunch(c.a, c.io, c.env, .{
        .apk = apk,
        .package_name = c.settings.package_name,
        .extras = run.env,
    });
}

// ── bundle/replace: bundle ────────────────────────────────────────────────

/// The Android `versionCode` from `--build-number`: a positive integer no
/// greater than Google Play's 2100000000. Absent means 1.
pub fn versionCode(build_number: ?[]const u8) !u32 {
    const text = build_number orelse return 1;
    const value = std.fmt.parseInt(u32, text, 10) catch {
        std.debug.print("labelle-android: --build-number '{s}' is not an Android versionCode (a positive integer)\n", .{text});
        return error.InvalidBuildNumber;
    };
    if (value == 0 or value > 2_100_000_000) {
        std.debug.print("labelle-android: --build-number {d} is out of range for an Android versionCode (1..2100000000)\n", .{value});
        return error.InvalidBuildNumber;
    }
    return value;
}

/// `<output_dir>/<package>-<versionName>.apk`, packaged again from this
/// build with `versionCode = --build-number`, plus its size report and the
/// unstripped library. Staging stays under the target directory, so a
/// `--output` elsewhere only ever receives finished files.
pub fn bundleHook(c: Context) !void {
    const target_dir = c.ctx.target_dir orelse return error.MissingTargetDir;
    const code = try versionCode(c.ctx.build_number);
    const out_dir = c.ctx.output_dir;
    try std.Io.Dir.cwd().createDirPath(c.io, out_dir);
    const stem = try std.fmt.allocPrint(c.a, "{s}-{s}", .{ c.settings.package_name, c.settings.version_name });
    const apk = try std.fs.path.join(c.a, &.{ out_dir, try std.fmt.allocPrint(c.a, "{s}.apk", .{stem}) });
    const strip = stripFor(c.ctx.optimize);
    const tools = try pkg.findTools(c.a, c.io, c.env, c.settings.target_sdk_version, strip);
    try pkg.package(c.a, c.io, c.env, .{
        .project_dir = c.ctx.project_dir.?,
        .target_dir = target_dir,
        .settings = c.settings,
        .identity = c.identity,
        .strip = strip,
        .version_code = code,
    }, .{
        .apk = apk,
        .staging = try std.fs.path.join(c.a, &.{ try apkDir(c.a, target_dir), try stagingName(c.a, "bundle-staging") }),
        .symbols = try std.fs.path.join(c.a, &.{ out_dir, try std.fmt.allocPrint(c.a, "{s}-symbols", .{stem}) }),
    }, tools);
    if (slim.printSizeReport(c.a, c.io, apk)) |report| {
        try std.Io.Dir.cwd().writeFile(c.io, .{
            .sub_path = try std.fs.path.join(c.a, &.{ out_dir, try std.fmt.allocPrint(c.a, "{s}.size.txt", .{stem}) }),
            .data = report,
        });
    }
    std.debug.print("labelle-android: bundle ready: {s} (versionCode {d}, versionName {s})\n", .{ apk, code, c.settings.version_name });
}

// ── commands ──────────────────────────────────────────────────────────────

/// Every `.labelle/*_android/<sub...>` entry that exists, e.g. the built APK
/// of each backend's Android target.
fn builtOutputs(c: Context, sub: []const []const u8) ![]const []const u8 {
    const labelle_dir = try std.fs.path.join(c.a, &.{ c.ctx.project_dir.?, ".labelle" });
    var found: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(c.io, labelle_dir, .{ .iterate = true }) catch return found.items;
    defer dir.close(c.io);
    var it = dir.iterate();
    while (try it.next(c.io)) |entry| {
        if (entry.kind != .directory or !std.mem.endsWith(u8, entry.name, "_android")) continue;
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.appendSlice(c.a, &.{ labelle_dir, entry.name });
        try parts.appendSlice(c.a, sub);
        const path = try std.fs.path.join(c.a, parts.items);
        if (std.Io.Dir.cwd().access(c.io, path, .{})) |_| try found.append(c.a, path) else |_| {}
    }
    std.mem.sort([]const u8, found.items, {}, lessThan);
    return found.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Exactly one of `candidates`, or an actionable error.
fn exactlyOne(candidates: []const []const u8, what: []const u8, how: []const u8) ![]const u8 {
    if (candidates.len == 1) return candidates[0];
    if (candidates.len == 0) {
        std.debug.print("labelle-android: no {s} found: {s}\n", .{ what, how });
        return error.NoBuiltApk;
    }
    std.debug.print("labelle-android: several {s}s found; pick one with --apk:\n", .{what});
    for (candidates) |candidate| std.debug.print("  {s}\n", .{candidate});
    return error.AmbiguousBuildOutput;
}

pub const RunOptions = struct {
    device: ?[]const u8 = null,
    apk: ?[]const u8 = null,
};

pub const run_usage = "usage: labelle android run [--device <serial>] [--apk <path>]\n";

/// Parse `run`'s arguments (`--flag value` or `--flag=value`).
pub fn parseRunArgs(args: []const []const u8) !RunOptions {
    var o: RunOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const flag = if (eq) |e| arg[0..e] else arg;
        const slot: *?[]const u8 = if (std.mem.eql(u8, flag, "--device"))
            &o.device
        else if (std.mem.eql(u8, flag, "--apk"))
            &o.apk
        else {
            std.debug.print("labelle-android: unknown argument '{s}'\n{s}", .{ arg, run_usage });
            return error.UnknownArgument;
        };
        const value = if (eq) |e| arg[e + 1 ..] else blk: {
            i += 1;
            break :blk if (i < args.len) args[i] else "";
        };
        if (value.len == 0) {
            std.debug.print("labelle-android: {s} needs a value\n{s}", .{ flag, run_usage });
            return error.InvalidArgs;
        }
        slot.* = value;
    }
    return o;
}

/// `labelle android run`: install and launch the APK the last
/// `labelle build --platform=android` packaged (checked against its package
/// record) or `--apk`, on `--device` or adb's default. Builds nothing.
pub fn runCommand(c: Context, args: []const []const u8) !void {
    const o = try parseRunArgs(args);
    const apk = o.apk orelse blk: {
        const found = try exactlyOne(
            try builtOutputs(c, &.{ "zig-out", "apk", apk_name }),
            "built APK",
            "run `labelle build --platform=android` first",
        );
        // `<target>/zig-out/apk/game.apk`: check it against its record, as
        // the `deploy` hook does.
        const target_dir = std.fs.path.dirname(std.fs.path.dirname(std.fs.path.dirname(found).?).?).?;
        break :blk try checkedApk(c, target_dir);
    };
    try run_mod.installAndLaunch(c.a, c.io, c.env, .{
        .apk = apk,
        .package_name = c.settings.package_name,
        .device = o.device,
    });
}

/// `labelle android deploy`: publish the APK `labelle bundle
/// --platform=android` produced (or `--apk`) as a GitHub Release.
pub fn deployCommand(c: Context, args: []const []const u8) !void {
    const o = try deploy_mod.parseArgs(args);
    const apk = o.apk orelse blk: {
        var candidates: std.ArrayList([]const u8) = .empty;
        for (try builtOutputs(c, &.{ "zig-out", "bundle", "android" })) |dir| {
            var d = try std.Io.Dir.cwd().openDir(c.io, dir, .{ .iterate = true });
            defer d.close(c.io);
            var it = d.iterate();
            while (try it.next(c.io)) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".apk"))
                    try candidates.append(c.a, try std.fs.path.join(c.a, &.{ dir, entry.name }));
            }
        }
        std.mem.sort([]const u8, candidates.items, {}, lessThan);
        break :blk try exactlyOne(candidates.items, "bundled APK", "run `labelle bundle --platform=android --optimize=ReleaseFast` first, or pass --apk");
    };
    const label = settings_mod.appName(c.settings, if (c.identity.title.len > 0) c.identity.title else c.identity.name);
    try deploy_mod.publish(c.a, c.io, try deploy_mod.ghArgv(c.a, o, apk, label, c.settings.deploy));
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "strip follows the optimize mode: every release mode strips, Debug copies" {
    try std.testing.expect(!stripFor(.Debug));
    try std.testing.expect(stripFor(.ReleaseSafe));
    try std.testing.expect(stripFor(.ReleaseFast));
    try std.testing.expect(stripFor(.ReleaseSmall));
}

test "versionCode: absent is 1; a positive integer up to 2100000000; nothing else" {
    try std.testing.expectEqual(@as(u32, 1), try versionCode(null));
    try std.testing.expectEqual(@as(u32, 7), try versionCode("7"));
    try std.testing.expectEqual(@as(u32, 2_100_000_000), try versionCode("2100000000"));
    for ([_][]const u8{ "0", "2100000001", "1.2.3", "-4", "x", "" }) |bad| {
        try std.testing.expectError(error.InvalidBuildNumber, versionCode(bad));
    }
}

test "parseRunArgs: both spellings; unknown flags and missing values are refused" {
    const o = try parseRunArgs(&.{ "--device", "R9XR", "--apk=g.apk" });
    try std.testing.expectEqualStrings("R9XR", o.device.?);
    try std.testing.expectEqualStrings("g.apk", o.apk.?);
    try std.testing.expectError(error.UnknownArgument, parseRunArgs(&.{"--release"}));
    try std.testing.expectError(error.InvalidArgs, parseRunArgs(&.{"--device"}));
    try std.testing.expectError(error.InvalidArgs, parseRunArgs(&.{"--apk="}));
}

test "staleness: the recorded library and settings must both match" {
    const a = std.testing.allocator;
    const settings = "{\"schema_version\": 1, \"package_name\": \"com.a.b\"}";
    const settings_sha = try hexSha256(a, settings);
    defer a.free(settings_sha);
    const so_sha = try hexSha256(a, "LIB");
    defer a.free(so_sha);
    const record: Record = .{ .package_name = "com.a.b", .version_code = 1, .optimize = .Debug, .so_sha256 = so_sha, .settings_sha256 = settings_sha };
    try std.testing.expectEqual(Staleness.fresh, staleness(record, so_sha, settings_sha, "com.a.b"));

    const other_so = try hexSha256(a, "REBUILT");
    defer a.free(other_so);
    try std.testing.expectEqual(Staleness.library, staleness(record, other_so, settings_sha, "com.a.b"));

    // providers/android.json edited (a new package_name) without a rebuild.
    const edited = try hexSha256(a, "{\"schema_version\": 1, \"package_name\": \"com.a.c\"}");
    defer a.free(edited);
    try std.testing.expectEqual(Staleness.settings, staleness(record, so_sha, edited, "com.a.c"));
    // A record whose package differs is stale even if the digest matched.
    try std.testing.expectEqual(Staleness.settings, staleness(record, so_sha, settings_sha, "com.a.c"));
}

test "exactlyOne: one wins, none and several are errors" {
    try std.testing.expectEqualStrings("a", try exactlyOne(&.{"a"}, "x", "y"));
    try std.testing.expectError(error.NoBuiltApk, exactlyOne(&.{}, "x", "y"));
    try std.testing.expectError(error.AmbiguousBuildOutput, exactlyOne(&.{ "a", "b" }, "x", "y"));
}

test {
    _ = pkg;
    _ = slim;
    _ = run_mod;
    _ = deploy_mod;
    _ = @import("package/icon.zig");
    _ = @import("package/manifest.zig");
    _ = @import("package/signing.zig");
}
