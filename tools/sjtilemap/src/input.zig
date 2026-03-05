const std = @import("std");
const zigimg = @import("zigimg");
const color_mod = @import("color.zig");
const OklabAlpha = color_mod.OklabAlpha;

/// A loaded image with pixels in OKLab color space.
pub const LoadedImage = struct {
    pixels: []OklabAlpha,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.pixels);
    }
};

/// Load a PNG file and convert pixels to OKLab color space.
/// Reads the entire file into memory first to work around a zigimg seekability bug
/// where fromFilePath fails with SeekError.Unseekable on some PNG files.
pub fn loadImage(allocator: std.mem.Allocator, path: []const u8) !LoadedImage {
    const file_bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);
    defer allocator.free(file_bytes);
    var image = try zigimg.Image.fromMemory(allocator, file_bytes);
    defer image.deinit(allocator);

    try image.convert(allocator, .float32);

    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(
        allocator,
        image.pixels.float32,
    );

    return LoadedImage{
        .pixels = oklab_pixels,
        .width = @intCast(image.width),
        .height = @intCast(image.height),
        .allocator = allocator,
    };
}
