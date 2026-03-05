const std = @import("std");

pub const OutputWriter = struct {
    pub fn write(_: @This(), _: []const u8) !void {
        return error.NotImplemented;
    }
};
