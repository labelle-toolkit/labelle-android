//! `labelle android deploy`: upload a bundled APK to GitHub Releases
//! (ported from labelle-cli `src/cli/android/deploy.zig`, #141, development
//! 23aa180; labelle-cli#405). Testers subscribe to the repository in
//! Obtainium and get the release on its next poll.
//!
//! Unlike the CLI's command it builds nothing: the APK comes from
//! `labelle bundle --platform=android` (the provider's `bundle` hook), found
//! under `.labelle/*_android/zig-out/bundle/android/`, or named with
//! `--apk`. So a release is always exactly what was bundled and checked.
const std = @import("std");
const settings_mod = @import("settings.zig");
const proc = @import("proc.zig");

pub const Options = struct {
    tag: ?[]const u8 = null,
    channel: ?settings_mod.Channel = null,
    notes_file: ?[]const u8 = null,
    apk: ?[]const u8 = null,
};

pub const usage =
    \\usage: labelle android deploy --tag <tag> [--channel stable|staging|preview|internal]
    \\                              [--notes-file <file>] [--apk <path>]
    \\
;

/// Parse `deploy`'s arguments (`--flag value` or `--flag=value`).
pub fn parseArgs(args: []const []const u8) !Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const flag = if (eq) |e| arg[0..e] else arg;
        const known = [_][]const u8{ "--tag", "--channel", "--notes-file", "--apk" };
        for (known) |k| {
            if (std.mem.eql(u8, flag, k)) break;
        } else {
            std.debug.print("labelle-android: unknown argument '{s}'\n{s}", .{ arg, usage });
            return error.UnknownArgument;
        }
        const value: []const u8 = if (eq) |e| arg[e + 1 ..] else blk: {
            if (i + 1 >= args.len) {
                std.debug.print("labelle-android: {s} needs a value\n{s}", .{ flag, usage });
                return error.InvalidArgs;
            }
            i += 1;
            break :blk args[i];
        };
        if (value.len == 0) {
            std.debug.print("labelle-android: {s} needs a value\n{s}", .{ flag, usage });
            return error.InvalidArgs;
        }
        if (std.mem.eql(u8, flag, "--tag")) {
            o.tag = value;
        } else if (std.mem.eql(u8, flag, "--channel")) {
            o.channel = std.meta.stringToEnum(settings_mod.Channel, value) orelse {
                std.debug.print("labelle-android: unknown channel '{s}'\n{s}", .{ value, usage });
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, flag, "--notes-file")) {
            o.notes_file = value;
        } else {
            o.apk = value;
        }
    }
    if (o.tag == null) {
        std.debug.print("labelle-android: deploy needs --tag (the release tag, e.g. v0.3.0)\n{s}", .{usage});
        return error.InvalidArgs;
    }
    return o;
}

/// `gh release create <tag> <apk> --title "<label> <tag>" [--repo R]
/// [--prerelease] (--notes-file F | --generate-notes)`.
pub fn ghArgv(a: std.mem.Allocator, o: Options, apk: []const u8, label: []const u8, deploy_cfg: ?settings_mod.Deploy) ![]const []const u8 {
    const tag = o.tag.?;
    const channel = o.channel orelse if (deploy_cfg) |d| d.channel else .stable;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "gh", "release", "create", tag, apk, "--title", try std.fmt.allocPrint(a, "{s} {s}", .{ label, tag }) });
    if (deploy_cfg) |d| try argv.appendSlice(a, &.{ "--repo", d.repo });
    if (channel != .stable) try argv.append(a, "--prerelease");
    if (o.notes_file) |f| {
        try argv.appendSlice(a, &.{ "--notes-file", f });
    } else {
        try argv.append(a, "--generate-notes");
    }
    return argv.toOwnedSlice(a);
}

/// Check `gh` is installed and authenticated, then publish.
pub fn publish(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const auth = proc.run(a, io, &.{ "gh", "auth", "status" }, .{}) catch |err| {
        std.debug.print("labelle-android: failed to run `gh` ({s}): install it from https://cli.github.com/ and run `gh auth login`\n", .{@errorName(err)});
        return error.DeployFailed;
    };
    if (!proc.succeeded(auth.term)) {
        std.debug.print("labelle-android: `gh` is not authenticated: run `gh auth login`\n", .{});
        return error.DeployFailed;
    }
    std.debug.print("labelle-android: uploading {s} to GitHub Releases as {s}...\n", .{ argv[4], argv[3] });
    const result = proc.run(a, io, argv, .{}) catch |err| {
        std.debug.print("labelle-android: gh release create failed to start: {s}\n", .{@errorName(err)});
        return error.DeployFailed;
    };
    if (!proc.succeeded(result.term)) {
        std.debug.print("labelle-android: gh release create failed:\n{s}\n", .{result.stderr});
        return error.DeployFailed;
    }
    std.debug.print(
        \\labelle-android: release {s} published.
        \\  Testers with Obtainium subscribed to this repo will see the update on next poll.
        \\
    , .{argv[3]});
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "parseArgs: both flag spellings, and --tag is required" {
    const o = try parseArgs(&.{ "--tag", "v1.2.0", "--channel=staging", "--notes-file", "notes.md", "--apk=x.apk" });
    try std.testing.expectEqualStrings("v1.2.0", o.tag.?);
    try std.testing.expectEqual(settings_mod.Channel.staging, o.channel.?);
    try std.testing.expectEqualStrings("notes.md", o.notes_file.?);
    try std.testing.expectEqualStrings("x.apk", o.apk.?);
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{}));
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{"--tag"}));
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--tag", "v1", "--channel", "beta" }));
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{ "--tag", "v1", "--release" }));
}

test "ghArgv: stable with generated notes; the settings' repo and channel apply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgv(&.{ "gh", "release", "create", "v1", "g.apk", "--title", "Game v1", "--generate-notes" }, try ghArgv(a, .{ .tag = "v1" }, "g.apk", "Game", null));
    try expectArgv(
        &.{ "gh", "release", "create", "v1", "g.apk", "--title", "Game v1", "--repo", "o/r", "--prerelease", "--notes-file", "n.md" },
        try ghArgv(a, .{ .tag = "v1", .notes_file = "n.md" }, "g.apk", "Game", .{ .repo = "o/r", .channel = .preview }),
    );
    // --channel overrides the settings' channel.
    const argv = try ghArgv(a, .{ .tag = "v1", .channel = .stable }, "g.apk", "Game", .{ .repo = "o/r", .channel = .internal });
    for (argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--prerelease"));
}
