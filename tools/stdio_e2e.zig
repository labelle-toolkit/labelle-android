//! labelle-cli#446 end to end: runs the BUILT `labelle-android` with stdout
//! and stderr redirected to one regular file that already holds a line, the
//! way `labelle build > log 2>&1` does, then appends another. Every line must
//! survive, whole and in order; a positional writer in the tool overwrites
//! the first line from offset 0.
//!
//! Usage (from build.zig): stdio_e2e <labelle-android> <output-file>
const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.skip();
    const tool = args.next() orelse return error.MissingToolArgument;
    const out_path = args.next() orelse return error.MissingOutputArgument;

    const before = "cli: a line written before the provider ran\n";
    const after = "cli: a line written after the provider exited\n";
    {
        const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, before);
        // No LABELLE_CONTEXT: the tool prints its two-line refusal and exits 1.
        var env = try init.environ_map.clone(a);
        _ = env.swapRemove("LABELLE_CONTEXT");
        var child = try std.process.spawn(io, .{
            .argv = &.{tool},
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .{ .file = file },
            .stderr = .{ .file = file },
        });
        const term = try child.wait(io);
        if (term != .exited or term.exited != 1) return error.UnexpectedToolExit;
        try file.writeStreamingAll(io, after);
    }

    const got = try std.Io.Dir.cwd().readFileAlloc(io, out_path, a, .limited(64 * 1024));
    const want = before ++
        "labelle-android: run me through labelle (LABELLE_CONTEXT is not set)\n" ++
        "labelle-android: MissingContext\n" ++ after;
    const normalized = try std.mem.replaceOwned(u8, a, got, "\r\n", "\n");
    if (!std.mem.eql(u8, normalized, want)) {
        std.debug.print("redirected output mismatch (cli#446)\n--- want:\n{s}--- got:\n{s}---\n", .{ want, normalized });
        return 1;
    }
    return 0;
}
