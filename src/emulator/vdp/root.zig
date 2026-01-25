const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
comptime {
    std.debug.assert(@hasDecl(SDLBackend, "SDLBackend"));
}

const Bus = @import("../device/Bus.zig");
pub const VdpState = @import("VdpState.zig");
pub const VdpThread = @import("VdpThread.zig");
pub const CpuThread = @import("../riscv/CpuThread.zig");

var gpa: std.mem.Allocator = undefined;
pub const c = SDLBackend.c;

const vsync = true;
const content_width = 1280;
const content_height = 720;
const frame_time_ns: u64 = 16_627_502; // ~60 FPS

var window: *c.SDL_Window = undefined;
var window_surface: *c.SDL_Surface = undefined;

// VDP thread and double buffering with two SDL surfaces
var vdp_thread: *VdpThread = undefined;
var shadow_queue: Bus.Queue = undefined;
var surfaces: [2]*c.SDL_Surface = undefined;
var front_surface_index: u32 = 0;

// CPU thread and frame synchronization
var cpu_thread: ?*CpuThread = null;
var frame_futex: std.atomic.Value(u32) = .init(0);

var run_time: std.time.Timer = undefined;
var frame_count: u64 = 0;
var pending_frames: u64 = 0;
var last_blit_time: u64 = 0;

pub fn main(allocator: std.mem.Allocator, rom_path: ?[]const u8) !void {
    if (@import("builtin").os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    SDLBackend.enableSDLLogging();

    run_time = try std.time.Timer.start();

    // app_init is a stand-in for what your application is already doing to set things up
    try open_vdp_window(allocator);

    // Start CPU thread if ROM is provided
    if (rom_path) |path| {
        try start_cpu_thread(allocator, path);
    }

    while (try process_events(null, null)) {
        if (!run_frame()) {
            break;
        }
    }

    destroy_vdp_window();
    destroy_cpu_thread();

    c.SDL_Quit();
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
pub fn run_frame() bool {
    const current_time = run_time.read();
    const expected_frames = @max(1, current_time / frame_time_ns);
    var frames_to_do = @min(3, expected_frames - (frame_count + pending_frames));

    // While we are behind, try to catch up by skipping frames and running the CPU as fast as possible
    while (frames_to_do > 1) {
        if (cpu_thread) |cpu| {
            cpu.submitCommand(.run_frame);
        }
        submitVdpRenderRequest(true);
        pending_frames += 1;
        frames_to_do -= 1;

        // If the frame_futex is the expected value (1)
        if (frame_futex.cmpxchgWeak(1, 0, .release, .acquire) == null) {
            // Wake any waiting threads
            std.Thread.Futex.wake(&frame_futex, 10);
        }
    }

    var cpu_pending = pending_frames;
    var vdp_pending = pending_frames;

    while (cpu_pending > 0 or vdp_pending > 0) {
        // Check for CPU frame completion
        if (cpu_pending > 0) {
            if (cpu_thread) |cpu| {
                if (cpu.tryGetCompletion()) |result| {
                    cpu_pending -= 1;

                    switch (result) {
                        .cpu_halted => |error_level| {
                            std.debug.print("error_level: {}\r\n", .{error_level});

                            return false; // Stop main loop
                        },
                        .frame_complete => {
                            // Normal frame completion
                        },
                    }
                }
            } else {
                // No CPU thread, assume frame is done
                cpu_pending -= 1;
            }
        }

        // Check for VDP render completion
        if (vdp_pending > 0) {
            if (vdp_thread.tryGetResult()) |result| {
                vdp_pending -= 1;
                front_surface_index = result.index;
                frame_count += 1;
                pending_frames -= 1;
            }
        }

        std.atomic.spinLoopHint();

        // TODO: sleep?
    }

    // Queue another frame while we blit and wait for vsync
    if (frames_to_do > 0) {
        if (cpu_thread) |cpu| {
            cpu.submitCommand(.run_frame);
        }
        submitVdpRenderRequest(false);
        pending_frames += 1;

        // If the frame_futex is the expected value (1)
        if (frame_futex.cmpxchgWeak(1, 0, .release, .acquire) == null) {
            // Wake any waiting threads
            std.Thread.Futex.wake(&frame_futex, 10);
        }
    }

    // Blit front surface to window
    // NOTE: this will wait for vsync
    blitToWindow();
    const current_blit_time = run_time.read();
    // const frame_time = current_blit_time - last_blit_time;
    last_blit_time = current_blit_time;

    // if (frame_time > (frame_time_ns+(frame_time_ns / 2))) {
    //     std.debug.print("Warning: Blit took too long: {} us\r\n", .{frame_time/1000});
    // }

    return true;
}

fn submitVdpRenderRequest(skip: bool) void {
    const back_index = 1 - front_surface_index;
    const back_surface = surfaces[back_index];

    vdp_thread.submitRenderRequest(.{
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

pub fn start_cpu_thread(allocator: std.mem.Allocator, rom_path: []const u8) !void {
    cpu_thread = CpuThread.init(allocator, &frame_futex, &shadow_queue, rom_path) catch |err| {
        std.debug.print("Failed to create CPU thread: {}\n", .{err});
        return error.OutOfMemory;
    };

    cpu_thread.?.start() catch {
        std.debug.print("Failed to start CPU thread\n", .{});
        return error.BackendError;
    };
}

pub fn destroy_cpu_thread() void {
    if (cpu_thread) |cpu| {
        cpu.deinit();
        cpu_thread = null;
    }
}

pub fn open_vdp_window(allocator: std.mem.Allocator) !void {
    gpa = allocator;

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != if (SDLBackend.sdl3) true else 0) {
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
    shadow_queue = Bus.Queue.initCapacity(allocator, 0x200000) catch {
        std.debug.print("Failed to create shadow queue\n", .{});
        return error.OutOfMemory;
    };

    // Initialize VDP thread
    vdp_thread = VdpThread.init(allocator, &shadow_queue, &frame_futex) catch {
        std.debug.print("Failed to create VDP thread\n", .{});
        return error.OutOfMemory;
    };

    // Start the VDP thread
    vdp_thread.start() catch {
        std.debug.print("Failed to start VDP thread\n", .{});
        return error.BackendError;
    };

    last_blit_time = run_time.read();
}

pub fn destroy_vdp_window() void {
    // Stop VDP thread
    vdp_thread.deinit();

    // Free shadow queue
    shadow_queue.deinit(gpa);

    // Destroy surfaces
    if (SDLBackend.sdl3) {
        _ = c.SDL_DestroySurface(surfaces[0]);
        _ = c.SDL_DestroySurface(surfaces[1]);
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
