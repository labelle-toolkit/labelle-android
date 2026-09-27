//! `bin/labelle-android`: the labelle-cli provider executable (#405).
//!
//! One binary serves every command and hook `plugin.labelle` declares, like
//! labelle-web's `bin/labelle-web`. The CLI writes a contract context to the
//! file named by `LABELLE_CONTEXT`; this decodes it strictly
//! (`contract.zig`), routes on the invocation `(kind, id, step, phase)`, and
//! refuses any combination the manifest does not declare. Settings
//! (`providers/android.json`) are validated before any side effect.
//!
//! Exit status: 0 on success, 1 on any failure (with one `labelle-android:`
//! diagnostic line on stderr). Reports go to stderr, so stdout stays free
//! for the CLI's JSON progress protocol.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const settings_mod = @import("settings.zig");
const identity_mod = @import("project_identity.zig");
const doctor = @import("doctor.zig");
const sdk = @import("sdk.zig");
const actions = @import("actions.zig");

/// What an invocation runs.
pub const Action = enum {
    doctor,
    /// `labelle android run`: install + launch the built APK.
    run_command,
    /// `labelle android deploy`: upload a bundled APK to GitHub Releases.
    deploy_command,
    /// `after build`: package `zig-out/apk/game.apk`.
    package_hook,
    /// `replace run`: install + launch that APK with the run options.
    deploy_hook,
    /// `replace bundle`: the release APK in the bundle output directory.
    bundle_hook,
};

const Kind = @FieldType(contract.Invocation, "kind");

/// One declared entry point. Must match `plugin.labelle` exactly: a command
/// has no step/phase; a hook has both.
const Route = struct {
    kind: Kind,
    id: []const u8,
    step: ?contract.Step = null,
    phase: ?contract.Phase = null,
    action: Action,
    needs_project: bool,
};

const routes = [_]Route{
    .{ .kind = .command, .id = "doctor", .action = .doctor, .needs_project = false },
    .{ .kind = .command, .id = "run", .action = .run_command, .needs_project = true },
    .{ .kind = .command, .id = "deploy", .action = .deploy_command, .needs_project = true },
    .{ .kind = .hook, .id = "package", .step = .build, .phase = .after, .action = .package_hook, .needs_project = true },
    .{ .kind = .hook, .id = "deploy", .step = .run, .phase = .replace, .action = .deploy_hook, .needs_project = true },
    .{ .kind = .hook, .id = "bundle", .step = .bundle, .phase = .replace, .action = .bundle_hook, .needs_project = true },
};

/// The one target this provider's hooks serve.
pub const target = "android";

pub const RouteError = error{ UnknownCommand, UnknownHook, InvalidInvocation, UnsupportedTarget };

/// Resolve a decoded context to its action, or refuse it.
pub fn route(ctx: contract.Context) RouteError!Action {
    const inv = ctx.invocation;
    for (routes) |r| {
        if (r.kind != inv.kind or !std.mem.eql(u8, r.id, inv.id)) continue;
        if (!sameStep(r.step, inv.step) or !samePhase(r.phase, inv.phase)) return error.InvalidInvocation;
        if (r.needs_project and ctx.project_dir == null) return error.InvalidInvocation;
        if (r.kind == .hook and !std.mem.eql(u8, ctx.target orelse "", target)) return error.UnsupportedTarget;
        return r.action;
    }
    return switch (inv.kind) {
        .command => error.UnknownCommand,
        .hook => error.UnknownHook,
    };
}

fn sameStep(a: ?contract.Step, b: ?contract.Step) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn samePhase(a: ?contract.Phase, b: ?contract.Phase) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

pub fn main(init: std.process.Init) u8 {
    var err_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &err_buf);
    const out = &stderr.interface;
    const failed = execute(init, out) catch |err| {
        out.print("labelle-android: {s}\n", .{@errorName(err)}) catch {};
        out.flush() catch {};
        return 1;
    };
    out.flush() catch {};
    return if (failed) 1 else 0;
}

/// Returns true when the action ran and reported a failure it already
/// explained (doctor's FAIL lines).
fn execute(init: std.process.Init, out: *std.Io.Writer) !bool {
    const a = init.arena.allocator();
    const io = init.io;
    const context_path = init.environ_map.get(contract.context_env) orelse {
        try out.writeAll("labelle-android: run me through labelle (LABELLE_CONTEXT is not set)\n");
        return error.MissingContext;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, context_path, a, .limited(1024 * 1024));
    // Every route's own `needs_project` is enforced by `route`.
    const parsed = try contract.parseContext(a, bytes, false);
    const ctx = parsed.value;
    const action = try route(ctx);

    var args: std.ArrayList([]const u8) = .empty;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
        defer it.deinit();
        _ = it.skip();
        while (it.next()) |arg| {
            if (ctx.invocation.kind == .hook) return error.UnexpectedHookArguments;
            try args.append(a, try a.dupe(u8, arg));
        }
    }
    if (action == .doctor) {
        for (args.items) |arg| {
            try out.print("labelle-android: unknown argument '{s}'\n", .{arg});
            return error.UnknownArgument;
        }
    }

    // Validate settings before any side effect.
    var settings: ?settings_mod.Settings = null;
    var settings_bytes: []const u8 = "";
    if (ctx.config_file) |path| {
        settings_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        var diag: settings_mod.Diagnostic = .{};
        settings = settings_mod.parse(a, settings_bytes, &diag) catch |err| {
            try out.print("labelle-android: {s}: {s}\n", .{ path, diag.message });
            return err;
        };
    }
    var identity: ?identity_mod.Identity = null;
    if (ctx.project_dir) |project| identity = try identity_mod.load(a, io, project);

    if (action == .doctor) {
        if (settings) |s| {
            try out.print("\n  package: {s}  label: \"{s}\"  min SDK: {d}\n", .{
                s.package_name,
                settings_mod.appName(s, if (identity) |id| id.title else ""),
                s.min_sdk_version,
            });
        } else if (ctx.project_dir != null) {
            try out.writeAll("\n  note: no providers/android.json for this project (`.provider_config`); using defaults\n");
        }
        const level = if (settings) |s| s.target_sdk_version else settings_mod.default_target_sdk;
        const summary = try doctor.run(a, io, init.environ_map, .{ .target_sdk_version = level }, out);
        return summary.failures != 0;
    }

    // Everything else packages or installs, so it needs the settings.
    const s = settings orelse {
        try out.writeAll(
            \\labelle-android: this project has no Android settings. Add providers/android.json
            \\  (at least {"schema_version": 1, "package_name": "com.studio.game"}) and declare it in project.labelle:
            \\  .provider_config = .{ .{ .package = "android", .file = "providers/android.json" } },
            \\
        );
        return error.MissingSettings;
    };
    try out.flush();
    const run_ctx: actions.Context = .{
        .a = a,
        .io = io,
        .env = init.environ_map,
        .ctx = ctx,
        .settings = s,
        .settings_bytes = settings_bytes,
        .identity = identity.?,
    };
    switch (action) {
        .doctor => unreachable,
        .run_command => try actions.runCommand(run_ctx, args.items),
        .deploy_command => try actions.deployCommand(run_ctx, args.items),
        .package_hook => try actions.packageHook(run_ctx),
        .deploy_hook => try actions.deployHook(run_ctx),
        .bundle_hook => try actions.bundleHook(run_ctx),
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn contextFor(kind: Kind, id: []const u8, step: ?contract.Step, phase: ?contract.Phase, project: bool) contract.Context {
    const root = if (@import("builtin").os.tag == .windows) "C:/p" else "/p";
    return .{
        .contract_version = contract.version,
        .invocation = .{ .kind = kind, .id = id, .step = step, .phase = phase },
        .package_dir = root,
        .project_dir = if (project) root else null,
        .target = if (project) target else null,
        .lock_file = if (project) root else null,
        .config_file = null,
        .output_dir = root,
        .zig_executable = root,
        .optimize = .Debug,
        .progress = .human,
    };
}

/// What `route` must answer for one invocation, derived independently of
/// `route` from the declared table.
fn expected(kind: Kind, id: []const u8, step: ?contract.Step, phase: ?contract.Phase, project: bool) RouteError!Action {
    for (routes) |r| {
        if (r.kind != kind or !std.mem.eql(u8, r.id, id)) continue;
        if (!sameStep(r.step, step) or !samePhase(r.phase, phase)) return error.InvalidInvocation;
        if (r.needs_project and !project) return error.InvalidInvocation;
        return r.action;
    }
    return if (kind == .hook) error.UnknownHook else error.UnknownCommand;
}

test "invocation matrix: only the declared (kind, id, step, phase) runs" {
    const ids = [_][]const u8{ "doctor", "run", "studio", "deploy", "package", "bundle", "bogus" };
    const steps = [_]?contract.Step{ null, .generate, .build, .bundle, .run };
    const phases = [_]?contract.Phase{ null, .before, .replace, .after };
    var accepted: usize = 0;
    for ([_]Kind{ .command, .hook }) |kind| {
        for (ids) |id| {
            for (steps) |step| {
                for (phases) |phase| {
                    for ([_]bool{ false, true }) |project| {
                        const want = expected(kind, id, step, phase, project);
                        const got = route(contextFor(kind, id, step, phase, project));
                        if (want) |action| {
                            try std.testing.expectEqual(action, try got);
                            accepted += 1;
                        } else |err| try std.testing.expectError(err, got);
                    }
                }
            }
        }
    }
    // doctor inside a project and outside one; run and deploy commands in a
    // project; the three hooks on their own (step, phase).
    try std.testing.expectEqual(@as(usize, 7), accepted);
    // Spot-check the table itself, so `expected` cannot drift with it.
    try std.testing.expectEqual(Action.package_hook, try route(contextFor(.hook, "package", .build, .after, true)));
    try std.testing.expectEqual(Action.deploy_hook, try route(contextFor(.hook, "deploy", .run, .replace, true)));
    try std.testing.expectEqual(Action.bundle_hook, try route(contextFor(.hook, "bundle", .bundle, .replace, true)));
    try std.testing.expectEqual(Action.deploy_command, try route(contextFor(.command, "deploy", null, null, true)));
    try std.testing.expectError(error.InvalidInvocation, route(contextFor(.hook, "package", .build, .before, true)));
    try std.testing.expectError(error.InvalidInvocation, route(contextFor(.command, "run", null, null, false)));
    try std.testing.expectError(error.UnknownCommand, route(contextFor(.command, "studio", null, null, true)));
}

test "a hook for another target is refused" {
    var ctx = contextFor(.hook, "package", .build, .after, true);
    ctx.target = "desktop";
    try std.testing.expectError(error.UnsupportedTarget, route(ctx));
}

test "routes mirror plugin.labelle" {
    const a = std.testing.allocator;
    const manifest = @embedFile("plugin.labelle");
    const tool = ".build_step = \"install-provider\", .executable = \"bin/labelle-android\"";
    var commands: usize = 0;
    var hooks: usize = 0;
    for (routes) |r| {
        const needle = switch (r.kind) {
            .command => try std.fmt.allocPrint(a, ".name = \"{s}\", {s}", .{ r.id, tool }),
            .hook => try std.fmt.allocPrint(a, ".id = \"{s}\", .step = .{s}, .target = \"{s}\", .when = .{s}, {s}", .{
                r.id, @tagName(r.step.?), target, @tagName(r.phase.?), tool,
            }),
        };
        defer a.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, manifest, needle) != null);
        switch (r.kind) {
            .command => commands += 1,
            .hook => hooks += 1,
        }
    }
    // Nothing declared that the table does not route.
    const declared = manifest[std.mem.indexOf(u8, manifest, ".commands = .{").?..];
    try std.testing.expectEqual(commands, std.mem.count(u8, declared, ".name = \""));
    try std.testing.expectEqual(hooks, std.mem.count(u8, declared, ".id = \""));
    try std.testing.expect(std.mem.indexOf(u8, manifest, "studio") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".command_contract = \">=1.2.0 <1.2.1\"") != null);
}

test "the vendored decoder is contract 1.2.0 and accepts its own fixtures" {
    try std.testing.expectEqualStrings("1.2.0", contract.version);
    const fixture = if (@import("builtin").os.tag == .windows)
        @embedFile("provider_contract/projectless-windows.json")
    else
        @embedFile("provider_contract/projectless.json");
    const parsed = try contract.parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    try std.testing.expectEqual(Action.doctor, try route(parsed.value));
}

test {
    _ = contract;
    _ = actions;
    _ = settings_mod;
    _ = identity_mod;
    _ = doctor;
    _ = @import("sdk.zig");
    _ = @import("proc.zig");
}
