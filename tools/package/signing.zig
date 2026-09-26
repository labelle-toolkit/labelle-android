//! APK signing: which keystore signs, and the apksigner argv.
//!
//! Ported from labelle-cli `src/cli/android/package.zig` (`ResolvedSigning`,
//! `ensureDebugKeystore` and the apksigner call, development 23aa180;
//! labelle-cli#405):
//!
//! - With a `signing` block in `providers/android.json`, that keystore signs.
//!   Its passwords are only ever `env:VAR` / `file:PATH` sources (settings
//!   rejects `pass:` literals), handed to apksigner as-is, so no secret is in
//!   the provider's argv, its logs or the repository. A relative keystore or
//!   `file:` path is resolved against the project directory.
//! - Without one, the debug keystore signs, at the path the CLI has always
//!   used: `<LABELLE_HOME or ~/.labelle>/android-debug.keystore`. Keeping the
//!   path keeps the signature, so `adb install -r` still updates a device
//!   that has a CLI-built APK installed. It is generated with `keytool` on
//!   first use, with the CLI's exact arguments. Its `android` passwords are
//!   the public debug-keystore convention, not a secret.
const std = @import("std");
const builtin = @import("builtin");
const settings_mod = @import("../settings.zig");
const sdk = @import("../sdk.zig");
const proc = @import("../proc.zig");

pub const debug_keystore_name = "android-debug.keystore";
pub const debug_key_alias = "androiddebugkey";
/// The public debug-keystore password, in apksigner's `pass:` form.
pub const debug_password = "pass:android";

/// Post-validation signing values passed into apksigner.
pub const Resolved = struct {
    keystore: []const u8,
    /// apksigner password source: `env:VAR`, `file:PATH`, or the debug
    /// keystore's public `pass:android`.
    keystore_pass: []const u8,
    key_alias: ?[]const u8,
    key_pass: ?[]const u8,
    is_debug: bool,
};

/// Resolve the configured signing block against `project_dir`, checking
/// that every source it names is usable (the env var is set, the file
/// exists) without ever reading a secret's value into a message.
pub fn resolveConfigured(
    a: std.mem.Allocator,
    io: std.Io,
    env: *const sdk.Env,
    project_dir: []const u8,
    signing: settings_mod.Signing,
) !Resolved {
    const keystore = try absoluteFrom(a, project_dir, signing.keystore);
    std.Io.Dir.cwd().access(io, keystore, .{}) catch {
        std.debug.print("labelle-android: signing.keystore not found: {s}\n", .{keystore});
        return error.KeystoreNotFound;
    };
    return .{
        .keystore = keystore,
        .keystore_pass = try passwordSource(a, io, env, project_dir, "signing.store_password", signing.store_password),
        .key_alias = signing.key_alias,
        .key_pass = if (signing.key_password) |p| try passwordSource(a, io, env, project_dir, "signing.key_password", p) else null,
        .is_debug = false,
    };
}

/// Check an `env:`/`file:` source and return it in the form apksigner
/// reads (a relative `file:` made absolute). The value itself is never
/// read or printed.
fn passwordSource(
    a: std.mem.Allocator,
    io: std.Io,
    env: *const sdk.Env,
    project_dir: []const u8,
    key: []const u8,
    source: []const u8,
) ![]const u8 {
    if (std.mem.startsWith(u8, source, "env:")) {
        const name = source["env:".len..];
        if (sdk.envValue(env, name) == null) {
            std.debug.print("labelle-android: {s} names the environment variable {s}, which is not set\n", .{ key, name });
            return error.SigningPasswordUnavailable;
        }
        return source;
    }
    if (std.mem.startsWith(u8, source, "file:")) {
        const path = try absoluteFrom(a, project_dir, source["file:".len..]);
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            std.debug.print("labelle-android: {s} names the file {s}, which does not exist\n", .{ key, path });
            return error.SigningPasswordUnavailable;
        };
        return std.fmt.allocPrint(a, "file:{s}", .{path});
    }
    // settings.validate admits nothing else.
    return error.InvalidSigningPassword;
}

/// `path` against `base` when relative, normalised to the host's
/// separators (settings spell paths with `/` on every OS).
fn absoluteFrom(a: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    return std.fs.path.resolve(a, &.{ base, path });
}

/// The labelle home the CLI uses for its caches: `LABELLE_HOME`, else
/// `~/.labelle` (`%USERPROFILE%\.labelle` on Windows). A relative
/// `LABELLE_HOME` is resolved against this process's cwd, the project root
/// (the CLI resolves it against the user's cwd: export an absolute path
/// when the two differ).
pub fn labelleHome(a: std.mem.Allocator, env: *const sdk.Env, cwd: []const u8) ![]const u8 {
    if (sdk.envValue(env, "LABELLE_HOME")) |home| {
        if (std.fs.path.isAbsolute(home)) return a.dupe(u8, home);
        return std.fs.path.resolve(a, &.{ cwd, home });
    }
    const home_var = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = sdk.envValue(env, home_var) orelse {
        std.debug.print("labelle-android: cannot find the debug keystore: set LABELLE_HOME or {s}\n", .{home_var});
        return error.NoHomeDirectory;
    };
    return std.fs.path.join(a, &.{ home, ".labelle" });
}

/// The debug keystore, generated with `keytool` when missing.
pub fn debug(a: std.mem.Allocator, io: std.Io, env: *const sdk.Env, cwd: []const u8) !Resolved {
    const home = try labelleHome(a, env, cwd);
    const keystore = try std.fs.path.join(a, &.{ home, debug_keystore_name });
    std.Io.Dir.cwd().access(io, keystore, .{}) catch {
        std.debug.print("labelle-android: generating debug keystore {s}...\n", .{keystore});
        try std.Io.Dir.cwd().createDirPath(io, home);
        const keytool = (try sdk.findJdkTool(a, io, env, "keytool")) orelse {
            std.debug.print("labelle-android: keytool not found (install a JDK and set JAVA_HOME)\n", .{});
            return error.KeystoreFailed;
        };
        const result = proc.run(a, io, &.{
            keytool,                   "-genkey",    "-v",
            "-keystore",               keystore,     "-alias",
            debug_key_alias,           "-keyalg",    "RSA",
            "-keysize",                "2048",       "-validity",
            "10000",                   "-storepass", "android",
            "-keypass",                "android",    "-dname",
            "CN=Debug,O=Labelle,C=US",
        }, .{}) catch |err| {
            std.debug.print("labelle-android: failed to run keytool: {s}\n", .{@errorName(err)});
            return error.KeystoreFailed;
        };
        if (!proc.succeeded(result.term)) {
            std.debug.print("labelle-android: keytool failed: {s}\n", .{result.stderr});
            return error.KeystoreFailed;
        }
    };
    return .{
        .keystore = keystore,
        .keystore_pass = debug_password,
        .key_alias = debug_key_alias,
        .key_pass = debug_password,
        .is_debug = true,
    };
}

/// `apksigner sign --ks <ks> --ks-pass <src> [--ks-key-alias <a>]
/// [--key-pass <src>] --out <out> <in>`, the CLI's argv.
pub fn apksignerArgv(a: std.mem.Allocator, apksigner: []const u8, s: Resolved, out: []const u8, in: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ apksigner, "sign", "--ks", s.keystore, "--ks-pass", s.keystore_pass });
    if (s.key_alias) |alias| try args.appendSlice(a, &.{ "--ks-key-alias", alias });
    if (s.key_pass) |pass| try args.appendSlice(a, &.{ "--key-pass", pass });
    try args.appendSlice(a, &.{ "--out", out, in });
    return args.toOwnedSlice(a);
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "apksigner argv: debug keystore, the CLI's exact flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try apksignerArgv(arena.allocator(), "apksigner", .{
        .keystore = "/h/.labelle/android-debug.keystore",
        .keystore_pass = debug_password,
        .key_alias = debug_key_alias,
        .key_pass = debug_password,
        .is_debug = true,
    }, "out.apk", "in.apk");
    try expectArgv(&.{
        "apksigner",      "sign",            "--ks",       "/h/.labelle/android-debug.keystore", "--ks-pass", "pass:android",
        "--ks-key-alias", "androiddebugkey", "--key-pass", "pass:android",                       "--out",     "out.apk",
        "in.apk",
    }, argv);
}

test "apksigner argv: optional alias and key password are omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try apksignerArgv(arena.allocator(), "apksigner", .{
        .keystore = "k.jks",
        .keystore_pass = "env:KS",
        .key_alias = null,
        .key_pass = null,
        .is_debug = false,
    }, "o", "i");
    try expectArgv(&.{ "apksigner", "sign", "--ks", "k.jks", "--ks-pass", "env:KS", "--out", "o", "i" }, argv);
}

test "configured signing: sources pass through, relative paths resolve, values are never read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try tmp.dir.createDirPath(std.testing.io, "keys");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keys/release.jks", .data = "KS" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keys/key.pass", .data = "hunter2" });
    var env = sdk.Env.init(a);
    try env.put("FP_KS_PASS", "hunter2");

    const r = try resolveConfigured(a, std.testing.io, &env, root, .{
        .keystore = "keys/release.jks",
        .store_password = "env:FP_KS_PASS",
        .key_alias = "release",
        .key_password = "file:keys/key.pass",
    });
    try std.testing.expect(!r.is_debug);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "keys", "release.jks" }), r.keystore);
    try std.testing.expectEqualStrings("env:FP_KS_PASS", r.keystore_pass);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "file:{s}", .{try std.fs.path.join(a, &.{ root, "keys", "key.pass" })}), r.key_pass.?);
    const argv = try apksignerArgv(a, "apksigner", r, "o", "i");
    for (argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "hunter2") == null);
}

test "configured signing: an unset env var or a missing file is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "release.jks", .data = "KS" });
    var env = sdk.Env.init(a);
    try std.testing.expectError(error.SigningPasswordUnavailable, resolveConfigured(a, std.testing.io, &env, root, .{
        .keystore = "release.jks",
        .store_password = "env:NOT_SET_ANYWHERE",
    }));
    try std.testing.expectError(error.SigningPasswordUnavailable, resolveConfigured(a, std.testing.io, &env, root, .{
        .keystore = "release.jks",
        .store_password = "file:missing.pass",
    }));
    try std.testing.expectError(error.KeystoreNotFound, resolveConfigured(a, std.testing.io, &env, root, .{
        .keystore = "nope.jks",
        .store_password = "env:X",
    }));
}

test "debug keystore path: LABELLE_HOME, else ~/.labelle (the CLI's cache root)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (builtin.os.tag == .windows) "C:\\p" else "/p";
    var env = sdk.Env.init(a);
    try std.testing.expectError(error.NoHomeDirectory, labelleHome(a, &env, root));
    try env.put(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME", root);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, ".labelle" }), try labelleHome(a, &env, root));
    const abs_home = if (builtin.os.tag == .windows) "C:\\lh" else "/lh";
    try env.put("LABELLE_HOME", abs_home);
    try std.testing.expectEqualStrings(abs_home, try labelleHome(a, &env, root));
    try env.put("LABELLE_HOME", "rel");
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "rel" }), try labelleHome(a, &env, root));
}

test "an existing debug keystore is reused without keytool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = debug_keystore_name, .data = "KS" });
    var env = sdk.Env.init(a);
    try env.put("LABELLE_HOME", root);
    // No JAVA_HOME and no PATH: reaching keytool would fail.
    const r = try debug(a, std.testing.io, &env, root);
    try std.testing.expect(r.is_debug);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, debug_keystore_name }), r.keystore);
}
