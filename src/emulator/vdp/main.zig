const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
comptime {
    std.debug.assert(@hasDecl(SDLBackend, "SDLBackend"));
}

const Bus = @import("../device/Bus.zig");
const System = @import("../System.zig");
const Vdp = @import("../Vdp.zig");
const Audio = @import("../Audio.zig");
const ui = @import("../ui.zig");

var gpa: std.mem.Allocator = undefined;
const c = SDLBackend.c;

const vsync = true;
const content_width = 1280;
const content_height = 720;
const frame_time_ns: u64 = 16_627_502; // ~60 FPS

var window: *c.SDL_Window = undefined;
var window_surface: *c.SDL_Surface = undefined;

// VDP thread and double buffering with two SDL surfaces
var vdp_thread: *Vdp.Thread = undefined;
var vdp_queue: Bus.Queue = undefined;
var surfaces: [2]*c.SDL_Surface = undefined;
var front_surface_index: u32 = 0;

// CPU thread and frame synchronization
var system: *System = undefined;
var system_thread: *System.Thread = undefined;

// Audio
var audio_stream: ?*c.SDL_AudioStream = null;
var audio_started: bool = false;
var audio_thread: *Audio.Thread = undefined;
var psg1_queue: Bus.Queue = undefined;
var psg2_queue: Bus.Queue = undefined;

var channel: ui.chan.Channel = undefined;

var run_time: std.time.Timer = undefined;
var frame_count: u64 = 0;
var cpu_pending: u32 = 0;
var vdp_pending: u32 = 0;
var audio_pending: u32 = 0;
var last_blit_time: u64 = 0;

pub fn main(allocator: std.mem.Allocator, rom_path: ?[]const u8) !void {
    if (@import("builtin").os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    SDLBackend.enableSDLLogging();

    channel = ui.chan.Channel.init(allocator);
    defer channel.deinit();

    defer c.SDL_Quit();

    try open_vdp_window(allocator);
    defer destroy_vdp_window();

    try start_audio_thread(allocator);
    defer destroy_audio_thread();

    system = try System.init(rom_path, true, &vdp_queue, &psg1_queue, &psg2_queue, allocator);
    try start_system_thread(allocator);
    defer destroy_system_thread();

    run_time = try std.time.Timer.start();
    last_blit_time = run_time.read();

    while (try process_events(null, null)) {
        if (!try runFrame()) {
            break;
        }
    }
}

pub fn process_events(backend: ?*SDLBackend, dvwin: ?*dvui.Window) !bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) == if (SDLBackend.sdl3) true else 1) {
        const event_window = if (SDLBackend.sdl3) c.SDL_GetWindowFromEvent(&event) else getWindowFromEvent(&event);
        var handled = false;
        if (event_window) |evwin| {
            if (evwin == window) {
                // some global quitting shortcuts
                switch (event.type) {
                    if (SDLBackend.sdl3) c.SDL_EVENT_KEY_DOWN else c.SDL_KEYDOWN => {
                        const key = if (SDLBackend.sdl3) event.key.key else event.key.keysym.sym;
                        const mod = if (SDLBackend.sdl3) event.key.mod else event.key.keysym.mod;
                        const key_q = if (SDLBackend.sdl3) c.SDLK_Q else c.SDLK_q;
                        const kmod_ctrl = if (SDLBackend.sdl3) c.SDL_KMOD_CTRL else c.KMOD_CTRL;
                        if (((mod & kmod_ctrl) > 0) and key == key_q) {
                            return false;
                        }
                    },
                    if (SDLBackend.sdl3) c.SDL_EVENT_QUIT else c.SDL_QUIT => {
                        return false;
                    },

                    else => {},
                }
                if (SDLBackend.sdl3) {
                    if (event.type == c.SDL_EVENT_WINDOW_CLOSE_REQUESTED) return false;
                } else if(event.type == c.SDL_WINDOWEVENT) {
                    if (event.window.event == c.SDL_WINDOWEVENT_CLOSE) {
                        return false;
                    }
                    if (event.window.event == c.SDL_WINDOWEVENT_RESIZED) {
                        // Enforce aspect ratio manually on SDL2
                        const ASPECT_RATIO = @as(f32, @floatFromInt(content_width)) / @as(f32, @floatFromInt(content_height));
                        var new_width = event.window.data1;
                        var new_height = event.window.data2;
                        const new_ratio: f32 = @as(f32, @floatFromInt(new_width)) / @as(f32, @floatFromInt(new_height));

                        if (new_ratio > ASPECT_RATIO) {
                            // Window is "too landscape", reduce width to match height
                            new_width = @intFromFloat(@as(f32, @floatFromInt(new_height)) * ASPECT_RATIO);
                        } else if (new_ratio < ASPECT_RATIO) {
                            // Window is "too portrait", reduce height to match width
                            new_height = @intFromFloat(@as(f32, @floatFromInt(new_width)) / ASPECT_RATIO);
                        }

                        // This attempts to set the window size, is super janky, but kinda works (sometimes)
                        _ = c.SDL_SetWindowSize(window, new_width, new_height);
                    }
                }
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

fn getWindowFromEvent(event: *const c.SDL_Event) ?*c.SDL_Window {
    if (SDLBackend.sdl3) {
        return c.SDL_GetWindowFromEvent(event);
    }

    const windowID: u32 = switch (event.type) {
        c.SDL_WINDOWEVENT => event.window.windowID,
        c.SDL_KEYDOWN, c.SDL_KEYUP => event.key.windowID,
        c.SDL_TEXTEDITING => event.edit.windowID,
        c.SDL_TEXTINPUT => event.text.windowID,
        c.SDL_MOUSEMOTION => event.motion.windowID,
        c.SDL_MOUSEBUTTONDOWN, c.SDL_MOUSEBUTTONUP => event.button.windowID,
        c.SDL_MOUSEWHEEL => event.wheel.windowID,
        c.SDL_USEREVENT => event.user.windowID,
        c.SDL_DROPFILE, c.SDL_DROPTEXT, c.SDL_DROPBEGIN, c.SDL_DROPCOMPLETE => event.drop.windowID,
        else => return null,
    };
    return c.SDL_GetWindowFromID(windowID);
}


/// Main frame loop: coordinate CPU and VDP threads
/// This runs once per monitor refresh (vsync)
pub fn runFrame() !bool {
    const current_time = run_time.read();
    const expected_frames = @max(1, current_time / frame_time_ns);
    var frames_to_do = @min(5, expected_frames - (frame_count + @min(cpu_pending, vdp_pending)));

    // While we are behind, try to catch up by skipping frames and running the CPU as fast as possible
    while (frames_to_do > 1) {
        cpu_pending += 1;
        try system_thread.submitCommand(.fast_frame);

        audio_pending += 1;
        try audio_thread.submitCommand(.fast_frame);

        vdp_pending += 1;
        try submitRenderCommand(true);

        frames_to_do -= 1;
    }

    while (cpu_pending > 0 or vdp_pending > 0) {
        if (channel.receive()) |msg| {
            switch (msg) {
                .cpu_halt => |halt| {
                    std.debug.print("error_level: {}\r\n", .{halt.error_level});

                    return false; // Stop main loop
                },
                .vdp_frame => |result| {
                    vdp_pending -= 1;
                    front_surface_index = result.index;
                    frame_count += 1;
                },
                .cpu_frame => |_| {
                    cpu_pending -= 1;
                },
                .audio_frame => |_| {
                    audio_pending -= 1;
                },
            }
        } else {
            std.debug.print("UI channel prematurely closed: exiting\r\n", .{});
            return false;
        }
    }


    // Queue another frame while we blit and wait for vsync
    if (frames_to_do > 0) {
        cpu_pending += 1;
        try system_thread.submitCommand(.full_frame);

        audio_pending += 1;
        try audio_thread.submitCommand(.full_frame);

        vdp_pending += 1;
        try submitRenderCommand(false);
    }

    writeAudio();

    // Blit front surface to window
    // NOTE: this will wait for vsync
    blitToWindow();
    const current_blit_time = run_time.read();
    const frame_time = current_blit_time - last_blit_time;
    last_blit_time = current_blit_time;

    if (frame_time > (frame_time_ns+(frame_time_ns / 2))) {
        std.debug.print("Warning: Frame took too long: {} us\r\n", .{frame_time/1000});
    }

    return true;
}

fn submitRenderCommand(skip: bool) !void {
    const back_index = 1 - front_surface_index;
    const back_surface = surfaces[back_index];

    try vdp_thread.submitRenderCommand(.{
        .buffer = @ptrCast(@alignCast(back_surface.pixels.?)),
        .width = content_width,
        .height = content_height,
        .pitch = @intCast(@divTrunc(back_surface.pitch, @sizeOf(u32))),
        .skip = skip,
        .index = back_index,
    });
}

fn blitToWindow() void {
    const front_surface = surfaces[front_surface_index];

    var window_w: c_int = 0;
    var window_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &window_w, &window_h);

    const srcrect: c.SDL_Rect = .{ .x = 0, .y = 0, .w = content_width, .h = content_height };
    const dstrect: c.SDL_Rect = .{ .x = 0, .y = 0, .w = window_w, .h = window_h };

    if (SDLBackend.sdl3) {
        _ = c.SDL_BlitSurfaceScaled(front_surface, &srcrect, window_surface, &dstrect, c.SDL_SCALEMODE_NEAREST);
    } else {
        _ = c.SDL_BlitScaled(front_surface, &srcrect, window_surface, @constCast(&dstrect));
    }

    _ = c.SDL_UpdateWindowSurface(window);
}

fn writeAudio() void {
    var audio_buffer: [65536]f32 = undefined;
    var audio_samples: usize = 0;
    var psg1_left = &audio_thread.psg1.left_queue;
    var psg1_right = &audio_thread.psg1.right_queue;
    var psg2_left = &audio_thread.psg2.left_queue;
    var psg2_right = &audio_thread.psg2.right_queue;

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
        if (audio_stream) |stream| {
            if (nonzero and !audio_started) {
                std.debug.print("Audio started at frame {} with {} samples\r\n", .{frame_count, audio_samples});
                audio_started = true;
                _ = c.SDL_ResumeAudioStreamDevice(stream);
            }

            if (audio_started) {
                const size: c_int = @truncate(@as(isize, @bitCast(audio_samples * @sizeOf(f32))));
                _ = c.SDL_PutAudioStreamData(stream, @ptrCast(&audio_buffer[0]), size);
            }
        }
    }
}

pub fn start_system_thread(allocator: std.mem.Allocator) !void {
    system_thread = System.Thread.init(allocator, &channel, &vdp_queue, system) catch |err| {
        std.debug.print("Failed to create CPU thread: {}\n", .{err});
        return error.OutOfMemory;
    };

    system_thread.start() catch {
        std.debug.print("Failed to start CPU thread\n", .{});
        return error.BackendError;
    };
}

pub fn start_audio_thread(allocator: std.mem.Allocator) !void {
    psg1_queue = Bus.Queue.initCapacity(allocator, 0x2000) catch {
        std.debug.print("Failed to create psg1 queue\n", .{});
        return error.OutOfMemory;
    };

    psg2_queue = Bus.Queue.initCapacity(allocator, 0x2000) catch {
        std.debug.print("Failed to create psg2 queue\n", .{});
        return error.OutOfMemory;
    };

    audio_thread = Audio.Thread.init(allocator, &channel, &psg1_queue, &psg2_queue) catch |err| {
        std.debug.print("Failed to create audio thread: {}\n", .{err});
        return error.OutOfMemory;
    };

    audio_thread.start() catch {
        std.debug.print("Failed to start audio thread\n", .{});
        return error.BackendError;
    };
}

pub fn destroy_system_thread() void {
    system_thread.deinit();
    system.deinit(gpa);
}

pub fn destroy_audio_thread() void {
    audio_thread.deinit();
    psg1_queue.deinit(gpa);
    psg2_queue.deinit(gpa);
}

pub fn open_vdp_window(allocator: std.mem.Allocator) !void {
    gpa = allocator;

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO) != if (SDLBackend.sdl3) true else 0) {
        std.debug.print("Couldn't initialize SDL: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    }

    const hidden_flag = if (dvui.accesskit_enabled) c.SDL_WINDOW_HIDDEN else 0;
    const aspect_ratio: f32 = @as(f32, content_width) / @as(f32, content_height);

    if (SDLBackend.sdl3) {
        window = c.SDL_CreateWindow("StarJay Fantasy Console", @as(c_int, @intCast(content_width)), @as(c_int, @intCast(content_height)), c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_RESIZABLE | hidden_flag) orelse {
            std.debug.print("Failed to open window: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
        // Lock aspect ratio during resize
        _ = c.SDL_SetWindowAspectRatio(window, aspect_ratio, aspect_ratio);
        window_surface = c.SDL_GetWindowSurface(window);
        if (vsync) {
            _ = c.SDL_SetWindowSurfaceVSync(window, 1);
        }
        // Create two surfaces for double buffering
        surfaces[0] = c.SDL_CreateSurface(content_width, content_height, c.SDL_PIXELFORMAT_ARGB8888) orelse {
            std.debug.print("Failed to create surface 0: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
        surfaces[1] = c.SDL_CreateSurface(content_width, content_height, c.SDL_PIXELFORMAT_ARGB8888) orelse {
            std.debug.print("Failed to create surface 1: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
        const audio_spec: c.SDL_AudioSpec = .{
            .freq = Audio.Thread.SOUND_SAMPLE_HZ,
            .format = c.SDL_AUDIO_F32,
            .channels = 2,
        };
        audio_stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &audio_spec, null, null) orelse blk: {
            std.debug.print("Failed to open audio stream: {s}\n", .{c.SDL_GetError()});
            break :blk null;
        };
    } else {
        window = c.SDL_CreateWindow("StarJay Fantasy Console", c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, @as(c_int, @intCast(content_width)), @as(c_int, @intCast(content_height)), c.SDL_WINDOW_ALLOW_HIGHDPI | c.SDL_WINDOW_RESIZABLE | hidden_flag) orelse {
            std.debug.print("Failed to open window: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
        window_surface = c.SDL_GetWindowSurface(window);
        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "nearest");
        // Create two surfaces for double buffering
        surfaces[0] = c.SDL_CreateRGBSurfaceWithFormat(0, content_width, content_height, 32, c.SDL_PIXELFORMAT_ARGB8888) orelse {
            std.debug.print("Failed to create surface 0: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
        surfaces[1] = c.SDL_CreateRGBSurfaceWithFormat(0, content_width, content_height, 32, c.SDL_PIXELFORMAT_ARGB8888) orelse {
            std.debug.print("Failed to create surface 1: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
    }

    // Initialize shadow queue for CPU writes to VDP memory
    vdp_queue = Bus.Queue.initCapacity(allocator, 0x200000) catch {
        std.debug.print("Failed to create shadow queue\n", .{});
        return error.OutOfMemory;
    };

    // Initialize VDP thread
    vdp_thread = Vdp.Thread.init(allocator, &vdp_queue, &channel) catch {
        std.debug.print("Failed to create VDP thread\n", .{});
        return error.OutOfMemory;
    };

    // Start the VDP thread
    vdp_thread.start() catch |err| {
        std.debug.print("Failed to start VDP thread: {}\n", .{err});
        return error.BackendError;
    };
}

pub fn destroy_vdp_window() void {
    // Stop VDP thread
    vdp_thread.deinit();

    // Free shadow queue
    vdp_queue.deinit(gpa);

    // Destroy surfaces
    if (SDLBackend.sdl3) {
        _ = c.SDL_DestroySurface(surfaces[0]);
        _ = c.SDL_DestroySurface(surfaces[1]);
        if (audio_stream) |stream| {
            _ = c.SDL_DestroyAudioStream(stream);
            audio_stream = null;
        }
    } else {
        _ = c.SDL_FreeSurface(surfaces[0]);
        _ = c.SDL_FreeSurface(surfaces[1]);
    }
    c.SDL_DestroyWindow(window);
}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
