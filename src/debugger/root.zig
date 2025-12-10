const std = @import("std");
const dvui = @import("dvui");
const RaylibBackend =  dvui.backend;
const raylib = RaylibBackend.raylib;

const colors = @import("colors.zig").colors;
const theme = @import("theme.zig");

// TODO: Figure out an icon to embed here
//const window_icon_png = @embedFile("zig-favicon.png");

const vsync = true;
var scale_val: f32 = 1.0;

pub fn main(gpa: std.mem.Allocator) !void {
    if (@import("builtin").os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere
        // so, attach it manually
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    RaylibBackend.enableRaylibLogging();

    // init Raylib backend (creates OS window)
    // initWindow() means the backend calls CloseWindow for you in deinit()
    var backend = try RaylibBackend.initWindow(.{
        .gpa = gpa,
        .min_size = .{ .w = 800.0, .h = 600.0 },
        .size = .{ .w = 1400.0, .h = 900.0 },
        .vsync = vsync,
        .title = "Starj Fantasy Console",
        //.icon = window_icon_png,
    });
    defer backend.deinit();
    backend.log_events = true;

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        // you can set the default theme here in the init options
        .theme = switch (backend.preferredColorScheme() orelse .dark) {
            .light => theme.light,
            .dark => theme.dark,
        },
    });
    defer win.deinit();

    main_loop: while (true) {
        raylib.beginDrawing();

        const nstime = win.beginWait(true);

        try win.begin(nstime);
        try backend.addAllEvents(&win);
        backend.clear();

        const keep_running = dvui_frame();
        if (!keep_running) break :main_loop;

        const end_micros = try win.end(.{});

        backend.setCursor(win.cursorRequested());

        const wait_event_micros = win.waitTime(end_micros);
        backend.EndDrawingWaitEventTimeout(wait_event_micros);
    }
}

// return true to keep running
fn dvui_frame() bool {
    var scaler = dvui.scale(@src(), .{ .scale = &scale_val }, .{ .expand = .both });
    defer scaler.deinit();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .window, .background = true, .expand = .horizontal });
        defer hbox.deinit();

        var m = dvui.menu(@src(), .horizontal, .{});
        defer m.deinit();

        if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();

            if (dvui.menuItemLabel(@src(), "Exit", .{}, .{ .expand = .horizontal }) != null) {
                return false;
            }
        }

        if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            if (dvui.menuItemLabel(@src(), "Zoom In", .{}, .{ .expand = .horizontal }) != null) {
                scale_val = @round(dvui.themeGet().font_body.size * scale_val + 1.0) / dvui.themeGet().font_body.size;
            }
            if (dvui.menuItemLabel(@src(), "Zoom Out", .{}, .{ .expand = .horizontal }) != null) {
                scale_val = @round(dvui.themeGet().font_body.size * scale_val - 1.0) / dvui.themeGet().font_body.size;
            }
            if (dvui.menuItemLabel(@src(), "Reset Zoom", .{}, .{ .expand = .horizontal }) != null) {
                scale_val = 1.0;
                m.close();
            }
        }


        if (dvui.menuItemLabel(@src(), "Debug", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();
            const label = if (dvui.Examples.show_demo_window) "Hide Demo" else "Show Demo";
            if (dvui.menuItemLabel(@src(), label, .{}, .{ .expand = .horizontal }) != null) {
                dvui.Examples.show_demo_window = !dvui.Examples.show_demo_window;
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Dvui Debug", .{}, .{ .expand = .horizontal }) != null) {
                dvui.toggleDebugWindow();
                m.close();
            }
        }
    }

    // toolbar
    {
        var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .control, .background = true, .expand = .horizontal });
        defer toolbar.deinit();

        if (dvui.button(@src(), "Run", .{}, .{ .style = .highlight })) {
            // do something
        }
        if (dvui.button(@src(), "Step Into", .{}, .{})) {
            // do something
        }
        if (dvui.button(@src(), "Step Over", .{}, .{})) {
            // do something
        }
        if (dvui.button(@src(), "Snapshot", .{}, .{})) {
            // do something
        }
        if (dvui.button(@src(), "Restore", .{}, .{})) {
            // do something
        }
    }

    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
            .background = true,
        });
        defer scroll.deinit();


    }

    dvui.Examples.demo();

    for (dvui.events()) |*e| {
        // assume we only have a single window
        if (e.evt == .window and e.evt.window.action == .close) return false;
        if (e.evt == .app and e.evt.app.action == .quit) return false;
    }

    return true;
}
