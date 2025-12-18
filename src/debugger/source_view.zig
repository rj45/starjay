const std = @import("std");
const dvui = @import("dvui");
const debugger = @import("debugger.zig");

var col_widths: [4]f32 = .{ 20.0, 40.0, 20.0, 100.0 };

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
        dvui.columnLayoutProportional(&.{-1, -3, -2, -30 }, &col_widths, grid.data().contentRect().w);

        for (listing.instructions[0..], 0..) |*dis, row_num| {
            var cell: dvui.GridWidget.Cell = .colRow(0, row_num);

            const addr: u16 = @intCast(dis.*.address);

            {
                defer cell.col_num += 1;

                var cell_box = grid.bodyCell(@src(), cell, .{});
                defer cell_box.deinit();
                if (dvui.button(@src(), " ", .{}, .{ .gravity_y = 0.5 })) {
                    // if (breakpoints.get(addr)) |bp| {
                    //     _ = bp;
                    //     breakpoints.remove(addr);
                    // } else {
                    //     _ = breakpoints.put(addr, true);
                    // }
                }
            }

            {
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, .{});
                defer cell_box.deinit();
                dvui.label(@src(), "{x:0>4}", .{addr}, .{ .gravity_y = 0.5 });
            }

            {
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, .{});
                defer cell_box.deinit();
                dvui.label(@src(), "{x:0>2}", .{dis.*.byte}, .{ .gravity_y = 0.5 });
            }

            {
                defer cell.col_num += 1;
                var cell_box = grid.bodyCell(@src(), cell, .{});
                defer cell_box.deinit();
                switch (dis.*.operand) {
                    .none => dvui.label(@src(), "{s}", .{dis.*.opcode.toMnemonic()}, .{ .gravity_y = 0.5 }),
                    .csr => |*csr| dvui.label(@src(), "{s} {s}", .{dis.*.opcode.toMnemonic(), @tagName(csr.*)}, .{ .gravity_y = 0.5 }),
                    .address => |*address| {
                        const blk = listing.getBlockForAddress(address.*);
                        if (blk) |b| {
                            if (b.label) |lbl| {
                                dvui.label(@src(), "{s} {s}", .{dis.*.opcode.toMnemonic(), lbl}, .{ .gravity_y = 0.5 });
                            } else {
                                dvui.label(@src(), "{s} 0x{x:0>4}", .{dis.*.opcode.toMnemonic(), address.*}, .{ .gravity_y = 0.5 });
                            }
                        } else {
                            dvui.label(@src(), "{s} 0x{x:0>4}", .{dis.*.opcode.toMnemonic(), address.*}, .{ .gravity_y = 0.5 });
                        }
                    },
                    .unsigned => |*imm| {
                        dvui.label(@src(), "{s} 0x{x:0>4}", .{dis.*.opcode.toMnemonic(), imm.*}, .{ .gravity_y = 0.5 });
                    },
                    .signed => |*imm| {
                        dvui.label(@src(), "{s} {}", .{dis.*.opcode.toMnemonic(), imm.*}, .{ .gravity_y = 0.5 });
                    },
                }
            }
        }
    }
}
