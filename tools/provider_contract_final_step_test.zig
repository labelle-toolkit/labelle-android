//! Vendored verbatim from labelle-cli `src/cli/provider_contract_final_step_test.zig` at
//! d7827ebec1b936ad953ae1893a797ad115e791af (labelle-cli#443, contract 1.4.0). Re-vendor verbatim
//! (keep this header) when the CLI ships a new contract minor; do not edit below.
//!
//! Wire tests of contract §2 `final_step` (wire `1.4.0`+, cli#443): required
//! on every `1.4.0` context, a step the hook's own step leads to on a hook,
//! null on a command, and never present below `1.4.0`.
const std = @import("std");
const contract = @import("provider_contract.zig");

fn hookOn(base: contract.Context, wire: []const u8, step: contract.Step, phase: contract.Phase) contract.Context {
    var value = contract.hookContext(base, wire, step);
    value.invocation.phase = phase;
    value.target_dir = value.package_dir;
    value.cache_dir = value.package_dir;
    if (contract.envFileSlot(value.invocation)) value.env_file = value.zig_executable;
    if (step == .run) value.run = .{ .env = &.{}, .args = &.{}, .timeout_ms = null };
    return value;
}

test "stepReaches: generate always, build under every building command, run and bundle only under themselves" {
    const reaches = contract.stepReaches;
    for ([_]contract.Step{ .generate, .build, .run, .bundle }) |final| {
        try std.testing.expect(reaches(final, .generate));
        try std.testing.expectEqual(final != .generate, reaches(final, .build));
    }
    try std.testing.expect(reaches(.bundle, .bundle));
    try std.testing.expect(reaches(.run, .run));
    try std.testing.expect(!reaches(.run, .bundle));
    try std.testing.expect(!reaches(.bundle, .run));
    try std.testing.expect(!reaches(.build, .bundle));
    try std.testing.expect(!reaches(.build, .run));
}

test "1.4.0: final_step is required on hooks, must be reachable, and is null on commands" {
    try std.testing.expect(contract.carriesFinalStep("1.4.0"));
    try std.testing.expect(!contract.carriesFinalStep("1.3.0"));
    const parsed = try contract.parseContext(std.testing.allocator, contract.fixture, false);
    defer parsed.deinit();
    // An `after build` hook under `labelle bundle` (the cli#443 case).
    var value = hookOn(parsed.value, "1.4.0", .build, .after);
    try std.testing.expectError(error.MissingFinalStep, value.validate(true));
    for ([_]contract.Step{ .build, .run, .bundle }) |final| {
        value.final_step = final;
        try value.validate(true);
    }
    // A build hook under `labelle generate` cannot exist.
    value.final_step = .generate;
    try std.testing.expectError(error.InvalidFinalStep, value.validate(true));
    // A bundle hook only ever runs under `labelle bundle`.
    var bundle_hook = hookOn(parsed.value, "1.4.0", .bundle, .replace);
    bundle_hook.final_step = .bundle;
    try bundle_hook.validate(true);
    bundle_hook.final_step = .run;
    try std.testing.expectError(error.InvalidFinalStep, bundle_hook.validate(true));
    // A command: null; a value is refused.
    var command = parsed.value;
    command.contract_version = "1.4.0";
    command.cache_dir = command.package_dir;
    try command.validate(false);
    command.final_step = .build;
    try std.testing.expectError(error.InvalidInvocation, command.validate(false));
    // Below 1.4.0 the key does not exist, on any older wire.
    for ([_][]const u8{ "1.3.0", "1.2.0", "1.1.0", "1.0.0" }) |older| {
        var old = contract.hookContext(parsed.value, older, .build);
        old.invocation.phase = .after;
        old.target_dir = if (contract.carriesRunContext(older)) old.package_dir else null;
        old.cache_dir = if (contract.carriesToolchainContext(older)) old.package_dir else null;
        try old.validate(true);
        old.final_step = .bundle;
        try std.testing.expectError(error.UnsupportedContract, old.validate(true));
    }
}

test "1.4.0 wire: final_step is written and read back; a 1.3.0 wire never has the key" {
    const a = std.testing.allocator;
    const parsed = try contract.parseContext(a, contract.fixture, false);
    defer parsed.deinit();
    var value = hookOn(parsed.value, "1.4.0", .build, .after);
    value.final_step = .bundle;
    const wire = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"final_step\":\"bundle\"") != null);
    const back = try contract.parseContext(a, wire, true);
    defer back.deinit();
    try std.testing.expectEqual(contract.Step.bundle, back.value.final_step.?);
    // A 1.4.0 hook context without the key: refused.
    const omitted = try std.mem.replaceOwned(u8, a, wire, ",\"final_step\":\"bundle\"", "");
    defer a.free(omitted);
    try std.testing.expect(!std.mem.eql(u8, omitted, wire));
    try std.testing.expectError(error.MissingFinalStep, contract.parseContext(a, omitted, true));
    // A 1.4.0 command writes it as an explicit null.
    var command = parsed.value;
    command.contract_version = "1.4.0";
    command.cache_dir = command.output_dir;
    const command_wire = try std.json.Stringify.valueAlloc(a, command, .{});
    defer a.free(command_wire);
    try std.testing.expect(std.mem.indexOf(u8, command_wire, "\"final_step\":null") != null);
    (try contract.parseContext(a, command_wire, false)).deinit();
    // ...and omitting it there is a missing field, although null decodes the
    // same: the key check sees what the typed decode cannot.
    const no_key = try std.mem.replaceOwned(u8, a, command_wire, ",\"final_step\":null", "");
    defer a.free(no_key);
    try std.testing.expect(!std.mem.eql(u8, no_key, command_wire));
    try std.testing.expectError(error.MissingField, contract.parseContext(a, no_key, false));
    // A 1.3.0 context never writes it, and refuses it even as null.
    var older = hookOn(parsed.value, "1.3.0", .build, .after);
    older.final_step = null;
    const older_wire = try std.json.Stringify.valueAlloc(a, older, .{});
    defer a.free(older_wire);
    try std.testing.expect(std.mem.indexOf(u8, older_wire, "final_step") == null);
    (try contract.parseContext(a, older_wire, true)).deinit();
    const smuggled = try std.mem.concat(a, u8, &.{ older_wire[0 .. older_wire.len - 1], ",\"final_step\":null}" });
    defer a.free(smuggled);
    try std.testing.expectError(error.UnknownField, contract.parseContext(a, smuggled, true));
}
