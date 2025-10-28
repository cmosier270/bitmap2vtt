//! Minimal FFmpeg C bindings shared across the dvdsub tool.

pub const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavformat/avformat.h");
});
