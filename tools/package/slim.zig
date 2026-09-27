//! APK size controls (labelle-assembler#755): what `package.zig` puts in
//! the APK beyond "everything that was built and everything under
//! `assets/`", and a size report printed after every package.
//!
//! Three independent pieces, each defaulting to the old behaviour when
//! its input is missing:
//!
//!   * **Native strip.** Release builds (`ReleaseFast` / `ReleaseSafe` /
//!     `ReleaseSmall`) stage `libgame.so` through the NDK's
//!     `llvm-strip --strip-unneeded` — the same tool and flag the Android
//!     Gradle plugin uses. Only non-allocated sections go (DWARF,
//!     `.symtab`/`.strtab`); the program headers, dynamic section,
//!     relocations and `.dynsym` the loader reads are untouched. The
//!     unstripped library is kept at `zig-out/apk/symbols/<abi>/libgame.so`
//!     for `ndk-stack -sym`. Debug builds are staged as built. No NDK
//!     strip tool, or a strip that fails, stages the unstripped library
//!     with a warning — never a failed build.
//!   * **Asset staging.** On Android the only files the runtime reads OUT
//!     OF the APK are videos (labelle-bgfx's VideoBackend opens them by
//!     name through `AAssetManager`). Atlases, images, sounds and fonts
//!     are compiled into `libgame.so` with `@embedFile`, so their `assets/`
//!     copies are dead weight. `stageAssets` skips exactly the files that
//!     are provably dead and copies everything else:
//!       - `raw/**` — the texture packer's source art (`labelle pack`
//!         inputs), never loaded by the game;
//!       - every `assets/...` path the generated `main.zig` `@embedFile`s;
//!       - the `.png` sibling of an embedded `.astc` (the platform's
//!         `asset_compression` swapped the texture, so the PNG is loaded
//!         by nothing on this platform).
//!     Videos are never skipped, whatever rule matches them. A `main.zig`
//!     that cannot be read only disables the embedded rules.
//!   * **Size report.** The APK total plus its five largest entries, read
//!     from the zip central directory, so growth shows up in every build.
//!
//! Ported from labelle-cli `src/cli/android/apk_slim.zig` (development
//! 23aa180) for the provider (labelle-cli#405): the same rules, so the APK
//! is the same size and layout as the CLI's. The zspec specs are
//! `std.testing` tests here (the provider tool builds with `zig build
//! --system`, which fetches nothing), and every file operation takes the
//! `Io` explicitly.
const std = @import("std");
const builtin = @import("builtin");
const proc = @import("../proc.zig");

/// True for the optimize modes whose packaged library should be
/// stripped. `null` (no `--optimize`, i.e. the build's Debug default)
/// and anything unrecognised keep the library as built.
pub fn stripForOptimize(optimize: ?[]const u8) bool {
    const mode = optimize orelse return false;
    inline for (.{ "ReleaseFast", "ReleaseSafe", "ReleaseSmall" }) |release| {
        if (std.mem.eql(u8, mode, release)) return true;
    }
    return false;
}

// ── Native library ─────────────────────────────────────────────────

/// Where the unstripped copy of each staged library lands, relative to
/// the target dir: `symbols/<abi>/libgame.so`. The file keeps the
/// library's own name so `ndk-stack -sym symbols/<abi>` matches it.
pub const symbols_dir_name = "symbols";

/// How `stageNativeLib` staged one library.
pub const NativeStage = enum {
    /// Debug build: copied as built.
    copied,
    /// Stripped; the unstripped copy is in `symbols/<abi>/`.
    stripped,
    /// Release build but no NDK `llvm-strip` was found: copied as built.
    strip_unavailable,
    /// `llvm-strip` ran and failed: copied as built.
    strip_failed,
    /// The unstripped copy could not be written to `symbols/`: copied as
    /// built (a strip nobody can symbolize is not worth shipping).
    symbols_unwritable,
};

/// Stage `so_path` at `staged_so`. When `strip` is set and `strip_tool`
/// resolves, the staged copy is `strip_tool --strip-unneeded` of the
/// library and the original is copied to `symbols_so` first. Every
/// failure of the strip path — including a `symbols/` that cannot be
/// written — falls back to a plain copy: symbol preservation and
/// stripping are best-effort and must not cost the user their APK.
pub fn stageNativeLib(
    allocator: std.mem.Allocator,
    io: std.Io,
    so_path: []const u8,
    staged_so: []const u8,
    symbols_so: []const u8,
    strip: bool,
    strip_tool: ?[]const u8,
) !NativeStage {
    const cwd = std.Io.Dir.cwd();
    if (!strip) {
        try cwd.copyFile(so_path, cwd, staged_so, io, .{});
        return .copied;
    }
    const tool = strip_tool orelse {
        try cwd.copyFile(so_path, cwd, staged_so, io, .{});
        return .strip_unavailable;
    };

    preserveSymbols(io, so_path, symbols_so) catch |err| {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        writeSymbolsWarning(&w, symbols_so, err) catch {};
        std.debug.print("{s}", .{w.buffered()});
        try cwd.copyFile(so_path, cwd, staged_so, io, .{});
        return .symbols_unwritable;
    };

    const ok = blk: {
        const result = proc.run(allocator, io, &.{ tool, "--strip-unneeded", "-o", staged_so, so_path }, .{}) catch break :blk false;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        const exited_ok = result.term == .exited and result.term.exited == 0;
        if (!exited_ok) std.debug.print("labelle-android: llvm-strip failed: {s}\n", .{result.stderr});
        break :blk exited_ok;
    };
    if (!ok) {
        try cwd.copyFile(so_path, cwd, staged_so, io, .{});
        return .strip_failed;
    }
    return .stripped;
}

fn preserveSymbols(io: std.Io, so_path: []const u8, symbols_so: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(symbols_so)) |dir| try cwd.createDirPath(io, dir);
    try cwd.copyFile(so_path, cwd, symbols_so, io, .{});
}

/// The warning `stageNativeLib` prints when the unstripped copy cannot be
/// written. Separate so a spec can pin that it names the path and error.
pub fn writeSymbolsWarning(w: *std.Io.Writer, symbols_so: []const u8, err: anyerror) !void {
    try w.print("labelle-android: warning: cannot write unstripped copy {s} ({s}); packaging libgame.so unstripped\n", .{ symbols_so, @errorName(err) });
}

// ── Asset staging ──────────────────────────────────────────────────

/// Why `stageAssets` left a file out of the APK.
pub const SkipReason = enum {
    /// Under `raw/`: texture-packer source art.
    packer_source,
    /// `@embedFile`d by the generated `main.zig` — already in `libgame.so`.
    embedded,
    /// The `.png` of an embedded `.astc` — replaced on this platform.
    astc_png_sibling,
};

/// The `assets/`-relative paths the generated `main.zig` embeds, with
/// `/` separators (as they are spelled in the source).
pub const EmbeddedAssets = struct {
    paths: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *EmbeddedAssets, allocator: std.mem.Allocator) void {
        var it = self.paths.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.paths.deinit(allocator);
    }

    pub fn contains(self: EmbeddedAssets, rel: []const u8) bool {
        return self.paths.contains(rel);
    }
};

/// Collect every `@embedFile("assets/<rel>")` literal in `source`. A
/// literal containing an escape (`\`) is skipped rather than decoded —
/// missing an entry only means that file ships as before.
pub fn scanEmbeddedAssets(allocator: std.mem.Allocator, source: []const u8) !EmbeddedAssets {
    const needle = "@embedFile(\"assets/";
    var out: EmbeddedAssets = .{};
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, needle)) |hit| {
        const start = hit + needle.len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        pos = end;
        const rel = source[start..end];
        if (rel.len == 0 or std.mem.indexOfScalar(u8, rel, '\\') != null) continue;
        if (out.paths.contains(rel)) continue;
        const owned = try allocator.dupe(u8, rel);
        errdefer allocator.free(owned);
        try out.paths.put(allocator, owned, {});
    }
    return out;
}

/// Read `<target_dir>/main.zig` and scan it. A missing or unreadable
/// file yields an empty set: only the `raw/` rule then applies.
pub fn loadEmbeddedAssets(allocator: std.mem.Allocator, io: std.Io, target_dir: []const u8) !EmbeddedAssets {
    const main_zig = try std.fs.path.join(allocator, &.{ target_dir, "main.zig" });
    defer allocator.free(main_zig);
    const source = std.Io.Dir.cwd().readFileAlloc(io, main_zig, allocator, .limited(64 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{},
    };
    defer allocator.free(source);
    return scanEmbeddedAssets(allocator, source);
}

/// Extensions the runtime opens from the APK by name (the video path).
/// Never skipped, whichever rule would otherwise match.
pub const apk_read_extensions = [_][]const u8{ ".mp4", ".m4v", ".webm", ".mkv", ".mov", ".3gp" };

fn isApkRead(rel: []const u8) bool {
    const ext = std.fs.path.extension(rel);
    for (apk_read_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// The staging decision for one file, `rel` being its `assets/`-relative
/// path with `/` separators. `null` means "ship it".
pub fn skipReason(rel: []const u8, embedded: EmbeddedAssets) ?SkipReason {
    if (isApkRead(rel)) return null;
    if (std.mem.startsWith(u8, rel, "raw/")) return .packer_source;
    if (embedded.contains(rel)) return .embedded;
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(rel), ".png")) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const stem = rel[0 .. rel.len - ".png".len];
        const astc = std.fmt.bufPrint(&buf, "{s}.astc", .{stem}) catch return null;
        if (embedded.contains(astc)) return .astc_png_sibling;
    }
    return null;
}

/// Totals for the staging log line.
pub const StageSummary = struct {
    kept_files: usize = 0,
    skipped_files: [std.enums.values(SkipReason).len]usize = @splat(0),
    skipped_bytes: [std.enums.values(SkipReason).len]u64 = @splat(0),

    pub fn skippedFiles(self: StageSummary) usize {
        var n: usize = 0;
        for (self.skipped_files) |c| n += c;
        return n;
    }

    pub fn skippedBytes(self: StageSummary) u64 {
        var n: u64 = 0;
        for (self.skipped_bytes) |c| n += c;
        return n;
    }
};

/// Copy `src` to `dst` recursively, leaving out what `skipReason` rejects.
pub fn stageAssets(allocator: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8, embedded: EmbeddedAssets) !StageSummary {
    var summary: StageSummary = .{};
    try stageDir(allocator, io, src, dst, "", embedded, &summary);
    return summary;
}

fn stageDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    src: []const u8,
    dst: []const u8,
    rel_prefix: []const u8,
    embedded: EmbeddedAssets,
    summary: *StageSummary,
) !void {
    const cwd = std.Io.Dir.cwd();
    // `dst` is created on the first file kept in it, so a tree whose files
    // are all skipped (a `raw/` without videos) leaves no empty dirs behind.
    var dst_made = false;

    var src_dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        const rel = if (rel_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, entry.name });
        defer allocator.free(rel);
        const src_sub = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_sub);
        const dst_sub = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_sub);

        switch (try entryAction(io, src_dir, entry.name, entry.kind)) {
            // Every file, `raw/` included, goes through `skipReason`: that is
            // where the video exemption lives.
            .recurse => try stageDir(allocator, io, src_sub, dst_sub, rel, embedded, summary),
            .copy => {
                if (skipReason(rel, embedded)) |reason| {
                    const st = try cwd.statFile(io, src_sub, .{});
                    summary.skipped_files[@intFromEnum(reason)] += 1;
                    summary.skipped_bytes[@intFromEnum(reason)] += st.size;
                    continue;
                }
                if (!dst_made) {
                    cwd.createDirPath(io, dst) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                    dst_made = true;
                }
                try cwd.copyFile(src_sub, cwd, dst_sub, io, .{});
                summary.kept_files += 1;
            },
            .skip => {},
        }
    }
}

pub const EntryAction = enum { recurse, copy, skip };

/// What staging does with the entry `name` of `dir`, whose iterator reported
/// `kind`: recurse into directories, copy files, skip the rest (symlinks,
/// devices...). Some filesystems (NFS, FUSE mounts) report `.unknown` for
/// every entry; those are resolved with a no-follow stat first, so their
/// files are staged rather than silently left out, and a symlink stays a
/// symlink (skipped) as it would on any other filesystem.
pub fn entryAction(io: std.Io, dir: std.Io.Dir, name: []const u8, kind: std.Io.File.Kind) !EntryAction {
    const resolved = if (kind == .unknown)
        (try dir.statFile(io, name, .{ .follow_symlinks = false })).kind
    else
        kind;
    return switch (resolved) {
        .directory => .recurse,
        .file => .copy,
        else => .skip,
    };
}

// ── Size report ────────────────────────────────────────────────────

/// One APK entry as the zip central directory describes it.
pub const ZipEntry = struct {
    name: []const u8,
    /// Bytes the entry occupies in the APK (its compressed size).
    packed_size: u64,
    unpacked_size: u64,
    stored: bool,
};

/// Parse the central directory of the zip held in `tail`, where `tail`
/// is the LAST `tail.len` bytes of a file of `file_len` bytes. Names are
/// slices into `tail`. Zip64 is not handled (an APK over 4 GiB is not a
/// thing Android installs): its entries come back with their 32-bit
/// sentinel sizes.
pub fn parseCentralDirectory(allocator: std.mem.Allocator, tail: []const u8, file_len: u64) ![]ZipEntry {
    const eocd_sig = [4]u8{ 'P', 'K', 5, 6 };
    const cd_sig = [4]u8{ 'P', 'K', 1, 2 };
    if (tail.len < 22) return error.NotAZip;
    const eocd = std.mem.lastIndexOf(u8, tail[0 .. tail.len - 18], &eocd_sig) orelse return error.NotAZip;
    const cd_size = std.mem.readInt(u32, tail[eocd + 12 ..][0..4], .little);
    const cd_offset = std.mem.readInt(u32, tail[eocd + 16 ..][0..4], .little);
    const tail_start = file_len - tail.len;
    if (cd_offset < tail_start or cd_offset - tail_start + cd_size > tail.len) return error.CentralDirectoryOutOfRange;
    const cd = tail[@intCast(cd_offset - tail_start)..][0..cd_size];

    var entries: std.ArrayList(ZipEntry) = .empty;
    errdefer entries.deinit(allocator);
    var pos: usize = 0;
    while (pos + 46 <= cd.len and std.mem.eql(u8, cd[pos..][0..4], &cd_sig)) {
        const h = cd[pos..];
        const method = std.mem.readInt(u16, h[10..12], .little);
        const packed_size = std.mem.readInt(u32, h[20..24], .little);
        const unpacked_size = std.mem.readInt(u32, h[24..28], .little);
        const name_len = std.mem.readInt(u16, h[28..30], .little);
        const extra_len = std.mem.readInt(u16, h[30..32], .little);
        const comment_len = std.mem.readInt(u16, h[32..34], .little);
        if (pos + 46 + name_len > cd.len) return error.TruncatedCentralDirectory;
        try entries.append(allocator, .{
            .name = h[46..][0..name_len],
            .packed_size = packed_size,
            .unpacked_size = unpacked_size,
            .stored = method == 0,
        });
        pos += 46 + @as(usize, name_len) + extra_len + comment_len;
    }
    return entries.toOwnedSlice(allocator);
}

fn biggerFirst(_: void, a: ZipEntry, b: ZipEntry) bool {
    return a.packed_size > b.packed_size;
}

/// Write the report: APK total, then the `top_n` biggest entries.
pub fn writeSizeReport(w: *std.Io.Writer, apk_path: []const u8, apk_len: u64, entries: []ZipEntry, top_n: usize) !void {
    std.mem.sort(ZipEntry, entries, {}, biggerFirst);
    try w.print("labelle-android: APK size {d:.1} MB ({d} bytes, {d} entries): {s}\n", .{ mb(apk_len), apk_len, entries.len, apk_path });
    for (entries[0..@min(top_n, entries.len)]) |e| {
        // KB below a tenth of a MB, so small entries don't all read "0.0 MB".
        if (e.packed_size >= 100_000) {
            try w.print("  {d:>7.1} MB  {s}{s}\n", .{ mb(e.packed_size), e.name, if (e.stored) " (stored)" else "" });
        } else {
            try w.print("  {d:>7.1} KB  {s}{s}\n", .{ @as(f64, @floatFromInt(e.packed_size)) / 1_000.0, e.name, if (e.stored) " (stored)" else "" });
        }
    }
}

pub fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1_000_000.0;
}

/// Read `apk_path`'s central directory and print the size report to
/// stderr. Best-effort: a report that cannot be produced is a one-line
/// note, never a failed build. Returns the report (owned by `allocator`)
/// when there is one, so a caller can also keep it beside the artifact.
pub fn printSizeReport(allocator: std.mem.Allocator, io: std.Io, apk_path: []const u8) ?[]u8 {
    const text = sizeReport(allocator, io, apk_path) catch |err| {
        std.debug.print("labelle-android: APK size report unavailable ({s})\n", .{@errorName(err)});
        return null;
    };
    std.debug.print("{s}", .{text});
    return text;
}

/// The size report of `apk_path`. Caller owns the text.
pub fn sizeReport(allocator: std.mem.Allocator, io: std.Io, apk_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, apk_path, .{});
    defer file.close(io);
    const len = try file.length(io);
    // The central directory sits right before the end record; one read of
    // the last few MiB covers it for any APK with a sane entry count.
    const tail_len: usize = @intCast(@min(len, 8 << 20));
    const tail = try allocator.alloc(u8, tail_len);
    defer allocator.free(tail);
    const n = try file.readPositionalAll(io, tail, len - tail_len);
    if (n != tail_len) return error.ShortRead;

    const entries = try parseCentralDirectory(allocator, tail, len);
    defer allocator.free(entries);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try writeSizeReport(&aw.writer, apk_path, len, entries, 5);
    return aw.toOwnedSlice();
}

// ── Tests ──────────────────────────────────────────────────────────

test {
    _ = StripDecisionSpec;
    _ = StageNativeLibSpec;
    _ = ScanEmbeddedAssetsSpec;
    _ = SkipReasonSpec;
    _ = StageAssetsSpec;
    _ = SizeReportSpec;
}

fn expectEq(actual: anytype, expected: @TypeOf(actual)) !void {
    try std.testing.expectEqual(expected, actual);
}

pub const StripDecisionSpec = struct {
    test "release optimize modes strip, Debug and no --optimize do not" {
        try std.testing.expect(stripForOptimize("ReleaseFast"));
        try std.testing.expect(stripForOptimize("ReleaseSafe"));
        try std.testing.expect(stripForOptimize("ReleaseSmall"));
        try std.testing.expect(!stripForOptimize("Debug"));
        try std.testing.expect(!stripForOptimize(null));
        try std.testing.expect(!stripForOptimize("releasefast"));
    }
};

/// Scratch dir + helpers for the native-staging specs.
const NativeFixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,

    fn init() !NativeFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *NativeFixture) void {
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn path(self: NativeFixture, sub: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.root, sub });
    }

    fn read(self: NativeFixture, sub: []const u8) ![]u8 {
        const p = try self.path(sub);
        defer std.testing.allocator.free(p);
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, std.testing.allocator, .limited(1 << 20));
    }

    fn exists(self: NativeFixture, sub: []const u8) bool {
        const p = self.path(sub) catch return false;
        defer std.testing.allocator.free(p);
        std.Io.Dir.cwd().access(std.testing.io, p, .{}) catch return false;
        return true;
    }

    fn write(self: NativeFixture, sub: []const u8, data: []const u8) !void {
        const p = try self.path(sub);
        defer std.testing.allocator.free(p);
        if (std.fs.path.dirname(p)) |d| try std.Io.Dir.cwd().createDirPath(std.testing.io, d);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = p, .data = data });
    }

    /// A stand-in `llvm-strip` that records its argv and writes a marker
    /// to the `-o` path, so a spec can tell a stripped stage from a copy.
    fn fakeStrip(self: NativeFixture, exit_code: u8) ![]u8 {
        const script = try std.fmt.allocPrint(std.testing.allocator,
            \\#!/bin/sh
            \\echo "$@" > "{s}/strip-args"
            \\[ {d} -eq 0 ] && printf STRIPPED > "$3"
            \\exit {d}
            \\
        , .{ self.root, exit_code, exit_code });
        defer std.testing.allocator.free(script);
        try self.write("fake-strip", script);
        const p = try self.path("fake-strip");
        errdefer std.testing.allocator.free(p);
        const r = try proc.run(std.testing.allocator, std.testing.io, &.{ "chmod", "+x", p }, .{});
        std.testing.allocator.free(r.stdout);
        std.testing.allocator.free(r.stderr);
        return p;
    }
};

pub const StageNativeLibSpec = struct {
    test "no strip: the staged library is the built one, no symbols copy" {
        const a = std.testing.allocator;
        var fx = try NativeFixture.init();
        defer fx.deinit();
        try fx.write("libgame.so", "BUILT-WITH-DWARF");
        const so = try fx.path("libgame.so");
        defer a.free(so);
        const staged = try fx.path("staged.so");
        defer a.free(staged);
        const sym = try fx.path("symbols/arm64-v8a/libgame.so");
        defer a.free(sym);

        try expectEq(try stageNativeLib(a, std.testing.io, so, staged, sym, false, "/nonexistent/llvm-strip"), .copied);
        const got = try fx.read("staged.so");
        defer a.free(got);
        try std.testing.expectEqualStrings("BUILT-WITH-DWARF", got);
        try std.testing.expect(!fx.exists("symbols/arm64-v8a/libgame.so"));
    }

    test "strip: the tool writes the staged copy and the original lands in symbols/" {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const a = std.testing.allocator;
        var fx = try NativeFixture.init();
        defer fx.deinit();
        try fx.write("libgame.so", "BUILT-WITH-DWARF");
        const tool = try fx.fakeStrip(0);
        defer a.free(tool);
        const so = try fx.path("libgame.so");
        defer a.free(so);
        const staged = try fx.path("staged.so");
        defer a.free(staged);
        const sym = try fx.path("symbols/arm64-v8a/libgame.so");
        defer a.free(sym);

        try expectEq(try stageNativeLib(a, std.testing.io, so, staged, sym, true, tool), .stripped);
        // The staged bytes came from the TOOL, not from a copy.
        const got = try fx.read("staged.so");
        defer a.free(got);
        try std.testing.expectEqualStrings("STRIPPED", got);
        // The flag is the one AGP uses, reading the built library.
        const args = try fx.read("strip-args");
        defer a.free(args);
        const want = try std.fmt.allocPrint(a, "--strip-unneeded -o {s} {s}\n", .{ staged, so });
        defer a.free(want);
        try std.testing.expectEqualStrings(want, args);
        // The unstripped original is preserved for ndk-stack.
        const kept = try fx.read("symbols/arm64-v8a/libgame.so");
        defer a.free(kept);
        try std.testing.expectEqualStrings("BUILT-WITH-DWARF", kept);
    }

    test "strip requested but no tool: staged as built, reported as unavailable" {
        const a = std.testing.allocator;
        var fx = try NativeFixture.init();
        defer fx.deinit();
        try fx.write("libgame.so", "BUILT-WITH-DWARF");
        const so = try fx.path("libgame.so");
        defer a.free(so);
        const staged = try fx.path("staged.so");
        defer a.free(staged);
        const sym = try fx.path("symbols/arm64-v8a/libgame.so");
        defer a.free(sym);

        try expectEq(try stageNativeLib(a, std.testing.io, so, staged, sym, true, null), .strip_unavailable);
        const got = try fx.read("staged.so");
        defer a.free(got);
        try std.testing.expectEqualStrings("BUILT-WITH-DWARF", got);
    }

    test "an unwritable symbols/ stages the built library unstripped, strip never runs" {
        const a = std.testing.allocator;
        var fx = try NativeFixture.init();
        defer fx.deinit();
        try fx.write("libgame.so", "BUILT-WITH-DWARF");
        // The recording fake needs `sh`; on Windows a missing tool still
        // tells the paths apart (it would report `.strip_failed`).
        const tool = if (builtin.os.tag == .windows) try a.dupe(u8, "Z:\\nonexistent\\llvm-strip.exe") else try fx.fakeStrip(0);
        defer a.free(tool);
        // A regular FILE where the `symbols` dir must go: no directory can
        // be created under it, for any user (root included) on any OS —
        // unlike a chmod'ed dir, which root writes through anyway.
        try fx.write("symbols", "not a directory");
        const so = try fx.path("libgame.so");
        defer a.free(so);
        const staged = try fx.path("staged.so");
        defer a.free(staged);
        const sym = try fx.path("symbols/arm64-v8a/libgame.so");
        defer a.free(sym);

        try expectEq(try stageNativeLib(a, std.testing.io, so, staged, sym, true, tool), .symbols_unwritable);
        // The fallback ran BEFORE the tool: nothing was stripped.
        try std.testing.expect(!fx.exists("strip-args"));
        const got = try fx.read("staged.so");
        defer a.free(got);
        try std.testing.expectEqualStrings("BUILT-WITH-DWARF", got);
    }

    test "the symbols warning names the path and the error" {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeSymbolsWarning(&w, "t/symbols/arm64-v8a/libgame.so", error.NotDir);
        try std.testing.expectEqualStrings(
            "labelle-android: warning: cannot write unstripped copy t/symbols/arm64-v8a/libgame.so (NotDir); packaging libgame.so unstripped\n",
            w.buffered(),
        );
    }

    test "a failing strip falls back to the built library" {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const a = std.testing.allocator;
        var fx = try NativeFixture.init();
        defer fx.deinit();
        try fx.write("libgame.so", "BUILT-WITH-DWARF");
        const tool = try fx.fakeStrip(1);
        defer a.free(tool);
        const so = try fx.path("libgame.so");
        defer a.free(so);
        const staged = try fx.path("staged.so");
        defer a.free(staged);
        const sym = try fx.path("symbols/arm64-v8a/libgame.so");
        defer a.free(sym);

        try expectEq(try stageNativeLib(a, std.testing.io, so, staged, sym, true, tool), .strip_failed);
        // The tool DID run (so this is the fallback, not the no-tool path).
        try std.testing.expect(fx.exists("strip-args"));
        const got = try fx.read("staged.so");
        defer a.free(got);
        try std.testing.expectEqualStrings("BUILT-WITH-DWARF", got);
    }
};

pub const ScanEmbeddedAssetsSpec = struct {
    test "collects assets/ embeds from generated main.zig, ignores the rest" {
        const a = std.testing.allocator;
        const src =
            \\    try g.loadAtlasFromMemory("rooms", @embedFile("assets/rooms.json"), @embedFile("assets/rooms.astc"), ".png");
            \\    try g.loadAtlasFromMemory("sky", @embedFile("packs/sky/assets/cloud.json"), @embedFile("packs/sky/assets/cloud.astc"), ".png");
            \\    g.assets.register("logo", .image, ".png", @embedFile("assets/ui/logo.png")) catch {};
            \\    const s = @embedFile("scenes/main.jsonc");
            \\    const odd = @embedFile("assets/we\"ird.png");
            \\    try g.loadAtlasFromMemory("rooms2", @embedFile("assets/rooms.json"), @embedFile("assets/rooms.astc"), ".png");
        ;
        var set = try scanEmbeddedAssets(a, src);
        defer set.deinit(a);
        try expectEq(set.paths.count(), 3);
        try std.testing.expect(set.contains("rooms.json"));
        try std.testing.expect(set.contains("rooms.astc"));
        try std.testing.expect(set.contains("ui/logo.png"));
        try std.testing.expect(!set.contains("cloud.astc"));
    }
};

pub const SkipReasonSpec = struct {
    fn fpEmbeds(a: std.mem.Allocator) !EmbeddedAssets {
        return scanEmbeddedAssets(a,
            \\@embedFile("assets/characters.json") @embedFile("assets/characters.astc")
            \\@embedFile("assets/ship.json") @embedFile("assets/ship.png")
            \\@embedFile("assets/intro.mp4")
        );
    }

    test "raw/ is packer source" {
        const a = std.testing.allocator;
        var set = try fpEmbeds(a);
        defer set.deinit(a);
        try expectEq(skipReason("raw/characters/idle/0.png", set), .packer_source);
        try expectEq(skipReason("raw/characters.ftpp", set), .packer_source);
        // Only the top-level raw/: a nested one is ordinary content.
        try expectEq(skipReason("ui/raw/x.png", set), null);
    }

    test "embedded files and the PNG of an embedded ASTC are skipped" {
        const a = std.testing.allocator;
        var set = try fpEmbeds(a);
        defer set.deinit(a);
        try expectEq(skipReason("characters.json", set), .embedded);
        try expectEq(skipReason("characters.astc", set), .embedded);
        try expectEq(skipReason("characters.png", set), .astc_png_sibling);
        // ship was NOT swapped to ASTC here: its PNG is the embedded one.
        try expectEq(skipReason("ship.png", set), .embedded);
        try expectEq(skipReason("ship.astc", set), null);
    }

    test "videos and unreferenced files ship" {
        const a = std.testing.allocator;
        var set = try fpEmbeds(a);
        defer set.deinit(a);
        // Even an embedded or raw/ video: the VideoBackend opens it by name.
        try expectEq(skipReason("intro.mp4", set), null);
        try expectEq(skipReason("raw/clip.MP4", set), null);
        try expectEq(skipReason("icon.png", set), null);
        try expectEq(skipReason("ui/icons/icon_menu.png", set), null);
    }
};

pub const StageAssetsSpec = struct {
    test "stages only what the APK needs and accounts for the rest" {
        const a = std.testing.allocator;
        var fx = try NativeFixture.init();
        defer fx.deinit();
        try fx.write("src/intro.mp4", "VIDEO");
        try fx.write("src/rooms.json", "{}");
        try fx.write("src/rooms.astc", "ASTC");
        try fx.write("src/rooms.png", "PNG");
        try fx.write("src/icon.png", "ICON");
        try fx.write("src/ui/icons/a.png", "UI");
        try fx.write("src/raw/rooms/r0.png", "RAW0");
        try fx.write("src/raw/rooms.ftpp", "PROJ");

        var set = try scanEmbeddedAssets(a, "@embedFile(\"assets/rooms.json\") @embedFile(\"assets/rooms.astc\")");
        defer set.deinit(a);
        const src = try fx.path("src");
        defer a.free(src);
        const dst = try fx.path("dst");
        defer a.free(dst);
        const summary = try stageAssets(a, std.testing.io, src, dst, set);

        try std.testing.expect(fx.exists("dst/intro.mp4"));
        try std.testing.expect(fx.exists("dst/icon.png"));
        try std.testing.expect(fx.exists("dst/ui/icons/a.png"));
        try std.testing.expect(!fx.exists("dst/rooms.json"));
        try std.testing.expect(!fx.exists("dst/rooms.astc"));
        try std.testing.expect(!fx.exists("dst/rooms.png"));
        try std.testing.expect(!fx.exists("dst/raw"));

        try expectEq(summary.kept_files, 3);
        try expectEq(summary.skipped_files[@intFromEnum(SkipReason.packer_source)], 2);
        try expectEq(summary.skipped_files[@intFromEnum(SkipReason.embedded)], 2);
        try expectEq(summary.skipped_files[@intFromEnum(SkipReason.astc_png_sibling)], 1);
        try expectEq(summary.skippedBytes(), 4 + 4 + 2 + 4 + 3);
    }

    test "a video under raw/ is staged, the rest of raw/ is not" {
        const a = std.testing.allocator;
        var fx = try NativeFixture.init();
        defer fx.deinit();
        try fx.write("src/raw/clip.mp4", "VIDEO");
        try fx.write("src/raw/x.MP4", "VID2");
        try fx.write("src/raw/frame.png", "RAW");
        try fx.write("src/raw/sheet/f0.png", "RAW0");
        const src = try fx.path("src");
        defer a.free(src);
        const dst = try fx.path("dst");
        defer a.free(dst);
        var none: EmbeddedAssets = .{};
        defer none.deinit(a);
        const summary = try stageAssets(a, std.testing.io, src, dst, none);

        const got = try fx.read("dst/raw/clip.mp4");
        defer a.free(got);
        try std.testing.expectEqualStrings("VIDEO", got);
        try std.testing.expect(fx.exists("dst/raw/x.MP4"));
        try std.testing.expect(!fx.exists("dst/raw/frame.png"));
        // A raw/ subtree with nothing kept is not even created.
        try std.testing.expect(!fx.exists("dst/raw/sheet"));
        try expectEq(summary.kept_files, 2);
        try expectEq(summary.skipped_files[@intFromEnum(SkipReason.packer_source)], 2);
    }

    test "entryAction: known kinds decide directly, .unknown is resolved by a no-follow stat" {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "clip.mp4", .data = "VIDEO" });
        try tmp.dir.createDirPath(io, "sub");
        // Known kinds never touch the filesystem (the name does not exist).
        try expectEq(try entryAction(io, tmp.dir, "absent", .file), .copy);
        try expectEq(try entryAction(io, tmp.dir, "absent", .directory), .recurse);
        try expectEq(try entryAction(io, tmp.dir, "absent", .sym_link), .skip);
        // What an NFS/FUSE iterator reports: resolved from the entry itself.
        try expectEq(try entryAction(io, tmp.dir, "clip.mp4", .unknown), .copy);
        try expectEq(try entryAction(io, tmp.dir, "sub", .unknown), .recurse);
        if (builtin.os.tag != .windows) {
            try tmp.dir.symLink(io, "clip.mp4", "link.mp4", .{});
            try expectEq(try entryAction(io, tmp.dir, "link.mp4", .unknown), .skip);
        }
    }

    test "no embeds known: everything but raw/ ships" {
        const a = std.testing.allocator;
        var fx = try NativeFixture.init();
        defer fx.deinit();
        try fx.write("src/rooms.png", "PNG");
        try fx.write("src/rooms.astc", "ASTC");
        try fx.write("src/raw/r0.png", "RAW0");
        const src = try fx.path("src");
        defer a.free(src);
        const dst = try fx.path("dst");
        defer a.free(dst);
        // What `loadEmbeddedAssets` yields for a target without main.zig.
        var none = try loadEmbeddedAssets(a, std.testing.io, fx.root);
        defer none.deinit(a);
        const summary = try stageAssets(a, std.testing.io, src, dst, none);
        try std.testing.expect(fx.exists("dst/rooms.png"));
        try std.testing.expect(fx.exists("dst/rooms.astc"));
        try std.testing.expect(!fx.exists("dst/raw"));
        try expectEq(summary.kept_files, 2);
        try expectEq(summary.skippedFiles(), 1);
    }
};

/// Build a minimal zip image: `pad` filler bytes standing in for the
/// local headers + data, then a central directory and end record.
fn testZip(a: std.mem.Allocator, pad: usize, entries: []const ZipEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendNTimes(a, 0xAA, pad);
    const cd_start = out.items.len;
    for (entries) |e| {
        var h: [46]u8 = @splat(0);
        @memcpy(h[0..4], "PK\x01\x02");
        std.mem.writeInt(u16, h[10..12], if (e.stored) 0 else 8, .little);
        std.mem.writeInt(u32, h[20..24], @intCast(e.packed_size), .little);
        std.mem.writeInt(u32, h[24..28], @intCast(e.unpacked_size), .little);
        std.mem.writeInt(u16, h[28..30], @intCast(e.name.len), .little);
        try out.appendSlice(a, &h);
        try out.appendSlice(a, e.name);
    }
    const cd_size = out.items.len - cd_start;
    var eocd: [22]u8 = @splat(0);
    @memcpy(eocd[0..4], "PK\x05\x06");
    std.mem.writeInt(u16, eocd[10..12], @intCast(entries.len), .little);
    std.mem.writeInt(u32, eocd[12..16], @intCast(cd_size), .little);
    std.mem.writeInt(u32, eocd[16..20], @intCast(cd_start), .little);
    try out.appendSlice(a, &eocd);
    return out.toOwnedSlice(a);
}

pub const SizeReportSpec = struct {
    const sample = [_]ZipEntry{
        .{ .name = "AndroidManifest.xml", .packed_size = 900, .unpacked_size = 2000, .stored = false },
        .{ .name = "lib/arm64-v8a/libgame.so", .packed_size = 35_191_400, .unpacked_size = 35_191_400, .stored = true },
        .{ .name = "assets/intro.mp4", .packed_size = 4_804_688, .unpacked_size = 4_804_688, .stored = true },
        .{ .name = "assets/a.png", .packed_size = 10, .unpacked_size = 10, .stored = true },
        .{ .name = "assets/b.png", .packed_size = 20, .unpacked_size = 20, .stored = true },
        .{ .name = "META-INF/CERT.SF", .packed_size = 30, .unpacked_size = 300, .stored = false },
    };

    test "parses the central directory from a tail read" {
        const a = std.testing.allocator;
        const zip = try testZip(a, 5000, &sample);
        defer a.free(zip);
        // Hand the parser only the last part of the file, as the reader does.
        const tail = zip[4000..];
        const entries = try parseCentralDirectory(a, tail, zip.len);
        defer a.free(entries);
        try expectEq(entries.len, sample.len);
        try std.testing.expectEqualStrings("lib/arm64-v8a/libgame.so", entries[1].name);
        try expectEq(entries[1].packed_size, 35_191_400);
        try std.testing.expect(entries[1].stored);
        try std.testing.expect(!entries[0].stored);
    }

    test "a tail that misses the central directory is an error, not garbage" {
        const a = std.testing.allocator;
        const zip = try testZip(a, 5000, &sample);
        defer a.free(zip);
        try std.testing.expectError(error.CentralDirectoryOutOfRange, parseCentralDirectory(a, zip[zip.len - 30 ..], zip.len));
        try std.testing.expectError(error.NotAZip, parseCentralDirectory(a, "not a zip file at all, no end record", 36));
    }

    test "report lists the total and the five biggest entries, biggest first" {
        const a = std.testing.allocator;
        var entries = sample;
        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        try writeSizeReport(&aw.writer, "game.apk", 40_100_000, &entries, 5);
        const text = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, text, "labelle-android: APK size 40.1 MB (40100000 bytes, 6 entries): game.apk\n"));
        var lines = std.mem.splitScalar(u8, text, '\n');
        _ = lines.next();
        try std.testing.expectEqualStrings("     35.2 MB  lib/arm64-v8a/libgame.so (stored)", lines.next().?);
        try std.testing.expectEqualStrings("      4.8 MB  assets/intro.mp4 (stored)", lines.next().?);
        try std.testing.expectEqualStrings("      0.9 KB  AndroidManifest.xml", lines.next().?);
        _ = lines.next();
        _ = lines.next();
        // Five entries, then the trailing newline: the smallest is cut.
        try std.testing.expectEqualStrings("", lines.next().?);
        try std.testing.expect(std.mem.indexOf(u8, text, "assets/a.png") == null);
    }
};
