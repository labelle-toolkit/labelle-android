//! The provider's stdout/stderr writers (labelle-cli#446).
//!
//! `labelle build > log 2>&1` hands the CLI and this tool ONE open file
//! description, so both must append at its shared offset. Zig 0.16's
//! `File.writer` is POSITIONAL: it pwrite()s at an offset it tracks itself,
//! starting from 0, so on a redirected file it overwrites whatever the CLI
//! already wrote (a pipe is unseekable and hid the bug). Every stdout/stderr
//! writer in the tool comes from here and is streaming.
const std = @import("std");

/// A streaming writer on `file`: every write lands at the file's current
/// (shared) offset.
pub fn streaming(io: std.Io, file: std.Io.File, buffer: []u8) std.Io.File.Writer {
    return file.writerStreaming(io, buffer);
}

pub fn stdoutWriter(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return streaming(io, std.Io.File.stdout(), buffer);
}

pub fn stderrWriter(io: std.Io, buffer: []u8) std.Io.File.Writer {
    return streaming(io, std.Io.File.stderr(), buffer);
}

test "streaming appends at the shared offset instead of overwriting from 0" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "redirected.txt", .{ .read = true });
    defer file.close(io);
    // What the CLI wrote first, advancing the shared offset.
    try file.writeStreamingAll(io, "cli: first line\n");
    var buf: [16]u8 = undefined;
    var w = streaming(io, file, &buf);
    try w.interface.writeAll("tool: a line longer than the buffer\n");
    try w.interface.flush();
    try file.writeStreamingAll(io, "cli: last line\n");
    const got = try tmp.dir.readFileAlloc(io, "redirected.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("cli: first line\ntool: a line longer than the buffer\ncli: last line\n", got);
}
