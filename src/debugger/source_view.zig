const std = @import("std");
const dvui = @import("dvui");

pub fn sourceView() void {
    var vbox = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .border = .all(1) });
    defer vbox.deinit();

    dvui.label(@src(), "Source Area", .{}, .{});
}
