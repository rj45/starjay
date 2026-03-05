const std = @import("std");
const lib = @import("lib");

pub fn run() void {
    std.debug.print("=== bench_delta_e: deltaE() 1M ops ===\n", .{});

    const n_ops: usize = 1_000_000;

    // Two color pairs to alternate between (prevent constant-folding)
    const a = lib.color.OklabAlpha{ .l = 0.6, .a = 0.2, .b = -0.1, .alpha = 1.0 };
    const b = lib.color.OklabAlpha{ .l = 0.3, .a = -0.15, .b = 0.2, .alpha = 1.0 };
    const c = lib.color.OklabAlpha{ .l = 0.8, .a = 0.05, .b = 0.05, .alpha = 1.0 };
    const d = lib.color.OklabAlpha{ .l = 0.1, .a = -0.1, .b = -0.05, .alpha = 1.0 };

    var result_sum: f32 = 0;
    const start = std.time.nanoTimestamp();
    for (0..n_ops) |i| {
        if (i & 1 == 0) {
            result_sum += lib.color.deltaE(a, b);
        } else {
            result_sum += lib.color.deltaE(c, d);
        }
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;
    const ns_per_op = @divTrunc(elapsed_ns, n_ops);

    std.debug.print("  deltaE: {} ns/op (sum={d:.4})\n", .{ ns_per_op, result_sum });
}
