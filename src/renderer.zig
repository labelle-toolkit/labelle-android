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
//!      `crash_guard.zig`, labelle-android#28) → `gles`. The guard is keyed
//!      on the app's versionCode and the effective setting (rule 3), so a
//!      new version or a changed setting tries Vulkan again.
//!   3. `setting`: the provider setting, stamped into the manifest as
//!      `<meta-data android:name="labelle.renderer" android:value="..."/>`
//!      (labelle-android#26). Missing (the key is not in the bundle) → the
//!      default, `auto` (rule 4, source `auto` with `; default`;
//!      labelle-android#30). Unreadable (a JNI error) → `gles`. Invalid —
//!      an unknown string, a too-long one, or a present non-string/null
//!      value — → `gles` with a warning (source `setting` with
//!      `; invalid meta-data`); never the default, never Vulkan.
//!   4. `auto` (the setting's third value, and the default since 0.5.0):
//!      Vulkan when the device reports `android.hardware.vulkan.version`
//!      >= 1.1 (0x401000), else `gles`.
//!
//! Then, when the result is `vulkan`, `crash_guard.beginVulkanStart` (the
//! start mark + the stable thread: 120 frames and 10 s). If the start mark
//! cannot be recorded, `afterStart` switches this launch to `gles` (fail
//! closed; not for an intent override). Then
//! `setenv("LABELLE_BGFX_RENDERER", "vulkan"|"gles", 1)` and one log line:
//! `renderer: <value> (source: intent|crash-guard|setting|auto)`, with
//! `; previous Vulkan start did not complete` (or `; could not record the
//! Vulkan start`) after `crash-guard`, `; default` after an `auto` that
//! came from a missing meta-data, and `; invalid meta-data` after a
//! `setting` that was present but invalid. A default `auto` that picks Vulkan goes
//! through the crash guard exactly like an explicit `vulkan` or `auto`.
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
    /// The guard could not record the Vulkan start (no start mark), so this
    /// launch stays off Vulkan (`afterStart`).
    crash_guard_unrecorded,
    setting,
    /// `gles` because the meta-data is present but invalid (an unknown or
    /// too-long string, or not a string at all). Logged as `setting` with
    /// `; invalid meta-data`.
    setting_invalid,
    auto,
    /// `auto` because the meta-data is missing: the default setting
    /// (labelle-android#30). Logged as `auto` with `; default`.
    auto_default,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .intent => "intent",
            .crash_guard, .crash_guard_unrecorded => "crash-guard",
            .setting, .setting_invalid => "setting",
            .auto, .auto_default => "auto",
        };
    }

    /// Extra context after the label in the log line ("" for none).
    pub fn detail(self: Source) []const u8 {
        return switch (self) {
            .crash_guard => "; previous Vulkan start did not complete",
            .crash_guard_unrecorded => "; could not record the Vulkan start",
            .auto_default => "; default",
            .setting_invalid => "; invalid meta-data",
            else => "",
        };
    }
};

pub const Decision = struct { renderer: Renderer, source: Source };

/// After `crash_guard.beginVulkanStart` for a `vulkan` decision: when the
/// start mark could NOT be recorded (`recorded` false), a Vulkan crash would
/// go unnoticed, so the launch falls back to `gles` (fail closed). An intent
/// override is a developer's explicit request and keeps Vulkan (warned).
pub fn afterStart(d: Decision, recorded: bool) Decision {
    if (d.renderer != .vulkan or recorded) return d;
    if (d.source == .intent) {
        std.log.warn("android: crash guard: Vulkan start not recorded; keeping vulkan for the intent override", .{});
        return d;
    }
    return .{ .renderer = .gles, .source = .crash_guard_unrecorded };
}

/// The provider setting's values.
pub const Setting = enum { gles, vulkan, auto };

/// What a missing `labelle.renderer` meta-data means (labelle-android#30):
/// the same default as a `providers/android.json` without a `renderer` key,
/// so an APK packaged without the meta-data behaves like a new default one.
/// `gles` is the explicit opt-out.
pub const default_setting: Setting = .auto;

/// The outcomes of the `labelle.renderer` meta-data read. The JNI helper's
/// return code carries them across the C boundary (the contract is spelled
/// out on `labelle_android_read_renderer_meta` in `jni/renderer_query.c`):
/// `>= 0` = value length, `-1` = absent (`containsKey` false, or no bundle),
/// `-3` = too long, `-4` = present but not a String (or null), `-2` (or any
/// other negative) = read error.
pub const MetaRead = union(enum) {
    /// Read successfully (may still be an invalid value; `decide` warns).
    value: []const u8,
    /// Read successfully; the key is not there → the default
    /// (`default_setting`, `auto`).
    absent,
    /// Read successfully; the value does not fit the buffer (so it is not a
    /// valid setting) → `gles`, like any invalid value.
    too_long,
    /// Read successfully; the key is present but its value is not a String
    /// (a Boolean, an Integer, a resource id) or is null. Invalid → `gles`,
    /// NOT the default: a malformed meta-data must never enable Vulkan.
    wrong_type,
    /// The JNI walk failed: the setting is UNKNOWN.
    read_error,

    pub fn fromCode(n: c_int, buf: []const u8) MetaRead {
        if (n >= 0) return .{ .value = buf[0..@intCast(n)] };
        return switch (n) {
            -1 => .absent,
            -3 => .too_long,
            -4 => .wrong_type,
            else => .read_error,
        };
    }

    /// The setting the crash guard compares/records: the effective setting
    /// for every SUCCESSFUL read (absent → the default `auto`; invalid, too
    /// long or wrong type → `gles`), and null for a read error, which the guard treats as
    /// unknown (marks kept).
    pub fn guardSetting(self: MetaRead) ?[]const u8 {
        return switch (self) {
            .value => |v| settingLabel(v),
            .absent => settingLabel(null),
            .too_long, .wrong_type => "gles",
            .read_error => null,
        };
    }
};

/// The effective setting the crash guard's stamp records: the parsed
/// meta-data, `default_setting` (`auto`) for missing, and `gles` for
/// invalid (which is what they mean).
pub fn settingLabel(meta: ?[]const u8) []const u8 {
    const raw = meta orelse return @tagName(default_setting);
    return @tagName(parseSetting(raw) orelse .gles);
}

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
///   * `metaData() MetaRead` — the `labelle.renderer` meta-data read
///     (absent → `default_setting`; read error, invalid, too long or wrong
///     type → `gles`)
///   * `hasVulkan() bool` — asked only for `auto` (explicit or default)
pub fn decide(q: anytype) Decision {
    if (q.intentExtra()) |v| {
        // An empty extra counts as absent, as it does in `intent_env`.
        if (v.len > 0) {
            if (!q.debuggable()) {
                // Not logged here: `launch_intent.apply` (intent_env's
                // debuggable-only gate) already logs "ignoring intent extra
                // LABELLE_BGFX_RENDERER: the apk is not debuggable" once.
            } else if (parseRenderer(v)) |r| {
                return .{ .renderer = r, .source = .intent };
            } else {
                std.log.warn("android: ignoring intent extra {s}='{s}' (expected 'vulkan' or 'gles')", .{ env_name, v });
            }
        }
    }
    if (q.vulkanDisabled()) return .{ .renderer = .gles, .source = .crash_guard };
    const meta: MetaRead = q.metaData();
    const setting: Setting = switch (meta) {
        .value => |raw| parseSetting(raw) orelse {
            std.log.warn("android: invalid {s} meta-data '{s}' (expected 'gles', 'vulkan' or 'auto'); using gles", .{ meta_data_name, raw });
            return .{ .renderer = .gles, .source = .setting_invalid };
        },
        .absent => default_setting,
        // Present but unusable: the safe renderer, never the default.
        // (Warned once where the read happens, `JniQuery.metaRead`.)
        .too_long, .wrong_type => return .{ .renderer = .gles, .source = .setting_invalid },
        // Unknown: stay on the safe renderer.
        .read_error => .gles,
    };
    return switch (setting) {
        .gles => .{ .renderer = .gles, .source = .setting },
        .vulkan => .{ .renderer = .vulkan, .source = .setting },
        .auto => .{
            .renderer = if (q.hasVulkan()) .vulkan else .gles,
            .source = if (meta == .absent) .auto_default else .auto,
        },
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
    /// The meta-data is asked for by the guard (for its stamp) and by the
    /// setting rule; the JNI walk (and its log line) happens once.
    meta: ?MetaRead = null,

    pub fn intentExtra(self: *JniQuery) ?[]const u8 {
        return self.extra;
    }
    pub fn debuggable(self: *JniQuery) bool {
        return debuggable_mod.isDebuggable(self.activity);
    }
    pub fn vulkanDisabled(self: *JniQuery) bool {
        return crash_guard.vulkanDisabled(self.activity, self.metaRead().guardSetting());
    }
    pub fn metaData(self: *JniQuery) MetaRead {
        return self.metaRead();
    }
    fn metaRead(self: *JniQuery) MetaRead {
        if (self.meta) |m| return m;
        const n = labelle_android_read_renderer_meta(self.activity, &self.meta_buf, self.meta_buf.len);
        const m = MetaRead.fromCode(n, &self.meta_buf);
        switch (m) {
            .value => {},
            .absent => std.log.info("android: no {s} meta-data; using the default ({s})", .{ meta_data_name, @tagName(default_setting) }),
            .too_long => std.log.warn("android: {s} meta-data too long; using gles", .{meta_data_name}),
            .wrong_type => std.log.warn("android: {s} meta-data is not a string (use android:value=\"gles|vulkan|auto\"); using gles", .{meta_data_name}),
            .read_error => std.log.warn("android: could not read the {s} meta-data; using gles (crash-guard marks kept)", .{meta_data_name}),
        }
        self.meta = m;
        return m;
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
    // Every resolution supersedes this process's earlier Vulkan stable
    // thread (whatever it picks), keeping its start mark "incomplete".
    crash_guard.beginResolution();
    var q: JniQuery = .{ .activity = a, .extra = intent_extra };
    var d = decide(&q);
    if (d.renderer == .vulkan) d = afterStart(d, crash_guard.beginVulkanStart(a, q.metaRead().guardSetting()));
    if (setenv(env_name.ptr, d.renderer.envValue().ptr, 1) != 0) {
        std.log.warn("android: could not set {s}={s}", .{ env_name, d.renderer.envValue() });
    }
    std.log.info("renderer: {s} (source: {s}{s})", .{ d.renderer.envValue(), d.source.label(), d.source.detail() });
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// Scripted answers + a record of which questions were asked, so each test
/// asserts WHICH rule decided, not just the value.
const Fake = struct {
    extra: ?[]const u8 = null,
    is_debuggable: bool = false,
    disabled: bool = false,
    /// The meta-data value; null = the key is absent.
    meta: ?[]const u8 = null,
    /// Overrides `meta` with another read outcome (too long, read error).
    read: ?MetaRead = null,
    /// Overrides both with a raw JNI return code, decoded by
    /// `MetaRead.fromCode` exactly as `JniQuery` does (with `code_buf`).
    code: ?c_int = null,
    code_buf: []const u8 = "",
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
    pub fn metaData(self: *Fake) MetaRead {
        self.meta_calls += 1;
        if (self.code) |n| return MetaRead.fromCode(n, self.code_buf);
        if (self.read) |r| return r;
        return if (self.meta) |v| .{ .value = v } else .absent;
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

test "the default setting is auto (labelle-android#30)" {
    try testing.expectEqual(Setting.auto, default_setting);
    try testing.expectEqualStrings("auto", settingLabel(null));
}

test "missing meta-data means the default auto: Vulkan on a Vulkan 1.1 device" {
    var f: Fake = .{ .meta = null, .vulkan = true };
    // The default-auto path ran (not `setting`, not an explicit `auto`).
    try expectDecision(.{ .renderer = .vulkan, .source = .auto_default }, decide(&f));
    try testing.expectEqual(@as(usize, 1), f.guard_calls);
    try testing.expectEqual(@as(usize, 1), f.meta_calls);
    try testing.expectEqual(@as(usize, 1), f.vulkan_calls); // the device check ran
}

test "missing meta-data on a device without Vulkan 1.1: gles via the default auto's device check" {
    var f: Fake = .{ .meta = null, .vulkan = false };
    try expectDecision(.{ .renderer = .gles, .source = .auto_default }, decide(&f));
    try testing.expectEqual(@as(usize, 1), f.vulkan_calls);
}

test "explicit gles is the opt-out: no device check, even on a Vulkan device" {
    var f: Fake = .{ .meta = "gles", .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .setting }, decide(&f));
    try testing.expectEqual(@as(usize, 0), f.vulkan_calls);
}

test "an unreadable meta-data stays gles (not the default)" {
    var f: Fake = .{ .read = .read_error, .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .setting }, decide(&f));
    try testing.expectEqual(@as(usize, 0), f.vulkan_calls);
}

test "a too-long or non-string meta-data is invalid: gles, never the default" {
    inline for (.{ MetaRead.too_long, MetaRead.wrong_type }) |r| {
        var f: Fake = .{ .read = r, .vulkan = true };
        try expectDecision(.{ .renderer = .gles, .source = .setting_invalid }, decide(&f));
        try testing.expectEqual(@as(usize, 0), f.vulkan_calls);
    }
}

test "JNI codes end to end: only -1 (absent) reaches the default auto" {
    // -1: the key is not in the bundle → the default auto; the device
    // check RUNS, and the guard stamp is `auto`.
    var absent: Fake = .{ .code = -1, .vulkan = true };
    try expectDecision(.{ .renderer = .vulkan, .source = .auto_default }, decide(&absent));
    try testing.expectEqual(@as(usize, 1), absent.vulkan_calls);
    try testing.expectEqualStrings("auto", absent.metaData().guardSetting().?);

    // -4: present but a Boolean / Integer / resource id / null (labelle-
    // android#39 review) → gles via the INVALID path, the device check
    // never runs, and the guard stamp is `gles`, not `auto`.
    var wrong: Fake = .{ .code = -4, .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .setting_invalid }, decide(&wrong));
    try testing.expectEqual(@as(usize, 0), wrong.vulkan_calls);
    try testing.expectEqual(@as(usize, 1), wrong.guard_calls);
    const wrong_stamp = wrong.metaData().guardSetting().?;
    try testing.expectEqualStrings("gles", wrong_stamp);
    try testing.expect(!std.mem.eql(u8, wrong_stamp, "auto"));

    // -2 (and any unknown negative): a read failure → gles, no device
    // check, and an UNKNOWN guard setting (marks kept).
    inline for (.{ -2, -9 }) |n| {
        var err: Fake = .{ .code = n, .vulkan = true };
        try expectDecision(.{ .renderer = .gles, .source = .setting }, decide(&err));
        try testing.expectEqual(@as(usize, 0), err.vulkan_calls);
        try testing.expect(err.metaData().guardSetting() == null);
    }

    // -3: too long → invalid, gles.
    var long: Fake = .{ .code = -3, .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .setting_invalid }, decide(&long));
    try testing.expectEqual(@as(usize, 0), long.vulkan_calls);

    // >= 0: a String, parsed as before.
    var ok: Fake = .{ .code = 4, .code_buf = "autoXX", .vulkan = true };
    try expectDecision(.{ .renderer = .vulkan, .source = .auto }, decide(&ok));
    try testing.expectEqual(@as(usize, 1), ok.vulkan_calls);
}

test "the crash guard still beats the default auto; the intent still beats both" {
    var f: Fake = .{ .meta = null, .disabled = true, .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .crash_guard }, decide(&f));
    try testing.expectEqual(@as(usize, 0), f.meta_calls);
    try testing.expectEqual(@as(usize, 0), f.vulkan_calls);

    var g: Fake = .{ .extra = "gles", .is_debuggable = true, .meta = null, .vulkan = true };
    try expectDecision(.{ .renderer = .gles, .source = .intent }, decide(&g));
    try testing.expectEqual(@as(usize, 0), g.guard_calls);
    try testing.expectEqual(@as(usize, 0), g.meta_calls);
}

test "an invalid meta-data value means gles" {
    inline for (.{ "metal", "VULKAN", "Auto", "", "vulkan " }) |bad| {
        var f: Fake = .{ .meta = bad, .vulkan = true };
        try expectDecision(.{ .renderer = .gles, .source = .setting_invalid }, decide(&f));
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
    try testing.expectEqualStrings("auto", Source.auto_default.label());
    try testing.expectEqualStrings("; default", Source.auto_default.detail());
    try testing.expectEqualStrings("", Source.auto.detail());
    try testing.expectEqualStrings("; previous Vulkan start did not complete", Source.crash_guard.detail());
    try testing.expectEqualStrings("crash-guard", Source.crash_guard_unrecorded.label());
    try testing.expectEqualStrings("; could not record the Vulkan start", Source.crash_guard_unrecorded.detail());
    try testing.expectEqualStrings("", Source.setting.detail());
    try testing.expectEqualStrings("setting", Source.setting_invalid.label());
    try testing.expectEqualStrings("; invalid meta-data", Source.setting_invalid.detail());
}

test "MetaRead: the JNI return code's outcomes, and what each side sees" {
    const buf = "vulkanXXXX";
    const v = MetaRead.fromCode(6, buf);
    try testing.expectEqualStrings("vulkan", v.value);
    try testing.expectEqualStrings("vulkan", v.guardSetting().?);

    // Absent: a successful read → the default auto for both sides.
    const a = MetaRead.fromCode(-1, buf);
    try testing.expect(a == .absent);
    try testing.expectEqualStrings("auto", a.guardSetting().?);

    // Too long: an (invalid) value → gles.
    const t = MetaRead.fromCode(-3, buf);
    try testing.expect(t == .too_long);
    try testing.expectEqualStrings("gles", t.guardSetting().?);

    // Wrong type (present, not a String): invalid → gles, NOT absent.
    const w = MetaRead.fromCode(-4, buf);
    try testing.expect(w == .wrong_type);
    try testing.expectEqualStrings("gles", w.guardSetting().?);

    // Read error: the renderer still gets gles, the guard gets UNKNOWN.
    inline for (.{ -2, -7 }) |code| {
        const e = MetaRead.fromCode(code, buf);
        try testing.expect(e == .read_error);
        try testing.expect(e.guardSetting() == null);
    }

    // An invalid value is still a successful read: effective gles.
    try testing.expectEqualStrings("gles", MetaRead.fromCode(5, "metal").guardSetting().?);
}

test "settingLabel: the effective setting for the crash guard's stamp" {
    try testing.expectEqualStrings("vulkan", settingLabel("vulkan"));
    try testing.expectEqualStrings("auto", settingLabel("auto"));
    try testing.expectEqualStrings("gles", settingLabel("gles"));
    try testing.expectEqualStrings("auto", settingLabel(null)); // missing = default
    try testing.expectEqualStrings("gles", settingLabel("metal"));
}

test "resolve is a no-op off Android (and never touches the externs)" {
    if (comptime is_android) return error.SkipZigTest;
    resolve(null, null);
    resolve(@ptrFromInt(0x1000), "vulkan");
}
