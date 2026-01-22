// Code from libvaxis: https://github.com/rockorager/libvaxis
// Copyright (c) 2023 Tim Culverhouse - MIT License

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const windows = std.os.windows;


/// The target TTY implementation
pub const Tty = if (builtin.is_test)
    TestTty
else switch (builtin.os.tag) {
    .windows => WindowsTty,
    else => PosixTty,
};

/// global tty instance, used in case of a panic. Not guaranteed to work if
/// for some reason there are multiple TTYs open under a single vaxis
/// compilation unit - but this is better than nothing
pub var global_tty: ?Tty = null;

pub const PosixTty = struct {
    /// the original state of the terminal, prior to calling makeRaw
    termios: posix.termios,

    /// The file descriptor of the tty
    fd: posix.fd_t,

    /// File.Writer for efficient buffered writing
    tty_writer: std.fs.File.Writer,
    tty_reader: std.fs.File.Reader,

    /// initializes a Tty instance by opening /dev/tty and "making it raw".
    pub fn init(read_buffer: []u8, write_buffer: []u8) !PosixTty {
        // Open our tty
        const fd = try posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0);

        // Set the termios of the tty
        const termios = try makeRaw(fd);

        const file = std.fs.File{ .handle = fd };

        const self: PosixTty = .{
            .fd = fd,
            .termios = termios,
            .tty_writer = .initStreaming(file, write_buffer),
            .tty_reader = .initStreaming(file, read_buffer),
        };

        global_tty = self;

        return self;
    }

    /// release resources associated with the Tty return it to its original state
    pub fn deinit(self: PosixTty) void {
        posix.tcsetattr(self.fd, .FLUSH, self.termios) catch |err| {
            std.log.err("couldn't restore terminal: {}", .{err});
        };
        if (builtin.os.tag != .macos) // closing /dev/tty may block indefinitely on macos
            posix.close(self.fd);
    }

    pub fn writer(self: *PosixTty) *std.Io.Writer {
        return &self.tty_writer.interface;
    }

    pub fn reader(self: *PosixTty) *std.Io.Reader {
        return &self.tty_reader.interface;
    }

    /// makeRaw enters the raw state for the terminal.
    pub fn makeRaw(fd: posix.fd_t) !posix.termios {
        const state = try posix.tcgetattr(fd);
        var raw = state;
        // see termios(3)
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = true;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = true;
        raw.lflag.IEXTEN = false;

        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        // never wait for input bytes, return immediately with 0 from read() if none are available
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(fd, .FLUSH, raw);
        return state;
    }
};

pub const WindowsTty = struct {
    stdin: windows.HANDLE,
    stdout: windows.HANDLE,

    initial_codepage: c_uint,
    initial_input_mode: CONSOLE_MODE_INPUT,
    initial_output_mode: CONSOLE_MODE_OUTPUT,

    /// File.Writer for efficient buffered writing
    tty_writer: std.fs.File.Writer,
    tty_reader: std.fs.File.Reader,

    /// The last mouse button that was pressed. We store the previous state of button presses on each
    /// mouse event so we can detect which button was released
    last_mouse_button_press: u16 = 0,

    const utf8_codepage: c_uint = 65001;

    /// The input mode set by init
    pub const input_raw_mode: CONSOLE_MODE_INPUT = .{
    };

    /// The output mode set by init
    pub const output_raw_mode: CONSOLE_MODE_OUTPUT = .{
        .PROCESSED_OUTPUT = 1, // handle control sequences
        .VIRTUAL_TERMINAL_PROCESSING = 1, // handle ANSI sequences
        .DISABLE_NEWLINE_AUTO_RETURN = 1, // disable inserting a new line when we write at the last column
        .ENABLE_LVB_GRID_WORLDWIDE = 1, // enables reverse video and underline
    };

    pub fn init(read_buffer: []u8, write_buffer: []u8) !Tty {
        const stdin: std.fs.File = .stdin();
        const stdout: std.fs.File = .stdout();

        // get initial modes
        const initial_output_codepage = windows.kernel32.GetConsoleOutputCP();
        const initial_input_mode = try getConsoleMode(CONSOLE_MODE_INPUT, stdin.handle);
        const initial_output_mode = try getConsoleMode(CONSOLE_MODE_OUTPUT, stdout.handle);

        // set new modes
        try setConsoleMode(stdin.handle, input_raw_mode);
        try setConsoleMode(stdout.handle, output_raw_mode);
        if (windows.kernel32.SetConsoleOutputCP(utf8_codepage) == 0)
            return windows.unexpectedError(windows.kernel32.GetLastError());

        const self: Tty = .{
            .stdin = stdin.handle,
            .stdout = stdout.handle,
            .initial_codepage = initial_output_codepage,
            .initial_input_mode = initial_input_mode,
            .initial_output_mode = initial_output_mode,
            .tty_writer = .initStreaming(stdout, write_buffer),
            .tty_reader = .initStreaming(stdin, read_buffer),
        };

        // save a copy of this tty as the global_tty for panic handling
        global_tty = self;

        return self;
    }

    pub fn deinit(self: Tty) void {
        _ = windows.kernel32.SetConsoleOutputCP(self.initial_codepage);
        setConsoleMode(self.stdin, self.initial_input_mode) catch {};
        setConsoleMode(self.stdout, self.initial_output_mode) catch {};
        windows.CloseHandle(self.stdin);
        windows.CloseHandle(self.stdout);
    }

    pub const CONSOLE_MODE_INPUT = packed struct(u32) {
        PROCESSED_INPUT: u1 = 0,
        LINE_INPUT: u1 = 0,
        ECHO_INPUT: u1 = 0,
        WINDOW_INPUT: u1 = 0,
        MOUSE_INPUT: u1 = 0,
        INSERT_MODE: u1 = 0,
        QUICK_EDIT_MODE: u1 = 0,
        EXTENDED_FLAGS: u1 = 0,
        AUTO_POSITION: u1 = 0,
        VIRTUAL_TERMINAL_INPUT: u1 = 0,
        _: u22 = 0,
    };
    pub const CONSOLE_MODE_OUTPUT = packed struct(u32) {
        PROCESSED_OUTPUT: u1 = 0,
        WRAP_AT_EOL_OUTPUT: u1 = 0,
        VIRTUAL_TERMINAL_PROCESSING: u1 = 0,
        DISABLE_NEWLINE_AUTO_RETURN: u1 = 0,
        ENABLE_LVB_GRID_WORLDWIDE: u1 = 0,
        _: u27 = 0,
    };

    pub fn getConsoleMode(comptime T: type, handle: windows.HANDLE) !T {
        var mode: u32 = undefined;
        if (windows.kernel32.GetConsoleMode(handle, &mode) == 0) return switch (windows.kernel32.GetLastError()) {
            .INVALID_HANDLE => error.InvalidHandle,
            else => |e| windows.unexpectedError(e),
        };
        return @bitCast(mode);
    }

    pub fn setConsoleMode(handle: windows.HANDLE, mode: anytype) !void {
        if (windows.kernel32.SetConsoleMode(handle, @bitCast(mode)) == 0) return switch (windows.kernel32.GetLastError()) {
            .INVALID_HANDLE => error.InvalidHandle,
            else => |e| windows.unexpectedError(e),
        };
    }

    pub fn writer(self: *Tty) *std.Io.Writer {
        return &self.tty_writer.interface;
    }

    pub fn reader(self: *PosixTty) *std.Io.Reader {
        return &self.tty_reader.interface;
    }
};

pub const TestTty = struct {
    /// Used for API compat
    fd: posix.fd_t,
    pipe_read: posix.fd_t,
    pipe_write: posix.fd_t,
    tty_writer: *std.Io.Writer.Allocating,
    tty_reader: std.fs.File.Reader,

    /// Initializes a TestTty.
    pub fn init(read_buffer: []u8, write_buffer: []u8) !TestTty {
        _ = write_buffer;

        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const list = try std.testing.allocator.create(std.Io.Writer.Allocating);
        list.* = .init(std.testing.allocator);
        const r, const w = try posix.pipe();
        return .{
            .fd = r,
            .pipe_read = r,
            .pipe_write = w,
            .tty_writer = list,
            .tty_reader = std.fs.File.Reader.initStreaming(std.fs.File{ .handle = r }, read_buffer),
        };
    }

    pub fn deinit(self: TestTty) void {
        std.posix.close(self.pipe_read);
        std.posix.close(self.pipe_write);
        self.tty_writer.deinit();
        std.testing.allocator.destroy(self.tty_writer);
    }

    pub fn writer(self: *TestTty) *std.Io.Writer {
        return &self.tty_writer.writer;
    }

    pub fn reader(self: *TestTty) *std.Io.Reader {
        return &self.tty_reader.reader;
    }

    pub fn resetSignalHandler() void {
        return;
    }
};
