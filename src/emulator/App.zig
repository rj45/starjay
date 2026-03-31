const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
comptime {
    std.debug.assert(@hasDecl(SDLBackend, "SDLBackend"));
}

const Bus = @import("device/Bus.zig");
const System = @import("System.zig");
const Vdp = @import("Vdp.zig");
const Audio = @import("Audio.zig");
const ui = @import("ui.zig");

const c = SDLBackend.c;

const vsync = true;
const content_width = 1280;
const content_height = 720;
const window_width = content_width;
const window_height = content_height;
const frame_time_ns: u64 = 16_627_502; // ~60 FPS

const App = @This();

gpa: std.mem.Allocator,

// VDP window
window: *c.SDL_Window = undefined,
window_surface: *c.SDL_Surface = undefined,

// VDP thread and double buffering with two SDL surfaces
vdp_thread: *Vdp.Thread = undefined,
vdp_queue: Bus.Queue = undefined,
surfaces: [2]*c.SDL_Surface = undefined,
front_surface_index: u32 = 0,

// CPU thread
system: *System = undefined,
system_thread: *System.Thread = undefined,

// Audio
audio_stream: ?*c.SDL_AudioStream = null,
audio_started: bool = false,
audio_thread: *Audio.Thread = undefined,
psg1_queue: Bus.Queue = undefined,
psg2_queue: Bus.Queue = undefined,

channel: ui.chan.Channel = undefined,

run_time: std.time.Timer = undefined,
frame_count: u64 = 0,
cpu_pending: u32 = 0,
vdp_pending: u32 = 0,
audio_pending: u32 = 0,
last_blit_time: u64 = 0,
initial_cpu_frame_done: bool = false,

pub fn init(allocator: std.mem.Allocator, rom_path: ?[]const u8) !*App {
    if (@import("builtin").os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    SDLBackend.enableSDLLogging();

    errdefer c.SDL_Quit();

    var app: *App = try allocator.create(App);
    app.* = .{.gpa = allocator};

    app.channel = ui.chan.Channel.init(allocator);
    errdefer app.channel.deinit();

    try app.open_vdp_window();
    errdefer app.destroy_vdp_window();

    try app.start_audio_thread();
    errdefer app.destroy_audio_thread();

    app.system = try System.init(rom_path, true, &app.vdp_queue, &app.psg1_queue, &app.psg2_queue, allocator);
    try app.start_system_thread();
    errdefer app.destroy_system_thread();

    return app;
}

pub fn deinit(self: *App) void {
    self.destroy_system_thread();
    self.destroy_audio_thread();
    self.destroy_vdp_window();
    self.channel.deinit();
    self.gpa.destroy(self);
    c.SDL_Quit();
}

pub fn main_loop(self: *App) !void {
    self.run_time = try std.time.Timer.start();
    self.last_blit_time = self.run_time.read();

    while (try self.process_events(null, null)) {
        if (!try self.runFrame()) {
            break;
        }
    }
}

fn process_events(self: *App, backend: ?*SDLBackend, dvwin: ?*dvui.Window) !bool {
    var hid_queue = &self.system.hid.queue;

    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        const event_window = c.SDL_GetWindowFromEvent(&event);
        var handled = false;
        if (event_window) |evwin| {
            if (evwin == self.window) {
                // some global quitting shortcuts
                switch (event.type) {
                    c.SDL_EVENT_KEY_DOWN => {
                        const scancode: u8 = @truncate(event.key.scancode);
                        _ = hid_queue.tryPush(.{.key = .{
                            .scancode = scancode,
                            .pressed = true,
                        }});
                    },
                    c.SDL_EVENT_KEY_UP => {
                        const scancode: u8 = @truncate(event.key.scancode);
                        _ = hid_queue.tryPush(.{.key = .{
                            .scancode = scancode,
                            .pressed = false,
                        }});
                    },
                    c.SDL_EVENT_QUIT => {
                        return false;
                    },

                    else => {},
                }
                if (event.type == c.SDL_EVENT_WINDOW_CLOSE_REQUESTED) return false;
                handled = true;
            }
        }

        if (!handled) {
            if (backend) |b| {
                if (dvwin) |w| {
                    handled = true;
                    _ = try SDLBackend.addEvent(b, w, event);
                }
            }
        }
    }
    return true;
}

/// Main frame loop: coordinate CPU and VDP threads
/// This runs once per monitor refresh (vsync)
fn runFrame(self: *App) !bool {
    const current_time = self.run_time.read();
    const expected_frames = @max(1, current_time / frame_time_ns);
    var frames_to_do = @min(5, expected_frames - (self.frame_count + @min(self.cpu_pending, self.vdp_pending)));

    if (!self.initial_cpu_frame_done) {
        self.initial_cpu_frame_done = true;
        // Run the CPU one frame ahead of the VDP/PSG so the IO it does is known in advance
        try self.system_thread.submitCommand(.full_frame);
        if (self.channel.receive()) |msg| {
            switch (msg) {
                .cpu_halt => |halt| {
                    std.debug.print("error_level: {}\r\n", .{halt.error_level});

                    return false; // Stop main loop
                },
                .cpu_frame => |_| {},
                else => unreachable, // can't happen
            }
        } else {
            std.debug.print("UI channel prematurely closed: exiting\r\n", .{});
            return false;
        }
    }

    // While we are behind, try to catch up by skipping frames and running the CPU as fast as possible
    while (frames_to_do > 1) {
        self.cpu_pending += 1;
        try self.system_thread.submitCommand(.fast_frame);

        self.audio_pending += 1;
        try self.audio_thread.submitCommand(.fast_frame);

        self.vdp_pending += 1;
        try self.submitRenderCommand(true);

        frames_to_do -= 1;
    }

    while (self.cpu_pending > 0 or self.vdp_pending > 0) {
        if (self.channel.receive()) |msg| {
            switch (msg) {
                .cpu_halt => |halt| {
                    std.debug.print("error_level: {}\r\n", .{halt.error_level});

                    return false; // Stop main loop
                },
                .vdp_frame => |result| {
                    self.vdp_pending -= 1;
                    self.front_surface_index = result.index;
                    self.frame_count += 1;
                },
                .cpu_frame => |_| {
                    self.cpu_pending -= 1;
                },
                .audio_frame => |_| {
                    self.audio_pending -= 1;
                },
            }
        } else {
            std.debug.print("UI channel prematurely closed: exiting\r\n", .{});
            return false;
        }
    }


    // Queue another frame while we blit and wait for vsync
    if (frames_to_do > 0) {
        self.cpu_pending += 1;
        try self.system_thread.submitCommand(.full_frame);

        self.audio_pending += 1;
        try self.audio_thread.submitCommand(.full_frame);

        self.vdp_pending += 1;
        try self.submitRenderCommand(false);
    }

    self.writeAudio();

    // Blit front surface to window
    // NOTE: this will wait for vsync
    self.blitToWindow();
    const current_blit_time = self.run_time.read();
    const frame_time = current_blit_time - self.last_blit_time;
    self.last_blit_time = current_blit_time;

    if (frame_time > (frame_time_ns+(frame_time_ns / 2))) {
        std.debug.print("Warning: Frame took too long: {} us\r\n", .{frame_time/1000});
    }

    return true;
}

fn submitRenderCommand(self: *App, skip: bool) !void {
    const back_index = 1 - self.front_surface_index;
    const back_surface = self.surfaces[back_index];

    try self.vdp_thread.submitRenderCommand(.{
        .buffer = @ptrCast(@alignCast(back_surface.pixels.?)),
        .width = content_width,
        .height = content_height,
        .pitch = @intCast(@divTrunc(back_surface.pitch, @sizeOf(u32))),
        .skip = skip,
        .index = back_index,
    });
}

fn blitToWindow(self: *App) void {
    const front_surface = self.surfaces[self.front_surface_index];

    var window_w: c_int = 0;
    var window_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(self.window, &window_w, &window_h);

    const srcrect: c.SDL_Rect = .{ .x = 0, .y = 0, .w = content_width, .h = content_height };
    const dstrect: c.SDL_Rect = .{ .x = 0, .y = 0, .w = window_w, .h = window_h };

    _ = c.SDL_BlitSurfaceScaled(front_surface, &srcrect, self.window_surface, &dstrect, c.SDL_SCALEMODE_NEAREST);

    _ = c.SDL_UpdateWindowSurface(self.window);
}

fn writeAudio(self: *App) void {
    var audio_buffer: [65536]f32 = undefined;
    var audio_samples: usize = 0;
    var psg1_left = &self.audio_thread.psg1.left_queue;
    var psg1_right = &self.audio_thread.psg1.right_queue;
    var psg2_left = &self.audio_thread.psg2.left_queue;
    var psg2_right = &self.audio_thread.psg2.right_queue;

    var nonzero: bool = false;

    while ((audio_samples + 2) < audio_buffer.len) {
        if (psg1_left.front()) |s1_left| {
            if (psg2_left.front()) |s2_left| {
                if (psg1_right.front()) |s1_right| {
                    if (psg2_right.front()) |s2_right| {
                        // TODO: fix this when properly implementing TurboSound support
                        const factor = @sqrt(0.5);
                        const left_sample = (factor * s1_left.* + factor * s2_left.*);
                        audio_buffer[audio_samples + 0] = left_sample;
                        const right_sample = (factor * s1_right.* + factor * s2_right.*);
                        audio_buffer[audio_samples + 1] = right_sample;
                        audio_samples += 2;

                        if (@abs(left_sample) > 0.00001 or @abs(right_sample) > 0.00001) {
                            nonzero = true;
                        }

                        psg1_left.pop();
                        psg1_right.pop();
                        psg2_left.pop();
                        psg2_right.pop();
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else {
                break;
            }
        } else {
            break;
        }
    }

    if (audio_samples > 0) {
        if (self.audio_stream) |stream| {
            if (nonzero and !self.audio_started) {
                std.debug.print("Audio started at frame {} with {} samples\r\n", .{self.frame_count, audio_samples});
                self.audio_started = true;
                _ = c.SDL_ResumeAudioStreamDevice(stream);
            }

            if (self.audio_started) {
                const size: c_int = @truncate(@as(isize, @bitCast(audio_samples * @sizeOf(f32))));
                _ = c.SDL_PutAudioStreamData(stream, @ptrCast(&audio_buffer[0]), size);
            }
        }
    }
}

fn start_system_thread(self: *App) !void {
    self.system_thread = System.Thread.init(self.gpa, &self.channel, &self.vdp_queue, self.system) catch |err| {
        std.debug.print("Failed to create CPU thread: {}\n", .{err});
        return error.OutOfMemory;
    };

    self.system_thread.start() catch {
        std.debug.print("Failed to start CPU thread\n", .{});
        return error.BackendError;
    };
}

fn start_audio_thread(self: *App) !void {
    self.psg1_queue = Bus.Queue.initCapacity(self.gpa, 0x2000) catch {
        std.debug.print("Failed to create psg1 queue\n", .{});
        return error.OutOfMemory;
    };

    self.psg2_queue = Bus.Queue.initCapacity(self.gpa, 0x2000) catch {
        std.debug.print("Failed to create psg2 queue\n", .{});
        return error.OutOfMemory;
    };

    self.audio_thread = Audio.Thread.init(self.gpa, &self.channel, &self.psg1_queue, &self.psg2_queue) catch |err| {
        std.debug.print("Failed to create audio thread: {}\n", .{err});
        return error.OutOfMemory;
    };

    self.audio_thread.start() catch {
        std.debug.print("Failed to start audio thread\n", .{});
        return error.BackendError;
    };
}

fn destroy_system_thread(self: *App) void {
    self.system_thread.deinit();
    self.system.deinit(self.gpa);
}

fn destroy_audio_thread(self: *App) void {
    self.audio_thread.deinit();
    self.psg1_queue.deinit(self.gpa);
    self.psg2_queue.deinit(self.gpa);
}

fn open_vdp_window(self: *App) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO)) {
        std.debug.print("Couldn't initialize SDL: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    }

    const hidden_flag = if (dvui.accesskit_enabled) c.SDL_WINDOW_HIDDEN else 0;
    const aspect_ratio: f32 = @as(f32, content_width) / @as(f32, content_height);
    const flags = c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_RESIZABLE | hidden_flag;

    self.window = c.SDL_CreateWindow("StarJay Fantasy Console", @as(c_int, @intCast(window_width)), @as(c_int, @intCast(window_height)), flags) orelse {
        std.debug.print("Failed to open window: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    };
    // _ = c.SDL_SetWindowPosition(self.window, 0, 1440 - window_height);
    // Lock aspect ratio during resize
    _ = c.SDL_SetWindowAspectRatio(self.window, aspect_ratio, aspect_ratio);
    if (vsync) {
        _ = c.SDL_SetWindowSurfaceVSync(self.window, 1);
    }
    self.window_surface = c.SDL_GetWindowSurface(self.window);

    // Create two surfaces for double buffering
    self.surfaces[0] = c.SDL_CreateSurface(content_width, content_height, c.SDL_PIXELFORMAT_ARGB8888) orelse {
        std.debug.print("Failed to create surface 0: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    };
    self.surfaces[1] = c.SDL_CreateSurface(content_width, content_height, c.SDL_PIXELFORMAT_ARGB8888) orelse {
        std.debug.print("Failed to create surface 1: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    };
    const audio_spec: c.SDL_AudioSpec = .{
        .freq = Audio.Thread.SOUND_SAMPLE_HZ,
        .format = c.SDL_AUDIO_F32,
        .channels = 2,
    };
    self.audio_stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &audio_spec, null, null) orelse blk: {
        std.debug.print("Failed to open audio stream: {s}\n", .{c.SDL_GetError()});
        break :blk null;
    };

    // Initialize shadow queue for CPU writes to VDP memory
    self.vdp_queue = Bus.Queue.initCapacity(self.gpa, 0x200000) catch {
        std.debug.print("Failed to create shadow queue\n", .{});
        return error.OutOfMemory;
    };

    // Initialize VDP thread
    self.vdp_thread = Vdp.Thread.init(self.gpa, &self.vdp_queue, &self.channel) catch {
        std.debug.print("Failed to create VDP thread\n", .{});
        return error.OutOfMemory;
    };

    // Start the VDP thread
    self.vdp_thread.start() catch |err| {
        std.debug.print("Failed to start VDP thread: {}\n", .{err});
        return error.BackendError;
    };
}

fn destroy_vdp_window(self: *App) void {
    self.vdp_thread.deinit();
    self.vdp_queue.deinit(self.gpa);

    if (self.audio_stream) |stream| {
        _ = c.SDL_DestroyAudioStream(stream);
        self.audio_stream = null;
    }

    _ = c.SDL_DestroySurface(self.surfaces[0]);
    _ = c.SDL_DestroySurface(self.surfaces[1]);

    c.SDL_DestroyWindow(self.window);
}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
