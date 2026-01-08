const std = @import("std");

const clap = @import("clap");

const emulator = @import("emulator/cpu/root.zig");
const hl_emu = @import("emulator/cpu/highlevel/root.zig");
const ll_emu = @import("emulator/cpu/microcoded/root.zig");
const debugger = @import("debugger/root.zig");

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_instance.allocator();

pub export const cpu: *emulator.CpuState = &@import("debugger/debugger.zig").cpu;

pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

var log_level = std.log.default_level;

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

pub fn main() !void {
    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-d, --debugger         Show debugger GUI window.
        \\-r, --rom <str>        Load ROM file.
        \\-l, --llemu            Use low-level emulator (default is high-level).
        \\-q, --quiet            Suppress non-error output.
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

    if (res.args.quiet != 0) {
        log_level = .err;
    }

    if (res.args.debugger != 0) {
        try debugger.main(gpa);
        return;
    }

    if (res.args.rom) |rom| {
        const quiet = res.args.quiet != 0;
        if (res.args.llemu != 0) {
            try ll_emu.main(rom, 100000000, quiet, gpa);
        } else {
            try hl_emu.main(rom, 100000000, quiet, gpa);
        }
    }
}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
