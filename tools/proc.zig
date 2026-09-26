//! Child processes for the provider's SDK tools (ported from labelle-cli
//! `util.zig`'s `runCmd`).
//!
//! On Windows the SDK ships some tools as `.bat` wrappers (apksigner). Zig's
//! spawn launches a `.bat`/`.cmd` through `cmd.exe` with cmd-safe argument
//! quoting when argv[0] names one, so callers pass the full script path (see
//! `sdk.toolPath`) and never build a `cmd /c` line themselves.
const std = @import("std");

pub const Options = struct {
    cwd: ?[]const u8 = null,
    /// Replaces the child's environment when set.
    environ_map: ?*const std.process.Environ.Map = null,
};

/// Run `argv` to completion, capturing stdout and stderr. Caller owns both.
pub fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, opts: Options) !std.process.RunResult {
    return std.process.run(a, io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |dir| .{ .path = dir } else .inherit,
        .environ_map = opts.environ_map,
    });
}

/// True when a child exited normally with status 0.
pub fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "succeeded accepts only a clean zero exit" {
    try std.testing.expect(succeeded(.{ .exited = 0 }));
    try std.testing.expect(!succeeded(.{ .exited = 1 }));
}

test "a missing executable is an error, not a silent success" {
    const argv = [_][]const u8{"labelle-android-test-no-such-tool-4f1c"};
    if (run(std.testing.allocator, std.testing.io, &argv, .{})) |result| {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
        return error.TestUnexpectedResult;
    } else |_| {}
}
