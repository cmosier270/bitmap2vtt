# dvdsub-tool

A command-line tool for extracting DVD bitmap subtitles (VobSub) from video files and converting them to WebVTT format using OCR.

Haven't tested yet with PGS, but the intent is that they should be 

**Note: PGS subtitle support is intended but not yet fully tested.**

**Note this is not yet generally usable, requires some better command line processing**
 - expects subtitle "ink" to be in VCSubtitleRect's palette at index 2, is currently hardcoded
 - output file name also hardcoded

## Features

- Extract DVD bitmap subtitles from media files via FFmpeg
- Convert bitmap subtitles to text using Tesseract OCR
- Output subtitles in WebVTT format
- Support for multiple subtitle streams
- Handles various media container formats supported by FFmpeg

## Requirements

### Zig

- **Zig version 0.15.2** (required)

### System Dependencies

The following libraries must be installed on your system:

- **FFmpeg libraries**:
  - `libavformat`
  - `libavcodec`
  - `libavutil`
  - `libswresample`
  - `libswscale`

- **Tesseract OCR**:
  - `libtesseract`

#### Installing Dependencies

**Ubuntu/Debian:**
```bash
sudo apt-get install ffmpeg libavformat-dev libavcodec-dev libavutil-dev \
                     libswresample-dev libswscale-dev \
                     libtesseract-dev tesseract-ocr
```

**Fedora/RHEL:**
```bash
sudo dnf install ffmpeg-devel tesseract-devel
```

**macOS (Homebrew):**
```bash
brew install ffmpeg tesseract
```

**Arch Linux:**
```bash
sudo pacman -S ffmpeg tesseract
```

## Building

```bash
zig build
```

The executable will be created in `zig-out/bin/dvdsub-tool`.

## Usage

```bash
dvdsub-tool --input <path-to-video-file>
```

### Options

- `--input <path>` - Path to the media file (required)
- `--help` - Display help message

### Example

```bash
./zig-out/bin/dvdsub-tool --input movie.mkv
```

This will:
1. Scan the input file for subtitle streams
2. Extract bitmap subtitles from DVD subtitle tracks
3. Convert them to text using Tesseract OCR
4. Save the output to `test.vtt` in WebVTT format

## Output

The tool generates a `test.vtt` file containing the extracted subtitles in WebVTT format with timestamps:

```
WEBVTT

00:00:05.000 --> 00:00:08.000
Example subtitle text

00:00:10.500 --> 00:00:13.200
Another subtitle line
```

## Project Structure

```
.
├── build.zig                 # Build configuration
└── src/
    ├── main.zig              # CLI entry point and main logic
    ├── c.zig                 # FFmpeg C library bindings
    ├── read_subtitle.zig     # Subtitle stream handling
    ├── read_sub_bitmap.zig   # Bitmap processing
    └── tesseract_help.zig    # Tesseract OCR integration
```

## How It Works

1. **Input Parsing**: Uses FFmpeg's libavformat to open and parse the media file
2. **Stream Detection**: Identifies all subtitle streams in the container
3. **Codec Initialization**: Sets up decoders for each subtitle stream
4. **Frame Iteration**: Reads and decodes subtitle packets
5. **Bitmap Conversion**: Converts indexed color bitmaps to grayscale
6. **OCR Processing**: Applies Tesseract OCR to extract text from bitmap subtitles
7. **WebVTT Output**: Formats the results with proper timestamps

## Limitations

- NOT yet usable generally:
- Currently hardcoded to palette index 2 for subtitle detection
- Outputs to a fixed filename (`test.vtt`)
- Requires visual tuning for optimal palette selection on some media files

## Future Enhancements

- Interactive palette selection mode for better subtitle extraction
- Configurable output filename
- Support for multiple output formats
- Batch processing of multiple files
- GUI preview for palette debugging

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Acknowledgments

- Built with [Zig](https://ziglang.org/)
- Uses [FFmpeg](https://ffmpeg.org/) for media handling
- Uses [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) for text recognition
