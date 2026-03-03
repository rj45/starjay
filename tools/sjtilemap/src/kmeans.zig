//! K-Means in Zig
//! Copied from https://github.com/KlimentLagrangiewicz/k-means-in-Zig
//! License: unknown
//! Copyright (c) 2025 Kliment Lagrangiewicz

const std = @import("std");

const simd = @import("std").simd;

fn checkSlicesLen(comptime T: type, x: []const []const T) !bool {
    const lenFirst = x.ptr[0].len;

    for (x[1..]) |xi| if (xi.len != lenFirst) return false;
    return true;
}

fn free(comptime T: type, x: *[][]T, allocator: std.mem.Allocator) !void {
    if (x.*.len != 0) {
        for (x.*) |*xi| allocator.free(xi.*);
        allocator.free(x.*);
    }
}

fn copyMatr(comptime T: type, x: []const []const T, allocator: std.mem.Allocator) ![][]T {
    const res: [][]T = try allocator.alloc([]T, x.len);
    for (x, res) |xi, *resi| {
        resi.* = try allocator.alloc(T, xi.len);
        @memcpy(resi.*, xi);
    }
    return res;
}

pub fn KMeans(comptime T: type, allocator: ?std.mem.Allocator, k: ?usize, _tol: ?T, _max_it: ?u64) type {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    return struct {
        centers: ?[][]T = null, // cluster centers
        n_clusters: usize = if (k) |v| v else 0, // number of clusters
        allocator: std.mem.Allocator = if (allocator) |alloc| alloc else std.heap.c_allocator, // memory allocator
        tol: ?T = _tol,
        max_it: ?u64 = _max_it,

        // initializator
        pub fn init(self: *@This(), n_clusters: usize, _tol_: ?T, _max_it_: ?u64) !void {
            self.n_clusters = n_clusters;
            self.tol = _tol_;
            self.max_it = _max_it_;
        }

        // returns reference on cluster centers
        pub fn getCenters(self: @This()) ![][]T {
            if (self.centers) |c| return c;
            return error.EmptyCenters;
        }

        // returns copy of cluster centers
        pub fn getCentersCopy(self: @This()) ![][]T {
            if (self.centers) |c| return try copyMatr(T, c, self.allocator);
            return error.EmptyCenters;
        }

        // returns number of clusters
        pub fn getNumOfClusters(self: @This()) usize {
            return self.n_clusters;
        }

        // returns allocator
        pub fn getAllocator(self: @This()) std.mem.Allocator {
            return self.allocator;
        }

        // returns maximum number of iterations
        pub fn getNumOfIterations(self: @This()) !u64 {
            return if (self.max_it) |max_it_v| max_it_v else error.UndefinedValue;
        }

        //
        pub fn getTol(self: @This()) !T {
            return if (self.tol) |tol_v| tol_v else error.UndefinedValue;
        }

        //
        pub fn fit(self: *@This(), x: [][]T) !void {
            if (x.len == 0 or self.n_clusters == 0) return error.ErrorFit;

            if (self.n_clusters > x.len) return error.IncorrectDataForFit;

            if (self.centers) |_| {
                try free(T, &(self.centers.?), self.allocator);
                self.centers = null;
            }

            if (self.tol) |tol_v| {
                if (self.max_it) |max_iter_v| {
                    if (tol_v <= 0.0) {
                        if (max_iter_v < 1) {
                            self.centers = try kmeansCores(T, x, self.n_clusters, self.allocator);
                        } else {
                            self.centers = try kmeansCoresWithMaxIter(T, x, self.n_clusters, self.allocator, max_iter_v);
                        }
                    } else {
                        if (max_iter_v < 1) {
                            self.centers = try kmeansCoresWithTol(T, x, self.n_clusters, self.allocator, tol_v);
                        } else {
                            self.centers = try kmeansCoresWithTolAndMaxIter(T, x, self.n_clusters, self.allocator, tol_v, max_iter_v);
                        }
                    }
                } else {
                    if (tol_v <= 0.0) {
                        self.centers = try kmeansCores(T, x, self.n_clusters, self.allocator);
                    } else {
                        self.centers = try kmeansCoresWithTol(T, x, self.n_clusters, self.allocator, tol_v);
                    }
                }
            } else {
                if (self.max_it) |max_iter_v| {
                    if (max_iter_v < 1) {
                        self.centers = try kmeansCores(T, x, self.n_clusters, self.allocator);
                    } else {
                        self.centers = try kmeansCoresWithMaxIter(T, x, self.n_clusters, self.allocator, max_iter_v);
                    }
                } else {
                    self.centers = try kmeansCores(T, x, self.n_clusters, self.allocator);
                }
            }
        }

        // get predictions
        pub fn predict(self: *@This(), x: []const []const T) ![]usize {
            if (x.len == 0) return error.EmptyInput;
            if (!try checkSlicesLen(T, x)) return error.UnequalLenOfInput;

            if (self.centers) |_| {
                if ((self.centers.?).len == 0 or (self.centers.?)[0].len != x[0].len) {
                    if (self.n_clusters == 0) return error.EmptyNumOfClusters;

                    const y = try kmeansY(T, x, self.n_clusters, self.allocator);

                    try free(T, &(self.centers.?), self.allocator);
                    self.centers.? = try calcCores(T, x, y, self.n_clusters, self.allocator);

                    return y;
                }
                return try getPartition(T, x, self.centers.?, self.allocator);
            }

            if (self.n_clusters == 0) return error.EmptyNumOfClusters;
            const y = try kmeansY(T, x, self.n_clusters, self.allocator);
            self.centers = try calcCores(T, x, y, self.n_clusters, self.allocator);
            return y;
        }

        // de-facto destructor
        pub fn deinit(self: *@This()) void {
            if (self.centers) |_| {
                try free(T, &(self.centers.?), self.allocator);
                self.centers = null;
            }
            self.n_clusters = 0;
        }
    };
}

// returns Euclidean distance between `y` and `x`
// pub fn getDistance(comptime T: type, y: []const T, x: []const T) !T {
//     if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
//     if (y.len != x.len) return error.DimensionsMismatch;

//     var sum: T = 0.0;
//     for (y, x) |yi, xi| {
//         const d = yi - xi;
//         sum += d * d;
//     }
//     return sum;
// }

// SIMD Euclidean distance between `a` and `b`
pub fn getDistance(comptime T: type, a: []const T, b: []const T) !T {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    if (a.len != b.len)
        return error.DimensionsMismatch;

    const vec_len = simd.suggestVectorLength(T) orelse 1;

    const Vector = @Vector(vec_len, T);
    var sum_sq: T = 0.0;

    var i: usize = 0;
    const end = a.len - (a.len % vec_len);

    while (i < end) : (i += vec_len) {
        const va = @as(Vector, a[i..][0..vec_len].*);
        const vb = @as(Vector, b[i..][0..vec_len].*);
        const d = va - vb;
        sum_sq += @reduce(.Add, d * d);
    }

    while (i < a.len) : (i += 1) {
        const diff = a[i] - b[i];
        sum_sq += diff * diff;
    }

    return sum_sq;
}

// scaler: x = (x - { mean of x }) / sqrt({ dispersion of x })
pub fn scaling(comptime T: type, x: []const []T) !void {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    const n: usize = x.len;
    const m: usize = x[0].len;
    for (0..m) |j| {
        var ex: T = 0.0;
        var exx: T = 0.0;
        for (x) |xi| {
            const v = xi[j];
            ex += v;
            exx += v * v;
        }
        ex /= @floatFromInt(n);
        exx = exx / @as(T, @floatFromInt(n)) - ex * ex;
        exx = if (exx == 0.0) 1.0 else 1.0 / std.math.sqrt(exx);

        for (x) |*xi| {
            xi.*[j] = (xi.*[j] - ex) * exx;
        }
    }
}

// returns number of cluster for point `x`
fn getCluster(comptime T: type, x: []const T, c: []const []const T) !usize {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    var res: usize = 0;
    var min_d: T = std.math.floatMax(T);

    for (c, 0..) |ci, i| {
        const cur_d: T = try getDistance(T, x, ci);
        if (cur_d < min_d) {
            min_d = cur_d;
            res = i;
        }
    }

    return res;
}

fn contain(comptime T: type, y: []const T, val: T) !bool {
    for (y) |yi| if (yi == val) return true;
    return false;
}

test "test 1 contain fun" {
    const x = [_]usize{ 0, 1 };

    try std.testing.expectEqual(true, try contain(usize, &x, 1));
}

test "test 2 contain fun" {
    const x = [_]usize{ 0, 1 };

    try std.testing.expectEqual(false, try contain(usize, &x, 3));
}

test "test 3 contain fun" {
    const x = [_]usize{};

    try std.testing.expectEqual(false, try contain(usize, &x, 1));
}

fn getUnique(n: usize, k: usize, allocator: std.mem.Allocator) ![]usize {
    if (k > n) return error.ImpossibilityGenUniq;

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp() - std.time.timestamp() * @as(comptime_int, 1000)));
    const rnd = prng.random();
    const res: []usize = try allocator.alloc(usize, k);
    for (0..k) |i| {
        var val = rnd.intRangeAtMost(usize, 0, n - 1);
        while (try contain(usize, res[0..i], val)) : (val = rnd.intRangeAtMost(usize, 0, n - 1)) {}

        res[i] = val;
    }

    return res;
}

fn detCores(comptime T: type, x: []const []const T, k: usize, allocator: std.mem.Allocator) ![][]T {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    const m = x[0].len;
    const nums = try getUnique(x.len, k, allocator);
    defer allocator.free(nums);

    const c: [][]T = try allocator.alloc([]T, k);
    for (c, nums) |*ci, idx| {
        ci.* = try allocator.alloc(T, m);
        @memcpy(ci.*, x[idx]);
    }

    return c;
}

fn getPartition(comptime T: type, x: []const []const T, c: []const []const T, allocator: std.mem.Allocator) ![]usize {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    const y: []usize = try allocator.alloc(usize, x.len);

    for (x, y) |xi, *yi| yi.* = try getCluster(T, xi, c);

    return y;
}

fn kmeansY(comptime T: type, x: []const []const T, k: usize, allocator: std.mem.Allocator) ![]usize {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    const c: [][]T = try detCores(T, x, k, allocator);
    defer {
        for (c) |*ci| allocator.free(ci.*);
        allocator.free(c);
    }

    const new_c = try allocator.alloc([]T, k);
    for (new_c) |*new_ci| new_ci.* = try allocator.alloc(T, c[0].len);

    defer {
        for (new_c) |*new_ci| allocator.free(new_ci.*);
        allocator.free(new_c);
    }

    const nums = try allocator.alloc(usize, k);
    defer allocator.free(nums);

    const y: []usize = try allocator.alloc(usize, x.len);

    @memset(y, 0);

    while (try checkPartition(T, x, c, new_c, y, nums)) {}

    return y;
}

// fn addToCore(comptime T: type, ci: []T, xi: []const T) !void {
//     if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
//     if (ci.len != xi.len) return error.DimensionsMismatch;
//     for (ci, xi) |*cij, xij| cij.* += xij;
// }

fn addToCore(comptime T: type, ci: []T, xi: []const T) !void {
    if (ci.len != xi.len) return error.DimensionsMismatch;

    const vec_len: comptime_int = comptime simd.suggestVectorLength(T) orelse 1;
    const vec = @Vector(vec_len, T);

    var i: usize = 0;
    const simd_end = ci.len - ci.len % vec_len;

    while (i < simd_end) : (i += vec_len) {
        const c_ptr: *align(1) vec = @ptrCast(ci.ptr + i);
        const x_ptr: *align(1) const vec = @ptrCast(xi.ptr + i);

        c_ptr.* = c_ptr.* + x_ptr.*;
    }

    while (i < ci.len) : (i += 1)
        ci[i] += xi[i];
}

fn calcCores(comptime T: type, x: []const []const T, y: []const usize, k: usize, allocator: std.mem.Allocator) ![][]T {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    if (k == 0) return error.IncorrectLen;
    const c: [][]T = try allocator.alloc([]T, k);
    for (c) |*ci| {
        ci.* = try allocator.alloc(T, x[0].len);
        @memset(ci.*, 0);
    }

    const nums: []usize = try allocator.alloc(usize, k);
    defer allocator.free(nums);
    @memset(nums, 0);

    for (y, x) |yi, xi| {
        const c_yi = c[yi];
        nums[yi] += 1;
        try addToCore(T, c_yi, xi);
    }

    for (c, nums) |ci, count| {
        const inv = if (count == 0) 1.0 else 1.0 / @as(T, @floatFromInt(count));
        for (ci) |*cij|
            cij.* *= inv;
    }
    return c;
}

// fn calcNewCore(comptime T: type, new_ci: []const T, ci: []T, mul: T) !void {
//     if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
//     if (new_ci.len != ci.len) return error.DimensionsMismatch;

//     for (ci, new_ci) |*cij, new_cij| cij.* = new_cij * mul;
// }

fn calcNewCore(comptime T: type, new_ci: []const T, ci: []T, mul: T) !void {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    if (new_ci.len != ci.len) return error.DimensionsMismatch;

    const vec_len: comptime_int = comptime simd.suggestVectorLength(T) orelse 1;
    const vec = @Vector(vec_len, T);

    const mul_vec: vec = @splat(mul);

    var i: usize = 0;
    const simd_end = ci.len - ci.len % vec_len;

    while (i < simd_end) : (i += vec_len) {
        const src_ptr: *align(1) const vec = @ptrCast(new_ci.ptr + i);
        const dst_ptr: *align(1) vec = @ptrCast(ci.ptr + i);

        dst_ptr.* = src_ptr.* * mul_vec;
    }

    while (i < ci.len) : (i += 1)
        ci[i] = new_ci[i] * mul;
}

fn checkPartition(comptime T: type, x: []const []const T, c: []const []T, new_c: []const []T, y: []usize, nums: []usize) !bool {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    for (new_c) |new_ci| @memset(new_ci, 0);

    @memset(nums, 0);
    var flag: bool = false;
    for (x, y) |xi, *yi| {
        const f: usize = try getCluster(T, xi, c);
        if (f != yi.*) flag = true;
        yi.* = f;
        nums[f] += 1;
        try addToCore(T, new_c[f], xi);
    }

    for (c, new_c, nums) |ci, new_ci, count| {
        const inv = if (count == 0) 1.0 else 1.0 / @as(T, @floatFromInt(count));
        try calcNewCore(T, new_ci, ci, inv);
    }

    return flag;
}

fn kmeansCores(comptime T: type, x: []const []const T, k: usize, allocator: std.mem.Allocator) ![][]T {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    const c: [][]T = try detCores(T, x, k, allocator);

    const new_c = try allocator.alloc([]T, k);
    for (new_c) |*new_ci| new_ci.* = try allocator.alloc(T, x[0].len);

    defer {
        for (new_c) |new_ci| allocator.free(new_ci);
        allocator.free(new_c);
    }

    const nums = try allocator.alloc(usize, k);
    defer allocator.free(nums);

    const y: []usize = try allocator.alloc(usize, x.len);
    defer allocator.free(y);

    @memset(y, 0);

    while (try checkPartition(T, x, c, new_c, y, nums)) {}

    return c;
}

fn checkCores(comptime T: type, c1: []const []const T, c2: []const []const T, tol: T) !bool {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    const pow2tol = tol * tol;
    for (c1, c2) |c1i, c2i| {
        const d = try getDistance(T, c1i, c2i);
        if (d > pow2tol) return false;
    }
    return true;
}

// fn divCore(comptime T: type, ci: []T, mul: T) !void {
//     if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

//     for (ci) |*cij| cij.* *= mul;
// }

fn divCore(comptime T: type, ci: []T, mul: T) !void {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    const vec_len: comptime_int = comptime simd.suggestVectorLength(T) orelse 1;
    const vec = @Vector(vec_len, T);

    const vec_mul: vec = @splat(mul);

    var i: usize = 0;
    const aligned_len = ci.len - ci.len % vec_len;

    while (i < aligned_len) : (i += vec_len) {
        const dst_ptr: *align(1) vec = @ptrCast(ci.ptr + i);
        dst_ptr.* *= vec_mul;
    }

    while (i < ci.len) : (i += 1) {
        ci[i] *= mul;
    }
}

fn checkPartitionWithTol(comptime T: type, x: []const []const T, c: []const []T, new_c: []const []T, y: []usize, nums: []usize, tol: T) !bool {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    for (new_c) |new_ci| @memset(new_ci, 0);

    @memset(nums, 0);
    for (x, y) |xi, *yi| {
        const f: usize = try getCluster(T, xi, c);
        yi.* = f;
        nums[f] += 1;
        try addToCore(T, new_c[f], xi);
    }

    for (new_c, nums) |new_ci, count| {
        const inv = if (count == 0) 1.0 else 1.0 / @as(T, @floatFromInt(count));
        try divCore(T, new_ci, inv);
    }

    const flag = !try checkCores(T, c, new_c, tol);

    for (c, new_c) |ci, new_ci|
        @memcpy(ci, new_ci);

    return flag;
}

fn kmeansCoresWithTol(comptime T: type, x: []const []const T, k: usize, allocator: std.mem.Allocator, tol: T) ![][]T {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    const c: [][]T = try detCores(T, x, k, allocator);

    const new_c = try allocator.alloc([]T, k);
    for (new_c) |*new_ci| new_ci.* = try allocator.alloc(T, x[0].len);

    defer {
        for (new_c) |new_ci| allocator.free(new_ci);
        allocator.free(new_c);
    }

    const nums = try allocator.alloc(usize, k);
    defer allocator.free(nums);

    const y: []usize = try allocator.alloc(usize, x.len);
    defer allocator.free(y);

    @memset(y, 0);

    while (try checkPartitionWithTol(T, x, c, new_c, y, nums, tol)) {}

    return c;
}

fn kmeansCoresWithMaxIter(comptime T: type, x: []const []const T, k: usize, allocator: std.mem.Allocator, max_it: u64) ![][]T {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    const c: [][]T = try detCores(T, x, k, allocator);

    const new_c = try allocator.alloc([]T, k);
    for (new_c) |*new_ci| new_ci.* = try allocator.alloc(T, x[0].len);

    defer {
        for (new_c) |new_ci| allocator.free(new_ci);
        allocator.free(new_c);
    }

    const nums = try allocator.alloc(usize, k);
    defer allocator.free(nums);

    const y: []usize = try allocator.alloc(usize, x.len);
    defer allocator.free(y);

    @memset(y, 0);
    var i: u64 = 0;
    while (try checkPartition(T, x, c, new_c, y, nums) and i < max_it) : (i += 1) {}

    return c;
}

fn kmeansCoresWithTolAndMaxIter(comptime T: type, x: []const []const T, k: usize, allocator: std.mem.Allocator, tol: T, max_it: u64) ![][]T {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");
    const c: [][]T = try detCores(T, x, k, allocator);

    const new_c = try allocator.alloc([]T, k);
    for (new_c) |*new_ci| new_ci.* = try allocator.alloc(T, x[0].len);

    defer {
        for (new_c) |new_ci| allocator.free(new_ci);
        allocator.free(new_c);
    }

    const nums = try allocator.alloc(usize, k);
    defer allocator.free(nums);

    const y: []usize = try allocator.alloc(usize, x.len);
    defer allocator.free(y);

    @memset(y, 0);
    var i: u64 = 0;
    while (try checkPartitionWithTol(T, x, c, new_c, y, nums, tol) and i < max_it) : (i += 1) {}

    return c;
}

fn kmeansYWithTol(comptime T: type, x: []const []const T, k: usize, allocator: std.mem.Allocator, tol: T) ![]usize {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    const c: [][]T = try detCores(T, x, k, allocator);
    defer {
        for (c) |*ci| allocator.free(ci.*);
        allocator.free(c);
    }

    const new_c = try allocator.alloc([]T, k);
    for (new_c) |*new_ci| new_ci.* = try allocator.alloc(T, c[0].len);

    defer {
        for (new_c) |*new_ci| allocator.free(new_ci.*);
        allocator.free(new_c);
    }

    const nums = try allocator.alloc(usize, k);
    defer allocator.free(nums);

    const y: []usize = try allocator.alloc(usize, x.len);

    @memset(y, 0);

    while (try checkPartitionWithTol(T, x, c, new_c, y, nums, tol)) {}

    return y;
}

fn kmeansYWithTolAndMaxIter(comptime T: type, x: []const []const T, k: usize, allocator: std.mem.Allocator, tol: T, max_it: u64) ![]usize {
    if (@typeInfo(T) != .float) @compileError("Only floats are accepted");

    const c: [][]T = try detCores(T, x, k, allocator);
    defer {
        for (c) |*ci| allocator.free(ci.*);
        allocator.free(c);
    }

    const new_c = try allocator.alloc([]T, k);
    for (new_c) |*new_ci| new_ci.* = try allocator.alloc(T, c[0].len);

    defer {
        for (new_c) |*new_ci| allocator.free(new_ci.*);
        allocator.free(new_c);
    }

    const nums = try allocator.alloc(usize, k);
    defer allocator.free(nums);

    const y: []usize = try allocator.alloc(usize, x.len);

    @memset(y, 0);

    var i: u64 = 0;
    while (try checkPartitionWithTol(T, x, c, new_c, y, nums, tol) and i < max_it) : (i += 1) {}

    return y;
}
