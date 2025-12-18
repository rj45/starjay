const std = @import("std");
const dvui = @import("dvui");
const debugger = @import("debugger.zig");

var col_widths: [5]f32 = .{ 24.0, 40.0, 20.0, 40.0, 100.0 };
const Word = debugger.emulator.Word;

var scroll_info: dvui.ScrollInfo = .{};
var last_scroll_addr: Word = 0;

pub fn sourceView() void {
    var vbox = dvui.scrollArea(@src(), .{.scroll_info = &scroll_info}, .{ .expand = .horizontal, .background = true, .border = .all(1) });
    defer vbox.deinit();

    dvui.label(@src(), "Source Area", .{}, .{});

    const pc = debugger.cpu.reg.pc;

    if (debugger.listing) |listing| {
        var grid = dvui.grid(@src(), .colWidths(&col_widths), .{
            .resize_rows = true,
        }, .{
            .expand = .both,
        });
        defer grid.deinit();

        // Layout both columns equally, taking up the full width of the grid.
        dvui.columnLayoutProportional(&.{-1, -3, -2, -3, -20 }, &col_widths, grid.data().contentRect().w);

        var row_num: usize = 0;

        for (listing.instructions[0..]) |*dis| {
            var cell: dvui.GridWidget.Cell = .colRow(0, row_num);
            row_num += 1;

            const addr: Word = @intCast(dis.*.address);
            const blk: ?*const debugger.disasm.Block = listing.getBlockForAddress(addr);

            // Check if we need to emit a block label for this address
            if (blk) |b| {
                if (b.address == addr) {
                    if (b.label) |lbl| {
                        { // breakpoint
                            defer cell.col_num += 1;
                            var cell_box = grid.bodyCell(@src(), cell, .{});
                            defer cell_box.deinit();
                        }

                        { // address
                            defer cell.col_num += 1;
                            var cell_box = grid.bodyCell(@src(), cell, .{});
                            defer cell_box.deinit();
                            dvui.label(@src(), "{x:0>4}", .{addr}, .{ });
                        }
                        { // byte
                            defer cell.col_num += 1;
                            var cell_box = grid.bodyCell(@src(), cell, .{});
                            defer cell_box.deinit();
                        }
                        { // label
                            defer cell.col_num += 1;
                            var cell_box = grid.bodyCell(@src(), cell, .{});
                            defer cell_box.deinit();
                            dvui.label(@src(), "{s}:", .{lbl}, .{ });
                        }

                        { // instruction
                            defer cell.col_num += 1;
                            var cell_box = grid.bodyCell(@src(), cell, .{});
                            defer cell_box.deinit();
                        }

                        cell = .colRow(0, row_num);
                        row_num += 1;
                    }
                }
            }

            const highlight = addr == pc;
            const cell_style: dvui.widgets.GridWidget.CellOptions = .{.background = highlight, .color_fill = if (highlight) dvui.themeGet().fill_press else null};

            { // breakpoint column
                defer cell.col_num += 1;

                var cell_box = grid.bodyCell(@src(), cell, cell_style);
                defer cell_box.deinit();

                if (addr == pc and last_scroll_addr != pc) {
                    const one_fifth = scroll_info.viewport.h / 5;
                    const top_threshold = scroll_info.viewport.y + one_fifth;
                    const bottom_threshold = scroll_info.viewport.y + scroll_info.viewport.h - one_fifth;

                    const cell_y = cell_box.data().rect.y;
                    if (cell_y < top_threshold) {
                        // scroll so that cell_y is one_fifth from the top
                        scroll_info.scrollToOffset(.vertical, cell_y - one_fifth);
                    } else if(cell_y > bottom_threshold) {
                        // scroll so that cell_y is one_fifth from the bottom
                        scroll_info.scrollToOffset(.vertical, cell_y - scroll_info.viewport.h + one_fifth);
                    }
                    last_scroll_addr = pc;
                }

                const text = if (listing.breakpoints.contains(addr))
                    "•"
                else " ";

                if (dvui.labelClick(@src(), "{s}", .{text}, .{}, .{ .color_text = dvui.themeGet().err.fill_press })) {
                    listing.breakpoints.put(addr, true) catch {};
                }
            }

            { // address column
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, cell_style);
                defer cell_box.deinit();
                dvui.label(@src(), "{x:0>4}", .{addr}, .{ });
            }

            { // byte column
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, cell_style);
                defer cell_box.deinit();
                dvui.label(@src(), "{x:0>2}", .{dis.*.byte}, .{ });
            }

            { // label column
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, cell_style);
                defer cell_box.deinit();
                dvui.labelNoFmt(@src(), "", .{}, .{ });
            }

            { // instruction column
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, cell_style);
                defer cell_box.deinit();
                switch (dis.*.operand) {
                    .none => dvui.label(@src(), "{s}", .{dis.*.opcode.toMnemonic()}, .{ }),
                    .csr => |*csr| dvui.label(@src(), "{s} {s}", .{dis.*.opcode.toMnemonic(), @tagName(csr.*)}, .{ }),
                    .address => |*address| {
                        const dest = listing.getBlockForAddress(address.*);
                        if (dest) |b| {
                            if (b.label) |lbl| {
                                dvui.label(@src(), "{s} {s}", .{dis.*.opcode.toMnemonic(), lbl}, .{ });
                            } else {
                                dvui.label(@src(), "{s} 0x{x:0>4}", .{dis.*.opcode.toMnemonic(), address.*}, .{ });
                            }
                        } else {
                            dvui.label(@src(), "{s} 0x{x:0>4}", .{dis.*.opcode.toMnemonic(), address.*}, .{ });
                        }
                    },
                    .unsigned => |*imm| {
                        if (dis.*.opcode == .shi) {
                            dvui.label(@src(), "{s} 0x{x:0>2}", .{dis.*.opcode.toMnemonic(), imm.*}, .{ });
                        } else {
                            dvui.label(@src(), "{s} 0x{x:0>4}", .{dis.*.opcode.toMnemonic(), imm.*}, .{ });
                        }
                    },
                    .signed => |*imm| {
                        dvui.label(@src(), "{s} {}", .{dis.*.opcode.toMnemonic(), imm.*}, .{ });
                    },
                }
            }
        }
    }
}
