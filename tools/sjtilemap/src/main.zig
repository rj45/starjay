const std = @import("std");
const kmeans = @import("kmeans.zig");
const clap = @import("clap");
const zigimg = @import("zigimg");

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-i, --input <str>      Input image.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0 or res.args.input == null) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        return;
    }

    var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
    var image = try zigimg.Image.fromFilePath(gpa, res.args.input.?, read_buffer[0..]);
    defer image.deinit(gpa);

    const width = image.width;
    const height = image.height;
    const stride = image.pixels.len() / image.height;

    std.debug.print("Processing {}x{} image\n", .{width, height});

    // convert to RGB float32
    try image.convert(gpa, .float32);

    const oklab_pixels = try zigimg.color.sRGB.sliceToOklabAlphaCopy(gpa, image.pixels.float32);
    defer gpa.free(oklab_pixels);

    const example_x = 10;
    const example_y = 25;

    std.debug.print("Pixel at ({},{}): {}\n", .{example_x, example_y, oklab_pixels[example_y*stride + example_x]});

    // do something with image
}
