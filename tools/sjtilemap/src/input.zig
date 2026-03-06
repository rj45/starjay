const std = @import("std");
const zigimg = @import("zigimg");
const color_mod = @import("color.zig");
const OklabAlpha = color_mod.OklabAlpha;

/// A loaded image with pixels in OKLab color space.
pub const LoadedImage = struct {
    pixels: []OklabAlpha,
    /// Original sRGB u8 bytes: 3 bytes per pixel (R, G, B), captured before OKLab conversion.
    /// Used for accurate PSNR calculation to avoid the OKLab→sRGB round-trip precision loss.
    /// null when LoadedImage was constructed programmatically (e.g. in tests).
    srgb_bytes: ?[]u8 = null,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.pixels);
        if (self.srgb_bytes) |b| self.allocator.free(b);
    }
};

/// Load a PNG file and convert pixels to OKLab color space.
/// Reads the entire file into memory first to work around a zigimg seekability bug
/// where fromFilePath fails with SeekError.Unseekable on some PNG files.
/// Also captures original sRGB u8 bytes (in LoadedImage.srgb_bytes) for accurate PSNR calculation.
pub fn loadImage(allocator: std.mem.Allocator, path: []const u8) !LoadedImage {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(file_bytes);
    var image = try zigimg.Image.fromMemory(allocator, file_bytes);
    defer image.deinit(allocator);

    try image.convert(allocator, .float32);

    // Capture original sRGB u8 bytes from float32 before OKLab conversion.
    // float32 stores scaled [0,1] values; multiplying by 255 and rounding recovers the original u8.
    // This avoids the OKLab→sRGB round-trip precision loss in PSNR calculation.
    const npixels = image.width * image.height;
    const srgb_bytes = try allocator.alloc(u8, npixels * 3);
    for (image.pixels.float32, 0..) |px, i| {
        srgb_bytes[i * 3 + 0] = @intFromFloat(std.math.clamp(px.r * 255.0 + 0.5, 0.0, 255.0));
        srgb_bytes[i * 3 + 1] = @intFromFloat(std.math.clamp(px.g * 255.0 + 0.5, 0.0, 255.0));
        srgb_bytes[i * 3 + 2] = @intFromFloat(std.math.clamp(px.b * 255.0 + 0.5, 0.0, 255.0));
    }

    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .srgb_bytes = srgb_bytes,
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .allocator = allocator,
    };
}
