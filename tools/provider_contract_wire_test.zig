//! Vendored verbatim from labelle-cli `src/cli/provider_contract_wire_test.zig` at
//! d7827ebec1b936ad953ae1893a797ad115e791af (labelle-cli#443, contract 1.4.0). Re-vendor verbatim
//! (keep this header) when the CLI ships a new contract minor; do not edit below.
//!
//! Wire tests of contract §2 `target_dir` and `run` (wire `1.2.0`+) and of
//! `cache_dir` / `env_file` (wire `1.3.0`+): where each key is required,
//! where it is null, and that an older wire never carries it.
const std = @import("std");
const contract = @import("provider_contract.zig");
const parseContext = contract.parseContext;
const hookContext = contract.hookContext;
const fixture = contract.fixture;
const carriesRunContext = contract.carriesRunContext;
const carriesToolchainContext = contract.carriesToolchainContext;
const envFileSlot = contract.envFileSlot;
const Step = contract.Step;
const Phase = contract.Phase;
const RunEnv = contract.RunEnv;
const RunContext = contract.RunContext;

test "1.2.0: target_dir is required on hooks, null on commands, absent below 1.2.0" {
    try std.testing.expect(carriesRunContext("1.2.0"));
    try std.testing.expect(!carriesRunContext("1.1.0"));
    try std.testing.expect(!carriesRunContext("1.0.0"));
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    for ([_]Step{ .generate, .build, .bundle }) |step| {
        var value = hookContext(parsed.value, "1.2.0", step);
        // A 1.2.0 hook without its target dir: refused.
        try std.testing.expectError(error.MissingTargetDir, value.validate(true));
        value.target_dir = "relative/target";
        try std.testing.expectError(error.InvalidPath, value.validate(true));
        value.target_dir = value.package_dir;
        try value.validate(true);
        // The same hook on an older wire may not carry it: a strict 1.1.0
        // or 1.0.0 decoder would reject the key.
        for ([_][]const u8{ "1.1.0", "1.0.0" }) |older| {
            value.contract_version = older;
            try std.testing.expectError(error.UnsupportedContract, value.validate(true));
        }
        value.target_dir = null;
        for ([_][]const u8{ "1.1.0", "1.0.0" }) |older| {
            value.contract_version = older;
            try value.validate(true);
        }
    }
    // A command: null on 1.2.0; a value is refused.
    var command = parsed.value;
    command.contract_version = "1.2.0";
    try command.validate(false);
    command.target_dir = command.package_dir;
    try std.testing.expectError(error.InvalidInvocation, command.validate(false));
}

test "1.2.0: run is only on run-step hooks and its env is well formed" {
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    const env = [_]RunEnv{ .{ .name = "LABELLE_SCENE", .value = "intro" }, .{ .name = "LABELLE_PROFILE", .value = "1" } };
    const options: RunContext = .{ .env = &env, .args = &.{ "a", "b" }, .timeout_ms = 2000 };
    var value = hookContext(parsed.value, "1.2.0", .run);
    value.target_dir = value.package_dir;
    // A run hook on 1.2.0 must carry it (possibly empty)...
    try std.testing.expectError(error.MissingRunContext, value.validate(true));
    value.run = .{ .env = &.{}, .args = &.{}, .timeout_ms = null };
    try value.validate(true);
    try std.testing.expect(!value.run.?.given());
    value.run = options;
    try value.validate(true);
    try std.testing.expect(value.run.?.given());
    // ...and no other step's hook, nor a command, may.
    for ([_]Step{ .generate, .build, .bundle }) |step| {
        var other = hookContext(parsed.value, "1.2.0", step);
        other.target_dir = other.package_dir;
        other.run = options;
        try std.testing.expectError(error.InvalidInvocation, other.validate(true));
    }
    var command = parsed.value;
    command.contract_version = "1.2.0";
    command.run = options;
    try std.testing.expectError(error.InvalidInvocation, command.validate(false));
    // Below 1.2.0 the key does not exist.
    for ([_][]const u8{ "1.1.0", "1.0.0" }) |older| {
        var old = hookContext(parsed.value, older, .run);
        try old.validate(true);
        old.run = options;
        try std.testing.expectError(error.UnsupportedContract, old.validate(true));
    }
    // Malformed env: bad names, duplicates, NUL bytes.
    for ([_][]const RunEnv{
        &.{.{ .name = "", .value = "x" }},
        &.{.{ .name = "1ABC", .value = "x" }},
        &.{.{ .name = "HAS SPACE", .value = "x" }},
        &.{.{ .name = "A=B", .value = "x" }},
        &.{ .{ .name = "LABELLE_SCENE", .value = "a" }, .{ .name = "LABELLE_SCENE", .value = "b" } },
        &.{.{ .name = "LABELLE_SCENE", .value = "a\x00b" }},
    }) |bad| {
        value.run = .{ .env = bad, .args = &.{}, .timeout_ms = null };
        try std.testing.expectError(error.InvalidRunEnv, value.validate(true));
    }
    value.run = .{ .env = &.{}, .args = &.{"a\x00b"}, .timeout_ms = null };
    try std.testing.expectError(error.InvalidRunArgument, value.validate(true));
}

test "1.2.0 wire: written and read back; key presence follows the wire" {
    const a = std.testing.allocator;
    const parsed = try parseContext(a, fixture, false);
    defer parsed.deinit();
    const env = [_]RunEnv{.{ .name = "LABELLE_SCENE", .value = "intro" }};
    var value = hookContext(parsed.value, "1.2.0", .run);
    value.target_dir = value.package_dir;
    value.run = .{ .env = &env, .args = &.{ "a", "b" }, .timeout_ms = null };
    const wire = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"timeout_ms\":null") != null);
    const back = try parseContext(a, wire, true);
    defer back.deinit();
    try std.testing.expectEqualStrings(value.package_dir, back.value.target_dir.?);
    try std.testing.expectEqualStrings("LABELLE_SCENE", back.value.run.?.env[0].name);
    try std.testing.expectEqualStrings("intro", back.value.run.?.env[0].value);
    try std.testing.expectEqual(@as(usize, 2), back.value.run.?.args.len);
    try std.testing.expect(back.value.run.?.timeout_ms == null);
    // A 1.2.0 command writes `target_dir` as an explicit null, and a
    // decoder refuses a 1.2.0 context that omits the key.
    var command = parsed.value;
    command.contract_version = "1.2.0";
    const command_wire = try std.json.Stringify.valueAlloc(a, command, .{});
    defer a.free(command_wire);
    try std.testing.expect(std.mem.indexOf(u8, command_wire, "\"target_dir\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, command_wire, "\"run\":") == null);
    (try parseContext(a, command_wire, false)).deinit();
    const omitted = try std.mem.replaceOwned(u8, a, command_wire, ",\"target_dir\":null", "");
    defer a.free(omitted);
    try std.testing.expectError(error.MissingField, parseContext(a, omitted, false));
    // An older wire never writes the key, and refuses it even as null.
    var older = parsed.value;
    older.contract_version = "1.1.0";
    const older_wire = try std.json.Stringify.valueAlloc(a, older, .{});
    defer a.free(older_wire);
    try std.testing.expect(std.mem.indexOf(u8, older_wire, "target_dir") == null);
    const smuggled = try std.mem.replaceOwned(u8, a, older_wire, "\"progress\":\"json\"", "\"progress\":\"json\",\"target_dir\":null");
    defer a.free(smuggled);
    try std.testing.expect(!std.mem.eql(u8, older_wire, smuggled));
    try std.testing.expectError(error.UnknownField, parseContext(a, smuggled, false));
    // An optional key is absent, never null.
    const null_run = try std.mem.replaceOwned(u8, a, command_wire, "\"target_dir\":null", "\"target_dir\":null,\"run\":null");
    defer a.free(null_run);
    try std.testing.expectError(error.NullOptionalKey, parseContext(a, null_run, false));
    // A run hook on 1.2.0 whose `run` lacks a key: refused like any
    // missing required field.
    const partial = try std.mem.replaceOwned(u8, a, wire, ",\"timeout_ms\":null", "");
    defer a.free(partial);
    try std.testing.expectError(error.MissingField, parseContext(a, partial, true));
}

test "1.3.0: cache_dir on every context, env_file only on the contributing hook slots" {
    try std.testing.expect(carriesToolchainContext("1.3.0"));
    try std.testing.expect(!carriesToolchainContext("1.2.0"));
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    const slots = [_]struct { step: Step, phase: Phase, env_file: bool }{
        .{ .step = .generate, .phase = .before, .env_file = true },
        .{ .step = .generate, .phase = .replace, .env_file = false },
        .{ .step = .generate, .phase = .after, .env_file = true },
        .{ .step = .build, .phase = .before, .env_file = true },
        .{ .step = .build, .phase = .replace, .env_file = false },
        .{ .step = .build, .phase = .after, .env_file = false },
        .{ .step = .bundle, .phase = .before, .env_file = false },
        .{ .step = .bundle, .phase = .after, .env_file = false },
        .{ .step = .run, .phase = .before, .env_file = false },
        .{ .step = .run, .phase = .replace, .env_file = false },
        .{ .step = .run, .phase = .after, .env_file = false },
    };
    for (slots) |slot| {
        var value = hookContext(parsed.value, "1.3.0", slot.step);
        value.invocation.phase = slot.phase;
        value.target_dir = value.package_dir;
        if (slot.step == .run) value.run = .{ .env = &.{}, .args = &.{}, .timeout_ms = null };
        try std.testing.expectEqual(slot.env_file, envFileSlot(value.invocation));
        // A 1.3.0 context without its cache dir: refused, and a relative one too.
        value.env_file = if (slot.env_file) value.zig_executable else null;
        try std.testing.expectError(error.MissingCacheDir, value.validate(true));
        value.cache_dir = "relative/cache";
        try std.testing.expectError(error.InvalidPath, value.validate(true));
        value.cache_dir = value.package_dir;
        try value.validate(true);
        if (slot.env_file) {
            // The slot's env_file is required and absolute...
            value.env_file = null;
            try std.testing.expectError(error.MissingEnvFile, value.validate(true));
            value.env_file = "relative/env.json";
            try std.testing.expectError(error.InvalidPath, value.validate(true));
        } else {
            // ...and any other hook carrying one is refused.
            value.env_file = value.zig_executable;
            try std.testing.expectError(error.EnvFileNotAllowed, value.validate(true));
        }
    }
    // A command: cache_dir required, env_file null.
    var command = parsed.value;
    command.contract_version = "1.3.0";
    try std.testing.expectError(error.MissingCacheDir, command.validate(false));
    command.cache_dir = command.package_dir;
    try command.validate(false);
    command.env_file = command.zig_executable;
    try std.testing.expectError(error.EnvFileNotAllowed, command.validate(false));
    // Below 1.3.0 neither key exists: a 1.2.0 strict decoder rejects them.
    for ([_][]const u8{ "1.2.0", "1.1.0", "1.0.0" }) |older| {
        var old = hookContext(parsed.value, older, .generate);
        old.invocation.phase = .before;
        old.target_dir = if (carriesRunContext(older)) old.package_dir else null;
        try old.validate(true);
        old.cache_dir = old.package_dir;
        try std.testing.expectError(error.UnsupportedContract, old.validate(true));
        old.cache_dir = null;
        old.env_file = old.zig_executable;
        try std.testing.expectError(error.UnsupportedContract, old.validate(true));
    }
}

test "1.3.0 wire: keys are written and read back; a 1.2.0 decoder refuses them" {
    const a = std.testing.allocator;
    const parsed = try parseContext(a, fixture, false);
    defer parsed.deinit();
    var value = hookContext(parsed.value, "1.3.0", .generate);
    value.invocation.phase = .before;
    value.target_dir = value.package_dir;
    value.cache_dir = value.output_dir;
    value.env_file = value.zig_executable;
    const wire = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(wire);
    const back = try parseContext(a, wire, true);
    defer back.deinit();
    try std.testing.expectEqualStrings(value.output_dir, back.value.cache_dir.?);
    try std.testing.expectEqualStrings(value.zig_executable, back.value.env_file.?);
    // A 1.3.0 command writes `env_file` as an explicit null; omitting either
    // key is a missing field.
    var command = parsed.value;
    command.contract_version = "1.3.0";
    command.cache_dir = command.output_dir;
    const command_wire = try std.json.Stringify.valueAlloc(a, command, .{});
    defer a.free(command_wire);
    try std.testing.expect(std.mem.indexOf(u8, command_wire, "\"env_file\":null") != null);
    (try parseContext(a, command_wire, false)).deinit();
    const no_env = try std.mem.replaceOwned(u8, a, command_wire, ",\"env_file\":null", "");
    defer a.free(no_env);
    try std.testing.expect(!std.mem.eql(u8, no_env, command_wire));
    try std.testing.expectError(error.MissingField, parseContext(a, no_env, false));
    // The same keys smuggled onto a 1.2.0 wire are unknown fields, even null.
    var older = parsed.value;
    older.contract_version = "1.2.0";
    const older_wire = try std.json.Stringify.valueAlloc(a, older, .{});
    defer a.free(older_wire);
    try std.testing.expect(std.mem.indexOf(u8, older_wire, "cache_dir") == null);
    try std.testing.expect(std.mem.indexOf(u8, older_wire, "env_file") == null);
    // A null is caught by the key check, a value by validation.
    const cases = [_]struct { extra: []const u8, err: anyerror }{
        .{ .extra = ",\"env_file\":null", .err = error.UnknownField },
        .{ .extra = ",\"cache_dir\":null", .err = error.UnknownField },
        .{ .extra = ",\"cache_dir\":\"/c\"", .err = error.UnsupportedContract },
    };
    for (cases) |case| {
        const smuggled = try std.mem.concat(a, u8, &.{ older_wire[0 .. older_wire.len - 1], case.extra, "}" });
        defer a.free(smuggled);
        try std.testing.expectError(case.err, parseContext(a, smuggled, false));
    }
}
