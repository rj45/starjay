const std = @import("std");

const clap = @import("clap");

const emulator = @import("emulator/root.zig");
const debugger = @import("debugger/root.zig");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

pub fn main() !void {
    defer _ = gpa_instance.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-d, --debugger         Show debugger GUI window.
        \\-r, --rom <str>        Load ROM file.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        // Report useful error and exit.
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        return;
    }

    if (res.args.debugger != 0) {
        try debugger.main(gpa);
        return;
    }

    if (res.args.rom) |rom| {
        try emulator.main(rom, 10000000, gpa);
    }

}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
