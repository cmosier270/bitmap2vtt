//! CLI entry point for reading VobSub subtitle bitmaps via FFmpeg.

const std = @import("std");
const bm = @import("read_subtitle.zig");
const c = @import("c.zig").c;
const tesseract = @import("tesseract_help.zig");
const ink_detector = @import("ink_detector.zig");

/// Parsed representation of the supported command-line arguments.
const Args = struct {
    input: ?[]const u8 = null,
    help: bool = false,
    stream_index: ?usize = null,
    debug_output_dir: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
};

/// Parses raw CLI arguments (`--input`, `--help`, `--stream`, `--debug-output`) into an `Args` struct.
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
        } else if (std.mem.eql(u8, current, "--stream")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --stream requires a stream index\n", .{});
                std.process.exit(1);
            }
            const idx_str = std.mem.sliceTo(args[i + 1], 0);
            result.stream_index = std.fmt.parseInt(usize, idx_str, 10) catch {
                std.debug.print("Error: --stream must be a valid stream index number\n", .{});
                std.process.exit(1);
            };
            i += 2;
        } else if (std.mem.eql(u8, current, "--debug-output")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --debug-output requires a directory path\n", .{});
                std.process.exit(1);
            }
            result.debug_output_dir = std.mem.sliceTo(args[i + 1], 0);
            i += 2;
        } else if (std.mem.eql(u8, current, "--output")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --output requires a file path\n", .{});
                std.process.exit(1);
            }
            result.output_file = std.mem.sliceTo(args[i + 1], 0);
            i += 2;
        } else {
            std.debug.print("Error: Unknown argument '{s}'\n", .{current});
            std.process.exit(1);
        }
    }

    return result;
}

const CollectedCue = struct {
    start_ms: u64,
    end_ms: ?u64, // null means "until next subtitle" (PGS sentinel)
    text: []u8, // owned by allocator
};

pub const SubtitleContext = struct {
    alloc: std.mem.Allocator,
    selected_stream_index: usize, // Stream to process
    tess_handle: tesseract.Handle, // we own this
    ocr_result_buffer: std.ArrayList(u8), // we own this
    base_file_path: []const u8,
    // map subtitle stream offset from avformat to
    // internal list for other records (caching filenames, etc)
    stream_map: []const ?usize, // we own
    files: ?[]MyFileWriter, // we own these
    debug_output_dir: ?[]const u8, // Optional directory for debug PGM output
    vtt_writer: MyFileWriter, // VTT output file
    stream_duration_ms: ?u64, // Optional container duration in ms

    collected_cues: std.ArrayList(CollectedCue), // we own this

    fn deinit(self: *SubtitleContext) void {
        const alloc = self.alloc;
        tesseract.deinit(&self.tess_handle);
        self.ocr_result_buffer.deinit(alloc);
        alloc.free(self.stream_map);
        self.vtt_writer.deinit();
        // Free collected cue texts
        for (self.collected_cues.items) |cue| {
            alloc.free(cue.text);
        }
        self.collected_cues.deinit(alloc);
        if (self.files) |f| {
            for (f) |*fw| {
                fw.deinit();
            }
        }
    }
};

pub const SubtitleError = tesseract.TesseractError || error{
    OutOfMemory,
};

fn subtitle_handler(my_ctx: *SubtitleContext, subtitle: *c.AVSubtitle, frame_pts: i64, stream_codec: *bm.StreamCodec) SubtitleError!void {
    // Only process the selected stream
    if (stream_codec.stream_index != my_ctx.selected_stream_index) return;

    var alloc = my_ctx.alloc;
    const start_display_time: u32 = subtitle.start_display_time;
    const end_display_time: u32 = subtitle.end_display_time;

    // Translate packet PTS to milliseconds using the codec time_base
    if (frame_pts == c.AV_NOPTS_VALUE) {
        std.log.warn("Subtitle frame has no PTS; skipping", .{});
        return;
    }
    const ms_time_base = c.AVRational{ .num = 1, .den = 1000 };
    var pts_ms_i64 = c.av_rescale_q(frame_pts, stream_codec.context.?.time_base, ms_time_base);
    if (pts_ms_i64 < 0) pts_ms_i64 = 0;
    const pts_ms: u64 = @intCast(pts_ms_i64);

    // Check if rects is available (may be null for some subtitle formats)
    if (subtitle.rects == null or subtitle.num_rects == 0) {
        // std.log.warn("Subtitle at PTS {d} has no rects (format may not be supported)", .{frame_pts});
        return;
    }

    for (subtitle.rects[0..subtitle.num_rects]) |rect| {
        if (rect.*.type != c.SUBTITLE_BITMAP) {
            // std.debug.print("Skipping non-bitmap subtitle type: {d}\n", .{rect.*.type});
            continue;
        }

        const bitmap = rect.*.data[0];
        const width = @as(usize, @intCast(rect.*.w));
        const height = @as(usize, @intCast(rect.*.h));
        const linesize = @as(usize, @intCast(rect.*.linesize[0]));
        const bitmap_len = height * linesize;
        const nb_colors = @as(usize, @intCast(rect.*.nb_colors));
        const palette = @as([*]const u32, @ptrCast(@alignCast(rect.*.data[1])));

        // Automatic ink detection per subtitle
        const detection = try ink_detector.detectInkPaletteIndex(
            alloc,
            bitmap,
            width,
            height,
            linesize,
            palette,
            nb_colors,
        );
        defer detection.deinit(alloc);

        const ink_index = detection.best_index;
        // Diagnostics to stderr
        // std.log.info("PTS {d}: Detected ink at palette index {d} (confidence: {d:.3})", .{ frame_pts, ink_index, detection.confidence });

        // Convert bitmap to grayscale: ink → black, others → white
        var gray_buf = try alloc.alloc(u8, bitmap_len);
        defer alloc.free(gray_buf);

        for (bitmap[0..bitmap_len], 0..) |value, i| {
            gray_buf[i] = if (value == ink_index) 0 else 255;
        }

        // Optional debug output
        if (my_ctx.debug_output_dir) |debug_dir| {
            print_gray8(debug_dir, frame_pts, ink_index, gray_buf, height, linesize);
        }

        // Run OCR on the ink mask
        try tesseract.recognizeGray8(my_ctx, gray_buf, linesize, height);

        const ocr_text = my_ctx.ocr_result_buffer.items;

        // Copy OCR result because the buffer is reused on the next subtitle
        const text_copy = try alloc.dupe(u8, ocr_text);
        errdefer alloc.free(text_copy);

        // Calculate actual start time: packet PTS (in ms) + display time offset (in ms)
        const start_ms = pts_ms + @as(u64, start_display_time);

        // Determine end time:
        // - DVDsub: end_display_time is a valid offset (typically 0-5000ms)
        // - PGS: end_display_time is often 0 or 0xFFFFFFFF (sentinel = "until next")
        const end_ms: ?u64 = if (end_display_time == 0 or end_display_time == std.math.maxInt(u32))
            null // PGS "until next" case
        else
            pts_ms + @as(u64, end_display_time); // DVDsub explicit end

        // Collect the cue for later finalization
        try my_ctx.collected_cues.append(alloc, .{
            .start_ms = start_ms,
            .end_ms = end_ms,
            .text = text_copy,
        });
    }
}

/// Maximum duration for a subtitle without explicit end time (5 seconds)
const MAX_SUBTITLE_DURATION_MS: u64 = 5000;

const MS_PER_HOUR: u32 = 3_600_000;
const MS_PER_MIN: u32 = 60_000;
const MS_PER_SEC: u32 = 1_000;

/// Finalize collected cues and write them to VTT output.
/// This function:
/// 1. Sorts cues by start time
/// 2. Fills in missing end times (PGS "until next" semantics)
/// 3. Writes all cues to the VTT file
fn finalizeAndWriteCues(ctx: *SubtitleContext) !void {
    const cues = ctx.collected_cues.items;

    // Sort by start time
    std.mem.sort(CollectedCue, cues, {}, struct {
        fn lessThan(_: void, a: CollectedCue, b: CollectedCue) bool {
            return a.start_ms < b.start_ms;
        }
    }.lessThan);

    // Finalize end times and write cues
    for (cues, 0..) |cue, i| {
        const start_ms = cue.start_ms;

        // Determine end time
        const end_ms: u64 = if (cue.end_ms) |explicit_end|
            explicit_end // DVDsub: use explicit end time
        else if (i + 1 < cues.len)
            cues[i + 1].start_ms // PGS: use next subtitle's start
        else
            start_ms + MAX_SUBTITLE_DURATION_MS; // Last subtitle: cap at 5 seconds

        // Write to VTT
        var timebuf1: [32]u8 = undefined;
        var timebuf2: [32]u8 = undefined;

        const start_clamped: u32 = @intCast(@min(start_ms, @as(u64, std.math.maxInt(u32))));
        const end_clamped: u32 = @intCast(@min(end_ms, @as(u64, std.math.maxInt(u32))));

        const time1 = to_vtt_time(start_clamped, &timebuf1);
        const time2 = to_vtt_time(end_clamped, &timebuf2);

        var w = &ctx.vtt_writer.writer;
        try w.interface.print("{s} --> {s}\n", .{ time1, time2 });
        try w.interface.writeAll(cue.text);
        try w.interface.writeAll("\n\n");
    }
}

fn to_vtt_time(pts: u32, result_slice: []u8) []const u8 {
    // Convert pts (milliseconds) to hh:mm:ss.sss format for WebVTT
    // DVD timestamps should always be non-negative

    const total_ms = pts;
    const hours = total_ms / MS_PER_HOUR;
    const minutes = (total_ms % MS_PER_HOUR) / MS_PER_MIN;
    const seconds = (total_ms % MS_PER_MIN) / MS_PER_SEC;
    const millis = total_ms % MS_PER_SEC;

    return std.fmt.bufPrint(result_slice, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, minutes, seconds, millis }) catch &[_]u8{};
}

fn print_gray8(output_dir: []const u8, pts: i64, palette_idx: ?usize, grey: []const u8, height: usize, stride: usize) void {
    var path_buf: [512]u8 = undefined;
    const filename = if (palette_idx) |idx| blk: {
        break :blk std.fmt.bufPrint(&path_buf, "{s}/subtitle_{d}_palette_{d:0>2}.pgm", .{ output_dir, pts, idx }) catch |err| {
            std.log.err("Error formatting filename: {}", .{err});
            return;
        };
    } else blk: {
        break :blk std.fmt.bufPrint(&path_buf, "{s}/subtitle_{d}.pgm", .{ output_dir, pts }) catch |err| {
            std.log.err("Error formatting filename: {}", .{err});
            return;
        };
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
        std.debug.print("Usage: dvdsub-tool --input <path> --stream <N> [OPTIONS]\n\n", .{});
        std.debug.print("Description:\n", .{});
        std.debug.print("  Extracts bitmap subtitles from video files and converts them to text\n", .{});
        std.debug.print("  using OCR. Automatically detects subtitle ink on a per-subtitle basis,\n", .{});
        std.debug.print("  supporting both DVDSub and PGS/HDMV formats.\n\n", .{});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --input <path>         Media file supported by libavformat (required)\n", .{});
        std.debug.print("  --stream <N>           Subtitle stream index to process (required)\n", .{});
        std.debug.print("  --output <file>        Output VTT file (required)\n", .{});
        std.debug.print("  --debug-output <dir>   Save debug PGM images to directory\n", .{});
        std.debug.print("  --help                 Show this help message\n\n", .{});
        std.debug.print("Note: Run without --stream to list available subtitle streams\n", .{});
        return;
    }

    const parsed_input = parsed_args.input orelse {
        std.debug.print("Error: --input is required\n", .{});
        std.process.exit(1);
    };

    //
    // TODO:  get the base path of the input file (without extension)
    //
    const base_path_idx = std.mem.lastIndexOfScalar(u8, parsed_input, '.') orelse parsed_input.len;
    const base_path = parsed_input[0..base_path_idx];

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
            codec.deinit(allocator);
        }
        list.deinit(allocator);
    }

    std.debug.print("\n--- Subtitle Stream Codecs ---\n", .{});
    for (list.items) |codec| {
        std.debug.print("Stream {d}:\n", .{codec.stream_index});
        std.debug.print("  Codec: {s}\n", .{c.avcodec_get_name(codec.codec.*.id)});

        // Display metadata if available
        const lang = codec.metadata.get("language") orelse "unknown";
        const title = codec.metadata.get("title");
        if (title) |t| {
            std.debug.print("  Language: {s}, Title: {s}\n", .{ lang, t });
        } else {
            std.debug.print("  Language: {s}\n", .{lang});
        }

        // Display disposition flags
        if (codec.disposition.default) std.debug.print("  [default]\n", .{});
        if (codec.disposition.forced) std.debug.print("  [forced]\n", .{});
        if (codec.disposition.hearing_impaired) std.debug.print("  [hearing_impaired]\n", .{});
    }

    // If no stream selected, exit here after showing available streams
    const selected_stream_index = parsed_args.stream_index orelse {
        std.debug.print("\nError: --stream is required. Please select a stream from the list above.\n", .{});
        std.process.exit(1);
    };

    // Validate that selected stream exists and find its StreamCodec
    var selected_stream_codec: ?*bm.StreamCodec = null;
    for (list.items) |*codec| {
        if (codec.stream_index == selected_stream_index) {
            selected_stream_codec = codec;
            break;
        }
    }

    if (selected_stream_codec == null) {
        std.debug.print("\nError: Stream {d} not found or is not a subtitle stream\n", .{selected_stream_index});
        std.debug.print("Available subtitle streams are listed above.\n", .{});
        std.process.exit(1);
    }

    std.debug.print("\nSelected stream {d} for processing\n", .{selected_stream_index});

    const codec_name = c.avcodec_get_name(selected_stream_codec.?.codec.*.id);
    std.debug.print("Codec: {s}\n", .{codec_name});

    const stream_map = bm.map_subtitle_streams(list.items, allocator);

    // Require output file
    const output_file = parsed_args.output_file orelse {
        std.debug.print("Error: --output is required\n", .{});
        std.process.exit(1);
    };

    // Create debug output directory if requested
    if (parsed_args.debug_output_dir) |debug_dir| {
        std.fs.cwd().makeDir(debug_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                std.debug.print("Error: Failed to create debug directory '{s}': {}\n", .{ debug_dir, err });
                std.process.exit(1);
            }
        };
        std.debug.print("Debug output enabled: {s}\n", .{debug_dir});
    }

    // Open VTT output file
    const vtt_writer = try MyFileWriter.init(output_file);
    std.debug.print("Writing WebVTT to: {s}\n", .{output_file});

    var my_ctx = SubtitleContext{
        .alloc = allocator,
        .selected_stream_index = selected_stream_index,
        .tess_handle = try tesseract.init(),
        .ocr_result_buffer = std.ArrayList(u8).empty,
        .base_file_path = base_path,
        .stream_map = stream_map,
        .files = null,
        .debug_output_dir = parsed_args.debug_output_dir,
        .vtt_writer = vtt_writer,
        .stream_duration_ms = null, // TODO: extract from container if needed
        .collected_cues = std.ArrayList(CollectedCue).empty,
    };
    defer my_ctx.deinit();

    // Write WebVTT header
    my_ctx.vtt_writer.writer.interface.writeAll("WEBVTT\n\n") catch |err| {
        std.debug.print("Error writing VTT header: {}\n", .{err});
        std.process.exit(1);
    };

    // Phase 1: Collect all subtitles
    try bm.iterate_frames(&my_ctx, fctx.?, list, subtitle_handler);

    std.debug.print("Collected {} subtitle cues\n", .{my_ctx.collected_cues.items.len});

    // Phase 2: Finalize end times and write to VTT
    try finalizeAndWriteCues(&my_ctx);

    std.debug.print("Successfully wrote VTT output to: {s}\n", .{output_file});
}

const MyFileWriter = struct {
    iobuffer: [4096]u8,
    file_handle: std.fs.File,
    writer: std.fs.File.Writer,

    pub fn init(file_path: []const u8) !MyFileWriter {
        const fh = try std.fs.cwd().createFile(file_path, .{});
        var result = MyFileWriter{
            .iobuffer = undefined,
            .file_handle = fh,
            .writer = undefined,
        };
        result.writer = fh.writer(&result.iobuffer);
        return result;
    }

    pub fn deinit(self: *MyFileWriter) void {
        self.writer.end() catch |err| {
            std.log.err("failed to flush MyFileWriter: {}", .{err});
        };
        self.file_handle.close();
    }
};
