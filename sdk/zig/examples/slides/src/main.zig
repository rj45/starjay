const std = @import("std");
const starjay = @import("starjay");
const clay = @import("zclay");

// volatile spin counter to prevent optimization out of spin wait loops
var spin_counter: u32 = 0;
const vol_spin_counter: *volatile u32 = &spin_counter;

var allocator_memory_buffer: [8 * 1024 * 1024]u8 = undefined;

fn measureText(text: []const u8, cfg: *clay.TextElementConfig, user_data: void) clay.Dimensions {
    _ = user_data; _ = cfg;
    var lines: u32 = 1;
    var line_len: u32 = 0;
    var max_len: u32 = 0;
    for (text) |ch| {
        if (ch == '\n') {
            lines += 1;
            line_len = 0;
        }
        line_len += 1;
        if (line_len > max_len) {
            max_len = line_len;
        }
    }

    return .{
        .w = @floatFromInt(max_len * 8),
        .h = @floatFromInt(lines * 16),
    };
}

fn main_main(console: *std.Io.Writer) !void {
    var fba_alloc = std.heap.FixedBufferAllocator.init(allocator_memory_buffer[0..]);
    var allocator = fba_alloc.allocator();

    const min_memory_size: u32 = clay.minMemorySize();

    try console.print("Hellorld from StarJay land!!!\r\n", .{});
    try console.print("Minimum memory size: {}\r\n", .{min_memory_size});
    try console.flush();

    const memory = try allocator.alloc(u8, min_memory_size);
    defer allocator.free(memory);
    const arena: clay.Arena = clay.createArenaWithCapacityAndMemory(memory);
    _ = clay.initialize(arena, .{ .w = 640, .h = 360 }, .{});
    clay.setMeasureTextFunction(void, {}, measureText);
}


export fn kmain() noreturn {
    const console = starjay.term.getWriter();

    main_main(console) catch |err| {
        console.print("\r\nError!: {}\r\n", .{err}) catch {};
        console.flush() catch {};
    };


    // You can send a power down like so if you wish to exit the emulator:
    // starjay.syscon.shutdown();

    // spin wait forever
    while (true) {}
}
