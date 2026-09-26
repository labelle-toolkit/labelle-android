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
const contract = @import("contract.zig");
const settings_mod = @import("settings.zig");
const identity_mod = @import("project_identity.zig");
const doctor = @import("doctor.zig");

/// What an invocation runs.
pub const Action = enum { doctor };

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

/// PR 1 declares `doctor` only; the packaging hooks (`package`, `deploy`,
/// `bundle`) and the `run`/`deploy` commands arrive with their
/// implementation.
const routes = [_]Route{
    .{ .kind = .command, .id = "doctor", .action = .doctor, .needs_project = false },
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

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (ctx.invocation.kind == .hook) return error.UnexpectedHookArguments;
        try out.print("labelle-android: unknown argument '{s}'\n", .{arg});
        return error.UnknownArgument;
    }

    // Validate settings before any side effect.
    var settings: ?settings_mod.Settings = null;
    if (ctx.config_file) |path| {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
        var diag: settings_mod.Diagnostic = .{};
        settings = settings_mod.parse(a, raw, &diag) catch |err| {
            try out.print("labelle-android: {s}: {s}\n", .{ path, diag.message });
            return err;
        };
    }
    var identity: ?identity_mod.Identity = null;
    if (ctx.project_dir) |project| identity = try identity_mod.load(a, io, project);

    switch (action) {
        .doctor => {
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
        },
    }
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

fn expectRoute(kind: Kind, id: []const u8, step: ?contract.Step, phase: ?contract.Phase, project: bool, accepted: *usize) !void {
    const ctx = contextFor(kind, id, step, phase, project);
    const declared = kind == .command and std.mem.eql(u8, id, "doctor") and step == null and phase == null;
    if (route(ctx)) |action| {
        try std.testing.expect(declared);
        try std.testing.expectEqual(Action.doctor, action);
        accepted.* += 1;
    } else |err| {
        try std.testing.expect(!declared);
        const expected: RouteError = if (kind == .hook)
            error.UnknownHook
        else if (std.mem.eql(u8, id, "doctor"))
            error.InvalidInvocation
        else
            error.UnknownCommand;
        try std.testing.expectEqual(expected, err);
    }
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
                        try expectRoute(kind, id, step, phase, project, &accepted);
                    }
                }
            }
        }
    }
    // doctor, inside a project and outside one.
    try std.testing.expectEqual(@as(usize, 2), accepted);
}

test "routes mirror plugin.labelle" {
    const manifest = @embedFile("plugin.labelle");
    for (routes) |r| {
        const needle = switch (r.kind) {
            .command => try std.fmt.allocPrint(std.testing.allocator, ".name = \"{s}\"", .{r.id}),
            .hook => try std.fmt.allocPrint(std.testing.allocator, ".id = \"{s}\"", .{r.id}),
        };
        defer std.testing.allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, manifest, needle) != null);
        if (r.kind == .command) {
            const project = if (r.needs_project) ".needs_project = true" else ".needs_project = false";
            try std.testing.expect(std.mem.indexOf(u8, manifest, project) != null);
        }
    }
    // No hooks declared until their implementation lands.
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".hooks") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"bin/labelle-android\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".command_contract = \">=1.2.0 <1.3.0\"") != null);
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
    _ = settings_mod;
    _ = identity_mod;
    _ = doctor;
    _ = @import("sdk.zig");
    _ = @import("proc.zig");
}
