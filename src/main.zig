//! CLI entry point for reading VobSub subtitle bitmaps via FFmpeg.

const std = @import("std");
const bm = @import("read_subtitle.zig");
const c = @import("c.zig").c;
const tesseract = @import("tesseract_help.zig");

/// Parsed representation of the supported command-line arguments.
const Args = struct {
    input: ?[]const u8 = null,
    help: bool = false,
};

/// Parses raw CLI arguments (`--input`, `--help`) into an `Args` struct.
/// Exits the process with an error message if required values are missing.
fn parseArgs(args: []const [:0]u8) !Args {
    var result = Args{};
    var i: usize = 1;

    while (i < args.len) {
        const current = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, current, "--help")) {
            result.help = true;
            i += 1;
        } else if (std.mem.eql(u8, current, "--input")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --input requires a path argument\n", .{});
                std.process.exit(1);
            }
            result.input = std.mem.sliceTo(args[i + 1], 0);
            i += 2;
        } else {
            std.debug.print("Error: Unknown argument '{s}'\n", .{current});
            std.process.exit(1);
        }
    }

    return result;
}

pub const SubtitleContext = struct {
    alloc: std.mem.Allocator,
    tess_handle: tesseract.Handle, // we own this
    ocr_debug: std.fs.File.Writer, // we own this
    ocr_result_buffer: std.ArrayList(u8), // we own this

    fn deinit(self: *SubtitleContext) void {
        self.ocr_debug.end() catch {};
        tesseract.deinit(&self.tess_handle);
        self.ocr_result_buffer.deinit(self.alloc);
    }
};

pub const SubtitleError = tesseract.TesseractError || error{
    OutOfMemory,
};

fn subtitle_handler(my_ctx: *SubtitleContext, subtitle: *c.AVSubtitle, frame_pts: i64) SubtitleError!void {
    var alloc = my_ctx.alloc;
    const start_display_time: u32 = subtitle.start_display_time;
    const end_display_time: u32 = subtitle.end_display_time;

    var timebuf1: [12]u8 = undefined;
    var timebuf2: [12]u8 = undefined;

    for (subtitle.rects[0..subtitle.num_rects]) |rect| {
        if (rect.*.type != c.SUBTITLE_BITMAP) {
            std.debug.print("Skipping non-bitmap subtitle type: {d}\n", .{rect.*.type});
            continue;
        }
        const bitmap = rect.*.data[0];
        const height = @as(usize, @intCast(rect.*.h));
        const linesize = @as(usize, @intCast(rect.*.linesize[0]));
        const bitmap_len = height * linesize;

        // Allocate GRAY8 buffer
        var gray_buf = try alloc.alloc(u8, bitmap_len);
        defer alloc.free(gray_buf);

        for (bitmap[0..bitmap_len], 0..) |value, i| {
            gray_buf[i] = if (value == 2) 0 else 255;
        }

        try tesseract.recognizeGray8(my_ctx, gray_buf, linesize, height);

        if (frame_pts < 0) {
            std.log.warn("Subtitle frame has negative PTS: {d}", .{frame_pts});
            return;
        }
        const pts: u32 = @intCast(frame_pts);
        const pts_start = pts + start_display_time;
        const pts_end = pts + end_display_time;
        var w = &my_ctx.ocr_debug;
        const ocr_text = my_ctx.ocr_result_buffer.items;

        to_vtt_time(pts_start, &timebuf1);
        to_vtt_time(pts_end, &timebuf2);

        w.interface.print("{s} --> {s}\n", .{ timebuf1, timebuf2 }) catch {};
        w.interface.writeAll(ocr_text) catch {};
        w.interface.writeAll("\n\n") catch {};

        //todo:  we have hardcoded to palette space at offset 2,
        // this was learned visually.  We need to
        // have an app mode where we can pull 3 frames or so, and
        // let someone see the visual for each palette offset so that
        // we can just use a human to figure out the right palette channel.

    }
}

const MS_PER_HOUR: u32 = 3_600_000;
const MS_PER_MIN: u32 = 60_000;
const MS_PER_SEC: u32 = 1_000;

fn to_vtt_time(pts: u32, result_slice: []u8) void {
    // Convert pts (milliseconds) to hh:mm:ss.sss format for WebVTT
    // DVD timestamps should always be non-negative

    const total_ms = pts;
    const hours = total_ms / MS_PER_HOUR;
    const minutes = (total_ms % MS_PER_HOUR) / MS_PER_MIN;
    const seconds = (total_ms % MS_PER_MIN) / MS_PER_SEC;
    const millis = total_ms % MS_PER_SEC;

    _ = std.fmt.bufPrint(result_slice, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, minutes, seconds, millis }) catch {};
}

fn print_gray8(pts: i64, grey: []const u8, height: usize, stride: usize) void {
    var name_buf: [64]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "subtitle_{d}.pgm", .{pts}) catch |err| {
        std.log.err("Error formatting filename: {}", .{err});
        return;
    };
    const file = std.fs.cwd().createFile(filename, .{ .read = false, .truncate = true }) catch |err| {
        std.log.err("Error opening file '{s}': {}", .{ filename, err });
        return;
    };
    defer file.close();
    var filebuf: [4096]u8 = undefined;
    var w = file.writer(&filebuf);
    defer w.end() catch {
        std.log.err("Error ending write to file '{s}'", .{filename});
    };
    w.interface.writeAll("P5\n") catch return;
    w.interface.print("{d} {d}\n", .{ stride, height }) catch return;
    w.interface.writeAll("255\n") catch return;
    w.interface.writeAll(grey) catch return;
}

fn to_c_string(allocator: std.mem.Allocator, str: []const u8) ![:0]const u8 {
    const c_str = try allocator.allocSentinel(u8, str.len, 0);
    @memcpy(c_str, str);
    return c_str;
}

/// Entry point: validates arguments and invokes `read_subtitle_bitmap` on the requested media input.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const parsed_args = try parseArgs(args);

    if (parsed_args.help) {
        std.debug.print("Usage: dvdsub --input <path>\n", .{});
        std.debug.print("  --input <path>       Media file supported by libavformat\n", .{});
        std.debug.print("  --help               Show this help message\n", .{});
        return;
    }

    const parsed_input = parsed_args.input orelse {
        std.debug.print("Error: --input is required\n", .{});
        std.process.exit(1);
    };

    const c_path = try to_c_string(allocator, parsed_input);
    defer allocator.free(c_path);

    var fctx: ?*c.AVFormatContext = null;
    const avstat = c.avformat_open_input(&fctx, c_path.ptr, null, null);
    if (avstat < 0) {
        var errbuf: [256]u8 = undefined;
        const errstr = c.av_make_error_string(&errbuf, errbuf.len, avstat);
        std.debug.print("Error: Failed to open input file '{s}': {s} (code {d})\n", .{ parsed_args.input.?, errstr, avstat });
        std.process.exit(1);
    }

    var list = bm.buildStreamCodecs(allocator, fctx.?) orelse {
        std.process.exit(1);
    };

    defer {
        for (list.items) |*codec| {
            codec.deinit();
        }
        list.deinit(allocator);
    }

    std.debug.print("\n--- Subtitle Stream Codecs ---\n", .{});
    for (list.items) |codec| {
        std.debug.print("Stream {d}:\n", .{codec.stream_index});
        std.debug.print("  Codec: {s}\n", .{c.avcodec_get_name(codec.codec.*.id)});
    }

    const debug_file = try std.fs.cwd().createFile("test.vtt", .{ .read = false, .truncate = true });
    defer debug_file.close();
    var debug_buffer: [4096]u8 = undefined;

    var my_ctx = SubtitleContext{
        .alloc = allocator,
        .tess_handle = try tesseract.init(),
        .ocr_debug = debug_file.writer(&debug_buffer),
        .ocr_result_buffer = std.ArrayList(u8).empty,
    };
    defer my_ctx.deinit();

    // Write WebVTT header to the debug file
    try my_ctx.ocr_debug.interface.writeAll("WEBVTT\n\n");

    try bm.iterate_frames(&my_ctx, fctx.?, list, subtitle_handler);

    //TODO:  Enhance the program to allow a user to visually see some PPM samples of some
    // subtitles.  Ideally, see one PPM for each palette entry held black and the others white.  Then,
    // they could just visually choose one - this assumes that each subtitle is encoded consistently,
    // which may be resonable.
}
