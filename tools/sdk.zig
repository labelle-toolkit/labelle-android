//! Android SDK / NDK / JDK discovery (ported from labelle-cli
//! `src/cli/android_sdk.zig` and the SDK helpers of `android/package.zig`).
//!
//! Every probe takes the environment map explicitly instead of reading the
//! process environment, so tests drive it against a fake `ANDROID_HOME`
//! tree. Probes return null on a miss; `detect` records every check so
//! `doctor` can report the whole picture instead of stopping at the first
//! missing tool. PATH lookups scan `PATH` directly (no `which`/`where`
//! child process), which keeps them deterministic under test.
const std = @import("std");
const builtin = @import("builtin");

pub const Env = std.process.Environ.Map;

/// How an SDK tool is launched, which decides its Windows file name:
/// native binaries (aapt, zipalign, adb) are `.exe`; the JVM launchers
/// (apksigner) are `.bat` wrappers. Elsewhere both are bare names.
pub const ToolKind = enum { native_exe, script };

/// A tool's file name on `os`. Host-independent so every rule is tested on
/// every host.
pub fn toolFileName(buf: []u8, os: std.Target.Os.Tag, name: []const u8, kind: ToolKind) []const u8 {
    const suffix: []const u8 = if (os != .windows) "" else switch (kind) {
        .native_exe => ".exe",
        .script => ".bat",
    };
    return std.fmt.bufPrint(buf, "{s}{s}", .{ name, suffix }) catch unreachable;
}

/// `<dir>/<name>` with the host's executable suffix. Caller owns it.
pub fn toolPath(a: std.mem.Allocator, dir: []const u8, name: []const u8, kind: ToolKind) ![]u8 {
    var buf: [64]u8 = undefined;
    return std.fs.path.join(a, &.{ dir, toolFileName(&buf, builtin.os.tag, name, kind) });
}

/// An environment variable, with an empty value treated as unset.
pub fn envValue(env: *const Env, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

/// `ANDROID_HOME`, falling back to `ANDROID_SDK_ROOT`.
pub fn findSdkHome(env: *const Env) ?[]const u8 {
    return envValue(env, "ANDROID_HOME") orelse envValue(env, "ANDROID_SDK_ROOT");
}

fn isFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind != .directory;
}

fn isDir(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// `<sdk>/platform-tools/adb`, else `adb` on PATH.
pub fn findAdbUnder(a: std.mem.Allocator, io: std.Io, env: *const Env, sdk_home: []const u8) !?[]u8 {
    const candidate = try toolPath(a, try std.fs.path.join(a, &.{ sdk_home, "platform-tools" }), "adb", .native_exe);
    if (isFile(io, candidate)) return candidate;
    return findOnPath(a, io, env, "adb");
}

pub const BuildTools = struct {
    dir: []const u8,
    version: []const u8,
};

/// The newest `<sdk>/build-tools/<version>/`, compared numerically
/// (`10.0.0` > `9.0.0`).
pub fn findBuildTools(a: std.mem.Allocator, io: std.Io, sdk_home: []const u8) !?BuildTools {
    const root = try std.fs.path.join(a, &.{ sdk_home, "build-tools" });
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?[]const u8 = null;
    var best_version: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const v = parseVersion(entry.name);
        if (best == null or v > best_version) {
            best = try a.dupe(u8, entry.name);
            best_version = v;
        }
    }
    const version = best orelse return null;
    return .{ .dir = try std.fs.path.join(a, &.{ root, version }), .version = version };
}

/// `<sdk>/platforms/android-<level>/android.jar`, the aapt compile classpath.
pub fn findAndroidJar(a: std.mem.Allocator, io: std.Io, sdk_home: []const u8, level: u32) !?[]u8 {
    const platform = try std.fmt.allocPrint(a, "android-{d}", .{level});
    const jar = try std.fs.path.join(a, &.{ sdk_home, "platforms", platform, "android.jar" });
    return if (isFile(io, jar)) jar else null;
}

/// The NDK root: `ANDROID_NDK_HOME` when it has a sysroot, else the greatest
/// `<sdk>/ndk/<version>` that HAS one (the rule `build.zig`'s `ndkRoot`
/// uses, so a partial install cannot shadow an older valid NDK).
pub fn findNdkRoot(a: std.mem.Allocator, io: std.Io, env: *const Env, sdk_home: ?[]const u8) !?[]u8 {
    if (envValue(env, "ANDROID_NDK_HOME")) |ndk| {
        if (isDir(io, try sysrootOf(a, ndk))) return try a.dupe(u8, ndk);
    }
    const home = sdk_home orelse return null;
    const ndk_dir = try std.fs.path.join(a, &.{ home, "ndk" });
    var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?[]u8 = null;
    var best_version: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const root = try std.fs.path.join(a, &.{ ndk_dir, entry.name });
        if (!isDir(io, try sysrootOf(a, root))) continue;
        const v = parseVersion(entry.name);
        if (best == null or v > best_version) {
            best = root;
            best_version = v;
        }
    }
    return best;
}

/// `<ndk>/toolchains/llvm/prebuilt/<host>/sysroot`.
pub fn sysrootOf(a: std.mem.Allocator, ndk_root: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ ndk_root, "toolchains", "llvm", "prebuilt", ndkHostTag(builtin.os.tag), "sysroot" });
}

/// `llvm-strip` beside the NDK sysroot: what the Android Gradle plugin
/// strips release `.so`s with (labelle-assembler#755).
pub fn findNdkLlvmStrip(a: std.mem.Allocator, io: std.Io, ndk_root: []const u8) !?[]u8 {
    const bin = try std.fs.path.join(a, &.{ ndk_root, "toolchains", "llvm", "prebuilt", ndkHostTag(builtin.os.tag), "bin" });
    const strip = try toolPath(a, bin, "llvm-strip", .native_exe);
    return if (isFile(io, strip)) strip else null;
}

/// The NDK ships `darwin-x86_64` only, even on Apple Silicon.
pub fn ndkHostTag(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}

/// A JDK tool (`jar`, `keytool`): `JAVA_HOME/bin` first (the packager's
/// rule for `jar`), else PATH.
pub fn findJdkTool(a: std.mem.Allocator, io: std.Io, env: *const Env, name: []const u8) !?[]u8 {
    if (envValue(env, "JAVA_HOME")) |java_home| {
        const path = try toolPath(a, try std.fs.path.join(a, &.{ java_home, "bin" }), name, .native_exe);
        if (isFile(io, path)) return path;
    }
    return findOnPath(a, io, env, name);
}

/// The first `PATH` entry holding `name` (with `.exe`/`.bat`/`.cmd` on
/// Windows).
pub fn findOnPath(a: std.mem.Allocator, io: std.Io, env: *const Env, name: []const u8) !?[]u8 {
    const path_var = envValue(env, "PATH") orelse envValue(env, "Path") orelse return null;
    const suffixes: []const []const u8 = if (builtin.os.tag == .windows) &.{ ".exe", ".bat", ".cmd", "" } else &.{""};
    var dirs = std.mem.tokenizeScalar(u8, path_var, std.fs.path.delimiter);
    while (dirs.next()) |dir| {
        for (suffixes) |suffix| {
            const file = try std.fmt.allocPrint(a, "{s}{s}", .{ name, suffix });
            const candidate = try std.fs.path.join(a, &.{ dir, file });
            if (isFile(io, candidate)) return candidate;
        }
    }
    return null;
}

/// `"1.2.3"` → a comparable number (the CLI's `util.parseVersion`, widened
/// so NDK build numbers like `27.2.12479018` do not overflow). Non-digit
/// bytes are skipped.
pub fn parseVersion(version: []const u8) u64 {
    var parts: [3]u64 = .{ 0, 0, 0 };
    var i: usize = 0;
    for (version) |c| {
        if (c == '.') {
            i += 1;
            if (i >= parts.len) break;
        } else if (c >= '0' and c <= '9') {
            parts[i] = @min(parts[i] *| 10 +| (c - '0'), 999_999);
        }
    }
    return parts[0] * 1_000_000_000_000 + parts[1] * 1_000_000 + parts[2];
}

// ── detect ────────────────────────────────────────────────────────────────

/// One probe's outcome, for the doctor report.
pub const Check = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    /// A remediation hint when `path` is null.
    hint: ?[]const u8 = null,
    /// A required miss fails doctor; an optional miss only warns.
    required: bool = true,
};

pub const DetectOptions = struct {
    /// The SDK platform whose `android.jar` aapt compiles against.
    target_sdk_version: u32 = 34,
};

pub const Report = struct {
    target_sdk_version: u32,
    checks: []const Check,

    pub fn failures(self: Report) usize {
        var n: usize = 0;
        for (self.checks) |c| {
            if (c.path == null and c.required) n += 1;
        }
        return n;
    }

    pub fn find(self: Report, name: []const u8) ?Check {
        for (self.checks) |c| {
            if (std.mem.eql(u8, c.name, name)) return c;
        }
        return null;
    }
};

/// Probe every tool the provider's packaging and deploy paths use. Misses
/// are recorded, not returned; only allocation/IO failures error.
pub fn detect(a: std.mem.Allocator, io: std.Io, env: *const Env, opts: DetectOptions) !Report {
    var checks: std.ArrayList(Check) = .empty;
    const sdk_home = findSdkHome(env);
    try checks.append(a, .{
        .name = "SDK home (ANDROID_HOME / ANDROID_SDK_ROOT)",
        .path = sdk_home,
        .hint = "set ANDROID_HOME to your Android SDK directory",
    });
    if (sdk_home) |home| {
        try checks.append(a, .{
            .name = "adb",
            .path = try findAdbUnder(a, io, env, home),
            .hint = "install SDK platform-tools: `sdkmanager \"platform-tools\"`",
        });
        const bt = try findBuildTools(a, io, home);
        try checks.append(a, .{
            .name = "build-tools",
            .path = if (bt) |b| b.dir else null,
            .hint = "install build-tools: `sdkmanager \"build-tools;34.0.0\"`",
        });
        // Exactly the files the packager launches (aapt, zipalign, and the
        // apksigner `.bat` on Windows).
        const tools = [_]struct { name: []const u8, kind: ToolKind }{
            .{ .name = "aapt", .kind = .native_exe },
            .{ .name = "zipalign", .kind = .native_exe },
            .{ .name = "apksigner", .kind = .script },
        };
        for (tools) |tool| {
            var found: ?[]const u8 = null;
            if (bt) |b| {
                const path = try toolPath(a, b.dir, tool.name, tool.kind);
                if (isFile(io, path)) found = path;
            }
            try checks.append(a, .{
                .name = tool.name,
                .path = found,
                .hint = if (bt == null) "resolve build-tools first" else "missing from build-tools",
            });
        }
        try checks.append(a, .{
            .name = "android.jar (platform)",
            .path = try findAndroidJar(a, io, home, opts.target_sdk_version),
            .hint = try std.fmt.allocPrint(a, "install SDK platform: `sdkmanager \"platforms;android-{d}\"`", .{opts.target_sdk_version}),
        });
    } else {
        for ([_][]const u8{ "adb", "build-tools", "aapt", "zipalign", "apksigner", "android.jar (platform)" }) |name| {
            try checks.append(a, .{ .name = name, .hint = "resolve SDK home first" });
        }
    }
    const ndk = try findNdkRoot(a, io, env, sdk_home);
    try checks.append(a, .{
        .name = "NDK sysroot",
        .path = if (ndk) |root| try sysrootOf(a, root) else null,
        .hint = "install an NDK: `sdkmanager \"ndk;27.2.12479018\"` (or set ANDROID_NDK_HOME)",
    });
    try checks.append(a, .{
        .name = "llvm-strip (NDK)",
        .path = if (ndk) |root| try findNdkLlvmStrip(a, io, root) else null,
        .hint = "release builds strip the .so with the NDK's llvm-strip",
        .required = false,
    });
    try checks.append(a, .{
        .name = "jar (JDK)",
        .path = try findJdkTool(a, io, env, "jar"),
        .hint = "install a JDK and set JAVA_HOME to it",
    });
    try checks.append(a, .{
        .name = "keytool (JDK)",
        .path = try findJdkTool(a, io, env, "keytool"),
        .hint = "install a JDK (it ships keytool, used for the debug keystore)",
    });
    return .{ .target_sdk_version = opts.target_sdk_version, .checks = try checks.toOwnedSlice(a) };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "toolFileName: .exe for native tools and .bat for scripts on Windows only" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("aapt.exe", toolFileName(&buf, .windows, "aapt", .native_exe));
    try std.testing.expectEqualStrings("apksigner.bat", toolFileName(&buf, .windows, "apksigner", .script));
    for ([_]std.Target.Os.Tag{ .linux, .macos }) |os| {
        try std.testing.expectEqualStrings("aapt", toolFileName(&buf, os, "aapt", .native_exe));
        try std.testing.expectEqualStrings("apksigner", toolFileName(&buf, os, "apksigner", .script));
    }
}

test "parseVersion orders numerically, not lexicographically" {
    try std.testing.expect(parseVersion("10.0.0") > parseVersion("9.0.0"));
    try std.testing.expect(parseVersion("34.0.0") > parseVersion("33.0.2"));
    try std.testing.expect(parseVersion("27.2.12479018") > parseVersion("27.0.12077973"));
    try std.testing.expectEqual(parseVersion("1.2.3"), parseVersion("1.2.3"));
}

test "ndkHostTag: darwin-x86_64 on macOS whatever the CPU" {
    try std.testing.expectEqualStrings("darwin-x86_64", ndkHostTag(.macos));
    try std.testing.expectEqualStrings("windows-x86_64", ndkHostTag(.windows));
    try std.testing.expectEqualStrings("linux-x86_64", ndkHostTag(.linux));
}

test "findSdkHome: ANDROID_HOME, then ANDROID_SDK_ROOT; empty means unset" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(findSdkHome(&env) == null);
    try env.put("ANDROID_SDK_ROOT", "/sdk-root");
    try std.testing.expectEqualStrings("/sdk-root", findSdkHome(&env).?);
    try env.put("ANDROID_HOME", "");
    try std.testing.expectEqualStrings("/sdk-root", findSdkHome(&env).?);
    try env.put("ANDROID_HOME", "/sdk-home");
    try std.testing.expectEqualStrings("/sdk-home", findSdkHome(&env).?);
}
