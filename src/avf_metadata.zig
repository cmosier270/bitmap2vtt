//! FFmpeg AVStream metadata handling.
//!
//! This module provides an idiomatic Zig interface for working with FFmpeg's
//! AVDictionary metadata attached to streams. Metadata typically includes
//! language codes, stream titles, handler names, and other descriptive information.
//!
//! IMPORTANT: The string slices in MetadataEntry reference FFmpeg's internal
//! memory and are only valid for the lifetime of the parent AVFormatContext.
//! Do not use these strings after the AVFormatContext is freed.

const std = @import("std");
const c = @import("c.zig").c;

/// A single key-value metadata entry.
///
/// Both key and value are slices that reference FFmpeg's internal C strings.
/// These strings remain valid for the lifetime of the parent AVFormatContext.
pub const MetadataEntry = struct {
    /// Metadata key (e.g., "language", "title", "handler_name")
    key: []const u8,

    /// Metadata value (e.g., "eng", "English Subtitles")
    value: []const u8,
};

/// Collection of metadata entries extracted from an AVStream.
///
/// This struct wraps an ArrayList of MetadataEntry pairs, providing
/// convenient access to stream metadata. The string data references
/// FFmpeg's internal memory and must not outlive the AVFormatContext.
pub const Metadata = struct {
    /// List of key-value metadata entries.
    entries: std.ArrayList(MetadataEntry),

    pub const empty: Metadata = .{ .entries = std.ArrayList(MetadataEntry).empty };

    /// Extracts metadata from an AVDictionary into a Zig-friendly structure.
    ///
    /// Iterates through all entries in the FFmpeg dictionary and converts them
    /// to MetadataEntry structs. The resulting strings are slices that reference
    /// the original C strings in FFmpeg's memory.
    ///
    /// ## Parameters
    /// - `allocator`: Allocator for the ArrayList (not for string data)
    /// - `dict`: Pointer to FFmpeg's AVDictionary, may be null
    ///
    /// ## Returns
    /// A Metadata struct containing all dictionary entries. Returns empty
    /// metadata if dict is null.
    ///
    /// ## Lifetime
    /// The string slices in the returned Metadata are only valid while the
    /// parent AVFormatContext remains alive. The caller must ensure the
    /// AVFormatContext outlives any use of these strings.
    ///
    /// ## Example
    /// ```zig
    /// const meta = try Metadata.fromAVDictionary(allocator, stream.*.metadata);
    /// defer meta.deinit();
    /// if (meta.get("language")) |lang| {
    ///     std.log.info("Stream language: {s}", .{lang});
    /// }
    /// ```
    pub fn fromAVDictionary(allocator: std.mem.Allocator, dict: ?*c.AVDictionary) !Metadata {
        var entries = std.ArrayList(MetadataEntry).empty;

        // Handle null dictionary - return empty metadata
        if (dict == null) {
            return .{ .entries = entries };
        }

        // Iterate through all dictionary entries using av_dict_iterate
        var entry: ?*const c.AVDictionaryEntry = null;
        while (true) {
            entry = c.av_dict_iterate(dict, entry);
            if (entry == null) break;

            const e = entry.?;

            // Convert C strings to Zig slices (zero-copy, references FFmpeg memory)
            const key_slice = std.mem.span(e.key);
            const value_slice = std.mem.span(e.value);

            try entries.append(allocator, .{
                .key = key_slice,
                .value = value_slice,
            });
        }

        return .{ .entries = entries };
    }

    /// Releases the ArrayList memory.
    ///
    /// Note: This only frees the ArrayList structure itself, not the string
    /// data (which belongs to FFmpeg and is managed by AVFormatContext).
    pub fn deinit(self: *Metadata, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
    }

    /// Looks up a metadata value by key.
    ///
    /// Performs a linear search through the entries. Case-sensitive comparison.
    ///
    /// ## Parameters
    /// - `key`: The metadata key to search for
    ///
    /// ## Returns
    /// The value string if found, or null if the key doesn't exist.
    pub fn get(self: Metadata, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Returns the number of metadata entries.
    pub fn count(self: Metadata) usize {
        return self.entries.items.len;
    }

    /// Returns true if there are no metadata entries.
    pub fn isEmpty(self: Metadata) bool {
        return self.entries.items.len == 0;
    }

    /// Formats the metadata as a human-readable string listing all entries.
    ///
    /// Output format: `Metadata{key1="value1", key2="value2"}`
    pub fn format(
        self: Metadata,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll("Metadata{");

        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s}=\"{s}\"", .{ entry.key, entry.value });
        }

        try writer.writeAll("}");
    }
};

test "Metadata.empty and isEmpty" {
    const testing = std.testing;

    const meta = Metadata.empty();
    try testing.expect(meta.isEmpty());
    try testing.expectEqual(@as(usize, 0), meta.count());
}

test "Metadata.fromAVDictionary with null" {
    const testing = std.testing;

    const meta = try Metadata.fromAVDictionary(testing.allocator, null);
    defer {
        var m = meta;
        m.deinit();
    }

    try testing.expect(meta.isEmpty());
}
