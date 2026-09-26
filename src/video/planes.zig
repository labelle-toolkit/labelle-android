//! Plane preparation for the GPU-side YUV→RGBA video path
//! (perf/gpu-yuv-video). Pure Zig, no NDK — host-unit-tested.
//!
//! The GPU path uploads raw Y/U/V planes to three single-channel R8 textures
//! and converts them in `fs_yuv` during the draw, instead of running the CPU
//! YUV→RGBA convert (`yuv.zig`) and uploading a full 8.3 MB RGBA frame. bgfx's
//! `updateTexture2D` uploads tightly packed rows, so before upload each plane
//! must be copied into a tight buffer:
//!
//!   - **Row stride** (`row_stride > width` alignment padding): drop the pad.
//!   - **Pixel stride**: `1` ⇒ planar/I420 (U,V tight) — a straight per-row
//!     copy. `2` ⇒ semi-planar/NV12 (U,V interleaved) — gather every other
//!     byte to de-interleave one chroma channel into its own tight plane.
//!
//! `tightenPlane` handles all of the above with one gather loop: for the luma
//! plane it's just a row de-pad; for chroma it de-pads AND (when pixel_stride==2)
//! de-interleaves. This is a chroma-only copy (¼ the data) — far cheaper than the
//! full RGBA convert it replaces.

const std = @import("std");

/// Chroma (U/V) plane width for a 4:2:0 frame of luma width `w` — half-res,
/// rounded up so odd dimensions keep a full sample column.
pub inline fn chromaWidth(w: u32) u32 {
    return (w + 1) / 2;
}

/// Chroma (U/V) plane height for a 4:2:0 frame of luma height `h`.
pub inline fn chromaHeight(h: u32) u32 {
    return (h + 1) / 2;
}

/// Copy a (possibly padded and/or interleaved) source plane into a tightly
/// packed `width`×`height` destination buffer.
///
///   dst[row*width + col] = src[row*row_stride + col*pixel_stride]
///
/// Covers every AImage / I420 / NV12 layout:
///   - luma:           row_stride ≥ width, pixel_stride == 1  → row de-pad
///   - chroma planar:  pixel_stride == 1                      → row de-pad
///   - chroma NV12:    pixel_stride == 2                      → de-interleave
///
/// `dst.len` must be exactly `width*height`; `src` must be large enough to reach
/// the bottom-right sample. The fast path (`pixel_stride == 1`) is a per-row
/// `@memcpy`; the interleaved path is a scalar gather.
pub fn tightenPlane(
    src: []const u8,
    row_stride: u32,
    pixel_stride: u32,
    width: u32,
    height: u32,
    dst: []u8,
) void {
    std.debug.assert(dst.len == @as(usize, width) * height);
    if (width == 0 or height == 0) return;
    // Bound the last source read so a release-unsafe build can't index OOB.
    const last = (height - 1) * @as(usize, row_stride) + (width - 1) * @as(usize, pixel_stride);
    std.debug.assert(src.len > last);

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const src_row = @as(usize, row) * row_stride;
        const dst_row = @as(usize, row) * width;
        if (pixel_stride == 1) {
            // Tight (or merely row-padded) row → straight copy.
            @memcpy(dst[dst_row..][0..width], src[src_row..][0..width]);
        } else if (pixel_stride == 2) {
            // Interleaved NV12 chroma → de-interleave with a wide shuffle
            // (compiles to NEON uzp/ld2 on aarch64). The scalar byte-by-byte
            // gather measured 21–30 ms/frame at 1080p on-device (each byte a
            // separate load from the gralloc buffer) and was the dominant video
            // frame cost; 32-byte vector loads bring it in line with the row
            // memcpy. The bounds check keeps the last chunk from reading one
            // byte past the plane (the final pair's other channel may be the
            // buffer's last byte); any tail falls through to the scalar loop.
            const V = 16; // dst bytes per step (32 interleaved src bytes)
            const even_mask = comptime blk: {
                var m: [V]i32 = undefined;
                for (&m, 0..) |*e, i| e.* = @intCast(i * 2);
                break :blk m;
            };
            var col: u32 = 0;
            while (col + V <= width and src_row + 2 * (col + V) <= src.len) : (col += V) {
                const chunk: @Vector(2 * V, u8) = src[src_row + 2 * col ..][0 .. 2 * V].*;
                const gathered: @Vector(V, u8) = @shuffle(u8, chunk, undefined, even_mask);
                dst[dst_row + col ..][0..V].* = gathered;
            }
            while (col < width) : (col += 1) {
                dst[dst_row + col] = src[src_row + col * 2];
            }
        } else {
            // Arbitrary stride → gather every sample.
            var col: u32 = 0;
            while (col < width) : (col += 1) {
                dst[dst_row + col] = src[src_row + col * pixel_stride];
            }
        }
    }
}

// ── Tests (host-runnable — no NDK) ───────────────────────────────────────

test "tightenPlane: tight planar plane copies verbatim" {
    const w = 3;
    const h = 2;
    const src = [_]u8{ 1, 2, 3, 4, 5, 6 };
    var dst: [w * h]u8 = undefined;
    tightenPlane(&src, w, 1, w, h, &dst);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "tightenPlane: row-padded luma drops the padding" {
    const w = 2;
    const h = 2;
    const row_stride = 4; // 2 bytes of right padding per row
    // Row 0: [10,20, pad,pad], Row 1: [30,40, pad,pad]
    const src = [_]u8{ 10, 20, 99, 99, 30, 40, 88, 88 };
    var dst: [w * h]u8 = undefined;
    tightenPlane(&src, row_stride, 1, w, h, &dst);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 40 }, &dst);
}

test "tightenPlane: semi-planar (NV12) de-interleaves U and V" {
    // Interleaved chroma buffer: U0,V0,U1,V1,U2,V2,U3,V3 for a 2x2 chroma plane.
    const cw = 2;
    const ch = 2;
    const uv = [_]u8{ 100, 200, 101, 201, 102, 202, 103, 203 };
    var u_tight: [cw * ch]u8 = undefined;
    var v_tight: [cw * ch]u8 = undefined;
    // U plane starts at uv[0], V plane at uv[1], pixel_stride 2, row_stride cw*2.
    tightenPlane(uv[0..], cw * 2, 2, cw, ch, &u_tight);
    tightenPlane(uv[1..], cw * 2, 2, cw, ch, &v_tight);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 100, 101, 102, 103 }, &u_tight);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 200, 201, 202, 203 }, &v_tight);
}

test "tightenPlane: semi-planar with row padding de-interleaves and de-pads" {
    const cw = 2;
    const ch = 2;
    const row_stride = 6; // 2 chroma px * pixel_stride 2 = 4 bytes data + 2 pad
    // Row 0: U0,V0,U1,V1,pad,pad ; Row 1: U2,V2,U3,V3,pad,pad
    const uv = [_]u8{ 10, 20, 11, 21, 0, 0, 12, 22, 13, 23, 0, 0 };
    var u_tight: [cw * ch]u8 = undefined;
    var v_tight: [cw * ch]u8 = undefined;
    tightenPlane(uv[0..], row_stride, 2, cw, ch, &u_tight);
    tightenPlane(uv[1..], row_stride, 2, cw, ch, &v_tight);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 11, 12, 13 }, &u_tight);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 20, 21, 22, 23 }, &v_tight);
}

test "tightenPlane: wide NV12 rows exercise the vectorized de-interleave" {
    // width 37 > 16 → two 16-wide vector steps + a 5-byte scalar tail per row.
    const cw = 37;
    const ch = 3;
    const row_stride = cw * 2 + 6; // interleaved pairs + right padding
    var uv: [row_stride * ch]u8 = undefined;
    for (0..ch) |r| {
        for (0..cw) |c| {
            uv[r * row_stride + c * 2] = @intCast((r * cw + c) % 251); // U
            uv[r * row_stride + c * 2 + 1] = @intCast((r * cw + c + 7) % 251); // V
        }
        for (cw * 2..row_stride) |p| uv[r * row_stride + p] = 0xEE; // padding
    }
    var u_tight: [cw * ch]u8 = undefined;
    var v_tight: [cw * ch]u8 = undefined;
    tightenPlane(uv[0..], row_stride, 2, cw, ch, &u_tight);
    tightenPlane(uv[1..], row_stride, 2, cw, ch, &v_tight);
    for (0..ch) |r| {
        for (0..cw) |c| {
            try std.testing.expectEqual(@as(u8, @intCast((r * cw + c) % 251)), u_tight[r * cw + c]);
            try std.testing.expectEqual(@as(u8, @intCast((r * cw + c + 7) % 251)), v_tight[r * cw + c]);
        }
    }
}

test "chroma dims round up for odd luma sizes" {
    try std.testing.expectEqual(@as(u32, 2), chromaWidth(3));
    try std.testing.expectEqual(@as(u32, 2), chromaWidth(4));
    try std.testing.expectEqual(@as(u32, 1), chromaHeight(1));
    try std.testing.expectEqual(@as(u32, 540), chromaHeight(1080));
    try std.testing.expectEqual(@as(u32, 960), chromaWidth(1920));
}
