const std = @import("std");

// C bindings for Tesseract OCR library
const c = @cImport({
    @cInclude("tesseract/capi.h");
});
const SubtitleContext = @import("main.zig").SubtitleContext;

/// Opaque handle to Tesseract API instance
pub const Handle = struct {
    api: *c.TessBaseAPI,
};

/// Error types for Tesseract operations
pub const TesseractError = error{
    InitializationFailed,
    RecognitionFailed,
    InvalidImage,
    OutOfMemory,
};

/// Initialize Tesseract with English (US) language data
/// Caller must call deinit() when done
pub fn init() TesseractError!Handle {

    // Create Tesseract API instance
    const api = c.TessBaseAPICreate();
    if (api == null) {
        return TesseractError.InitializationFailed;
    }

    // Initialize with English language
    // datapath=null uses default location (/usr/share/tessdata)
    // language="eng" for English
    const init_result = c.TessBaseAPIInit3(api, null, "eng");
    if (init_result != 0) {
        c.TessBaseAPIDelete(api);
        return TesseractError.InitializationFailed;
    }

    // Set page segmentation mode for subtitle text blocks
    // PSM_SINGLE_BLOCK (6) = single uniform block of text
    c.TessBaseAPISetPageSegMode(api, c.PSM_SINGLE_BLOCK);

    return Handle{ .api = api.? };
}

/// Clean up and destroy Tesseract API instance
pub fn deinit(handle: *Handle) void {
    c.TessBaseAPIDelete(handle.api);
}

/// Process a grayscale (GRAY8) image buffer and extract text
/// Parameters:
///   - handle: Initialized TesseractHandle
///   - image_data: Raw pixel buffer (8-bit grayscale)
///   - width: Image width in pixels
///   - height: Image height in pixels
///   - allocator: Not used (kept for future API flexibility)
/// Returns: OcrResult containing recognized text (caller must deinit)
pub fn recognizeGray8(
    my_ctx: *SubtitleContext,
    image_data: []const u8,
    width: usize,
    height: usize,
) TesseractError!void {

    // Validate image data size
    const expected_size = width * height;
    if (image_data.len != expected_size) {
        return TesseractError.InvalidImage;
    }

    const tess_api = my_ctx.tess_handle.api;
    // Pass image data to Tesseract
    // GRAY8: 1 byte per pixel, bytes_per_line = width
    c.TessBaseAPISetImage(
        tess_api,
        image_data.ptr,
        @intCast(width),
        @intCast(height),
        1, // bytes_per_pixel (grayscale)
        @intCast(width), // bytes_per_line (no padding)
    );

    // Perform OCR recognition
    const recognize_result = c.TessBaseAPIRecognize(tess_api, null);
    if (recognize_result != 0) {
        return TesseractError.RecognitionFailed;
    }

    // Get recognized text as C string
    const c_text = c.TessBaseAPIGetUTF8Text(tess_api);
    if (c_text == null) {
        return TesseractError.RecognitionFailed;
    }
    var text_buf = &my_ctx.ocr_result_buffer;
    text_buf.clearRetainingCapacity();
    const alloc = my_ctx.alloc;

    const text_len = std.mem.len(c_text);
    const c_slice = std.mem.span(c_text)[0..text_len];
    const trimmed = std.mem.trim(u8, c_slice, &std.ascii.whitespace);
    var prev_char: u8 = undefined;
    for (0..trimmed.len) |i| {
        const my_char = trimmed[i];
        if (my_char != '\r' and my_char != '\n' and my_char != '\t') {
            try text_buf.append(alloc, my_char);
        } else if (prev_char != ' ') {
            try text_buf.append(alloc, ' ');
        }
        prev_char = my_char;
    }
}
