const std = @import("std");
const zigimg = @import("zigimg");
const color_mod = @import("../color.zig");
const OklabAlpha = color_mod.OklabAlpha;

/// Save OKLab pixels as a PNG file.
pub fn saveOklabAsPng(
    allocator: std.mem.Allocator,
    pixels: []const OklabAlpha,
    width: u32,
    height: u32,
    path: []const u8,
) !void {
    // Convert OKLab back to sRGB float32
    const float_pixels = try zigimg.color.sRGB.sliceFromOkLabAlphaCopy(
        allocator,
        pixels,
        .clamp,
    );
    defer allocator.free(float_pixels);

    // Create zigimg image with float32 format
    var image = try zigimg.Image.create(allocator, width, height, .float32);
    defer image.deinit(allocator);

    @memcpy(image.pixels.float32, float_pixels);

    try image.convert(allocator, .rgba32);

    // Write to file
    var write_buf: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    try image.writeToFilePath(allocator, path, write_buf[0..], .{ .png = .{} });
}
