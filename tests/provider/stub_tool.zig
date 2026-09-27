//! A stand-in for every external tool the provider runs (aapt, jar,
//! zipalign, apksigner, llvm-strip, keytool, adb, gh), for the fake-SDK e2e
//! (`tests/provider/e2e.py`). One binary, copied under each tool's name; it
//! picks its behaviour from its own file name (`<name>`, `<name>.exe`, or
//! `<name>-stub.exe` behind a Windows `.bat`).
//!
//! Every call appends one JSON line to `$STUB_LOG`:
//! `{"tool", "argv", "via_provider", ...}`. `via_provider` is whether
//! `LABELLE_CONTEXT` is set, i.e. whether the provider (not the CLI's own
//! legacy packager) ran the tool. Nothing from the environment is logged,
//! so a secret passed as `env:VAR` can only show up if a caller put it in
//! argv.
//!
//! `$STUB_FAIL` (comma-separated tool names) makes those tools exit 1, for
//! provider calls only.
//!
//! The APK stand-in is a real (stored-only) zip, so the e2e can read the
//! inventory the provider produced: aapt writes the manifest, `res/` and
//! `assets/`; `jar --update` adds `lib/`; zipalign and apksigner copy.
const std = @import("std");

const Entry = struct { name: []const u8, data: []const u8 };

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    var argv: std.ArrayList([]const u8) = .empty;
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    while (it.next()) |arg| try argv.append(a, try a.dupe(u8, arg));
    const args = argv.items[1..];

    var tool = std.fs.path.basename(argv.items[0]);
    if (std.mem.endsWith(u8, tool, ".exe")) tool = tool[0 .. tool.len - 4];
    if (std.mem.endsWith(u8, tool, "-stub")) tool = tool[0 .. tool.len - 5];

    const via_provider = env.get("LABELLE_CONTEXT") != null;
    var extra: std.ArrayList(u8) = .empty;
    const code: u8 = blk: {
        if (via_provider) {
            if (env.get("STUB_FAIL")) |fail| {
                var names = std.mem.tokenizeScalar(u8, fail, ',');
                while (names.next()) |name| {
                    if (std.mem.eql(u8, name, tool)) {
                        std.debug.print("{s}: failing on purpose (STUB_FAIL)\n", .{tool});
                        break :blk 1;
                    }
                }
            }
        }
        break :blk act(a, io, env, tool, args, &extra) catch |err| {
            std.debug.print("{s} stub: {s}\n", .{ tool, @errorName(err) });
            break :blk 2;
        };
    };

    if (env.get("STUB_LOG")) |log_path| {
        var line: std.Io.Writer.Allocating = .init(a);
        var js: std.json.Stringify = .{ .writer = &line.writer };
        try js.beginObject();
        try js.objectField("tool");
        try js.write(tool);
        try js.objectField("argv");
        try js.write(args);
        try js.objectField("via_provider");
        try js.write(via_provider);
        try js.objectField("exit");
        try js.write(code);
        try js.endObject();
        var text = line.written();
        if (extra.items.len != 0) {
            // Splice extra `"key": value` pairs before the closing brace.
            text = try std.fmt.allocPrint(a, "{s},{s}}}", .{ text[0 .. text.len - 1], extra.items });
        }
        // Read access too: Windows needs it to query the length.
        var file = std.Io.Dir.cwd().openFile(io, log_path, .{ .mode = .read_write }) catch
            try std.Io.Dir.cwd().createFile(io, log_path, .{ .read = true, .truncate = false });
        defer file.close(io);
        const end = try file.length(io);
        try file.writePositionalAll(io, try std.fmt.allocPrint(a, "{s}\n", .{text}), end);
    }
    return code;
}

fn flag(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, name) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn has(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn read(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 30));
}

fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn act(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, tool: []const u8, args: []const []const u8, extra: *std.ArrayList(u8)) !u8 {
    if (std.mem.eql(u8, tool, "aapt")) {
        var entries: std.ArrayList(Entry) = .empty;
        const manifest = try read(a, io, flag(args, "-M") orelse return error.NoManifest);
        try entries.append(a, .{ .name = "AndroidManifest.xml", .data = manifest });
        // The manifest is logged so the e2e can check what was packaged
        // (versionCode, debuggable, label) after staging is gone.
        var js: std.Io.Writer.Allocating = .init(a);
        var s: std.json.Stringify = .{ .writer = &js.writer };
        try s.write(manifest);
        try extra.print(a, "\"manifest\":{s}", .{js.written()});
        if (flag(args, "-S")) |res| {
            try entries.append(a, .{ .name = "resources.arsc", .data = "ARSC" });
            try addTree(a, io, res, "res", &entries);
        }
        if (flag(args, "-A")) |assets| try addTree(a, io, assets, "assets", &entries);
        try write(io, flag(args, "-F") orelse return error.NoOutput, try zip(a, entries.items));
        return 0;
    }
    if (std.mem.eql(u8, tool, "jar")) {
        if (!has(args, "--update") or !has(args, "--no-compress")) return error.UnexpectedJarArgs;
        const apk = flag(args, "--file") orelse return error.NoFile;
        const base = flag(args, "-C") orelse return error.NoBase;
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(a, try unzip(a, try read(a, io, apk)));
        const sub = args[args.len - 1];
        try addTree(a, io, try std.fs.path.join(a, &.{ base, sub }), sub, &entries);
        try write(io, apk, try zip(a, entries.items));
        return 0;
    }
    if (std.mem.eql(u8, tool, "zipalign")) {
        try write(io, args[args.len - 1], try read(a, io, args[args.len - 2]));
        return 0;
    }
    if (std.mem.eql(u8, tool, "apksigner")) {
        std.Io.Dir.cwd().access(io, flag(args, "--ks") orelse return error.NoKeystore, .{}) catch return error.KeystoreMissing;
        // Resolve the password sources the way apksigner does, without
        // logging a value: proves `env:`/`file:` reach a readable secret.
        inline for (.{ "--ks-pass", "--key-pass" }) |name| {
            if (flag(args, name)) |source| {
                if (std.mem.startsWith(u8, source, "env:")) {
                    const value: []const u8 = env.get(source[4..]) orelse "";
                    if (value.len == 0) return error.PasswordEnvUnset;
                } else if (std.mem.startsWith(u8, source, "file:")) {
                    if ((try read(a, io, source[5..])).len == 0) return error.PasswordFileEmpty;
                } else if (!std.mem.startsWith(u8, source, "pass:")) return error.BadPasswordSource;
            }
        }
        try write(io, flag(args, "--out") orelse return error.NoOut, try read(a, io, args[args.len - 1]));
        return 0;
    }
    if (std.mem.eql(u8, tool, "llvm-strip")) {
        try write(io, flag(args, "-o") orelse return error.NoOut, "STRIPPED");
        return 0;
    }
    if (std.mem.eql(u8, tool, "keytool")) {
        try write(io, flag(args, "-keystore") orelse return error.NoKeystore, "DEBUG-KEYSTORE");
        return 0;
    }
    if (std.mem.eql(u8, tool, "adb")) {
        var out_buf: [256]u8 = undefined;
        var out = std.Io.File.stdout().writer(io, &out_buf);
        if (has(args, "install")) try out.interface.writeAll("Success\n");
        if (has(args, "start")) try out.interface.writeAll("Starting: Intent\n");
        try out.interface.flush();
        return 0;
    }
    if (std.mem.eql(u8, tool, "gh")) return 0;
    return error.UnknownTool;
}

/// Every file under `dir`, as `<prefix>/<rel>` with `/` separators.
fn addTree(a: std.mem.Allocator, io: std.Io, dir: []const u8, prefix: []const u8, entries: *std.ArrayList(Entry)) !void {
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var walker = try d.walk(a);
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        const rel = try a.dupe(u8, e.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        try entries.append(a, .{
            .name = try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, rel }),
            .data = try read(a, io, try std.fs.path.join(a, &.{ dir, e.path })),
        });
    }
}

/// A stored-only zip.
fn zip(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var cd: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        const offset: u32 = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(e.data);
        var h: [30]u8 = @splat(0);
        @memcpy(h[0..4], "PK\x03\x04");
        std.mem.writeInt(u16, h[4..6], 10, .little);
        std.mem.writeInt(u32, h[14..18], crc, .little);
        std.mem.writeInt(u32, h[18..22], @intCast(e.data.len), .little);
        std.mem.writeInt(u32, h[22..26], @intCast(e.data.len), .little);
        std.mem.writeInt(u16, h[26..28], @intCast(e.name.len), .little);
        try out.appendSlice(a, &h);
        try out.appendSlice(a, e.name);
        try out.appendSlice(a, e.data);
        var c: [46]u8 = @splat(0);
        @memcpy(c[0..4], "PK\x01\x02");
        std.mem.writeInt(u16, c[4..6], 20, .little);
        std.mem.writeInt(u16, c[6..8], 10, .little);
        std.mem.writeInt(u32, c[16..20], crc, .little);
        std.mem.writeInt(u32, c[20..24], @intCast(e.data.len), .little);
        std.mem.writeInt(u32, c[24..28], @intCast(e.data.len), .little);
        std.mem.writeInt(u16, c[28..30], @intCast(e.name.len), .little);
        std.mem.writeInt(u32, c[42..46], offset, .little);
        try cd.appendSlice(a, &c);
        try cd.appendSlice(a, e.name);
    }
    const cd_offset: u32 = @intCast(out.items.len);
    try out.appendSlice(a, cd.items);
    var eocd: [22]u8 = @splat(0);
    @memcpy(eocd[0..4], "PK\x05\x06");
    std.mem.writeInt(u16, eocd[8..10], @intCast(entries.len), .little);
    std.mem.writeInt(u16, eocd[10..12], @intCast(entries.len), .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(cd.items.len), .little);
    std.mem.writeInt(u32, eocd[16..20], cd_offset, .little);
    try out.appendSlice(a, &eocd);
    return out.toOwnedSlice(a);
}

/// The entries of a zip `zip` wrote.
fn unzip(a: std.mem.Allocator, bytes: []const u8) ![]Entry {
    const eocd = std.mem.lastIndexOf(u8, bytes, "PK\x05\x06") orelse return error.NotAZip;
    const count = std.mem.readInt(u16, bytes[eocd + 10 ..][0..2], .little);
    var pos: usize = std.mem.readInt(u32, bytes[eocd + 16 ..][0..4], .little);
    var entries: std.ArrayList(Entry) = .empty;
    for (0..count) |_| {
        const c = bytes[pos..];
        const size = std.mem.readInt(u32, c[20..24], .little);
        const name_len = std.mem.readInt(u16, c[28..30], .little);
        const offset = std.mem.readInt(u32, c[42..46], .little);
        const name = c[46..][0..name_len];
        const local = bytes[offset..];
        const local_name = std.mem.readInt(u16, local[26..28], .little);
        const local_extra = std.mem.readInt(u16, local[28..30], .little);
        const data_start = 30 + @as(usize, local_name) + local_extra;
        try entries.append(a, .{ .name = try a.dupe(u8, name), .data = local[data_start..][0..size] });
        pos += 46 + @as(usize, name_len) + std.mem.readInt(u16, c[30..32], .little) + std.mem.readInt(u16, c[32..34], .little);
    }
    return entries.toOwnedSlice(a);
}
