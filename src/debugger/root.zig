const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("backend");
const debugger = @import("debugger.zig");
const vdp = @import("../emulator/vdp/root.zig");

const sourceView = @import("source_view.zig");
const disasm = debugger.disasm;

// TODO: Figure out an icon to embed here
//const window_icon_png = @embedFile("zig-favicon.png");

const WORDSIZE = debugger.emulator.cpu.WORDSIZE;
const SWord = debugger.emulator.cpu.SWord;

const vsync = true;
var scale_val: f32 = 1.0;

const cycles_per_frame: u64 = 10000;

pub fn main(gpa: std.mem.Allocator, show_vdp: bool) !void {
    debugger.allocator = gpa;

    if (@import("builtin").os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere
        // so, attach it manually
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    Backend.enableSDLLogging();

    const memory = try gpa.alloc(u16, 128 * 1024);
    defer gpa.free(memory);

    debugger.cpu = debugger.emulator.cpu.CpuState.init(memory);
    debugger.cpu.log_enabled = false;

    // if the seive.bin file exists, load it into memory at 0x0000
    const seive_path = "starjette/examples/sieve.bin";
    if (std.fs.cwd().statFile(seive_path)) |file_info|  {
        _ = file_info;
        try debugger.cpu.loadRom(seive_path);
        debugger.listing = try disasm.disassemble(debugger.cpu.memory, debugger.allocator);
    } else |err| {
        std.log.info("Could not find seive.bin to load at startup: {any}", .{err});
    }

    defer if (debugger.listing) |l| disasm.deinit(l, debugger.allocator);

    // init SDL backend (creates OS window)
    // initWindow() means the backend calls CloseWindow for you in deinit()
    var backend = try Backend.initWindow(.{
        .allocator = gpa,
        .min_size = .{ .w = 800.0, .h = 600.0 },
        .size = .{ .w = 1400.0, .h = 900.0 },
        .vsync = vsync,
        .title = "StarJay Fantasy Console",
        //.icon = window_icon_png,
    });
    defer backend.deinit();
    // backend.log_events = true;

    _ = Backend.c.SDL_EnableScreenSaver();

    // init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        // you can set the default theme here in the init options
        .theme = switch (backend.preferredColorScheme() orelse .dark) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
    });
    defer win.deinit();

    if (show_vdp) {
        vdp.open_vdp_window(gpa) catch |err| {
            std.log.err("Could not open VDP window: {any}", .{err});
        };
    }
    defer if (show_vdp) vdp.destroy_vdp_window();

    var interrupted = false;

    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);

        try win.begin(nstime);
        if (show_vdp) {
            if (!try vdp.process_events(&backend, &win)) {
                break :main_loop;
            }
        } else {
            _ = try backend.addAllEvents(&win);
        }

        // if dvui widgets might not cover the whole window, then need to clear
        // the previous frame's render
        _ = Backend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 255);
        _ = Backend.c.SDL_RenderClear(backend.renderer);

        const keep_running = try dvui_frame();
        if (!keep_running) break :main_loop;

        const end_micros = try win.end(.{});

        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());

        if (show_vdp) {
            vdp.render_vdp_frame();
        }

        // render frame to OS
        try backend.renderPresent();

        // run the CPU for a fixed number of cycles per frame
        if (debugger.running and !debugger.cpu.halted) {
            for (0..cycles_per_frame) |_| {
                _ = debugger.runForCycles(&debugger.cpu, 1);
                const pc = debugger.cpu.reg.pc;
                if (debugger.listing) |listing| {
                    if (listing.breakpoints.contains(pc)) {
                        debugger.running = false;
                        break;
                    }
                }
            }
        }

        // waitTime and beginWait combine to achieve variable framerates
        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }
}

// return true to keep running
fn dvui_frame() !bool {
    var scaler = dvui.scale(@src(), .{ .scale = &scale_val }, .{ .expand = .both });
    defer scaler.deinit();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .window, .background = true, .expand = .horizontal });
        defer hbox.deinit();

        const wasm_file_id = hbox.widget().extendId(@src(), 0);

        var m = dvui.menu(@src(), .horizontal, .{});
        defer m.deinit();

        if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
            var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
            defer fw.deinit();

            if (dvui.menuItemLabel(@src(), "Open Binary ROM", .{}, .{ .expand = .horizontal }) != null) {
                m.close();

                if (dvui.backend.kind == .web) {
                    dvui.dialogWasmFileOpen(wasm_file_id, .{ .accept = ".bin, .rom" });
                } else if (!dvui.useTinyFileDialogs) {
                    dvui.toast(@src(), .{ .message = "Tiny File Dilaogs disabled" });
                } else {
                    const filename = dvui.dialogNativeFileOpen(dvui.currentWindow().arena(), .{
                        .title = "Load Binary ROM",
                        .filters = &.{ "*.bin", "*.rom" },
                        .filter_description = "ROMs",
                    }) catch |err| blk: {
                        dvui.log.debug("Could not open file dialog, got {any}", .{err});
                        break :blk null;
                    };
                    if (filename) |f|  {
                        debugger.cpu.loadRom(f) catch |err| blk: {
                            dvui.log.debug("Could not open file dialog, got {any}", .{err});
                            break :blk;
                        };
                        if (debugger.listing) |old_listing| {
                            disasm.deinit(old_listing, debugger.allocator);
                        }
                        debugger.listing = try disasm.disassemble(debugger.cpu.memory, debugger.allocator);

                        dvui.toast(@src(), .{.message = "Loaded ROM", .timeout = 10_000_000 });
                    }
                }
            }

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

        if (dvui.backend.kind == .web) upload: {
            if (dvui.wasmFileUploaded(wasm_file_id)) |file| {
                const data = file.readData(dvui.currentWindow().arena()) catch |err| {
                    dvui.log.debug("Could not open file dialog, got {any}", .{err});
                    break :upload;
                };

                @memcpy(debugger.cpu.memory, data);
                if (debugger.listing) |old_listing| {
                    disasm.deinit(old_listing, debugger.allocator);
                }
                debugger.listing = try disasm.disassemble(debugger.cpu.memory, debugger.allocator);
                dvui.toast(@src(), .{.message = "Loaded ROM", .timeout = 10_000_000 });
            }
        }
    }

    // toolbar
    {
        var toolbar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .style = .control, .background = true, .expand = .horizontal });
        defer toolbar.deinit();

        const run_label = if (debugger.running) "Pause" else "Run";
        const run_color: dvui.Theme.Style.Name = if (debugger.running) .err else .highlight;

        if (dvui.button(@src(), run_label, .{}, .{ .style = run_color })) {
            debugger.running = !debugger.running;
        }
        if (dvui.button(@src(), "Step Into", .{}, .{})) {
            _ = debugger.runForCycles(&debugger.cpu, 1);
        }
        if (dvui.button(@src(), "Step Over", .{}, .{})) {
            // TODO: implement step over part
            _ = debugger.runForCycles(&debugger.cpu, 1);
        }

        dvui.label(@src(), "Cycles: {}", .{debugger.cpu.cycles}, .{.gravity_y = 0.5, .margin = .{ .x = 24 }});
    }

    {
        var mainbox = dvui.box(@src(), .{}, .{
            .expand = .both,
            .background = true,
        });
        defer mainbox.deinit();
        {
            var paned = dvui.paned(@src(), .{
                .direction = .horizontal,
                .collapsed_size = 0,
                .handle_margin = 4,
                .autofit_first = .{ .min_split = 0.8, .max_split = 1, .min_size = 50 },
            }, .{ .expand = .both, .background = false });
            defer paned.deinit();

            if (paned.showFirst()) {
                var leftPaned = dvui.paned(@src(), .{
                    .direction = .horizontal,
                    .collapsed_size = 0,
                    .handle_margin = 4,
                    .autofit_first = .{ .min_split = 0.25, .max_split = 0.8, .min_size = 100 },
                }, .{ .expand = .both, .background = false });
                defer leftPaned.deinit();

                if (leftPaned.showFirst()) {
                    var vbox = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .border = .all(1) });
                    defer vbox.deinit();

                    dvui.label(@src(), "Registers", .{}, .{.margin = .{ .h = 8 }});

                    dvui.label(@src(), "pc: 0x{x:0>4}", .{debugger.cpu.reg.pc}, .{});
                    dvui.label(@src(), "fp: 0x{x:0>4}", .{debugger.cpu.reg.fp()}, .{});
                    dvui.label(@src(), "rx: 0x{x:0>4}", .{debugger.cpu.reg.rx}, .{});
                    dvui.label(@src(), "ry: 0x{x:0>4}", .{debugger.cpu.reg.ry}, .{});

                    dvui.label(@src(), "CSRs", .{}, .{.margin = .{ .y = 16, .h = 8 }});
                    dvui.label(@src(), "status: th = {}, ie = {}, km = {}", .{
                        @intFromBool(debugger.cpu.reg.status.th),
                        @intFromBool(debugger.cpu.reg.status.ie),
                        @intFromBool(debugger.cpu.reg.status.km),
                    }, .{});
                    dvui.label(@src(), "estatus: th = {}, ie = {}, km = {}", .{
                        @intFromBool(debugger.cpu.reg.estatus.th),
                        @intFromBool(debugger.cpu.reg.estatus.ie),
                        @intFromBool(debugger.cpu.reg.estatus.km),
                    }, .{});
                    dvui.label(@src(), "epc: 0x{x:0>4}", .{debugger.cpu.reg.epc}, .{});
                    dvui.label(@src(), "afp: 0x{x:0>4}", .{debugger.cpu.reg.afp()}, .{});
                    dvui.label(@src(), "depth: 0x{x:0>4}", .{debugger.cpu.reg.depth}, .{});
                    dvui.label(@src(), "ecause: 0x{x:0>4}", .{debugger.cpu.reg.ecause}, .{});
                    dvui.label(@src(), "evec: 0x{x:0>4}", .{debugger.cpu.reg.evec}, .{});

                    dvui.label(@src(), "Data Stack", .{}, .{.margin = .{ .y = 16, .h = 8 }});
                    if (debugger.cpu.reg.depth > 0) {
                        var stack_area = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .background = true});
                        defer stack_area.deinit();

                        var colWidths = [_]f32{40.0, 70.0, 70.0, 70.0};
                        var grid = dvui.grid(@src(), .colWidths(&colWidths), .{
                            .resize_rows = true,
                        }, .{
                            .expand = .both,
                        });
                        defer grid.deinit();

                        var row_num: usize = 0;
                        for (0..debugger.cpu.reg.depth) |offset| {
                            var cell: dvui.GridWidget.Cell = .colRow(0, row_num);
                            row_num += 1;

                            const value = if (offset == 0) debugger.cpu.reg.tos
                                        else if (offset == 1) debugger.cpu.reg.nos
                                        else if (offset == 2) debugger.cpu.reg.ros
                                        else debugger.cpu.stack[debugger.cpu.reg.depth - 1 - offset];

                            { // label
                                defer cell.col_num += 1;
                                var cell_box = grid.bodyCell(@src(), cell, .{});
                                defer cell_box.deinit();
                                if (offset == 0) {
                                    dvui.label(@src(), "tos", .{}, .{ });
                                } else if (offset == 1) {
                                    dvui.label(@src(), "nos", .{}, .{ });
                                } else if (offset == 2) {
                                    dvui.label(@src(), "ros", .{}, .{ });
                                } else {
                                    dvui.label(@src(), "{}", .{offset+1}, .{ });
                                }
                            }

                            { // hex
                                defer cell.col_num += 1;
                                var cell_box = grid.bodyCell(@src(), cell, .{});
                                defer cell_box.deinit();
                                if (WORDSIZE == 16) {
                                    dvui.label(@src(), "0x{x:0<4}", .{value}, .{ });
                                } else {
                                    dvui.label(@src(), "0x{x:0<8}", .{value}, .{ });
                                }

                            }

                            { // unsigned
                                defer cell.col_num += 1;
                                var cell_box = grid.bodyCell(@src(), cell, .{});
                                defer cell_box.deinit();
                                dvui.label(@src(), "{}", .{value}, .{ });
                            }

                            { // signed
                                defer cell.col_num += 1;
                                var cell_box = grid.bodyCell(@src(), cell, .{});
                                defer cell_box.deinit();
                                const signed_val: SWord = @bitCast(value);
                                dvui.label(@src(), "{}", .{signed_val}, .{ });
                            }
                        }
                    }
                }

                if (leftPaned.showSecond()) {
                    sourceView.sourceView();
                }
            }

            if (paned.showSecond()) {
                var vbox = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .border = .all(1) });
                defer vbox.deinit();

                dvui.label(@src(), "Frame Stack", .{}, .{});
            }


        }

    }

    dvui.Examples.demo();

    for (dvui.events()) |*e| {
        // assume we only have a single window
        if (e.evt == .window and e.evt.window.action == .close) return false;
        if (e.evt == .app and e.evt.app.action == .quit) return false;
    }

    return true;
}
