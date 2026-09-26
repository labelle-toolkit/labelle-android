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
//! verifiable without a device. The conversion uses the BT.601 limited-range
//! integer coefficients (the standard for SD/most MediaCodec output).
//!
//! Strides are explicit: MediaCodec output planes are frequently padded
//! (`stride >= width`), so the caller passes the real plane strides from the
//! output `AMediaFormat` rather than assuming tight packing.

const std = @import("std");
const builtin = @import("builtin");

/// BT.601 limited-range YUV → RGB, integer math (matches the canonical
/// fixed-point coefficients). Inputs are the raw plane samples; output is a
/// clamped RGBA8 pixel.
inline fn yuvToRgba(y: u8, u: u8, v: u8, out: *[4]u8) void {
    const c: i32 = @as(i32, y) - 16;
    const d: i32 = @as(i32, u) - 128;
    const e: i32 = @as(i32, v) - 128;
    out[0] = clamp8((298 * c + 409 * e + 128) >> 8);
    out[1] = clamp8((298 * c - 100 * d - 208 * e + 128) >> 8);
    out[2] = clamp8((298 * c + 516 * d + 128) >> 8);
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
            yuvToRgba(y, u, v, out[o..][0..4]);
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
            yuvToRgba(y, u, v, out[o..][0..4]);
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

            const c = yv - @as(I32x, @splat(16));
            const d = uv - @as(I32x, @splat(128));
            const e = vv - @as(I32x, @splat(128));

            const c298 = @as(I32x, @splat(298)) * c;
            const rnd = @as(I32x, @splat(128));
            const r = (c298 + @as(I32x, @splat(409)) * e + rnd) >> @splat(8);
            const g = (c298 - @as(I32x, @splat(100)) * d - @as(I32x, @splat(208)) * e + rnd) >> @splat(8);
            const b = (c298 + @as(I32x, @splat(516)) * d + rnd) >> @splat(8);

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
            yuvToRgba(a.y[yi], a.u[ci], a.v[ci], a.out[o..][0..4]);
        }
    }
}

/// Reference scalar converter — the original naive double-loop, kept verbatim
/// as the bit-exact equivalence guard for the SIMD + threaded path. Test-only.
fn yuv420ToRgbaScalar(
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
            yuvToRgba(y[yi], u[ci], v[ci], out[o..][0..4]);
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
    yuvToRgba(40, 128, 128, &expect);
    try std.testing.expectEqualSlices(u8, &expect, out[(3) * 4 ..][0..4]);
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

            yuv420ToRgbaScalar(y, y_row_stride, 1, u_slice, v_slice, uv_row_stride, uv_pix, w, h, ref);
            yuv420ToRgba(y, y_row_stride, 1, u_slice, v_slice, uv_row_stride, uv_pix, w, h, got);

            try std.testing.expectEqualSlices(u8, ref, got);
        }
    }
}
