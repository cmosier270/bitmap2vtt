//! Knowing the index information, use these routines to
//! (together with libavcodec) to fetch the subtitle bitmaps
//!

const std = @import("std");
const c = @import("c.zig").c;

/// Converts a Zig slice to a null-terminated C string using the given allocator.
/// The returned memory must be freed by the caller.
pub fn to_c_string(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, s.len + 1);
    std.mem.copyForwards(u8, buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Opens the given VobSub index file, decodes subtitle bitmaps via FFmpeg, and
/// forwards each decoded subtitle to `bitmap_processor`.
pub fn read_subtitle_bitmap(
    allocator: std.mem.Allocator,
    file: []const u8,
    bitmap_processor: fn (rect: *c.AVSubtitle, pts: i64) void,
) !void {
    const c_file = try to_c_string(allocator, file);
    defer allocator.free(c_file);

    var fmt_ctx: ?*c.AVFormatContext = null;
    const fmt_status = c.avformat_open_input(&fmt_ctx, c_file, null, null);
    if (fmt_status < 0) {
        return error.OpenInputFailed;
    }
    defer c.avformat_close_input(&fmt_ctx);
    const fctx = fmt_ctx orelse return error.FormatContextIsNull;

    const subtitle_index = find_subtitle_stream_index(fctx) orelse return error.NoSubtitleStreamFound;
    const target_stream = fctx.*.streams[subtitle_index];
    const decoder = c.avcodec_find_decoder(target_stream.*.codecpar.*.codec_id) orelse return error.NoDecoderFound;
    var codec_ctx = c.avcodec_alloc_context3(decoder) orelse return error.AllocCodecContextFailed;
    defer c.avcodec_free_context(&codec_ctx);

    const pcopy_status = c.avcodec_parameters_to_context(codec_ctx, target_stream.*.codecpar);
    if (pcopy_status < 0) {
        return error.CodecParametersToContextFailed;
    }

    if (c.avcodec_open2(codec_ctx, decoder, null) < 0) {
        return error.OpenCodecFailed;
    }
    var packet: c.AVPacket = undefined;
    while (true) {
        const read_result = c.av_read_frame(fctx, &packet);
        if (read_result == c.AVERROR_EOF) {
            break; // End of file reached
        } else if (read_result < 0) {
            return error.ReadFrameFailed;
        }
        defer c.av_packet_unref(&packet);

        const ps_index = @as(usize, @intCast(packet.stream_index));
        if (ps_index != subtitle_index) {
            continue;
        }

        var subtitle: c.AVSubtitle = undefined;
        var got_subtitle: c_int = 0;
        const decode_result = c.avcodec_decode_subtitle2(codec_ctx, &subtitle, &got_subtitle, &packet);
        if (decode_result < 0) {
            return error.DecodeSubtitleFailed;
        }

        if (got_subtitle != 0) {
            bitmap_processor(&subtitle, packet.pts);
            c.avsubtitle_free(&subtitle);
        }
    }
}

/// Finds the index of the first subtitle stream in the given AVFormatContext.
/// Returns null if no subtitle stream is found.
fn find_subtitle_stream_index(ctx: *c.AVFormatContext) ?usize {
    var i: usize = 0;
    while (i < ctx.*.nb_streams) : (i += 1) {
        const stream = ctx.*.streams[i];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_SUBTITLE) {
            return i;
        }
    }
    return null;
}
