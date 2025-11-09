//! FFmpeg AVStream disposition flags.
//!
//! This module provides an idiomatic Zig interface for working with FFmpeg's
//! AVStream disposition field, which describes the intended use of a stream.
//!
//! The disposition field is a bitmask of flags that indicate properties like
//! whether a stream is the default, forced, hearing-impaired, etc.

const std = @import("std");
const c = @import("c.zig").c;

/// Disposition flags for an AVStream.
///
/// This struct provides a type-safe, idiomatic Zig interface to FFmpeg's
/// disposition flags, which are normally represented as a C integer bitmask.
///
/// Example usage:
/// ```zig
/// const stream = format_ctx.streams[0];
/// const disp = Disposition.fromInt(stream.*.disposition);
///
/// if (disp.default) {
///     std.log.info("This is the default stream", .{});
/// }
///
/// if (disp.forced or disp.hearing_impaired) {
///     // Handle accessibility tracks
/// }
/// ```
pub const Disposition = struct {
    /// The stream should be chosen by default among other streams of the same type.
    default: bool = false,

    /// The stream is not in original language (dubbed audio).
    dub: bool = false,

    /// The stream is in the original language.
    original: bool = false,

    /// The stream is a commentary track.
    comment: bool = false,

    /// The stream contains song lyrics.
    lyrics: bool = false,

    /// The stream contains karaoke audio (vocal track for sing-along).
    karaoke: bool = false,

    /// Track should be displayed/used during playback by default.
    /// Forced subtitles are typically used for translating foreign dialogue
    /// in otherwise native-language content.
    forced: bool = false,

    /// The stream is intended for hearing impaired audiences.
    /// May include descriptions of sound effects and music.
    hearing_impaired: bool = false,

    /// The stream is intended for visually impaired audiences.
    /// Typically audio description tracks.
    visual_impaired: bool = false,

    /// The audio stream contains music and sound effects without voice/dialogue.
    clean_effects: bool = false,

    /// The stream is stored as an attached picture (e.g., album cover art).
    /// Common in audio files.
    attached_pic: bool = false,

    /// The stream is sparse and contains thumbnail images at various timestamps.
    timed_thumbnails: bool = false,

    /// The stream contains non-diegetic audio (e.g., score, narration).
    /// Intended to be mixed with spatial audio tracks.
    non_diegetic: bool = false,

    /// The subtitle stream contains captions (transcription and translation of dialogue).
    captions: bool = false,

    /// The subtitle stream contains textual descriptions of video content.
    descriptions: bool = false,

    /// The subtitle stream contains time-aligned metadata not intended for direct display.
    metadata: bool = false,

    /// The stream is intended to be mixed with another stream before presentation.
    dependent: bool = false,

    /// The video stream contains still images only (no motion video).
    still_image: bool = false,

    /// The video stream contains multiple layers (e.g., stereoscopic 3D, multiview).
    multilayer: bool = false,

    /// Creates a Disposition from an FFmpeg integer bitmask.
    pub fn fromInt(value: c_int) Disposition {
        return .{
            .default = (value & (1 << 0)) != 0,
            .dub = (value & (1 << 1)) != 0,
            .original = (value & (1 << 2)) != 0,
            .comment = (value & (1 << 3)) != 0,
            .lyrics = (value & (1 << 4)) != 0,
            .karaoke = (value & (1 << 5)) != 0,
            .forced = (value & (1 << 6)) != 0,
            .hearing_impaired = (value & (1 << 7)) != 0,
            .visual_impaired = (value & (1 << 8)) != 0,
            .clean_effects = (value & (1 << 9)) != 0,
            .attached_pic = (value & (1 << 10)) != 0,
            .timed_thumbnails = (value & (1 << 11)) != 0,
            .non_diegetic = (value & (1 << 12)) != 0,
            .captions = (value & (1 << 16)) != 0,
            .descriptions = (value & (1 << 17)) != 0,
            .metadata = (value & (1 << 18)) != 0,
            .dependent = (value & (1 << 19)) != 0,
            .still_image = (value & (1 << 20)) != 0,
            .multilayer = (value & (1 << 21)) != 0,
        };
    }

    /// Converts this Disposition back to an FFmpeg integer bitmask.
    pub fn toInt(self: Disposition) c_int {
        var result: c_int = 0;
        if (self.default) result |= (1 << 0);
        if (self.dub) result |= (1 << 1);
        if (self.original) result |= (1 << 2);
        if (self.comment) result |= (1 << 3);
        if (self.lyrics) result |= (1 << 4);
        if (self.karaoke) result |= (1 << 5);
        if (self.forced) result |= (1 << 6);
        if (self.hearing_impaired) result |= (1 << 7);
        if (self.visual_impaired) result |= (1 << 8);
        if (self.clean_effects) result |= (1 << 9);
        if (self.attached_pic) result |= (1 << 10);
        if (self.timed_thumbnails) result |= (1 << 11);
        if (self.non_diegetic) result |= (1 << 12);
        if (self.captions) result |= (1 << 16);
        if (self.descriptions) result |= (1 << 17);
        if (self.metadata) result |= (1 << 18);
        if (self.dependent) result |= (1 << 19);
        if (self.still_image) result |= (1 << 20);
        if (self.multilayer) result |= (1 << 21);
        return result;
    }

    /// Returns true if no disposition flags are set.
    pub fn isEmpty(self: Disposition) bool {
        return self.toInt() == 0;
    }

    /// Returns true if this stream is marked for accessibility (hearing or visually impaired).
    pub fn isAccessibility(self: Disposition) bool {
        return self.hearing_impaired or self.visual_impaired;
    }

    /// Returns true if this subtitle stream provides textual content (captions or descriptions).
    pub fn isSubtitleText(self: Disposition) bool {
        return self.captions or self.descriptions;
    }

    /// Formats the disposition as a human-readable string listing all set flags.
    pub fn format(
        self: Disposition,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        var first = true;
        try writer.writeAll("Disposition{");

        inline for (@typeInfo(Disposition).@"struct".fields) |field| {
            if (field.type == bool and @field(self, field.name)) {
                if (!first) try writer.writeAll(", ");
                try writer.writeAll(field.name);
                first = false;
            }
        }

        try writer.writeAll("}");
    }
};

test "Disposition.fromInt and toInt" {
    const testing = std.testing;

    // Test default flag
    const disp1 = Disposition.fromInt(1 << 0);
    try testing.expect(disp1.default);
    try testing.expectEqual(@as(c_int, 1 << 0), disp1.toInt());

    // Test multiple flags
    const disp2 = Disposition.fromInt((1 << 6) | (1 << 7));
    try testing.expect(disp2.forced);
    try testing.expect(disp2.hearing_impaired);
    try testing.expectEqual(@as(c_int, (1 << 6) | (1 << 7)), disp2.toInt());

    // Test captions (bit 16)
    const disp3 = Disposition.fromInt(1 << 16);
    try testing.expect(disp3.captions);
    try testing.expectEqual(@as(c_int, 1 << 16), disp3.toInt());
}

test "Disposition.isEmpty" {
    const testing = std.testing;

    const empty = Disposition{};
    try testing.expect(empty.isEmpty());

    const not_empty = Disposition{ .default = true };
    try testing.expect(!not_empty.isEmpty());
}

test "Disposition.isAccessibility" {
    const testing = std.testing;

    const hearing = Disposition{ .hearing_impaired = true };
    try testing.expect(hearing.isAccessibility());

    const visual = Disposition{ .visual_impaired = true };
    try testing.expect(visual.isAccessibility());

    const normal = Disposition{ .default = true };
    try testing.expect(!normal.isAccessibility());
}
