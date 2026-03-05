const std = @import("std");
const lib = @import("lib");

pub fn run(gpa: std.mem.Allocator) !void {
    std.debug.print("=== bench_kmeans: k-means 16 colors on 1000 random 3D points ===\n", .{});

    // Generate 1000 random 3D points (simulating OKLab colors)
    const n_points: usize = 1000;
    const n_clusters: usize = 16;
    const n_runs: usize = 20;

    var prng = std.Random.DefaultPrng.init(12345);
    const rand = prng.random();

    // Allocate points
    const data = try gpa.alloc([]f32, n_points);
    defer {
        for (data) |row| gpa.free(row);
        gpa.free(data);
    }
    for (data) |*row| {
        row.* = try gpa.alloc(f32, 3);
        row.*[0] = rand.float(f32); // L
        row.*[1] = (rand.float(f32) - 0.5); // a
        row.*[2] = (rand.float(f32) - 0.5); // b
    }

    // Benchmark: run k-means n_runs times, measure total time
    const start = std.time.nanoTimestamp();
    for (0..n_runs) |_| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Copy data for this run (k-means modifies it via scaling)
        const run_data = try alloc.alloc([]f32, n_points);
        for (data, 0..) |row, i| {
            run_data[i] = try alloc.alloc(f32, 3);
            @memcpy(run_data[i], row);
        }

        var km = lib.kmeans.KMeans(f32, null, null, null, null){
            .allocator = alloc,
            .n_clusters = n_clusters,
            .max_it = 50,
        };
        try km.fit(run_data);
    }
    const elapsed_ns = std.time.nanoTimestamp() - start;
    const ns_per_op = @divTrunc(elapsed_ns, n_runs);
    std.debug.print("  k-means({} points, {} clusters, 50 iter): {} ms/op\n", .{
        n_points, n_clusters, @divTrunc(ns_per_op, 1_000_000),
    });
}
