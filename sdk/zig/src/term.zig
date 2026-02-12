const std = @import("std");

pub const term = @This();

const UART_BUF_REG_ADDR:usize = 0x10000000;
const UART_STATE_REG_ADDR:usize = 0x10000005;

var uart_reg: *volatile u8 = @ptrFromInt(UART_BUF_REG_ADDR);
var uart_state_reg: *volatile u8 = @ptrFromInt(UART_STATE_REG_ADDR);

var tw = TermWriter{};

/// Get a character from the UART.
pub fn getch() ?u8 {
    if (uart_state_reg.* & ~@as(u8, 0x60) > 0) {
        return uart_reg.*;
    } else {
        return null;
    }
}

/// Write a character to the UART.
pub fn uart_write(buf:[]const u8) !void {
    for (buf) |c| uart_reg.* = c;
}

/// Print to the UART and flush. Note that this will pull in ~1.5KB of code (this may be less
/// once the C extensions are implemented.) TODO: fix this comment later
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const w = getWriter();
    w.print(fmt, args) catch {};
    w.flush() catch {};
}

var wbuf: [4096]u8 = undefined;
var cw = TermWriter.init(wbuf[0..]);

pub const WriteError = error{ Unsupported, NotConnected };

pub const TermWriter = struct {
    interface: std.Io.Writer,
    err: ?WriteError = null,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        var ret: usize = 0;

        const b = w.buffered();
        _ = uart_write(b) catch 0;
        _ = w.consume(b.len);

        for (data) |d| {
            _ = uart_write(d) catch 0;
            ret += d.len;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            _ = uart_write(pattern) catch 0;
            ret += pattern.len;
        }

        return ret;
    }

    pub fn init(buf: []u8) TermWriter {
        return TermWriter{
            .interface = .{
                .buffer = buf,
                .vtable = &.{
                    .drain = drain,
                },
            },
        };
    }
};

pub fn getWriter() *std.Io.Writer {
    return &cw.interface;
}
