const std = @import("std");
const dvui = @import("dvui");
const debugger = @import("debugger.zig");

var col_widths: [5]f32 = .{ 20.0, 40.0, 20.0, 40.0, 100.0 };
const Word = debugger.emulator.Word;

// var breakpoints = std.AutoHashMap(u16, bool).init(debugger.allocator);

pub fn sourceView() void {
    var vbox = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .background = true, .border = .all(1) });
    defer vbox.deinit();

    dvui.label(@src(), "Source Area", .{}, .{});

    if (debugger.listing) |listing| {
        var grid = dvui.grid(@src(), .colWidths(&col_widths), .{
            .resize_rows = true,
        }, .{
            .expand = .both,
        });
        defer grid.deinit();

        // Layout both columns equally, taking up the full width of the grid.
        dvui.columnLayoutProportional(&.{-1, -3, -2, -3, -30 }, &col_widths, grid.data().contentRect().w);

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

            { // breakpoint column
                defer cell.col_num += 1;

                var cell_box = grid.bodyCell(@src(), cell, .{});
                defer cell_box.deinit();
                if (dvui.button(@src(), " ", .{}, .{ .rect = .{.w = 20, .h = 20} })) {
                    // if (breakpoints.get(addr)) |bp| {
                    //     _ = bp;
                    //     breakpoints.remove(addr);
                    // } else {
                    //     _ = breakpoints.put(addr, true);
                    // }
                }
            }

            { // address column
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, .{});
                defer cell_box.deinit();
                dvui.label(@src(), "{x:0>4}", .{addr}, .{ });
            }

            { // byte column
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, .{});
                defer cell_box.deinit();
                dvui.label(@src(), "{x:0>2}", .{dis.*.byte}, .{ });
            }

            { // label column
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, .{});
                defer cell_box.deinit();
            }

            { // instruction column
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, .{});
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
