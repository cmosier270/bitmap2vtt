//! FFmpeg subtitle stream codec initialization and management.
//!
//! This module provides utilities for discovering and initializing subtitle decoders
//! from an AVFormatContext. It supports multiple subtitle streams within a single
//! media file and handles codec allocation, parameter copying, and cleanup.

const std = @import("std");
const c = @import("c.zig").c;
const mn = @import("main.zig");
const SubtitleError = mn.SubtitleError;

/// Represents a single subtitle stream's decoder configuration.
///
/// Each StreamCodec encapsulates the FFmpeg codec and context needed to decode
/// subtitles from a specific stream within a media container. The context must
/// be freed using `deinit()` to avoid memory leaks.
const StreamCodec = struct {
    /// Zero-based index of this subtitle stream within the parent AVFormatContext.
    stream_index: usize,

    /// Pointer to the FFmpeg codec descriptor for this subtitle format.
    /// This remains valid for the lifetime of the FFmpeg library.
    codec: [*c]const c.AVCodec,

    /// Allocated codec context containing decoder state and parameters.
    /// Must be freed with avcodec_free_context() via deinit().
    context: ?*c.AVCodecContext,

    /// Releases the allocated codec context.
    ///
    /// This should be called when the StreamCodec is no longer needed to prevent
    /// memory leaks. Safe to call multiple times (context is set to null after free).
    pub fn deinit(self: *StreamCodec) void {
        if (self.context != null) {
            c.avcodec_free_context(&self.context);
            self.context = null;
        }
    }
};

/// Discovers and initializes all subtitle stream decoders in a media file.
///
/// Scans the provided AVFormatContext for subtitle streams, allocates and configures
/// a codec context for each valid stream, and returns them in an ArrayList.
///
/// ## Parameters
/// - `allocator`: Memory allocator for the returned ArrayList
/// - `fctx`: Pointer to an opened AVFormatContext containing stream information
///
/// ## Returns
/// An ArrayList of StreamCodec entries (one per successfully initialized subtitle stream),
/// or `null` if initialization fails. The caller is responsible for calling `deinit()`
/// on each StreamCodec and freeing the ArrayList.
///
/// ## Error Handling
/// Streams that fail to initialize are logged and skipped rather than causing the
/// entire function to fail. This allows partial success when some subtitle streams
/// are valid while others are not.
///
/// ## Example
/// ```zig
/// var codecs = buildStreamCodecs(allocator, format_ctx) orelse return error.NoCodecs;
/// defer {
///     for (codecs.items) |*codec| {
///         codec.deinit();
///     }
///     codecs.deinit();
/// }
/// ```
pub fn buildStreamCodecs(allocator: std.mem.Allocator, fctx: *c.AVFormatContext) ?std.ArrayList(StreamCodec) {
    const n_streams = fctx.*.nb_streams;

    var codecs = std.ArrayList(StreamCodec).empty;

    // Iterate through all streams in the media container
    for (0..n_streams) |i| {
        const stream = fctx.*.streams[i];
        const codecpar = stream.*.codecpar;

        // Only process subtitle streams
        if (codecpar.*.codec_type == c.AVMEDIA_TYPE_SUBTITLE) {
            // Find a decoder for this subtitle codec
            const found_codec = c.avcodec_find_decoder(codecpar.*.codec_id);
            if (found_codec == null) {
                const msg: [*:0]const u8 = c.av_get_media_type_string(codecpar.*.codec_type) orelse "no type found";
                std.log.warn("No decoder found for subtitle stream {d} (type: {s})", .{ i, msg });
                continue;
            }
            const codec = found_codec.?;

            // Allocate a new codec context for this decoder
            var context = c.avcodec_alloc_context3(codec);
            if (context == null) {
                std.log.err("Failed to allocate codec context for stream {d}", .{i});
                continue;
            }

            // Copy stream parameters into the codec context
            if (c.avcodec_parameters_to_context(context, codecpar) < 0) {
                std.log.err("Failed to copy codec parameters to context for stream {d}", .{i});
                c.avcodec_free_context(&context);
                continue;
            }

            // Open the codec for decoding
            if (c.avcodec_open2(context, codec, null) < 0) {
                std.log.err("Failed to open codec for stream {d}", .{i});
                c.avcodec_free_context(&context);
                continue;
            }

            // Add successfully initialized codec to the list
            codecs.append(allocator, .{
                .stream_index = i,
                .codec = codec,
                .context = context,
            }) catch |err| {
                std.log.err("Failed to append StreamCodec: {}", .{err});
                c.avcodec_free_context(&context);
                continue;
            };
        }
    }

    return codecs;
}

pub fn iterate_frames(my_ctx: *mn.SubtitleContext, fctx: *c.AVFormatContext, codecs: std.ArrayList(StreamCodec), comptime processor: anytype) !void {
    const total_streams = fctx.*.nb_streams;

    // Build a list of optional AVCodecContext pointers for all subtitle codecs
    var alloc = my_ctx.alloc;
    var codecs_list = try alloc.alloc(?*c.AVCodecContext, total_streams);
    defer alloc.free(codecs_list);

    // Initialize codecs_list: set each entry to null
    for (codecs_list) |*entry| {
        entry.* = null;
    }
    // For each StreamCodec, set the corresponding entry in codecs_list to its context
    for (codecs.items) |*codec| {
        codecs_list[codec.stream_index] = codec.context;
    }

    // Iterate all AVFrames in fctx
    var pkt = c.AVPacket{};
    while (c.av_read_frame(fctx, &pkt) >= 0) {
        defer c.av_packet_unref(&pkt);

        // Check if this packet belongs to a subtitle stream we care about
        const stream_index: usize = @intCast(pkt.stream_index);
        const codec = codecs_list[stream_index] orelse {
            continue;
        };
        var subtitle: c.AVSubtitle = undefined;
        var got_subtitle: c_int = 0;

        // Decode the subtitle packet
        const ret = c.avcodec_decode_subtitle2(
            codec,
            &subtitle,
            &got_subtitle,
            &pkt,
        );
        // Ensure subtitle is freed if got_subtitle is set, regardless of return value
        defer if (got_subtitle != 0) c.avsubtitle_free(&subtitle);

        if (ret < 0) {
            std.log.err("Failed to decode subtitle packet for stream {d}", .{stream_index});
        } else if (got_subtitle != 0) {
            // Successfully decoded a subtitle
            try processor(my_ctx, &subtitle, pkt.pts);
        }
    }
}

pub const RGBA = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

/// FFmpeg/AVSubtitleRect palette entry:
/// logically (A << 24) | (R << 16) | (G << 8) | B
pub fn unpackARGB(argb: u32) RGBA {
    return .{
        .a = @truncate(argb >> 24),
        .r = @truncate(argb >> 16),
        .g = @truncate(argb >> 8),
        .b = @truncate(argb),
    };
}

/// Get the RGBA for pixel (x,y) from an 8-bit index bitmap and a 256-entry ARGB palette.
/// - idx: rect->data[0]  (index plane, one byte per pixel)
/// - stride: rect->linesize[0] (bytes per row)
/// - pal: rect->data[1] cast to *const u32 (256 colors max)
pub fn colorAt(
    idx: [*]const u8,
    stride: usize,
    x: usize,
    y: usize,
    pal: [*]const u32,
) RGBA {
    const p: u8 = idx[y * stride + x];
    const argb: u32 = pal[p];
    return unpackARGB(argb);
}
