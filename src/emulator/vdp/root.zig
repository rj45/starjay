const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("backend");
comptime {
    std.debug.assert(@hasDecl(SDLBackend, "SDLBackend"));
}

var gpa: std.mem.Allocator = undefined;
pub const c = SDLBackend.c;

const vsync = true;

var window: *c.SDL_Window = undefined;
var renderer: *c.SDL_Renderer = undefined;

pub fn main(allocator: std.mem.Allocator) !void {
    if (@import("builtin").os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    SDLBackend.enableSDLLogging();

    // app_init is a stand-in for what your application is already doing to set things up
    try open_vdp_window(allocator);

    while (try process_events(null, null)) {
        render_vdp_frame();
    }

    destroy_vdp_window();
    c.SDL_Quit();
}

pub fn process_events(backend: ?*SDLBackend, dvwin: ?*dvui.Window) !bool {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) == if (SDLBackend.sdl3) true else 1) {
        const event_window = c.SDL_GetWindowFromEvent(&event);
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

pub fn render_vdp_frame() void {
    // clear the window
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);

    // draw some SDL stuff
    const rect: if (SDLBackend.sdl3) c.SDL_FRect else c.SDL_Rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    var rect2 = rect;
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255);
    _ = c.SDL_RenderFillRect(renderer, &rect2);

    rect2.x += 24;
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, 255);
    _ = c.SDL_RenderFillRect(renderer, &rect2);

    rect2.x += 24;
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 255, 255);
    _ = c.SDL_RenderFillRect(renderer, &rect2);

    _ = c.SDL_SetRenderDrawColor(renderer, 255, 0, 255, 255);

    if (SDLBackend.sdl3) _ = c.SDL_RenderLine(renderer, rect.x, rect.y + 30, rect.x + 100, rect.y + 30) else _ = c.SDL_RenderDrawLine(renderer, rect.x, rect.y + 30, rect.x + 100, rect.y + 30);

    if (SDLBackend.sdl3) {
        _ = c.SDL_RenderPresent(renderer);
    } else {
        c.SDL_RenderPresent(renderer);
    }
}

pub fn open_vdp_window(allocator: std.mem.Allocator) !void {
    gpa = allocator;

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != if (SDLBackend.sdl3) true else 0) {
        std.debug.print("Couldn't initialize SDL: {s}\n", .{c.SDL_GetError()});
        return error.BackendError;
    }

    const hidden_flag = if (dvui.accesskit_enabled) c.SDL_WINDOW_HIDDEN else 0;
    if (SDLBackend.sdl3) {
        window = c.SDL_CreateWindow("StarJay Fantasy Console", @as(c_int, @intCast(1280)), @as(c_int, @intCast(720)), c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_RESIZABLE | hidden_flag) orelse {
            std.debug.print("Failed to open window: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
        renderer = c.SDL_CreateRenderer(window, null) orelse {
            std.debug.print("Failed to create renderer: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
    } else {
        window = c.SDL_CreateWindow("StarJay Fantasy Console", c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, @as(c_int, @intCast(1280)), @as(c_int, @intCast(720)), c.SDL_WINDOW_ALLOW_HIGHDPI | c.SDL_WINDOW_RESIZABLE | hidden_flag) orelse {
            std.debug.print("Failed to open window: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "linear");
        renderer = c.SDL_CreateRenderer(window, -1, if (vsync) c.SDL_RENDERER_PRESENTVSYNC else 0) orelse {
            std.debug.print("Failed to create renderer: {s}\n", .{c.SDL_GetError()});
            return error.BackendError;
        };
    }

    const pma_blend = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD);
    _ = c.SDL_SetRenderDrawBlendMode(renderer, pma_blend);
}

pub fn destroy_vdp_window() void {
    c.SDL_DestroyRenderer(renderer);
    c.SDL_DestroyWindow(window);
}

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
