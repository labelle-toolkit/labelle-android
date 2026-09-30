//! labelle-android — shared Android platform services for the labelle backends
//! (labelle-bgfx#149, phase 1).
//!
//! ONE module, `labelle_android` (the assembler's `labelle_<name>` alias for a
//! plugin named `android`), rooted at `src/root.zig`. Every package file is
//! reached from that root by relative import INSIDE the module; consumers only
//! ever `@import("labelle_android")` and never root a second module at
//! `dep.path("src/...")` (a file may belong to exactly one module root).
//!
//! Unlike `labelle-android-gamepad` (which hands its `.c` to the consumer),
//! this package compiles its own JNI C: it owns the NDK sysroot helper, so it
//! can wire the Bionic headers onto its own module. The same helper is
//! exported for consumers (`@import("labelle_android").addAndroidSysroot`),
//! the way `labelle-sokol/build.zig` re-exports sokol's `emLinkStep`.
const std = @import("std");
const builtin = @import("builtin");

/// Resolved NDK sysroot paths + API level for one Android target.
pub const NdkPaths = struct {
    /// `<ndk>/toolchains/llvm/prebuilt/<host>/sysroot`.
    sysroot: []const u8,
    /// `<sysroot>/usr/include`.
    inc_common: []const u8,
    /// `<sysroot>/usr/include/<triple>`.
    inc_arch: []const u8,
    /// `<sysroot>/usr/lib/<triple>/<api>` — where `libandroid.so`, `liblog.so`
    /// etc. live.
    lib_path: []const u8,
    /// The `__ANDROID_API__` the C is compiled against.
    android_api: []const u8,
};

/// True for the four Android ABIs (arm64/x86_64 `.android`, arm/x86
/// `.androideabi`).
pub fn isAndroidTarget(t: std.Target) bool {
    return t.abi == .android or t.abi == .androideabi;
}

/// labelle-android#10: the toolkit builds, packages and ships 64-bit Android
/// only — the labelle CLI's `AbiArch` is `arm64`/`x86_64`, the bgfx/sokol
/// hooks accept `-Dandroid_arch=arm64|x86_64`, and shipped APKs carry only
/// `lib/arm64-v8a`. 32-bit `armeabi-v7a` / `x86` are unsupported (and
/// `aaudio.zig`'s 64-bit atomics cannot lower on 32-bit ARM). Kept in sync
/// with `unsupported_abi_message` in `src/root.zig`, which is the same guard
/// for consumers that compile the module from their own build.
pub const unsupported_abi_message =
    "labelle-android supports 64-bit Android only (arm64-v8a = aarch64-linux-android, " ++
    "x86_64 = x86_64-linux-android); 32-bit armeabi-v7a / x86 are not supported";

/// True for a 32-bit Android target (arm/thumb `.androideabi`, x86
/// `.android`): see `unsupported_abi_message`.
pub fn isUnsupportedAndroidTarget(t: std.Target) bool {
    return isAndroidTarget(t) and t.ptrBitWidth() != 64;
}

pub const ResolveOptions = struct {
    /// Matches the toolkit's default Android `min_sdk` (28). Must be >= 23:
    /// Bionic exposes `stdout`/`stderr` as real symbols only from API 23.
    android_api: []const u8 = "28",
};

/// Resolve the NDK sysroot paths for an Android `target`. `ANDROID_NDK_HOME`
/// first, else `ANDROID_HOME/ndk/<greatest version dir that HAS a sysroot>`
/// (the stricter rule from labelle-bgfx's `backend.hook.zig`: a stray or
/// partial NDK install cannot shadow an older valid one). Panics with an
/// actionable message when nothing resolves or the arch is unsupported — the
/// caller only invokes this when `isAndroidTarget` is true.
pub fn resolveNdk(b: *std.Build, target: std.Build.ResolvedTarget, opts: ResolveOptions) NdkPaths {
    const sysroot = getAndroidNdkSysroot(b) orelse
        @panic("Could not find Android NDK. Set ANDROID_NDK_HOME or ANDROID_HOME.");
    const triple: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => @panic("unsupported Android arch for labelle-android"),
    };
    return .{
        .sysroot = sysroot,
        .inc_common = b.pathJoin(&.{ sysroot, "usr/include" }),
        .inc_arch = b.pathJoin(&.{ sysroot, "usr/include", triple }),
        .lib_path = b.pathJoin(&.{ sysroot, "usr/lib", triple, opts.android_api }),
        .android_api = opts.android_api,
    };
}

/// Add the NDK sysroot system-include paths, the arch/API library path,
/// `__ANDROID_API__` and `pic = true` to `mod`, so its C/C++ translation
/// units resolve the Bionic headers and its objects can be archived into an
/// Android `.so`. MUST be called BEFORE `mod.addCSourceFile(s)`: include paths
/// do not retro-apply to sources already added.
pub fn addAndroidSysroot(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) NdkPaths {
    const n = resolveNdk(b, target, .{});
    mod.addSystemIncludePath(.{ .cwd_relative = n.inc_common });
    mod.addSystemIncludePath(.{ .cwd_relative = n.inc_arch });
    mod.addLibraryPath(.{ .cwd_relative = n.lib_path });
    mod.addCMacro("__ANDROID_API__", n.android_api);
    mod.pic = true;
    return n;
}

/// `<ndk>/sources/android/native_app_glue` (ships `android_native_app_glue.c`
/// + `.h`), resolved from the same NDK `resolveNdk` picks. Null when the NDK
/// or the glue dir cannot be found. For the phase-2 NativeActivity shell;
/// unused by this phase.
pub fn nativeAppGlueDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const root = ndkRoot(b) orelse return null;
    const glue = b.pathJoin(&.{ root, "sources", "android", "native_app_glue" });
    if (std.Io.Dir.cwd().access(io, glue, .{})) |_| return glue else |_| return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_android = isAndroidTarget(target.result);
    // Decided before any NDK discovery: a 32-bit Android target must get the
    // one clear message even with no NDK installed (labelle-android#10).
    const unsupported = isUnsupportedAndroidTarget(target.result);

    const mod = b.addModule("labelle_android", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // libc `setenv`/`getenv` + the JNI C below. Off Android nothing in the
        // module references libc (nor the AAudio/MediaCodec externs:
        // `aaudio.zig`'s `ensureStarted`/`stop` and `video/*`'s decoders are
        // comptime-gated stubs off Android).
        .link_libc = is_android,
    });
    if (is_android and !unsupported) {
        // Sysroot BEFORE the C sources (see `addAndroidSysroot`).
        _ = addAndroidSysroot(b, mod, target);
        mod.addCSourceFiles(.{
            .files = &.{
                "src/jni/intent_extras.c",
                "src/jni/debuggable.c",
                "src/jni/window_relayout.c",
                "src/jni/renderer_query.c",
            },
            .flags = &.{ "-std=c11", "-Wall" },
        });
        mod.linkSystemLibrary("android", .{});
        mod.linkSystemLibrary("log", .{});
        // `aaudio.zig` (the AAudio output device, phase 1c) is pure `extern fn`
        // against libaaudio (API 26+); the link propagates to any consumer
        // module that imports `labelle_android`.
        mod.linkSystemLibrary("aaudio", .{});
        // `video/decoder.zig` + `video/audio_track.zig` (MediaCodec video and
        // audio-track decode, phase 1d) are pure `extern fn` against
        // libmediandk (AMediaExtractor / AMediaCodec / AImageReader, API 28+
        // for the `*64` fd variants); the link propagates the same way.
        mod.linkSystemLibrary("mediandk", .{});
    }

    const test_step = b.step("test", "Run labelle-android unit tests");

    // 32-bit Android: fail every step with the one clear message rather than
    // a wall of atomics errors from `aaudio.zig` (labelle-android#10).
    if (unsupported) {
        const fail = b.addFail(unsupported_abi_message);
        b.default_step.dependOn(&fail.step);
        test_step.dependOn(&fail.step);
    }

    // Host-run tests (pure Zig: the intent allow-list / decision, the video
    // `yuv`/`planes` helpers), pinned to the host so
    // `-Dtarget=aarch64-linux-android` never tries to execute a foreign
    // binary.
    const host = b.resolveTargetQuery(.{});
    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(host_tests).step);

    // The NDK-selection rule and `isAndroidTarget` are tested in THIS file;
    // a test artifact rooted here runs them on the host.
    const build_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(build_tests).step);

    // ── Provider host tool (labelle-cli#405) ──────────────────────────────
    // `bin/labelle-android`, the one executable every command/hook in
    // `plugin.labelle` names. The CLI builds it with `zig build --system
    // <cache> install-provider`, which disables dependency fetching, so it
    // must stay dependency-free (std only). Always built for the host,
    // whatever `-Dtarget` says.
    const provider_module = b.createModule(.{
        .root_source_file = b.path("tools/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        // The launcher-icon PNG decode/encode: stb_image / stb_image_write,
        // vendored as C (no package fetch under `--system`).
        .link_libc = true,
    });
    provider_module.addCSourceFile(.{ .file = b.path("tools/vendor/stb_image_impl.c"), .flags = &.{"-std=c99"} });
    provider_module.addIncludePath(b.path("tools/vendor"));
    // `tools/main.zig`'s test checks its routing table against the manifest.
    provider_module.addAnonymousImport("plugin.labelle", .{ .root_source_file = b.path("plugin.labelle") });
    const provider = b.addExecutable(.{ .name = "labelle-android", .root_module = provider_module });
    b.step("install-provider", "Install the labelle-cli provider tool (bin/labelle-android)")
        .dependOn(&b.addInstallArtifact(provider, .{}).step);
    const provider_tests = b.addRunArtifact(b.addTest(.{ .root_module = provider_module }));
    b.step("test-provider", "Run the provider host-tool tests (wire contract, settings, doctor)")
        .dependOn(&provider_tests.step);
    test_step.dependOn(&provider_tests.step);

    // Android compile-check (object emission, as labelle-bgfx's
    // `android_app_tests` does): proves the JNI C and the `extern "c"`
    // bindings compile against the NDK. Depends on the compile step, never a
    // run step.
    if (is_android and !unsupported) {
        const android_check = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&android_check.step);
    }
}

// ── NDK discovery ─────────────────────────────────────────────────────────
// Env lookups go through `b.graph.environ_map` and filesystem probes through
// `std.Io.Dir.cwd().access(io, ...)` (Zig 0.16 removed `std.posix.getenv`
// and `std.fs.cwd()`).

/// The NDK root directory (`ANDROID_NDK_HOME`, else the greatest valid
/// `ANDROID_HOME/ndk/<version>`), or null.
fn ndkRoot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        if (std.Io.Dir.cwd().access(io, sysrootOf(b, ndk_home), .{})) |_| return ndk_home else |_| {}
    }
    if (b.graph.environ_map.get("ANDROID_HOME")) |home| {
        const ndk_dir = b.pathJoin(&.{ home, "ndk" });
        var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var candidates: std.ArrayList(NdkCandidate) = .empty;
        defer candidates.deinit(b.allocator);
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = b.allocator.dupe(u8, entry.name) catch continue;
            const root = b.pathJoin(&.{ ndk_dir, name });
            const has_sysroot = if (std.Io.Dir.cwd().access(io, sysrootOf(b, root), .{})) |_| true else |_| false;
            candidates.append(b.allocator, .{ .name = name, .has_sysroot = has_sysroot }) catch continue;
        }
        if (selectGreatestValidNdk(candidates.items)) |version| {
            return b.pathJoin(&.{ ndk_dir, version });
        }
    }
    return null;
}

fn getAndroidNdkSysroot(b: *std.Build) ?[]const u8 {
    const root = ndkRoot(b) orelse return null;
    return sysrootOf(b, root);
}

fn sysrootOf(b: *std.Build, ndk_root: []const u8) []const u8 {
    return b.pathJoin(&.{ ndk_root, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
}

/// A candidate `$ANDROID_HOME/ndk/<name>` dir paired with whether its
/// `toolchains/llvm/prebuilt/<host>/sysroot` actually exists.
const NdkCandidate = struct { name: []const u8, has_sysroot: bool };

/// Pick the lexicographically-greatest NDK version dir that HAS a valid
/// sysroot. Validity is part of the selection (not an after-the-fact check on
/// the greatest dir), so a stray/partial install cannot shadow an older valid
/// NDK. Returns a borrowed slice from `candidates` or null when none is valid.
fn selectGreatestValidNdk(candidates: []const NdkCandidate) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (candidates) |c| {
        if (!c.has_sysroot) continue;
        if (best) |prev| {
            if (std.mem.order(u8, c.name, prev) == .gt) best = c.name;
        } else {
            best = c.name;
        }
    }
    return best;
}

fn ndkHostTag() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}

test "selectGreatestValidNdk: greatest VALID dir wins; an invalid greater dir cannot shadow it" {
    const testing = std.testing;
    const c = [_]NdkCandidate{
        .{ .name = "26.1.10909125", .has_sysroot = true },
        .{ .name = "28.2.13676358", .has_sysroot = false },
        .{ .name = "27.0.12077973", .has_sysroot = true },
    };
    try testing.expectEqualStrings("27.0.12077973", selectGreatestValidNdk(&c).?);
    try testing.expect(selectGreatestValidNdk(&.{}) == null);
    try testing.expect(selectGreatestValidNdk(&.{.{ .name = "x", .has_sysroot = false }}) == null);
}

test "isUnsupportedAndroidTarget: only 32-bit Android is rejected" {
    const testing = std.testing;
    const q = std.Target.Query;
    const cases = [_]struct { q: q, unsupported: bool }{
        .{ .q = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android }, .unsupported = false },
        .{ .q = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .android }, .unsupported = false },
        .{ .q = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .androideabi }, .unsupported = true },
        .{ .q = .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .android }, .unsupported = true },
        .{ .q = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf }, .unsupported = false },
    };
    for (cases) |c| {
        const t = try std.zig.system.resolveTargetQuery(testing.io, c.q);
        try testing.expectEqual(c.unsupported, isUnsupportedAndroidTarget(t));
    }
}

test "isAndroidTarget: both Android ABIs, nothing else" {
    const testing = std.testing;
    var t = builtin.target;
    t.abi = .android;
    try testing.expect(isAndroidTarget(t));
    t.abi = .androideabi;
    try testing.expect(isAndroidTarget(t));
    t.abi = .gnu;
    try testing.expect(!isAndroidTarget(t));
}
