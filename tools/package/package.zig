//! The APK packager: `libgame.so` + assets + launcher icon + manifest →
//! a signed, aligned APK.
//!
//! Ported from labelle-cli `src/cli/android/package.zig`
//! (`packageApkWithAbis` + `buildApk`, development 23aa180; labelle-cli#405)
//! so the APK keeps the CLI's layout and size:
//!
//! - release optimize modes stage `libgame.so` through the NDK's
//!   `llvm-strip --strip-unneeded`, keeping the unstripped library under
//!   `symbols/arm64-v8a/`; Debug stages it as built (`slim.zig`);
//! - `assets/` is staged without the packer's `raw/` sources, the files the
//!   generated `main.zig` embeds, and the PNG of an embedded ASTC (`slim.zig`);
//! - `aapt package -f -M -I -F [-A assets] [-S res -0 arsc]`, then
//!   `jar --update --no-compress --file <apk> -C <staging> lib` (so `lib/` is
//!   stored), `zipalign -f 4`, and `apksigner sign` (`signing.zig`).
//!
//! What changed: the inputs (settings + project identity instead of the
//! CLI's `AndroidConfig`), the version stamp (a parameter), and where things
//! go. The caller names the output APK, the staging directory and the
//! symbols directory; staging is deleted on every exit, and the signed APK
//! is renamed onto the output path only after every tool succeeded, so a
//! failed package never leaves an APK behind.
const std = @import("std");
const settings_mod = @import("../settings.zig");
const identity_mod = @import("../project_identity.zig");
const sdk = @import("../sdk.zig");
const proc = @import("../proc.zig");
const slim = @import("slim.zig");
const icon = @import("icon.zig");
const manifest = @import("manifest.zig");
const signing = @import("signing.zig");

/// The ABI directory v1 packages (settings accept only this one).
pub const abi_dir = settings_mod.supported_abi;

pub const Inputs = struct {
    project_dir: []const u8,
    /// `.labelle/<backend>_android/`: holds `zig-out/lib/libgame.so`,
    /// `assets/`, `main.zig`, `default_icon.png` and `apk_assets.json`.
    target_dir: []const u8,
    settings: settings_mod.Settings,
    identity: identity_mod.Identity,
    /// Strip the packaged library (the release optimize modes).
    strip: bool,
    version_code: u32 = 1,
};

pub const Outputs = struct {
    /// The signed APK, written last.
    apk: []const u8,
    /// Scratch directory; deleted before and after.
    staging: []const u8,
    /// `<symbols>/<abi>/libgame.so` receives the unstripped library.
    symbols: []const u8,
};

pub const Tools = struct {
    aapt: []const u8,
    zipalign: []const u8,
    apksigner: []const u8,
    jar: []const u8,
    android_jar: []const u8,
    /// Null: a release build is packaged unstripped, with a warning.
    llvm_strip: ?[]const u8,
};

/// Resolve every SDK/JDK tool the packager runs, with one actionable line
/// per miss (doctor lists them all).
pub fn findTools(a: std.mem.Allocator, io: std.Io, env: *const sdk.Env, target_sdk: u32, strip: bool) !Tools {
    const home = sdk.findSdkHome(env) orelse {
        std.debug.print("labelle-android: Android SDK not found: set ANDROID_HOME (see `labelle android doctor`)\n", .{});
        return error.SdkNotFound;
    };
    const bt = (try sdk.findBuildTools(a, io, home)) orelse {
        std.debug.print("labelle-android: no build-tools under {s}/build-tools\n", .{home});
        return error.SdkNotFound;
    };
    const android_jar = (try sdk.findAndroidJar(a, io, home, target_sdk)) orelse {
        std.debug.print("labelle-android: android.jar for API {d} not found: sdkmanager \"platforms;android-{d}\"\n", .{ target_sdk, target_sdk });
        return error.SdkNotFound;
    };
    const jar = (try sdk.findJdkTool(a, io, env, "jar")) orelse {
        std.debug.print("labelle-android: the JDK's 'jar' tool was not found: set JAVA_HOME to a JDK\n", .{});
        return error.SdkNotFound;
    };
    var llvm_strip: ?[]const u8 = null;
    if (strip) {
        if (try sdk.findNdkRoot(a, io, env, home)) |ndk| llvm_strip = try sdk.findNdkLlvmStrip(a, io, ndk);
    }
    return .{
        .aapt = try sdk.toolPath(a, bt.dir, "aapt", .native_exe),
        .zipalign = try sdk.toolPath(a, bt.dir, "zipalign", .native_exe),
        .apksigner = try sdk.toolPath(a, bt.dir, "apksigner", .script),
        .jar = jar,
        .android_jar = android_jar,
        .llvm_strip = llvm_strip,
    };
}

/// The built library the packager consumes.
pub fn soPath(a: std.mem.Allocator, target_dir: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ target_dir, "zig-out", "lib", "libgame.so" });
}

/// Package `in` into `out.apk`. `a` should be an arena: this allocates
/// freely and frees nothing.
pub fn package(
    a: std.mem.Allocator,
    io: std.Io,
    env: *const sdk.Env,
    in: Inputs,
    out: Outputs,
    tools: Tools,
) !void {
    const cwd = std.Io.Dir.cwd();
    const so_path = try soPath(a, in.target_dir);
    cwd.access(io, so_path, .{}) catch {
        std.debug.print("labelle-android: {s} not found: the core build produces it\n", .{so_path});
        return error.BinaryNotFound;
    };
    try checkApkAssets(a, io, in.target_dir);

    // Intentionally ignoring errors: none of these may exist yet.
    cwd.deleteTree(io, out.staging) catch {};
    cwd.deleteFile(io, out.apk) catch {};
    // The unstripped library of the PREVIOUS package would not match this
    // APK: drop it before (maybe) writing a new one.
    cwd.deleteTree(io, out.symbols) catch {};
    defer cwd.deleteTree(io, out.staging) catch {};
    try cwd.createDirPath(io, out.staging);

    // Native library → `lib/<abi>/libgame.so`.
    {
        const lib_dir = try std.fs.path.join(a, &.{ out.staging, "lib", abi_dir });
        try cwd.createDirPath(io, lib_dir);
        const staged_so = try std.fs.path.join(a, &.{ lib_dir, "libgame.so" });
        const symbols_so = try std.fs.path.join(a, &.{ out.symbols, abi_dir, "libgame.so" });
        switch (try slim.stageNativeLib(a, io, so_path, staged_so, symbols_so, in.strip, tools.llvm_strip)) {
            .copied => {},
            .stripped => std.debug.print("labelle-android: stripped {s}/libgame.so; unstripped copy for ndk-stack: {s}\n", .{ abi_dir, symbols_so }),
            .strip_unavailable => std.debug.print("labelle-android: warning: NDK llvm-strip not found, packaging {s}/libgame.so unstripped\n", .{abi_dir}),
            .strip_failed => std.debug.print("labelle-android: warning: llvm-strip failed, packaging {s}/libgame.so unstripped\n", .{abi_dir}),
            // `stageNativeLib` already printed the path + error.
            .symbols_unwritable => {},
        }
    }

    // Launcher icon, BEFORE the manifest: `android:icon` may only reference
    // `@mipmap/ic_launcher` when the resource exists (cli#340).
    const has_icon = try icon.stage(a, io, out.staging, in.project_dir, in.target_dir, in.identity.app_icon);

    const manifest_path = try std.fs.path.join(a, &.{ out.staging, "AndroidManifest.xml" });
    {
        const s = in.settings;
        const xml = try manifest.generate(a, .{
            .package_name = s.package_name,
            .app_name = settings_mod.appName(s, in.identity.title),
            .min_sdk_version = s.min_sdk_version,
            .target_sdk_version = s.target_sdk_version,
            .orientation = s.orientation,
            .immersive_mode = in.identity.immersive(),
            .debuggable = s.debuggable,
            .version_code = in.version_code,
            .version_name = s.version_name,
            .has_launcher_icon = has_icon,
        });
        try cwd.writeFile(io, .{ .sub_path = manifest_path, .data = xml });
    }

    // Assets. A project with no `.resources` generates no `assets/`; aapt is
    // happy with an APK that has no assets/ entry.
    const assets_src = try std.fs.path.join(a, &.{ in.target_dir, "assets" });
    const assets_dst = try std.fs.path.join(a, &.{ out.staging, "assets" });
    if (cwd.access(io, assets_src, .{})) |_| {
        var embedded = try slim.loadEmbeddedAssets(a, io, in.target_dir);
        defer embedded.deinit(a);
        const summary = try slim.stageAssets(a, io, assets_src, assets_dst, embedded);
        if (summary.skippedFiles() > 0) {
            std.debug.print("labelle-android: staged {d} asset files; left out {d} ({d:.1} MB on disk) the runtime does not read from the APK\n", .{
                summary.kept_files,
                summary.skippedFiles(),
                slim.mb(summary.skippedBytes()),
            });
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const unsigned_apk = try std.fs.path.join(a, &.{ out.staging, "game.apk.unsigned" });
    const aligned_apk = try std.fs.path.join(a, &.{ out.staging, "game.apk.aligned" });
    const signed_apk = try std.fs.path.join(a, &.{ out.staging, "game.apk.signed" });

    // aapt: every input through its own flag. The staging dir itself is
    // never a positional argument (aapt would find a second manifest).
    std.debug.print("labelle-android: packaging APK...\n", .{});
    {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ tools.aapt, "package", "-f", "-M", manifest_path, "-I", tools.android_jar, "-F", unsigned_apk });
        if (cwd.access(io, assets_dst, .{})) |_| {
            try argv.appendSlice(a, &.{ "-A", assets_dst });
        } else |_| {}
        // `res/` exists only when the launcher icon was staged; `-S` is what
        // makes the APK carry a `resources.arsc`, which apps targeting API
        // 30+ must store uncompressed (`-0 arsc`).
        const res_dir = try std.fs.path.join(a, &.{ out.staging, icon.res_subdir });
        if (cwd.access(io, res_dir, .{})) |_| {
            try argv.appendSlice(a, &.{ "-S", res_dir, "-0", "arsc" });
        } else |_| {}
        try runTool(a, io, "aapt package", argv.items);
    }
    // Native libraries, STORED (`--no-compress` applies to the entries this
    // adds): API 30+ requires uncompressed `.so`s. `jar` ships with every
    // JDK, unlike `zip` on Windows.
    try runTool(a, io, "jar (add native libs)", &.{ tools.jar, "--update", "--no-compress", "--file", unsigned_apk, "-C", out.staging, "lib" });
    try runTool(a, io, "zipalign", &.{ tools.zipalign, "-f", "4", unsigned_apk, aligned_apk });

    const project_signing = in.settings.signing;
    const resolved = if (project_signing) |configured|
        try signing.resolveConfigured(a, io, env, in.project_dir, configured)
    else
        try signing.debug(a, io, env, in.project_dir);
    if (resolved.is_debug) {
        std.debug.print("labelle-android: signing APK with debug keystore\n", .{});
    } else {
        std.debug.print("labelle-android: signing APK with {s}\n", .{resolved.keystore});
    }
    try runTool(a, io, "apksigner", try signing.apksignerArgv(a, tools.apksigner, resolved, signed_apk, aligned_apk));

    // Every tool succeeded: publish the APK in one rename.
    if (std.fs.path.dirname(out.apk)) |dir| try cwd.createDirPath(io, dir);
    try std.Io.Dir.rename(cwd, signed_apk, cwd, out.apk, io);
    std.debug.print("  APK: {s}\n", .{out.apk});
}

/// Run one packaging tool; a non-zero exit is `error.PackageFailed` with
/// the tool's stderr printed.
fn runTool(a: std.mem.Allocator, io: std.Io, label: []const u8, argv: []const []const u8) !void {
    const result = proc.run(a, io, argv, .{}) catch |err| {
        std.debug.print("labelle-android: {s} failed to start ({s}): {s}\n", .{ label, @errorName(err), argv[0] });
        return error.PackageFailed;
    };
    if (!proc.succeeded(result.term)) {
        std.debug.print("labelle-android: {s} failed: {s}\n", .{ label, result.stderr });
        return error.PackageFailed;
    }
}

/// `apk_assets.json` (labelle-assembler#763): the files a
/// `load_assets_from_apk` build reads from the APK at runtime instead of
/// embedding. The assembler writes an empty list when the option is off,
/// which is all this packager supports so far: a non-empty list would need
/// those files staged under their target-relative path and deflated
/// (labelle-assembler#759), and packaging without them would install an APK that
/// fails at startup. So a non-empty list is refused, before anything is
/// staged. A missing or unparsable file (an older assembler) is ignored.
pub fn checkApkAssets(a: std.mem.Allocator, io: std.Io, target_dir: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ target_dir, "apk_assets.json" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch return;
    const count = apkAssetCount(a, bytes) orelse return;
    if (count == 0) return;
    std.debug.print(
        \\labelle-android: {s} lists {d} file(s) to load from the APK (project.labelle `.android.load_assets_from_apk = true`),
        \\  which this packager cannot stage yet (labelle-assembler#759). Set it to false.
        \\
    , .{ path, count });
    return error.ApkAssetsUnsupported;
}

fn apkAssetCount(a: std.mem.Allocator, bytes: []const u8) ?usize {
    const Doc = struct { files: []const []const u8 = &.{} };
    const doc = std.json.parseFromSliceLeaky(Doc, a, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    return doc.files.len;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "apk_assets.json: the empty list and an older assembler's absence pass, a non-empty list is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try checkApkAssets(a, std.testing.io, root);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "apk_assets.json", .data = "{\"version\":1,\"compression\":\"deflate\",\"files\":[]}\n" });
    try checkApkAssets(a, std.testing.io, root);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "apk_assets.json", .data = "{\"version\":1,\"compression\":\"deflate\",\"files\":[\"assets/a.json\"]}" });
    try std.testing.expectError(error.ApkAssetsUnsupported, checkApkAssets(a, std.testing.io, root));
}

test "package: a missing libgame.so fails before anything is staged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var env = sdk.Env.init(a);
    const staging = try std.fs.path.join(a, &.{ root, "staging" });
    try std.testing.expectError(error.BinaryNotFound, package(a, std.testing.io, &env, .{
        .project_dir = root,
        .target_dir = root,
        .settings = .{ .schema_version = 1, .package_name = "com.a.b" },
        .identity = .{ .name = "g" },
        .strip = false,
    }, .{ .apk = try std.fs.path.join(a, &.{ root, "game.apk" }), .staging = staging, .symbols = root }, .{
        .aapt = "aapt",
        .zipalign = "zipalign",
        .apksigner = "apksigner",
        .jar = "jar",
        .android_jar = "android.jar",
        .llvm_strip = null,
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, staging, .{}));
}
