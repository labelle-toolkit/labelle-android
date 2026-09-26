//! `labelle android doctor`: probe the Android SDK/NDK/JDK and print a
//! report of every tool the provider uses (ported from labelle-cli
//! `src/cli/android/doctor.zig`). A required miss makes the command fail;
//! an optional one only warns.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk.zig");

pub const Summary = struct {
    failures: usize,
    warnings: usize,
};

/// Probe and write the report to `out`. Returns the miss counts; the caller
/// decides the exit status.
pub fn run(a: std.mem.Allocator, io: std.Io, env: *const sdk.Env, opts: sdk.DetectOptions, out: *std.Io.Writer) !Summary {
    const report = try sdk.detect(a, io, env, opts);
    try out.print(
        \\
        \\labelle android doctor
        \\======================
        \\  target SDK: {d}
        \\
    , .{report.target_sdk_version});
    var summary: Summary = .{ .failures = 0, .warnings = 0 };
    for (report.checks) |check| {
        if (check.path) |path| {
            try out.print("  [  OK  ] {s}\n           {s}\n", .{ check.name, path });
            continue;
        }
        if (check.required) {
            summary.failures += 1;
            try out.print("  [ FAIL ] {s}\n", .{check.name});
        } else {
            summary.warnings += 1;
            try out.print("  [ WARN ] {s}\n", .{check.name});
        }
        if (check.hint) |hint| try out.print("           -> {s}\n", .{hint});
    }
    try out.writeAll("\n");
    if (summary.failures == 0) {
        try out.writeAll("  All required Android tools are present.\n");
        if (summary.warnings > 0) try out.print("  ({d} optional tool(s) missing: see WARN lines above.)\n", .{summary.warnings});
    } else {
        try out.print("  {d} required tool(s) missing: see FAIL lines above.\n", .{summary.failures});
        try out.writeAll("  Install instructions: https://developer.android.com/tools\n");
    }
    try out.writeAll("\n");
    try out.flush();
    return summary;
}

// ── Tests: a fake ANDROID_HOME tree ───────────────────────────────────────

const Fake = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    arena: std.heap.ArenaAllocator,
    env: sdk.Env,

    fn init() !*Fake {
        const self = try std.testing.allocator.create(Fake);
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .root = undefined,
            .arena = .init(std.testing.allocator),
            .env = .init(std.testing.allocator),
        };
        self.root = try self.tmp.dir.realPathFileAlloc(std.testing.io, ".", self.arena.allocator());
        return self;
    }

    fn deinit(self: *Fake) void {
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
        std.testing.allocator.destroy(self);
    }

    fn abs(self: *Fake, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, rel });
    }

    /// Create `dir/<tool with host suffix>`.
    fn tool(self: *Fake, parent: []const u8, name: []const u8, kind: sdk.ToolKind) !void {
        var buf: [64]u8 = undefined;
        const leaf = sdk.toolFileName(&buf, builtin.os.tag, name, kind);
        try self.file(try std.fs.path.join(self.arena.allocator(), &.{ parent, leaf }));
    }

    fn file(self: *Fake, rel: []const u8) !void {
        if (std.fs.path.dirname(rel)) |parent| try self.tmp.dir.createDirPath(std.testing.io, parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel, .data = "" });
    }

    fn mkdir(self: *Fake, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, rel);
    }

    /// A complete SDK + NDK + JDK, plus decoys a naive probe would pick.
    fn populate(self: *Fake) !void {
        const host = sdk.ndkHostTag(builtin.os.tag);
        try self.tool("sdk/platform-tools", "adb", .native_exe);
        // An older, empty build-tools, and a newer complete one.
        try self.mkdir("sdk/build-tools/9.0.0");
        for ([_][]const u8{ "aapt", "zipalign" }) |name| try self.tool("sdk/build-tools/34.0.0", name, .native_exe);
        try self.tool("sdk/build-tools/34.0.0", "apksigner", .script);
        try self.file("sdk/platforms/android-34/android.jar");
        // A valid NDK, and a greater partial one without a sysroot.
        const ndk = try std.fmt.allocPrint(self.arena.allocator(), "sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/{s}", .{host});
        try self.mkdir(try std.fs.path.join(self.arena.allocator(), &.{ ndk, "sysroot" }));
        try self.tool(try std.fs.path.join(self.arena.allocator(), &.{ ndk, "bin" }), "llvm-strip", .native_exe);
        try self.mkdir("sdk/ndk/28.2.13676358");
        try self.tool("jdk/bin", "jar", .native_exe);
        try self.tool("jdk/bin", "keytool", .native_exe);
        try self.env.put("ANDROID_HOME", try self.abs("sdk"));
        try self.env.put("JAVA_HOME", try self.abs("jdk"));
        // No host PATH: nothing may resolve outside the fake tree.
        try self.env.put("PATH", try self.abs("empty-path"));
    }

    fn doctor(self: *Fake, opts: sdk.DetectOptions, out: *std.Io.Writer) !Summary {
        return run(self.arena.allocator(), std.testing.io, &self.env, opts, out);
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find '{s}' in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "doctor: a complete fake SDK passes and resolves the right versions" {
    const fake = try Fake.init();
    defer fake.deinit();
    try fake.populate();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try fake.doctor(.{}, &out.writer);
    const text = out.written();
    try std.testing.expectEqual(@as(usize, 0), summary.failures);
    try std.testing.expectEqual(@as(usize, 0), summary.warnings);
    try expectContains(text, "All required Android tools are present.");
    for ([_][]const u8{ "adb", "build-tools", "aapt", "zipalign", "apksigner", "android.jar (platform)", "NDK sysroot", "llvm-strip (NDK)", "jar (JDK)", "keytool (JDK)" }) |name| {
        const line = try std.fmt.allocPrint(fake.arena.allocator(), "[  OK  ] {s}\n", .{name});
        try expectContains(text, line);
    }
    // The newest build-tools (numeric order) and the newest VALID NDK.
    try expectContains(text, "34.0.0");
    try expectContains(text, "27.0.12077973");
    try std.testing.expect(std.mem.indexOf(u8, text, "28.2.13676358") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "9.0.0") == null);
    if (builtin.os.tag == .windows) try expectContains(text, "apksigner.bat");
}

test "doctor: a missing platform for the configured target SDK fails with a hint" {
    const fake = try Fake.init();
    defer fake.deinit();
    try fake.populate();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try fake.doctor(.{ .target_sdk_version = 35 }, &out.writer);
    try std.testing.expectEqual(@as(usize, 1), summary.failures);
    try expectContains(out.written(), "target SDK: 35");
    try expectContains(out.written(), "[ FAIL ] android.jar (platform)");
    try expectContains(out.written(), "platforms;android-35");
    try expectContains(out.written(), "1 required tool(s) missing");
}

test "doctor: ANDROID_NDK_HOME wins; a missing llvm-strip only warns" {
    const fake = try Fake.init();
    defer fake.deinit();
    try fake.populate();
    const host = sdk.ndkHostTag(builtin.os.tag);
    const sysroot = try std.fmt.allocPrint(fake.arena.allocator(), "ndk-home/toolchains/llvm/prebuilt/{s}/sysroot", .{host});
    try fake.mkdir(sysroot);
    try fake.env.put("ANDROID_NDK_HOME", try fake.abs("ndk-home"));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try fake.doctor(.{}, &out.writer);
    try std.testing.expectEqual(@as(usize, 0), summary.failures);
    try std.testing.expectEqual(@as(usize, 1), summary.warnings);
    try expectContains(out.written(), "ndk-home");
    try expectContains(out.written(), "[ WARN ] llvm-strip (NDK)");
}

test "doctor: no SDK home cascades every SDK check to FAIL" {
    const fake = try Fake.init();
    defer fake.deinit();
    try fake.env.put("PATH", try fake.abs("empty-path"));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try fake.doctor(.{}, &out.writer);
    // SDK home, 6 SDK tools, NDK, jar and keytool.
    try std.testing.expectEqual(@as(usize, 10), summary.failures);
    try expectContains(out.written(), "set ANDROID_HOME");
    try expectContains(out.written(), "resolve SDK home first");
}

test "doctor: tools found on PATH when the SDK and JAVA_HOME lack them" {
    const fake = try Fake.init();
    defer fake.deinit();
    try fake.populate();
    try fake.tmp.dir.deleteTree(std.testing.io, "sdk/platform-tools");
    try fake.tmp.dir.deleteTree(std.testing.io, "jdk");
    try fake.tool("bin", "adb", .native_exe);
    try fake.tool("bin", "jar", .native_exe);
    try fake.tool("bin", "keytool", .native_exe);
    try fake.env.put("PATH", try fake.abs("bin"));
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const summary = try fake.doctor(.{}, &out.writer);
    try std.testing.expectEqual(@as(usize, 0), summary.failures);
    try expectContains(out.written(), try fake.abs("bin"));
}
