//! Automatic ink detection for bitmap subtitles.
//!
//! This module implements geometric analysis to identify which palette index
//! represents the subtitle text "ink" on a per-subtitle basis. Unlike hardcoded
//! palette indices, this approach works when palette meanings change between
//! subtitle events (common in PGS/HDMV format).
//!
//! Detection strategy:
//! 1. Extract foreground pixels using alpha threshold
//! 2. For each palette index, compute boundary vs interior statistics
//! 3. Exclude box backgrounds using geometric heuristics
//! 4. Score each palette index and select the best "ink" candidate

const std = @import("std");
const c = @import("c.zig").c;
const bm = @import("read_subtitle.zig");

/// Alpha threshold for foreground detection (0-255).
/// Pixels with alpha >= this value are considered foreground.
const ALPHA_THRESHOLD: u8 = 32;

/// Minimum area fraction (relative to total foreground) for a palette index
/// to be considered as a potential ink candidate.
const MIN_AREA_FRACTION: f32 = 0.05;

/// Statistics for a single palette index within a subtitle bitmap.
pub const PaletteStats = struct {
    palette_index: u8,
    area: usize, // Total foreground pixels using this index
    boundary_pixels: usize, // Pixels touching background
    interior_fraction: f32, // (area - boundary) / area
    boundary_fraction: f32, // boundary / area
    score: f32, // Combined metric for "ink-ness"
    is_box_background: bool, // Excluded as large rectangular background
};

/// Result of automatic ink detection.
pub const DetectionResult = struct {
    /// The palette index most likely to represent subtitle text ink.
    best_index: u8,

    /// Confidence score (0.0-1.0) for the selection.
    confidence: f32,

    /// Statistics for all palette indices found (for debugging).
    all_stats: []PaletteStats,

    pub fn deinit(self: DetectionResult, alloc: std.mem.Allocator) void {
        alloc.free(self.all_stats);
    }
};

/// Detects the palette index most likely to represent text ink in a subtitle bitmap.
///
/// ## Parameters
/// - `allocator`: Memory allocator for temporary buffers and result
/// - `bitmap`: Indexed color bitmap (one byte per pixel)
/// - `width`: Bitmap width in pixels
/// - `height`: Bitmap height in pixels
/// - `stride`: Row stride in bytes (may be > width for alignment)
/// - `palette`: ARGB palette (256 entries, packed as (A<<24)|(R<<16)|(G<<8)|B)
/// - `nb_colors`: Number of valid palette entries
///
/// ## Returns
/// DetectionResult containing the best ink index and statistics.
/// Caller must call deinit() on the result.
pub fn detectInkPaletteIndex(
    allocator: std.mem.Allocator,
    bitmap: [*]const u8,
    width: usize,
    height: usize,
    stride: usize,
    palette: [*]const u32,
    nb_colors: usize,
) !DetectionResult {
    // Step 1: Build foreground mask using alpha channel
    const fg_mask = try buildForegroundMask(allocator, bitmap, width, height, stride, palette);
    defer allocator.free(fg_mask);

    // Step 2: Compute statistics for each palette index
    var stats_list = std.ArrayList(PaletteStats).empty;
    defer stats_list.deinit(allocator);

    try computePaletteStats(allocator, bitmap, width, height, stride, fg_mask, nb_colors, &stats_list);

    // Step 3: Detect and exclude box backgrounds
    try detectBoxBackgrounds(bitmap, width, height, stride, fg_mask, stats_list.items);

    // Step 4: Score and select best ink candidate
    return scoreAndSelectInk(allocator, stats_list.items);
}

/// Builds a boolean mask indicating which pixels are foreground based on alpha.
fn buildForegroundMask(
    allocator: std.mem.Allocator,
    bitmap: [*]const u8,
    width: usize,
    height: usize,
    stride: usize,
    palette: [*]const u32,
) ![]bool {
    const mask = try allocator.alloc(bool, height * width);

    for (0..height) |y| {
        for (0..width) |x| {
            const idx = bitmap[y * stride + x];
            const color = bm.unpackARGB(palette[idx]);
            mask[y * width + x] = (color.a >= ALPHA_THRESHOLD);
        }
    }

    return mask;
}

/// Computes area, boundary, and interior statistics for each palette index.
fn computePaletteStats(
    allocator: std.mem.Allocator,
    bitmap: [*]const u8,
    width: usize,
    height: usize,
    stride: usize,
    fg_mask: []const bool,
    nb_colors: usize,
    stats_list: *std.ArrayList(PaletteStats),
) !void {
    // Count area and boundary pixels for each palette index
    var area_counts = try allocator.alloc(usize, nb_colors);
    defer allocator.free(area_counts);
    @memset(area_counts, 0);

    var boundary_counts = try allocator.alloc(usize, nb_colors);
    defer allocator.free(boundary_counts);
    @memset(boundary_counts, 0);

    // First pass: count area
    for (0..height) |y| {
        for (0..width) |x| {
            if (!fg_mask[y * width + x]) continue;

            const idx = bitmap[y * stride + x];
            if (idx < nb_colors) {
                area_counts[idx] += 1;
            }
        }
    }

    // Second pass: count boundary pixels (4-connected neighbors)
    for (0..height) |y| {
        for (0..width) |x| {
            if (!fg_mask[y * width + x]) continue;

            const idx = bitmap[y * stride + x];
            if (idx >= nb_colors) continue;

            // Check if any of the 4 neighbors is background
            const is_boundary = blk: {
                // Left
                if (x > 0 and !fg_mask[y * width + (x - 1)]) break :blk true;
                // Right
                if (x + 1 < width and !fg_mask[y * width + (x + 1)]) break :blk true;
                // Up
                if (y > 0 and !fg_mask[(y - 1) * width + x]) break :blk true;
                // Down
                if (y + 1 < height and !fg_mask[(y + 1) * width + x]) break :blk true;
                break :blk false;
            };

            if (is_boundary) {
                boundary_counts[idx] += 1;
            }
        }
    }

    // Calculate total foreground area for filtering
    var total_fg_area: usize = 0;
    for (area_counts) |count| {
        total_fg_area += count;
    }

    // Build stats for indices with sufficient area
    for (0..nb_colors) |idx| {
        const area = area_counts[idx];
        if (area == 0) continue;

        const area_fraction = @as(f32, @floatFromInt(area)) / @as(f32, @floatFromInt(total_fg_area));
        if (area_fraction < MIN_AREA_FRACTION) continue;

        const boundary = boundary_counts[idx];
        const interior = area - boundary;
        const interior_frac = @as(f32, @floatFromInt(interior)) / @as(f32, @floatFromInt(area));
        const boundary_frac = @as(f32, @floatFromInt(boundary)) / @as(f32, @floatFromInt(area));

        try stats_list.append(allocator, .{
            .palette_index = @intCast(idx),
            .area = area,
            .boundary_pixels = boundary,
            .interior_fraction = interior_frac,
            .boundary_fraction = boundary_frac,
            .score = 0.0, // Computed later
            .is_box_background = false,
        });
    }
}

/// Detects and marks palette indices that represent box backgrounds.
/// Uses heuristics: large area + high rectangularity + edge-touching.
fn detectBoxBackgrounds(
    bitmap: [*]const u8,
    width: usize,
    height: usize,
    stride: usize,
    fg_mask: []const bool,
    stats: []PaletteStats,
) !void {
    // Simplified box detection: check if a color dominates and touches multiple edges
    for (stats) |*stat| {
        const idx = stat.palette_index;

        // Check if this color touches at least 3 edges
        var edges_touched: u8 = 0;

        // Top edge
        for (0..width) |x| {
            if (fg_mask[x] and bitmap[x] == idx) {
                edges_touched |= 0b0001;
                break;
            }
        }

        // Bottom edge
        const last_row = (height - 1) * width;
        for (0..width) |x| {
            if (fg_mask[last_row + x] and bitmap[(height - 1) * stride + x] == idx) {
                edges_touched |= 0b0010;
                break;
            }
        }

        // Left edge
        for (0..height) |y| {
            if (fg_mask[y * width] and bitmap[y * stride] == idx) {
                edges_touched |= 0b0100;
                break;
            }
        }

        // Right edge
        for (0..height) |y| {
            if (fg_mask[y * width + (width - 1)] and bitmap[y * stride + (width - 1)] == idx) {
                edges_touched |= 0b1000;
                break;
            }
        }

        const edge_count = @popCount(edges_touched);

        // If touches 3+ edges and has high area, likely a box
        const total_pixels = width * height;
        const area_fraction = @as(f32, @floatFromInt(stat.area)) / @as(f32, @floatFromInt(total_pixels));

        if (edge_count >= 3 and area_fraction > 0.3) {
            stat.is_box_background = true;
        }
    }
}

/// Scores palette indices and selects the best ink candidate.
fn scoreAndSelectInk(
    allocator: std.mem.Allocator,
    stats: []PaletteStats,
) !DetectionResult {
    if (stats.len == 0) {
        // No valid palette indices found - return default
        return DetectionResult{
            .best_index = 0,
            .confidence = 0.0,
            .all_stats = try allocator.alloc(PaletteStats, 0),
        };
    }

    // Compute scores for each palette index
    var best_score: f32 = -1.0;
    var best_idx: u8 = 0;

    for (stats) |*stat| {
        if (stat.is_box_background) {
            stat.score = 0.0;
            continue;
        }

        // Score = interior_fraction * (1 - boundary_fraction) * size_weight
        // Ink should have substantial interior and less boundary contact
        const size_weight = @min(1.0, @as(f32, @floatFromInt(stat.area)) / 1000.0);
        stat.score = stat.interior_fraction * (1.0 - stat.boundary_fraction) * size_weight;

        if (stat.score > best_score) {
            best_score = stat.score;
            best_idx = stat.palette_index;
        }
    }

    // Copy stats for return
    const stats_copy = try allocator.alloc(PaletteStats, stats.len);
    @memcpy(stats_copy, stats);

    return DetectionResult{
        .best_index = best_idx,
        .confidence = best_score,
        .all_stats = stats_copy,
    };
}

test "unpack ARGB" {
    const color = bm.unpackARGB(0xFF102030);
    try std.testing.expectEqual(@as(u8, 0xFF), color.a);
    try std.testing.expectEqual(@as(u8, 0x10), color.r);
    try std.testing.expectEqual(@as(u8, 0x20), color.g);
    try std.testing.expectEqual(@as(u8, 0x30), color.b);
}
