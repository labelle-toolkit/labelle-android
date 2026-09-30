//! Launch-time renderer resolution (labelle-android#27; labelle-bgfx#172
//! D1-D3, D11).
//!
//! labelle-android owns the Android renderer POLICY; labelle-bgfx only reads
//! `LABELLE_BGFX_RENDERER` before `bgfx.init` (labelle-bgfx#176). This file
//! decides the value and exports it, once per activity launch.
//!
//! Resolution order, first match wins:
//!   1. `intent`: the `LABELLE_BGFX_RENDERER` launch extra (`vulkan`|`gles`),
//!      only in a debuggable apk (the same gate as the other debuggable-only
//!      keys in `intent_env.zig`). Anything else is warned about and ignored.
//!   2. `crash-guard`: Vulkan disabled after a crashed Vulkan start (D11,
//!      `crash_guard.zig`; a stub until labelle-android#28) → `gles`.
//!   3. `setting`: the provider setting, stamped into the manifest as
//!      `<meta-data android:name="labelle.renderer" android:value="..."/>`
//!      (labelle-android#26). Missing or unreadable → `gles`; an invalid
//!      value → `gles` with a warning.
//!   4. `auto` (the setting's third value): Vulkan when the device reports
//!      `android.hardware.vulkan.version` >= 1.1 (0x401000), else `gles`.
//!
//! Then `setenv("LABELLE_BGFX_RENDERER", "vulkan"|"gles", 1)` and one log
//! line: `renderer: <value> (source: intent|crash-guard|setting|auto)`.
//!
//! ## Where it runs
//!
//! `launch_intent.apply` calls `resolve` LAST, so it runs from the same entry
//! point the backends already call before anything reads the environment:
//! bgfx calls `apply` at the top of `run(app)`, before the event loop that
//! delivers the first INIT_WINDOW, and bgfx is only initialised inside that
//! loop, so the variable is always set before `bgfx.init`.
//!
//! `decide` is the PURE half (host-tested with fakes below); `resolve` is the
//! Android glue (JNI in `jni/renderer_query.c`, libc `setenv`).
const std = @import("std");
const debuggable_mod = @import("debuggable.zig");
const crash_guard = @import("crash_guard.zig");
const is_android = @import("root.zig").is_android;

/// The environment variable labelle-bgfx reads before `bgfx.init`.
pub const env_name: [:0]const u8 = "LABELLE_BGFX_RENDERER";
/// The manifest `<meta-data>` name the packager stamps (labelle-android#26).
pub const meta_data_name = "labelle.renderer";
/// `android.hardware.vulkan.version` for Vulkan 1.1 (D2, D7).
pub const vulkan_1_1: c_int = 0x401000;

/// What is exported in `LABELLE_BGFX_RENDERER`.
pub const Renderer = enum {
    gles,
    vulkan,

    pub fn envValue(self: Renderer) [:0]const u8 {
        return switch (self) {
            .gles => "gles",
            .vulkan => "vulkan",
        };
    }
};

/// Which rule decided (the `source:` in the log line).
pub const Source = enum {
    intent,
    crash_guard,
    setting,
    auto,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .intent => "intent",
            .crash_guard => "crash-guard",
            .setting => "setting",
            .auto => "auto",
        };
    }
};

pub const Decision = struct { renderer: Renderer, source: Source };

/// The provider setting's values.
pub const Setting = enum { gles, vulkan, auto };

/// An explicit renderer (the intent extra). Exact, lower-case match only.
pub fn parseRenderer(value: []const u8) ?Renderer {
    if (std.mem.eql(u8, value, "vulkan")) return .vulkan;
    if (std.mem.eql(u8, value, "gles")) return .gles;
    return null;
}

/// The `labelle.renderer` meta-data. Exact, lower-case match only (the
/// provider setting is parsed strictly, so a valid APK only carries these).
pub fn parseSetting(value: []const u8) ?Setting {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (parseRenderer(value)) |r| return switch (r) {
        .gles => .gles,
        .vulkan => .vulkan,
    };
    return null;
}

/// Decide the renderer. `q` answers, lazily and in this order, only what the
/// rules need:
///   * `intentExtra() ?[]const u8` — the launch extra (null = absent)
///   * `debuggable() bool` — asked only when the extra is present
///   * `vulkanDisabled() bool` — the D11 crash guard
///   * `metaData() ?[]const u8` — the `labelle.renderer` meta-data (null =
///     missing or unreadable)
///   * `hasVulkan() bool` — asked only for `auto`
pub fn decide(q: anytype) Decision {
    if (q.intentExtra()) |v| {
        // An empty extra counts as absent, as it does in `intent_env`.
        if (v.len > 0) {
            if (!q.debuggable()) {
                std.log.info("android: ignoring intent extra {s}: the apk is not debuggable", .{env_name});
            } else if (parseRenderer(v)) |r| {
                return .{ .renderer = r, .source = .intent };
            } else {
                std.log.warn("android: ignoring intent extra {s}='{s}' (expected 'vulkan' or 'gles')", .{ env_name, v });
            }
        }
    }
    if (q.vulkanDisabled()) return .{ .renderer = .gles, .source = .crash_guard };
    const setting: Setting = if (q.metaData()) |raw|
        parseSetting(raw) orelse blk: {
            std.log.warn("android: invalid {s} meta-data '{s}' (expected 'gles', 'vulkan' or 'auto'); using gles", .{ meta_data_name, raw });
            break :blk .gles;
        }
    else
        .gles;
    return switch (setting) {
        .gles => .{ .renderer = .gles, .source = .setting },
        .vulkan => .{ .renderer = .vulkan, .source = .setting },
        .auto => .{ .renderer = if (q.hasVulkan()) .vulkan else .gles, .source = .auto },
    };
}

// ── Android glue ────────────────────────────────────────────────────────

// `jni/renderer_query.c` — only referenced on Android, where build.zig
// compiles the C TU into this module.
extern "c" fn labelle_android_read_renderer_meta(activity: ?*const anyopaque, buf: [*]u8, buf_cap: usize) c_int;
extern "c" fn labelle_android_has_system_feature(activity: ?*const anyopaque, name: [*:0]const u8, version: c_int) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const JniQuery = struct {
    activity: *const anyopaque,
    extra: ?[:0]const u8,
    meta_buf: [64]u8 = undefined,

    pub fn intentExtra(self: *JniQuery) ?[]const u8 {
        return self.extra;
    }
    pub fn debuggable(self: *JniQuery) bool {
        return debuggable_mod.isDebuggable(self.activity);
    }
    pub fn vulkanDisabled(self: *JniQuery) bool {
        return crash_guard.isVulkanDisabled(self.activity);
    }
    pub fn metaData(self: *JniQuery) ?[]const u8 {
        const n = labelle_android_read_renderer_meta(self.activity, &self.meta_buf, self.meta_buf.len);
        switch (n) {
            -1 => {
                std.log.info("android: no {s} meta-data; using gles", .{meta_data_name});
                return null;
            },
            -3 => {
                std.log.warn("android: {s} meta-data too long; using gles", .{meta_data_name});
                return null;
            },
            else => if (n < 0) {
                std.log.warn("android: could not read the {s} meta-data; using gles", .{meta_data_name});
                return null;
            },
        }
        return self.meta_buf[0..@intCast(n)];
    }
    pub fn hasVulkan(self: *JniQuery) bool {
        return labelle_android_has_system_feature(self.activity, "android.hardware.vulkan.version", vulkan_1_1) != 0;
    }
};

/// Resolve the renderer and export `LABELLE_BGFX_RENDERER`. `activity` is the
/// running `ANativeActivity*` (opaque); `intent_extra` is this launch's
/// `LABELLE_BGFX_RENDERER` extra (null = absent). Comptime no-op off
/// Android; a null activity changes nothing. Called by `launch_intent.apply`,
/// after the intent extras are applied, so the value it writes is final.
pub fn resolve(activity: ?*const anyopaque, intent_extra: ?[:0]const u8) void {
    if (comptime !is_android) return;
    const a = activity orelse return;
    var q: JniQuery = .{ .activity = a, .extra = intent_extra };
    const d = decide(&q);
    if (setenv(env_name.ptr, d.renderer.envValue().ptr, 1) != 0) {
        std.log.warn("android: could not set {s}={s}", .{ env_name, d.renderer.envValue() });
    }
    std.log.info("renderer: {s} (source: {s})", .{ d.renderer.envValue(), d.source.label() });
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// Scripted answers + a record of which questions were asked, so each test
/// asserts WHICH rule decided, not just the value.
const Fake = struct {
    extra: ?[]const u8 = null,
    is_debuggable: bool = false,
    disabled: bool = false,
    meta: ?[]const u8 = null,
    vulkan: bool = false,

    debuggable_calls: usize = 0,
    guard_calls: usize = 0,
    meta_calls: usize = 0,
    vulkan_calls: usize = 0,

    pub fn intentExtra(self: *Fake) ?[]const u8 {
        return self.extra;
    }
    pub fn debuggable(self: *Fake) bool {
        self.debuggable_calls += 1;
        return self.is_debuggable;
    }
    pub fn vulkanDisabled(self: *Fake) bool {
        self.guard_calls += 1;
        return self.disabled;
    }
    pub fn metaData(self: *Fake) ?[]const u8 {
        self.meta_calls += 1;
        return self.meta;
    }
    pub fn hasVulkan(self: *Fake) bool {
        self.vulkan_calls += 1;
        return self.vulkan;
    }
};

fn expectDecision(expected: Decision, got: Decision) !void {
    try testing.expectEqual(expected.renderer, got.renderer);
    try testing.expectEqual(expected.source, got.source);
}

test "intent override wins in a debuggable apk; nothing later is asked" {
    var f: Fake = .{ .extra = "vulkan", .is_debuggable = true, .disabled = true, .meta = "gles" };
    try expectDecision(.{ .renderer = .vulkan, .source = .intent }, decide(&f));
    try testing.expectEqual(@as(usize, 1), f.debuggable_calls);
    try testing.expectEqual(@as(usize, 0), f.guard_calls);
    try testing.expectEqual(@as(usize, 0), f.meta_calls);

    var g: Fake = .{ .extra = "gles", .is_debuggable = true, .meta = "vulkan" };
    try expectDecision(.{ .renderer = .gles, .source = .intent }, decide(&g));
    try testing.expectEqual(@as(usize, 0), g.meta_calls);
}

test "the intent override is ignored when the apk is not debuggable" {
    var f: Fake = .{ .extra = "vulkan", .is_debuggable = false, .meta = "gles" };
    try expectDecision(.{ .renderer = .gles, .source = .setting }, decide(&f));
    try testing.expectEqual(@as(usize, 1), f.debuggable_calls);
    try testing.expectEqual(@as(usize, 1), f.meta_calls);
}

test "an absent or empty extra never asks debuggable" {
    var f: Fake = .{ .meta = "vulkan" };
    try expectDecision(.{ .renderer = .vulkan, .source = .setting }, decide(&f));
    var g: Fake = .{ .extra = "", .is_debuggable = true, .meta = "vulkan" };
    try expectDecision(.{ .renderer = .vulkan, .source = .setting }, decide(&g));
    try testing.expectEqual(@as(usize, 0), f.debuggable_calls + g.debuggable_calls);
}

test "an invalid intent value falls through to the next rule" {
    inline for (.{ "metal", "Vulkan", "opengl", "auto", " vulkan" }) |bad| {
        var f: Fake = .{ .extra = bad, .is_debuggable = true, .meta = "vulkan" };
        try expectDecision(.{ .renderer = .vulkan, .source = .setting }, decide(&f));
        try testing.expectEqual(@as(usize, 1), f.meta_calls);
    }
}

test "the crash guard comes after the intent and before the setting" {
    var f: Fake = .{ .disabled = true, .meta = "vulkan", .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .crash_guard }, decide(&f));
    try testing.expectEqual(@as(usize, 1), f.guard_calls);
    try testing.expectEqual(@as(usize, 0), f.meta_calls);
    try testing.expectEqual(@as(usize, 0), f.vulkan_calls);

    // A non-debuggable extra does not skip the guard either.
    var g: Fake = .{ .extra = "vulkan", .disabled = true, .meta = "vulkan" };
    try expectDecision(.{ .renderer = .gles, .source = .crash_guard }, decide(&g));
}

test "the setting applies when there is no override and the guard is clear" {
    var f: Fake = .{ .meta = "vulkan" };
    try expectDecision(.{ .renderer = .vulkan, .source = .setting }, decide(&f));
    try testing.expectEqual(@as(usize, 1), f.guard_calls);
    try testing.expectEqual(@as(usize, 0), f.vulkan_calls); // explicit: no device check
    var g: Fake = .{ .meta = "gles", .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .setting }, decide(&g));
}

test "missing meta-data means gles" {
    var f: Fake = .{ .meta = null, .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .setting }, decide(&f));
    try testing.expectEqual(@as(usize, 1), f.meta_calls);
    try testing.expectEqual(@as(usize, 0), f.vulkan_calls);
}

test "an invalid meta-data value means gles" {
    inline for (.{ "metal", "VULKAN", "Auto", "", "vulkan " }) |bad| {
        var f: Fake = .{ .meta = bad, .vulkan = true };
        try expectDecision(.{ .renderer = .gles, .source = .setting }, decide(&f));
        try testing.expectEqual(@as(usize, 0), f.vulkan_calls);
    }
}

test "auto: Vulkan when the device has Vulkan 1.1, else gles" {
    var f: Fake = .{ .meta = "auto", .vulkan = true };
    try expectDecision(.{ .renderer = .vulkan, .source = .auto }, decide(&f));
    try testing.expectEqual(@as(usize, 1), f.vulkan_calls);
    var g: Fake = .{ .meta = "auto", .vulkan = false };
    try expectDecision(.{ .renderer = .gles, .source = .auto }, decide(&g));
    try testing.expectEqual(@as(usize, 1), g.vulkan_calls);
}

test "env values and log labels" {
    try testing.expectEqualStrings("vulkan", Renderer.vulkan.envValue());
    try testing.expectEqualStrings("gles", Renderer.gles.envValue());
    try testing.expectEqualStrings("crash-guard", Source.crash_guard.label());
    try testing.expectEqualStrings("intent", Source.intent.label());
    try testing.expectEqualStrings("setting", Source.setting.label());
    try testing.expectEqualStrings("auto", Source.auto.label());
}

test "resolve is a no-op off Android (and never touches the externs)" {
    if (comptime is_android) return error.SkipZigTest;
    resolve(null, null);
    resolve(@ptrFromInt(0x1000), "vulkan");
}
