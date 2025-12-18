const std = @import("std");
const dvui = @import("dvui");
const debugger = @import("debugger.zig");

var col_widths: [3]f32 = .{ 20.0, 50.0, 100.0 };

// var breakpoints = std.AutoHashMap(u16, bool).init(debugger.allocator);

pub fn sourceView() void {
    var vbox = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .background = true, .border = .all(1) });
    defer vbox.deinit();

    dvui.label(@src(), "Source Area", .{}, .{});

    if (debugger.disasm.disassembly) |listing| {
        var grid = dvui.grid(@src(), .colWidths(&col_widths), .{
            .resize_rows = true,
        }, .{
            .expand = .both,
        });
        defer grid.deinit();

        // Layout both columns equally, taking up the full width of the grid.
        dvui.columnLayoutProportional(&.{-1, -2,  -20 }, &col_widths, grid.data().contentRect().w);

        for (listing[0..], 0..) |*dis, row_num| {
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
                if (dis.*.immediate) |imm| {
                    dvui.label(@src(), "{s} {}", .{dis.*.instr.toMnemonic(), imm}, .{ .gravity_y = 0.5 });
                } else {
                    dvui.label(@src(), "{s}", .{dis.*.instr.toMnemonic()}, .{ .gravity_y = 0.5 });
                }
            }
        }
    }
}
