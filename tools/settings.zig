//! `providers/android.json`, schema v1: the Android packaging settings a
//! project gives this provider through `.provider_config` (labelle-cli#405).
//! It replaces the CLI's old `project.labelle .android` packaging keys.
//!
//! The parse is strict: unknown keys, duplicate keys and wrong types are
//! errors. Validation runs before any side effect, so a bad file stops the
//! invocation before anything is built, staged or signed.
//!
//! Keys the assembler owns (`immersive_mode`, `load_assets_from_apk`) stay in
//! `project.labelle .android` and are rejected here, so no fact has two
//! authored homes. Passwords may only name a source (`env:VAR` or
//! `file:PATH`, the apksigner forms); a `pass:` literal would put a secret in
//! the repository and is rejected.
const std = @import("std");

pub const schema_version = 1;

/// The one ABI v1 packages (labelle-android#10: 64-bit only; the fat APK
/// and the emulator ABI are follow-ups).
pub const supported_abi = "arm64-v8a";

/// The lowest `min_sdk_version`: the runtime module links libmediandk's
/// API 28 entry points and AAudio (API 26).
pub const min_sdk_floor = 28;

/// Android 14.
pub const default_target_sdk = 34;

pub const Orientation = enum {
    portrait,
    /// Android `"landscape"`: one landscape direction.
    landscape,
    /// Android `"sensorLandscape"`: landscape, either direction.
    sensor_landscape,
    all,
};

pub const Signing = struct {
    /// The keystore file, relative to the project directory or absolute.
    keystore: []const u8,
    /// `env:VAR` or `file:PATH`.
    store_password: []const u8,
    key_alias: ?[]const u8 = null,
    /// `env:VAR` or `file:PATH`; apksigner falls back to the store password.
    key_password: ?[]const u8 = null,
};

pub const Deploy = struct {
    /// GitHub `owner/name` the release is published to.
    repo: []const u8,
    channel: Channel = .stable,
};

pub const Channel = enum { stable, staging, preview, internal };

/// The renderer the APK asks the runtime for (labelle-bgfx#172 D2). The
/// packager stamps it into the manifest as `labelle.renderer` meta-data.
pub const Renderer = enum {
    /// OpenGL ES 3.0.
    gles,
    /// Vulkan; the runtime falls back to GLES when init fails (D4).
    vulkan,
    /// Vulkan when the device reports Vulkan >= 1.1, else GLES.
    auto,

    /// The manifest `android:value`: the tag name.
    pub fn value(r: Renderer) []const u8 {
        return @tagName(r);
    }
};

/// `"gles", "vulkan", "auto"`, for the rejection message.
const renderer_values = blk: {
    var text: []const u8 = "";
    for (std.meta.fieldNames(Renderer), 0..) |name, i| {
        text = text ++ (if (i == 0) "" else ", ") ++ "\"" ++ name ++ "\"";
    }
    break :blk text;
};

pub const Settings = struct {
    schema_version: u32,
    package_name: []const u8,
    /// Defaults to the project's `.title`.
    app_name: ?[]const u8 = null,
    min_sdk_version: u32 = min_sdk_floor,
    target_sdk_version: u32 = default_target_sdk,
    orientation: Orientation = .all,
    debuggable: bool = false,
    version_name: []const u8 = "1.0",
    abis: []const []const u8 = &.{supported_abi},
    signing: ?Signing = null,
    deploy: ?Deploy = null,
    /// `gles` until the Vulkan production gate passes (D12 flips it).
    renderer: Renderer = .gles,
};

pub const Error = error{
    InvalidSettings,
    OutOfMemory,
};

/// Why a settings file was refused, for the user.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

/// Keys that belong to `project.labelle .android` (the assembler reads them
/// at generate time).
const assembler_owned = [_][]const u8{ "immersive_mode", "load_assets_from_apk" };

/// Parse and validate a settings document. `diag.message` explains a
/// refusal (allocated in `a`). The result borrows from `a`.
pub fn parse(a: std.mem.Allocator, bytes: []const u8, diag: *Diagnostic) Error!Settings {
    // Name the keys a typed decode would only report as `UnknownField`.
    const raw = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| return fail(a, diag, "not a valid JSON document ({s})", .{@errorName(err)});
    const object = switch (raw) {
        .object => |object| object,
        else => return fail(a, diag, "the top level must be a JSON object", .{}),
    };
    for (assembler_owned) |key| {
        if (object.contains(key))
            return fail(a, diag, "'{s}' is not a provider setting: set this in project.labelle `.android`", .{key});
    }
    for (object.keys()) |key| {
        if (!isField(Settings, key)) return fail(a, diag, "unknown key '{s}'", .{key});
    }
    if (object.get("schema_version")) |version| {
        if (version != .integer or version.integer != schema_version)
            return fail(a, diag, "schema_version must be {d}", .{schema_version});
    } else return fail(a, diag, "missing required key 'schema_version'", .{});
    // A typed decode only says `InvalidEnumTag`; name the allowed values.
    if (object.get("renderer")) |renderer| {
        const ok = renderer == .string and std.meta.stringToEnum(Renderer, renderer.string) != null;
        if (!ok) return fail(a, diag, "renderer must be one of {s}", .{renderer_values});
    }

    const settings = std.json.parseFromSliceLeaky(Settings, a, bytes, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| return fail(a, diag, "does not match schema v1: {s} (a required key is missing, a key has the wrong type, or a value is out of range)", .{@errorName(err)});
    try validate(a, settings, diag);
    return settings;
}

/// Every rule a typed decode cannot express.
pub fn validate(a: std.mem.Allocator, s: Settings, diag: *Diagnostic) Error!void {
    if (s.schema_version != schema_version) return fail(a, diag, "schema_version must be {d}", .{schema_version});
    if (!packageName(s.package_name))
        return fail(a, diag, "package_name '{s}' is not a valid Android package name (e.g. com.studio.game)", .{s.package_name});
    if (s.app_name) |name| {
        if (!displayText(name)) return fail(a, diag, "app_name must be non-empty text without control characters", .{});
    }
    if (s.min_sdk_version < min_sdk_floor)
        return fail(a, diag, "min_sdk_version must be at least {d}", .{min_sdk_floor});
    if (s.target_sdk_version < s.min_sdk_version)
        return fail(a, diag, "target_sdk_version ({d}) is below min_sdk_version ({d})", .{ s.target_sdk_version, s.min_sdk_version });
    if (!displayText(s.version_name)) return fail(a, diag, "version_name must be non-empty text without control characters", .{});
    if (s.abis.len != 1 or !std.mem.eql(u8, s.abis[0], supported_abi))
        return fail(a, diag, "abis must be [\"{s}\"]: 64-bit ARM is the only ABI schema v1 packages", .{supported_abi});
    if (s.signing) |signing| {
        if (signing.keystore.len == 0 or std.mem.indexOfScalar(u8, signing.keystore, 0) != null)
            return fail(a, diag, "signing.keystore must be a path", .{});
        try passwordSource(a, diag, "signing.store_password", signing.store_password);
        if (signing.key_alias) |alias| {
            if (!displayText(alias)) return fail(a, diag, "signing.key_alias must be non-empty text", .{});
        }
        if (signing.key_password) |password| try passwordSource(a, diag, "signing.key_password", password);
    }
    if (s.deploy) |deploy| {
        if (!githubRepo(deploy.repo)) return fail(a, diag, "deploy.repo '{s}' must be a GitHub 'owner/name'", .{deploy.repo});
    }
}

/// The label the launcher shows: `app_name`, else the project's title.
pub fn appName(s: Settings, project_title: []const u8) []const u8 {
    return s.app_name orelse project_title;
}

fn fail(a: std.mem.Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = try std.fmt.allocPrint(a, fmt, args);
    return error.InvalidSettings;
}

fn isField(comptime T: type, key: []const u8) bool {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, key)) return true;
    }
    return false;
}

/// apksigner's `env:VAR` / `file:PATH` forms only: no literal secret.
fn passwordSource(a: std.mem.Allocator, diag: *Diagnostic, key: []const u8, value: []const u8) Error!void {
    if (std.mem.startsWith(u8, value, "env:")) {
        if (envName(value[4..])) return;
        return fail(a, diag, "{s}: 'env:' must name an environment variable", .{key});
    }
    if (std.mem.startsWith(u8, value, "file:")) {
        const path = value[5..];
        if (path.len != 0 and std.mem.indexOfScalar(u8, path, 0) == null) return;
        return fail(a, diag, "{s}: 'file:' must name a file", .{key});
    }
    if (std.mem.startsWith(u8, value, "pass:"))
        return fail(a, diag, "{s}: 'pass:' puts a secret in the repository; use 'env:VAR' or 'file:PATH'", .{key});
    return fail(a, diag, "{s} must be 'env:VAR' or 'file:PATH'", .{key});
}

/// `[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+`.
pub fn packageName(value: []const u8) bool {
    var segments: usize = 0;
    var it = std.mem.splitScalar(u8, value, '.');
    while (it.next()) |segment| {
        if (segment.len == 0 or segment[0] < 'a' or segment[0] > 'z') return false;
        for (segment) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
        }
        segments += 1;
    }
    return segments >= 2;
}

fn envName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn displayText(value: []const u8) bool {
    if (std.mem.trim(u8, value, " \t").len == 0) return false;
    for (value) |c| {
        if (std.ascii.isControl(c)) return false;
    }
    return true;
}

fn githubRepo(value: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    const owner = value[0..slash];
    const name = value[slash + 1 ..];
    if (owner.len == 0 or name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (value, 0..) |c, i| {
        if (i == slash) continue;
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const full =
    \\{
    \\  "schema_version": 1,
    \\  "package_name": "com.labelle.flying_platform",
    \\  "app_name": "Flying Platform",
    \\  "min_sdk_version": 29,
    \\  "target_sdk_version": 34,
    \\  "orientation": "landscape",
    \\  "debuggable": true,
    \\  "version_name": "1.2",
    \\  "abis": ["arm64-v8a"],
    \\  "signing": { "keystore": "keys/release.jks", "store_password": "env:FP_KS_PASS",
    \\               "key_alias": "labelle-release", "key_password": "file:keys/key.pass" },
    \\  "deploy": { "repo": "owner/name", "channel": "staging" },
    \\  "renderer": "vulkan"
    \\}
;

test "the full schema parses into typed settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const s = try parse(arena.allocator(), full, &diag);
    try std.testing.expectEqualStrings("com.labelle.flying_platform", s.package_name);
    try std.testing.expectEqualStrings("Flying Platform", appName(s, "Title"));
    try std.testing.expectEqual(@as(u32, 29), s.min_sdk_version);
    try std.testing.expectEqual(Orientation.landscape, s.orientation);
    try std.testing.expect(s.debuggable);
    try std.testing.expectEqualStrings("1.2", s.version_name);
    try std.testing.expectEqualStrings("env:FP_KS_PASS", s.signing.?.store_password);
    try std.testing.expectEqualStrings("file:keys/key.pass", s.signing.?.key_password.?);
    try std.testing.expectEqual(Channel.staging, s.deploy.?.channel);
    try std.testing.expectEqual(Renderer.vulkan, s.renderer);
}

test "a minimal file gets today's defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const s = try parse(arena.allocator(), "{\"schema_version\": 1, \"package_name\": \"com.studio.game\"}", &diag);
    try std.testing.expectEqual(@as(u32, 28), s.min_sdk_version);
    try std.testing.expectEqual(@as(u32, 34), s.target_sdk_version);
    try std.testing.expectEqual(Orientation.all, s.orientation);
    try std.testing.expect(!s.debuggable);
    try std.testing.expectEqualStrings("1.0", s.version_name);
    try std.testing.expectEqual(@as(usize, 1), s.abis.len);
    try std.testing.expectEqualStrings("arm64-v8a", s.abis[0]);
    try std.testing.expect(s.signing == null and s.deploy == null);
    try std.testing.expectEqual(Renderer.gles, s.renderer);
    // app_name falls back to the project title.
    try std.testing.expectEqualStrings("Project Title", appName(s, "Project Title"));
}

test "every rejection names its reason" {
    const Case = struct { json: []const u8, reason: []const u8 };
    const cases = [_]Case{
        // Structure.
        .{ .json = "[]", .reason = "top level" },
        .{ .json = "{", .reason = "not a valid JSON" },
        .{ .json = "{\"package_name\": \"com.a.b\"}", .reason = "missing required key 'schema_version'" },
        .{ .json = "{\"schema_version\": 2, \"package_name\": \"com.a.b\"}", .reason = "schema_version must be 1" },
        .{ .json = "{\"schema_version\": \"1\", \"package_name\": \"com.a.b\"}", .reason = "schema_version must be 1" },
        .{ .json = "{\"schema_version\": 1}", .reason = "MissingField" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"typo\": 1}", .reason = "unknown key 'typo'" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"package_name\": \"com.a.c\"}", .reason = "DuplicateField" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"debuggable\": \"yes\"}", .reason = "UnexpectedToken" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"orientation\": \"sideways\"}", .reason = "InvalidEnumTag" },
        // Renderer: the message lists the allowed values.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"renderer\": \"metal\"}", .reason = "renderer must be one of \"gles\", \"vulkan\", \"auto\"" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"renderer\": \"Vulkan\"}", .reason = "renderer must be one of" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"renderer\": \"\"}", .reason = "renderer must be one of" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"renderer\": 1}", .reason = "renderer must be one of" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"renderer\": null}", .reason = "renderer must be one of" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"renderer\": \"gles\", \"renderer\": \"vulkan\"}", .reason = "DuplicateField" },
        // Dropped from v0.2.0: studio returns with its own schema.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"studio\": {\"output_dir\": \"x\"}}", .reason = "unknown key 'studio'" },
        // Nested blocks are strict too.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"deploy\": {\"repo\": \"a/b\", \"tag\": \"v1\"}}", .reason = "UnknownField" },
        // Assembler-owned keys.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"immersive_mode\": true}", .reason = "'immersive_mode' is not a provider setting: set this in project.labelle `.android`" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"load_assets_from_apk\": true}", .reason = "'load_assets_from_apk' is not a provider setting" },
        // Package name.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"game\"}", .reason = "package_name 'game'" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"Com.a.b\"}", .reason = "package_name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.1a.b\"}", .reason = "package_name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com..b\"}", .reason = "package_name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a-b.c\"}", .reason = "package_name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"\"}", .reason = "package_name" },
        // Text fields.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"app_name\": \" \"}", .reason = "app_name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"app_name\": \"a\\nb\"}", .reason = "app_name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"version_name\": \"\"}", .reason = "version_name" },
        // SDK levels.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"min_sdk_version\": 26}", .reason = "min_sdk_version must be at least 28" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"min_sdk_version\": 30, \"target_sdk_version\": 29}", .reason = "below min_sdk_version" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"min_sdk_version\": -1}", .reason = "Overflow" },
        // ABIs: arm64-v8a only.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"abis\": []}", .reason = "abis must be" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"abis\": [\"x86_64\"]}", .reason = "abis must be" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"abis\": [\"arm64-v8a\", \"arm64-v8a\"]}", .reason = "abis must be" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"abis\": [\"armeabi-v7a\"]}", .reason = "abis must be" },
        // Secrets.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"signing\": {\"keystore\": \"k.jks\", \"store_password\": \"pass:hunter2\"}}", .reason = "signing.store_password: 'pass:' puts a secret in the repository" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"signing\": {\"keystore\": \"k.jks\", \"store_password\": \"env:K\", \"key_password\": \"pass:x\"}}", .reason = "signing.key_password: 'pass:'" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"signing\": {\"keystore\": \"k.jks\", \"store_password\": \"hunter2\"}}", .reason = "must be 'env:VAR' or 'file:PATH'" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"signing\": {\"keystore\": \"k.jks\", \"store_password\": \"env:\"}}", .reason = "'env:' must name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"signing\": {\"keystore\": \"k.jks\", \"store_password\": \"env:1X\"}}", .reason = "'env:' must name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"signing\": {\"keystore\": \"k.jks\", \"store_password\": \"file:\"}}", .reason = "'file:' must name" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"signing\": {\"keystore\": \"\", \"store_password\": \"env:K\"}}", .reason = "signing.keystore" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"signing\": {\"keystore\": \"k.jks\"}}", .reason = "MissingField" },
        // Deploy.
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"deploy\": {\"repo\": \"name\"}}", .reason = "deploy.repo 'name'" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"deploy\": {\"repo\": \"a/b/c\"}}", .reason = "deploy.repo" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"deploy\": {\"repo\": \"/b\"}}", .reason = "deploy.repo" },
        .{ .json = "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"deploy\": {\"repo\": \"a/b\", \"channel\": \"beta\"}}", .reason = "InvalidEnumTag" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diag: Diagnostic = .{};
        const result = parse(arena.allocator(), case.json, &diag);
        if (result) |_| {
            std.debug.print("accepted: {s}\n", .{case.json});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.InvalidSettings, err);
        if (std.mem.indexOf(u8, diag.message, case.reason) == null) {
            std.debug.print("case {s}\n  expected reason containing '{s}', got '{s}'\n", .{ case.json, case.reason, diag.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "renderer accepts gles, vulkan and auto" {
    inline for (.{ .{ "gles", Renderer.gles }, .{ "vulkan", Renderer.vulkan }, .{ "auto", Renderer.auto } }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diag: Diagnostic = .{};
        const s = try parse(arena.allocator(), "{\"schema_version\": 1, \"package_name\": \"com.a.b\", \"renderer\": \"" ++ case[0] ++ "\"}", &diag);
        try std.testing.expectEqual(case[1], s.renderer);
        try std.testing.expectEqualStrings(case[0], s.renderer.value());
    }
}

test "packageName follows the Android application-id rule" {
    for ([_][]const u8{ "com.a", "com.labelle.flying_platform", "a1.b_2.c3" }) |ok| try std.testing.expect(packageName(ok));
    for ([_][]const u8{ "", "com", "com.", ".com", "com.A", "com._a", "com.a b", "com.a.1" }) |bad| try std.testing.expect(!packageName(bad));
}
