# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Pay special attention to ZIG Constraints below.  Do not stray or drift from those constraints.

## Project Overview

dvdsub-tool is a command-line utility for extracting DVD bitmap subtitles (VobSub) from video files and converting them to WebVTT format using OCR. Written in Zig 0.15.2, it integrates FFmpeg for media handling and Tesseract for optical character recognition.

**Current Status**: Early development. Not yet generally usable due to hardcoded palette index and output filename.

** TODOS **
 - write each subtitle bitmap pallette entry for a few time samples.
   This is in progress

## ZIG constraints
- version 0.15.2 only
- canonical source of truth is `zig-x86_64-linux-0.15.2` subdirectory

## Build Commands

Building must happen inside the docker container, otherwise libav* and avformat, etc won't resolve.

The image name is dvdsub-build

The Dockerfile build stage generally has the code to investigate how it was built.

To run map the desired directory to /work in the container.  I normally use (for build / test):

```bash
docker run --rm -v .:/work dvdsub-build 
```


```bash
# Build the project
zig build

# Run with arguments
zig build run -- --input <path-to-video>

# Run tests
zig build test
```

The executable is created at `zig-out/bin/dvdsub-tool`.

## System Dependencies

Required libraries must be installed:
- FFmpeg: `libavformat`, `libavcodec`, `libavutil`, `libswresample`, `libswscale`
- Tesseract OCR: `libtesseract`

See README.md for platform-specific installation instructions.

## Docker Development

The Dockerfile provides a build environment with all dependencies:
```bash
docker build -t dvdsub-tool .
```

## Architecture

### Data Flow Pipeline

1. **Input Parsing** ([main.zig:178-216](src/main.zig#L178-L216))
   - CLI argument parsing (`--input`, `--help`)
   - Opens media file via `avformat_open_input()`
   - Base filename extraction for future multi-stream output

2. **Stream Discovery** ([read_subtitle.zig:83-152](src/read_subtitle.zig#L83-L152))
   - `buildStreamCodecs()` scans all streams in the media container
   - Filters for `AVMEDIA_TYPE_SUBTITLE` streams
   - Initializes AVCodecContext for each subtitle stream
   - Captures stream metadata (language, title) and disposition flags (forced, hearing_impaired, captions, etc.)

3. **Frame Iteration** ([read_subtitle.zig:154-201](src/read_subtitle.zig#L154-L201))
   - `iterate_frames()` reads packets via `av_read_frame()`
   - Decodes subtitle packets using `avcodec_decode_subtitle2()`
   - Dispatches decoded subtitles to handler callback with PTS timestamp
   - Properly manages AVPacket and AVSubtitle lifecycle with defer statements

4. **Bitmap Processing** ([main.zig:69-123](src/main.zig#L69-L123))
   - `subtitle_ocr_handler()` processes `SUBTITLE_BITMAP` rectangles
   - Converts indexed color bitmap to grayscale (GRAY8 format)
   - **Currently hardcoded**: assumes subtitle "ink" is at palette index 2
   - Allocates grayscale buffer where palette[2] → 0 (black), others → 255 (white)

5. **OCR Processing** ([tesseract_help.zig:61-116](src/tesseract_help.zig#L61-L116))
   - `recognizeGray8()` passes image data to Tesseract API
   - Configured with `PSM_SINGLE_BLOCK` for subtitle text blocks
   - Text normalization: converts CR/LF/Tab to spaces, trims whitespace
   - Results stored in `SubtitleContext.ocr_result_buffer`

6. **Output Generation**
   - Timestamp conversion to WebVTT format (hh:mm:ss.sss) via `to_vtt_time()`
   - **Currently incomplete**: Output writing code is commented out
   - **Hardcoded**: Output filename is `test.vtt`

### Module Organization

- **[c.zig](src/c.zig)**: Minimal FFmpeg C bindings via `@cImport`
- **[main.zig](src/main.zig)**: CLI entry point, argument parsing, main processing loop, SubtitleContext management
- **[read_subtitle.zig](src/read_subtitle.zig)**: Stream codec initialization, frame iteration, stream mapping utilities
- **[tesseract_help.zig](src/tesseract_help.zig)**: Tesseract API wrapper for GRAY8 image OCR
- **[avf_disposition.zig](src/avf_disposition.zig)**: Type-safe wrapper for AVStream disposition flags (forced, captions, hearing_impaired, etc.)
- **[avf_metadata.zig](src/avf_metadata.zig)**: Metadata extraction from AVDictionary (language, title, etc.)

### Key Data Structures

**SubtitleContext** ([main.zig:41-63](src/main.zig#L41-L63)):
Global context threaded through the processing pipeline containing:
- Tesseract API handle
- OCR result buffer (reused across frames)
- Base file path for output naming
- Stream mapping from AVFormat indices to internal ordinal list
- File writer handles (currently unused)

**StreamCodec** ([read_subtitle.zig:19-52](src/read_subtitle.zig#L19-L52)):
Per-stream decoder state containing:
- Stream index within AVFormatContext
- AVCodec and AVCodecContext pointers
- Disposition flags and metadata dictionary
- Must call `deinit()` to free codec context

### Memory Management Patterns

- **FFmpeg resources**: Always paired with cleanup (`avformat_open_input` → close, `avcodec_alloc_context3` → `avcodec_free_context`)
- **defer statements**: Extensively used for exception-safe cleanup (packets, subtitles, allocations)
- **String lifetimes**: Metadata strings reference FFmpeg's internal memory and are only valid while AVFormatContext is alive
- **Arena allocation**: GeneralPurposeAllocator used at main() level, passed through context

## Known Limitations and TODOs

1. **Palette Detection** ([main.zig:116-120](src/main.zig#L116-L120))
   - Hardcoded to palette index 2 for subtitle detection
   - Visual tuning needed per media file
   - TODO: Interactive mode to preview each palette channel and select manually

2. **Output Configuration**
   - Fixed output filename (`test.vtt`)
   - TODO: Derive from input filename and stream metadata
   - TODO: Support multiple subtitle streams with distinct output files

3. **Command Line Interface**
   - Minimal argument parsing
   - TODO: Add options for palette selection, output path, stream selection

4. **PGS Subtitle Support**
   - Intended but not yet tested
   - Should work via same AVMEDIA_TYPE_SUBTITLE path

## Development Conventions

### FFmpeg Integration
- Always check return codes from FFmpeg functions (negative = error)
- Use `av_make_error_string()` to convert error codes to human-readable messages
- Properly sequence codec operations: find → alloc → copy params → open

### Error Handling
- Log warnings for non-fatal issues (streams that fail to initialize)
- Exit with status 1 and clear error messages for fatal errors
- Use Zig error unions (`!Type`) for propagating errors through call stack

### Testing
- Unit tests included in disposition and metadata modules
- Use `zig build test` to run all tests
- Tests demonstrate API usage patterns (see examples in avf_disposition.zig and avf_metadata.zig)

## Debugging Utilities

**print_gray8()** ([main.zig:149-169](src/main.zig#L149-L169)):
Dumps grayscale subtitle images as PGM files for visual inspection. Useful for debugging palette selection and OCR issues. Files named `subtitle_{pts}.pgm`.

**Color Utilities** ([read_subtitle.zig:203-235](src/read_subtitle.zig#L203-L235)):
- `unpackARGB()`: Converts FFmpeg's packed ARGB format to RGBA struct
- `colorAt()`: Extracts pixel color from indexed bitmap using palette
