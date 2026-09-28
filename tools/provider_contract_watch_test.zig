//! Vendored verbatim from labelle-cli `src/cli/provider_contract_watch_test.zig` at
//! d7827ebec1b936ad953ae1893a797ad115e791af (labelle-cli#443, contract 1.4.0). Re-vendor verbatim
//! (keep this header) when the CLI ships a new contract minor; do not edit below.
//!
//! Wire tests of contract §2 `run.watch` (wire `1.3.0`+, RFC cli#466 A2):
//! required (null or an object) on every `1.3.0` run context, absent below
//! it, and only ever non-null on the run replacement.
const std = @import("std");
const contract = @import("provider_contract.zig");

fn runHook(base: contract.Context, wire: []const u8, phase: contract.Phase) contract.Context {
    var value = contract.hookContext(base, wire, .run);
    value.invocation.phase = phase;
    value.target_dir = value.package_dir;
    if (contract.carriesToolchainContext(wire)) value.cache_dir = value.package_dir;
    value.run = .{ .env = &.{}, .args = &.{}, .timeout_ms = null };
    return value;
}

fn session(base: contract.Context) contract.WatchContext {
    return .{ .generation_file = base.zig_executable, .output_dir = base.output_dir };
}

test "1.3.0: run.watch is only on the run replacement, with absolute paths" {
    try std.testing.expect(contract.carriesWatchContext("1.3.0"));
    try std.testing.expect(!contract.carriesWatchContext("1.2.0"));
    const parsed = try contract.parseContext(std.testing.allocator, contract.fixture, false);
    defer parsed.deinit();
    // Null everywhere validates; a session on the replacement too.
    for ([_]contract.Phase{ .before, .replace, .after }) |phase| {
        var value = runHook(parsed.value, "1.3.0", phase);
        try value.validate(true);
        value.run.?.watch = session(parsed.value);
        if (phase == .replace) {
            try value.validate(true);
        } else {
            try std.testing.expectError(error.WatchNotAllowed, value.validate(true));
        }
    }
    // Relative paths are refused.
    var value = runHook(parsed.value, "1.3.0", .replace);
    value.run.?.watch = .{ .generation_file = "relative/generation", .output_dir = parsed.value.output_dir };
    try std.testing.expectError(error.InvalidPath, value.validate(true));
    value.run.?.watch = .{ .generation_file = parsed.value.zig_executable, .output_dir = "relative/out" };
    try std.testing.expectError(error.InvalidPath, value.validate(true));
    // A 1.2.0 replacement cannot carry one.
    var older = runHook(parsed.value, "1.2.0", .replace);
    try older.validate(true);
    older.run.?.watch = session(parsed.value);
    try std.testing.expectError(error.UnsupportedContract, older.validate(true));
}

test "1.3.0 wire: run.watch is written null or set and read back; a 1.2.0 wire never has the key" {
    const a = std.testing.allocator;
    const parsed = try contract.parseContext(a, contract.fixture, false);
    defer parsed.deinit();
    // Outside a watch session: an explicit null.
    var plain = runHook(parsed.value, "1.3.0", .replace);
    const plain_wire = try std.json.Stringify.valueAlloc(a, plain, .{});
    defer a.free(plain_wire);
    try std.testing.expect(std.mem.indexOf(u8, plain_wire, "\"watch\":null") != null);
    const plain_back = try contract.parseContext(a, plain_wire, true);
    defer plain_back.deinit();
    try std.testing.expect(plain_back.value.run.?.watch == null);
    // In one: the object, read back.
    plain.run.?.watch = session(parsed.value);
    const wire = try std.json.Stringify.valueAlloc(a, plain, .{});
    defer a.free(wire);
    const back = try contract.parseContext(a, wire, true);
    defer back.deinit();
    try std.testing.expectEqualStrings(parsed.value.zig_executable, back.value.run.?.watch.?.generation_file);
    try std.testing.expectEqualStrings(parsed.value.output_dir, back.value.run.?.watch.?.output_dir);
    // A 1.3.0 run context without the key: a missing field.
    const omitted = try std.mem.replaceOwned(u8, a, plain_wire, ",\"watch\":null", "");
    defer a.free(omitted);
    try std.testing.expect(!std.mem.eql(u8, omitted, plain_wire));
    try std.testing.expectError(error.MissingField, contract.parseContext(a, omitted, true));
    // An unknown key inside the session object is refused.
    const extra = try std.mem.replaceOwned(u8, a, wire, "\"generation_file\":", "\"typo\":1,\"generation_file\":");
    defer a.free(extra);
    try std.testing.expectError(error.UnknownField, contract.parseContext(a, extra, true));
    // 1.2.0: never written, refused even as null.
    const older = runHook(parsed.value, "1.2.0", .replace);
    const older_wire = try std.json.Stringify.valueAlloc(a, older, .{});
    defer a.free(older_wire);
    try std.testing.expect(std.mem.indexOf(u8, older_wire, "watch") == null);
    (try contract.parseContext(a, older_wire, true)).deinit();
    const smuggled = try std.mem.replaceOwned(u8, a, older_wire, "\"timeout_ms\":null", "\"timeout_ms\":null,\"watch\":null");
    defer a.free(smuggled);
    try std.testing.expect(!std.mem.eql(u8, smuggled, older_wire));
    try std.testing.expectError(error.UnknownField, contract.parseContext(a, smuggled, true));
}
