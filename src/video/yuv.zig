//! YUV → RGBA8 colour conversion for the in-engine video decode path
//! (Flying-Platform/flying-platform-labelle#549, Path A Half 2).
//!
//! Android's `AMediaCodec` ByteBuffer output is YUV, not RGBA — typically
//! `COLOR_FormatYUV420SemiPlanar` (NV12: Y plane + interleaved UV) or
//! `COLOR_FormatYUV420Planar` (I420: Y + U + V planes). bgfx draws RGBA8
//! textures, so the decoded frame must be converted before `updateTexture`.
//!
//! This module is **pure Zig with no NDK dependency**, so it builds and is
//! unit-tested on the host — the one piece of the Android decode path that is
//! verifiable without a device. The conversion is 8.8 fixed-point integer
//! math driven by a `Matrix`: BT.601 or BT.709 coefficients, limited (16–235)
//! or full (0–255) range. `nv12ToRgba` / `i420ToRgba` / `yuv420ToRgba` keep
//! the BT.601 limited-range default (the SD / desktop-ffmpeg convention);
//! `yuv420ToRgbaMatrix` takes the matrix the stream's colour metadata selects
//! (the Android decoder's `ColorSpace.matrix`, labelle-android#3 round 2).
//!
//! Strides are explicit: MediaCodec output planes are frequently padded
//! (`stride >= width`), so the caller passes the real plane strides from the
//! output `AMediaFormat` rather than assuming tight packing.

const std = @import("std");
const builtin = @import("builtin");

/// YUV → RGB coefficients in 8.8 fixed point (gain × 256, rounded):
///
///   R = (y_gain·(Y − y_off) + rv·(V − 128) + 128) >> 8
///   G = (y_gain·(Y − y_off) − gu·(U − 128) − gv·(V − 128) + 128) >> 8
///   B = (y_gain·(Y − y_off) + bu·(U − 128) + 128) >> 8
///
/// Limited range: Y 16–235 → `y_off` 16, `y_gain` 255/219 (298); chroma
/// 16–240 scales the standard's gains by 255/224. Full range: `y_off` 0,
/// `y_gain` 1 (256), chroma gains unscaled. BT.601 (Kr 0.299, Kb 0.114) vs
/// BT.709 (Kr 0.2126, Kb 0.0722) differ in every chroma gain.
pub const Matrix = struct {
    y_off: i32,
    y_gain: i32,
    rv: i32,
    gu: i32,
    gv: i32,
    bu: i32,

    /// The canonical SD matrix: 1.164·(Y−16), 1.596·V, 0.391·U, 0.813·V, 2.018·U.
    pub const bt601_limited: Matrix = .{ .y_off = 16, .y_gain = 298, .rv = 409, .gu = 100, .gv = 208, .bu = 516 };
    /// BT.601 over 0–255: 1.402·V, 0.344·U, 0.714·V, 1.772·U.
    pub const bt601_full: Matrix = .{ .y_off = 0, .y_gain = 256, .rv = 359, .gu = 88, .gv = 183, .bu = 454 };
    /// The HD matrix: 1.164·(Y−16), 1.793·V, 0.213·U, 0.533·V, 2.112·U.
    pub const bt709_limited: Matrix = .{ .y_off = 16, .y_gain = 298, .rv = 459, .gu = 55, .gv = 136, .bu = 541 };
    /// BT.709 over 0–255: 1.575·V, 0.187·U, 0.468·V, 1.856·U.
    pub const bt709_full: Matrix = .{ .y_off = 0, .y_gain = 256, .rv = 403, .gu = 48, .gv = 120, .bu = 475 };
};

/// One YUV sample → a clamped RGBA8 pixel with `m`'s coefficients. Inputs are
/// the raw plane samples.
inline fn yuvToRgba(m: Matrix, y: u8, u: u8, v: u8, out: *[4]u8) void {
    const c: i32 = @as(i32, y) - m.y_off;
    const d: i32 = @as(i32, u) - 128;
    const e: i32 = @as(i32, v) - 128;
    out[0] = clamp8((m.y_gain * c + m.rv * e + 128) >> 8);
    out[1] = clamp8((m.y_gain * c - m.gu * d - m.gv * e + 128) >> 8);
    out[2] = clamp8((m.y_gain * c + m.bu * d + 128) >> 8);
    out[3] = 255;
}

inline fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// NV12 (`COLOR_FormatYUV420SemiPlanar`): full-res Y plane, then a half-res
/// interleaved UV plane (U,V,U,V…). `out` is width*height*4 RGBA8 bytes.
pub fn nv12ToRgba(
    y_plane: []const u8,
    uv_plane: []const u8,
    width: u32,
    height: u32,
    y_stride: u32,
    uv_stride: u32,
    out: []u8,
) void {
    std.debug.assert(out.len == @as(usize, width) * height * 4);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const y = y_plane[row * y_stride + col];
            // UV is sub-sampled 2×2: one (U,V) pair per 2×2 luma block.
            const uv_off = (row / 2) * uv_stride + (col / 2) * 2;
            const u = uv_plane[uv_off];
            const v = uv_plane[uv_off + 1];
            const o = (row * width + col) * 4;
            yuvToRgba(.bt601_limited, y, u, v, out[o..][0..4]);
        }
    }
}

/// I420 (`COLOR_FormatYUV420Planar`): full-res Y, then half-res U, then
/// half-res V planes. `out` is width*height*4 RGBA8 bytes.
pub fn i420ToRgba(
    y_plane: []const u8,
    u_plane: []const u8,
    v_plane: []const u8,
    width: u32,
    height: u32,
    y_stride: u32,
    uv_stride: u32,
    out: []u8,
) void {
    std.debug.assert(out.len == @as(usize, width) * height * 4);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const y = y_plane[row * y_stride + col];
            const chroma_off = (row / 2) * uv_stride + (col / 2);
            const u = u_plane[chroma_off];
            const v = v_plane[chroma_off];
            const o = (row * width + col) * 4;
            yuvToRgba(.bt601_limited, y, u, v, out[o..][0..4]);
        }
    }
}

/// Generic YUV 4:2:0 → RGBA8, driven entirely by per-plane **row stride** and
/// **pixel stride** — the `AImage` / `AIMAGE_FORMAT_YUV_420_888` model. This is
/// the format-agnostic path: the Android decoder renders into an `AImageReader`,
/// and `AImage` exposes whatever the device produced (planar I420, semi-planar
/// NV12, or a vendor/tiled `COLOR_FormatYUV420Flexible`) as Y/U/V planes with
/// strides. A `pixel_stride` of 1 ⇒ planar; 2 ⇒ interleaved/semi-planar — both
/// fall out of the same loop, so one converter covers every real device.
/// `u`/`v` may point into the same interleaved buffer (NV12) or separate planes.
/// BT.601 limited range; `yuv420ToRgbaMatrix` takes the stream's matrix.
pub fn yuv420ToRgba(
    y: []const u8,
    y_row_stride: u32,
    y_pixel_stride: u32,
    u: []const u8,
    v: []const u8,
    uv_row_stride: u32,
    uv_pixel_stride: u32,
    width: u32,
    height: u32,
    out: []u8,
) void {
    yuv420ToRgbaMatrix(.bt601_limited, y, y_row_stride, y_pixel_stride, u, v, uv_row_stride, uv_pixel_stride, width, height, out);
}

/// `yuv420ToRgba` with an explicit `Matrix` — the one the decoder selects from
/// the stream's colour standard / range (`ColorSpace.matrix` in `decoder.zig`).
pub fn yuv420ToRgbaMatrix(
    m: Matrix,
    y: []const u8,
    y_row_stride: u32,
    y_pixel_stride: u32,
    u: []const u8,
    v: []const u8,
    uv_row_stride: u32,
    uv_pixel_stride: u32,
    width: u32,
    height: u32,
    out: []u8,
) void {
    std.debug.assert(out.len == @as(usize, width) * height * 4);
    if (width == 0 or height == 0) return;
    // Bound the plane reads so a release-unsafe build can't index OOB. The last
    // sampled offsets are at the bottom-right pixel (luma) and its 2×2 chroma
    // block (chroma planes are half-resolution, so use the last even row/col).
    const last_y = (height - 1) * y_row_stride + (width - 1) * y_pixel_stride;
    const last_c = ((height - 1) / 2) * uv_row_stride + ((width - 1) / 2) * uv_pixel_stride;
    std.debug.assert(y.len > last_y);
    std.debug.assert(u.len > last_c);
    std.debug.assert(v.len > last_c);

    const args = ConvertArgs{
        .m = m,
        .y = y,
        .y_row_stride = y_row_stride,
        .y_pixel_stride = y_pixel_stride,
        .u = u,
        .v = v,
        .uv_row_stride = uv_row_stride,
        .uv_pixel_stride = uv_pixel_stride,
        .width = width,
        .out = out,
    };

    // Decide whether threading is worth it. yuv.zig is pure-Zig and may be
    // compiled for non-threaded targets (wasm/single-threaded), so gate on
    // `builtin.single_threaded`. Below MIN_THREAD_HEIGHT the spawn/join cost
    // dominates, so just run inline.
    const MIN_THREAD_HEIGHT = 64;
    const thread_count: u32 = blk: {
        if (builtin.single_threaded or height < MIN_THREAD_HEIGHT) break :blk 1;
        const cpus = std.Thread.getCpuCount() catch 1;
        break :blk @intCast(@min(cpus, 8));
    };

    if (thread_count <= 1) {
        convertRowRange(args, 0, height);
        return;
    }

    // Split [0, height) into `thread_count` contiguous chunks. Each chunk owns a
    // disjoint `out` region (rows never overlap), so workers write lock-free.
    // Spawn `thread_count-1` workers and run the last chunk on this thread.
    const base = height / thread_count;
    const extra = height % thread_count; // first `extra` chunks get one more row

    var threads: [8]?std.Thread = .{null} ** 8;
    var spawned: u32 = 0;
    var start: u32 = 0;
    var t: u32 = 0;
    while (t < thread_count) : (t += 1) {
        const rows = base + (if (t < extra) @as(u32, 1) else 0);
        const end = start + rows;
        if (rows == 0) {
            start = end;
            continue;
        }
        if (t == thread_count - 1) {
            // Run the final chunk inline on the calling thread.
            convertRowRange(args, start, end);
        } else {
            threads[spawned] = std.Thread.spawn(.{}, convertRowRange, .{ args, start, end }) catch {
                // Spawn failed: fall back to doing this chunk inline.
                convertRowRange(args, start, end);
                start = end;
                continue;
            };
            spawned += 1;
        }
        start = end;
    }
    var j: u32 = 0;
    while (j < spawned) : (j += 1) {
        if (threads[j]) |th| th.join();
    }
}

/// Bundle of immutable conversion parameters shared by every worker. Carrying
/// these as one struct keeps the `std.Thread.spawn` arg-tuple small.
const ConvertArgs = struct {
    m: Matrix,
    y: []const u8,
    y_row_stride: u32,
    y_pixel_stride: u32,
    u: []const u8,
    v: []const u8,
    uv_row_stride: u32,
    uv_pixel_stride: u32,
    width: u32,
    out: []u8,
};

/// Number of i32 lanes processed per SIMD step.
const VEC = 8;
const I32x = @Vector(VEC, i32);

/// Convert the half-open row range `[row_start, row_end)` into the matching
/// disjoint slice of `out`. This is the per-worker (and single-threaded)
/// entry point. The inner column loop is SIMD-vectorized with a scalar
/// remainder; both share `yuvToRgba` so the math is bit-identical everywhere.
fn convertRowRange(a: ConvertArgs, row_start: u32, row_end: u32) void {
    const width = a.width;
    const vec_cols: u32 = if (a.y_pixel_stride == 1) (width / VEC) * VEC else 0;

    var row: u32 = row_start;
    while (row < row_end) : (row += 1) {
        const y_base = row * a.y_row_stride;
        const c_base = (row / 2) * a.uv_row_stride;
        const o_base = (row * width) * 4;

        var col: u32 = 0;
        // ── SIMD body: only when luma is tightly packed (the AImageReader
        // common case). Chroma is gathered scalar — it's 2×2 sub-sampled so it
        // costs half as many loads, cheap next to the vector arithmetic.
        while (col < vec_cols) : (col += VEC) {
            // Load Y lanes (contiguous, pixel_stride == 1).
            var yv: I32x = undefined;
            inline for (0..VEC) |k| {
                yv[k] = a.y[y_base + col + k];
            }
            // Build U/V lanes: each chroma sample feeds 2 adjacent columns, so
            // gather one sample per column index (col+k)/2.
            var uv: I32x = undefined;
            var vv: I32x = undefined;
            inline for (0..VEC) |k| {
                const ci = c_base + ((col + k) / 2) * a.uv_pixel_stride;
                uv[k] = a.u[ci];
                vv[k] = a.v[ci];
            }

            const c = yv - @as(I32x, @splat(a.m.y_off));
            const d = uv - @as(I32x, @splat(128));
            const e = vv - @as(I32x, @splat(128));

            const cy = @as(I32x, @splat(a.m.y_gain)) * c;
            const rnd = @as(I32x, @splat(128));
            const r = (cy + @as(I32x, @splat(a.m.rv)) * e + rnd) >> @splat(8);
            const g = (cy - @as(I32x, @splat(a.m.gu)) * d - @as(I32x, @splat(a.m.gv)) * e + rnd) >> @splat(8);
            const b = (cy + @as(I32x, @splat(a.m.bu)) * d + rnd) >> @splat(8);

            const lo: I32x = @splat(0);
            const hi: I32x = @splat(255);
            const rc = @min(@max(r, lo), hi);
            const gc = @min(@max(g, lo), hi);
            const bc = @min(@max(b, lo), hi);

            // Store: scalar lane extraction (A=255). Avoids fragile interleave
            // shuffles; the arithmetic above was the hot part.
            inline for (0..VEC) |k| {
                const o = o_base + (col + k) * 4;
                a.out[o + 0] = @intCast(rc[k]);
                a.out[o + 1] = @intCast(gc[k]);
                a.out[o + 2] = @intCast(bc[k]);
                a.out[o + 3] = 255;
            }
        }

        // ── Scalar remainder (and the entire row when y_pixel_stride != 1).
        while (col < width) : (col += 1) {
            const yi = y_base + col * a.y_pixel_stride;
            const ci = c_base + (col / 2) * a.uv_pixel_stride;
            const o = o_base + col * 4;
            yuvToRgba(a.m, a.y[yi], a.u[ci], a.v[ci], a.out[o..][0..4]);
        }
    }
}

/// Reference scalar converter — the original naive double-loop, kept verbatim
/// as the bit-exact equivalence guard for the SIMD + threaded path. Test-only.
fn yuv420ToRgbaScalar(
    m: Matrix,
    y: []const u8,
    y_row_stride: u32,
    y_pixel_stride: u32,
    u: []const u8,
    v: []const u8,
    uv_row_stride: u32,
    uv_pixel_stride: u32,
    width: u32,
    height: u32,
    out: []u8,
) void {
    std.debug.assert(out.len == @as(usize, width) * height * 4);
    if (width == 0 or height == 0) return;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const yi = row * y_row_stride + col * y_pixel_stride;
            const ci = (row / 2) * uv_row_stride + (col / 2) * uv_pixel_stride;
            const o = (row * width + col) * 4;
            yuvToRgba(m, y[yi], u[ci], v[ci], out[o..][0..4]);
        }
    }
}

// ── Tests (host-runnable — no NDK) ───────────────────────────────────────

test "nv12: neutral chroma maps Y=16→black, Y=235→white" {
    const w = 2;
    const h = 2;
    var out: [w * h * 4]u8 = undefined;

    // Y=16 everywhere, UV neutral (128,128) → black.
    const black_y = [_]u8{ 16, 16, 16, 16 };
    const neutral_uv = [_]u8{ 128, 128 }; // one pair covers the 2×2 block
    nv12ToRgba(&black_y, &neutral_uv, w, h, w, w, &out);
    for (0..w * h) |i| {
        try std.testing.expectEqual(@as(u8, 0), out[i * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 0), out[i * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 0), out[i * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 255), out[i * 4 + 3]);
    }

    // Y=235 everywhere, neutral UV → white.
    const white_y = [_]u8{ 235, 235, 235, 235 };
    nv12ToRgba(&white_y, &neutral_uv, w, h, w, w, &out);
    for (0..w * h) |i| {
        try std.testing.expectEqual(@as(u8, 255), out[i * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 255), out[i * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 255), out[i * 4 + 2]);
    }
}

test "i420 matches nv12 for the same logical frame" {
    const w = 2;
    const h = 2;
    const y = [_]u8{ 120, 120, 120, 120 };
    // NV12 interleaved vs I420 planar — same U=100, V=200.
    const nv12_uv = [_]u8{ 100, 200 };
    const i420_u = [_]u8{100};
    const i420_v = [_]u8{200};

    var a: [w * h * 4]u8 = undefined;
    var b: [w * h * 4]u8 = undefined;
    nv12ToRgba(&y, &nv12_uv, w, h, w, w, &a);
    i420ToRgba(&y, &i420_u, &i420_v, w, h, w, w, &b);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "yuv420ToRgba (YUV_420_888): semi-planar pixel_stride=2 matches nv12ToRgba" {
    const w = 2;
    const h = 2;
    const y = [_]u8{ 60, 120, 180, 240 };
    const uv = [_]u8{ 90, 200 }; // interleaved U,V — one pair for the 2×2 block
    var ref: [w * h * 4]u8 = undefined;
    var got: [w * h * 4]u8 = undefined;
    nv12ToRgba(&y, &uv, w, h, w, w, &ref);
    // AImage NV12: U plane points at uv[0], V plane at uv[1], pixel_stride=2.
    yuv420ToRgba(&y, w, 1, uv[0..], uv[1..], w, 2, w, h, &got);
    try std.testing.expectEqualSlices(u8, &ref, &got);
}

test "yuv420ToRgba (YUV_420_888): planar pixel_stride=1 matches i420ToRgba" {
    const w = 2;
    const h = 2;
    const y = [_]u8{ 60, 120, 180, 240 };
    const u = [_]u8{90};
    const v = [_]u8{200};
    var ref: [w * h * 4]u8 = undefined;
    var got: [w * h * 4]u8 = undefined;
    i420ToRgba(&y, &u, &v, w, h, w, w, &ref);
    yuv420ToRgba(&y, w, 1, &u, &v, w, 1, w, h, &got);
    try std.testing.expectEqualSlices(u8, &ref, &got);
}

test "stride padding is honoured (y_stride > width)" {
    const w = 2;
    const h = 2;
    const y_stride = 4; // 2px of row padding
    // Row 0: [10,20, pad,pad], Row 1: [30,40, pad,pad]
    const y = [_]u8{ 10, 20, 0, 0, 30, 40, 0, 0 };
    const uv = [_]u8{ 128, 128 };
    var out: [w * h * 4]u8 = undefined;
    nv12ToRgba(&y, &uv, w, h, y_stride, w, &out);
    // Just assert the padded bytes weren't sampled: pixel (1,1) uses y=40 not 0.
    var expect: [4]u8 = undefined;
    yuvToRgba(.bt601_limited, 40, 128, 128, &expect);
    try std.testing.expectEqualSlices(u8, &expect, out[(3) * 4 ..][0..4]);
}

test "Matrix: BT.709 limited decodes 709-encoded red that BT.601 would desaturate" {
    // Pure red (255,0,0) encoded per BT.709 limited range is Y=63 U=102 V=240;
    // per BT.601 it is Y=81 U=90 V=240. Each decodes to red only through its
    // own matrix — the mismatch the colour metadata exists to prevent.
    var px: [4]u8 = undefined;
    yuvToRgba(.bt709_limited, 63, 102, 240, &px);
    try std.testing.expectEqualSlices(u8, &.{ 255, 1, 0, 255 }, &px);
    yuvToRgba(.bt601_limited, 63, 102, 240, &px);
    try std.testing.expectEqualSlices(u8, &.{ 234, 0, 2, 255 }, &px); // the wrong matrix: dull, shifted
    yuvToRgba(.bt601_limited, 81, 90, 240, &px);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, &px);
    // Neutral chroma is grey under every matrix; limited white is Y=235.
    yuvToRgba(.bt709_limited, 235, 128, 128, &px);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &px);
}

test "Matrix: full range maps Y=0→black, Y=255→white, Y=128→mid grey without clipping" {
    var px: [4]u8 = undefined;
    inline for (.{ Matrix.bt601_full, Matrix.bt709_full }) |m| {
        yuvToRgba(m, 0, 128, 128, &px);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &px);
        yuvToRgba(m, 255, 128, 128, &px);
        try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &px);
        yuvToRgba(m, 128, 128, 128, &px);
        try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, &px);
    }
    // The limited matrix would crush a full-range Y=8 to black and clip Y=250.
    yuvToRgba(.bt601_limited, 8, 128, 128, &px);
    try std.testing.expectEqual(@as(u8, 0), px[0]);
    yuvToRgba(.bt601_full, 8, 128, 128, &px);
    try std.testing.expectEqual(@as(u8, 8), px[0]);
    // Full-range pure red per BT.709: Y=54 U=99 V=255 (chroma not compressed).
    yuvToRgba(.bt709_full, 54, 99, 255, &px);
    try std.testing.expect(px[0] == 254 or px[0] == 255);
    try std.testing.expect(px[1] <= 1 and px[2] <= 1);
}

test "yuv420ToRgba SIMD+threaded path is bit-exact vs scalar reference" {
    const alloc = std.testing.allocator;

    // (width, height) sizes: 1×1, 2×2, an odd width not a multiple of VEC, a
    // large multiple, and the deliberately-awkward 258×130 case.
    const Size = struct { w: u32, h: u32 };
    const sizes = [_]Size{
        .{ .w = 1, .h = 1 },
        .{ .w = 2, .h = 2 },
        .{ .w = 17, .h = 9 },
        .{ .w = 256, .h = 256 },
        .{ .w = 258, .h = 130 },
    };

    for (sizes) |s| {
        const w = s.w;
        const h = s.h;
        const cw = (w + 1) / 2; // chroma width (half-res, round up)
        const ch = (h + 1) / 2; // chroma height

        // Both interleaved (uv_pixel_stride=2) and planar (=1) layouts.
        const uv_pix_strides = [_]u32{ 1, 2 };
        for (uv_pix_strides) |uv_pix| {
            // y_row_stride > width to exercise padding.
            const y_row_stride = w + 7;
            const uv_row_stride = cw * uv_pix + 5;

            const y = try alloc.alloc(u8, @as(usize, y_row_stride) * h);
            defer alloc.free(y);
            // Combined U/V buffer. For planar (uv_pix=1) U and V are distinct
            // slices; for interleaved (=2) they alias one buffer at +0 and +1.
            const uv_buf_len: usize = @as(usize, uv_row_stride) * ch + 2;
            const ubuf = try alloc.alloc(u8, uv_buf_len);
            defer alloc.free(ubuf);
            const vbuf = if (uv_pix == 1) try alloc.alloc(u8, uv_buf_len) else ubuf;
            defer if (uv_pix == 1) alloc.free(vbuf);

            // Varied pattern.
            for (y, 0..) |*p, i| p.* = @intCast((i * 7) & 0xff);
            for (ubuf, 0..) |*p, i| p.* = @intCast((i * 11 + 3) & 0xff);
            if (uv_pix == 1) for (vbuf, 0..) |*p, i| {
                p.* = @intCast((i * 13 + 7) & 0xff);
            };

            const u_slice = ubuf[0..];
            const v_slice = if (uv_pix == 1) vbuf[0..] else ubuf[1..];

            const ref = try alloc.alloc(u8, @as(usize, w) * h * 4);
            defer alloc.free(ref);
            const got = try alloc.alloc(u8, @as(usize, w) * h * 4);
            defer alloc.free(got);

            yuv420ToRgbaScalar(.bt601_limited, y, y_row_stride, 1, u_slice, v_slice, uv_row_stride, uv_pix, w, h, ref);
            yuv420ToRgba(y, y_row_stride, 1, u_slice, v_slice, uv_row_stride, uv_pix, w, h, got);
            try std.testing.expectEqualSlices(u8, ref, got);

            // The matrix reaches the SIMD lanes too: BT.709 full range must
            // match its scalar reference AND differ from the BT.601 result.
            const bt601 = try alloc.dupe(u8, got); // the BT.601 result from above
            defer alloc.free(bt601);
            yuv420ToRgbaScalar(.bt709_full, y, y_row_stride, 1, u_slice, v_slice, uv_row_stride, uv_pix, w, h, ref);
            yuv420ToRgbaMatrix(.bt709_full, y, y_row_stride, 1, u_slice, v_slice, uv_row_stride, uv_pix, w, h, got);
            try std.testing.expectEqualSlices(u8, ref, got);
            if (w * h >= 4) try std.testing.expect(!std.mem.eql(u8, bt601, got));
        }
    }
}
