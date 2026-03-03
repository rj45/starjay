const std = @import("std");
const builtin = @import("builtin");

const clap = @import("clap");

const emulator = @import("emulator/starjette/root.zig");
const hl_emu = @import("emulator/starjette/highlevel/root.zig");
const ll_emu = @import("emulator/starjette/microcoded/root.zig");
const System = @import("emulator/System.zig");
const debugger = @import("debugger/root.zig");
const vdp = @import("emulator/vdp/main.zig");
const chan = @import("lib/chan.zig"); // for the tests

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

fn mainWithoutEnv(c_argc: c_int, c_argv: [*][*:0]c_char) callconv(.c) c_int {
    _ = @as([*][*:0]u8, @ptrCast(c_argv))[0..@as(usize, @intCast(c_argc))];
    const gpa = std.heap.c_allocator;
    vdp.main(gpa, "sdk/zig/examples/vdp_demo/zig-out/bin/vdp_demo") catch unreachable;
    return 0;
}

comptime {
    if (builtin.target.os.tag == .emscripten) {
        @export(&mainWithoutEnv, .{ .name = "__main_argc_argv" });
    }
}

pub fn main() !void {
    if (builtin.target.os.tag == .emscripten) return;

    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-d, --debugger         Show debugger GUI window.
        \\-v, --vdp              Show VDP window.
        \\-r, --rom <str>        Load ELF binary or ROM file.
        \\-l, --llemu            Use low-level emulator (default is high-level).
        \\-5, --riscv            Use RISC-V CPU core.
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
        std.debug.print("Debugger is currently broken, sorry.\n", .{});
        // try debugger.main(gpa, res.args.vdp != 0);
        return;
    } else if (res.args.vdp != 0) {
        try vdp.main(gpa, res.args.rom);
        return;
    }

    if (res.args.rom) |rom| {
        const quiet = res.args.quiet != 0;
        if (res.args.riscv != 0) {
            var system = try System.init(rom, quiet, null, null, null, gpa);
            defer system.deinit(gpa);

            try system.run(std.math.maxInt(usize));
        } else if (res.args.llemu != 0) {
            try ll_emu.main(rom, std.math.maxInt(usize), quiet, gpa);
        } else {
            try hl_emu.main(rom, std.math.maxInt(usize), quiet, gpa);
        }
    }
}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
