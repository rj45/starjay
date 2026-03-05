const std = @import("std");
const zigimg = @import("zigimg");

/// Primary internal color type: OKLab in Cartesian (L, a, b) form.
/// Used for all hot-path computations: deltaE, dithering, k-means feature vectors.
/// Cartesian coordinates avoid the circular-hue issues that arise in cylindrical LCH
/// for error diffusion and Euclidean distance, and require no trigonometry per call.
/// Delegates all sRGB <-> OKLab conversion math to zigimg.
///
/// To obtain the hue angle for hue-based sorting, use `hueAngle()` below.
/// To obtain the full LCH representation, use `OklabAlpha.toOkLChAlpha()`.
pub const OklabAlpha = zigimg.color.OklabAlpha;

/// OKLab in cylindrical (L, C, H) form. Use for hue-based operations such as
/// palette cluster sorting. H is in radians [0, 2π).
/// Convert: `pixel.toOkLChAlpha()` or `OkLChAlpha.fromOklabAlpha(pixel)`.
pub const OkLChAlpha = zigimg.color.OkLChAlpha;

/// Return the hue angle of a color in OKLab space, in radians [0, 2π).
/// Computed as atan2(b, a). For achromatic colors (a=0, b=0) returns 0.
/// Use for sorting/clustering by hue; do NOT use as a k-means distance dimension
/// (hue is circular — use Cartesian a, b instead).
pub inline fn hueAngle(c: OklabAlpha) f32 {
    var h = std.math.atan2(c.b, c.a);
    if (h < 0.0) h += 2.0 * std.math.pi;
    return h;
}

/// Euclidean distance squared in OKLab Cartesian space (avoids sqrt for hot loops).
/// Mathematically equivalent to dL^2 + dC^2 + dH^2 (Rust oklab_delta_e formula)
/// while requiring no trigonometry. Single query site for all color comparisons.
pub inline fn deltaESquared(a: OklabAlpha, b: OklabAlpha) f32 {
    const dl = a.l - b.l;
    const da = a.a - b.a;
    const db = a.b - b.b;
    return dl * dl + da * da + db * db;
}

/// Perceptual color difference in OKLab space: sqrt(DL^2 + Da^2 + Db^2)
pub inline fn deltaE(a: OklabAlpha, b: OklabAlpha) f32 {
    return @sqrt(deltaESquared(a, b));
}

// Ground-truth deltaE values gathered from colorjs.io `deltaEOK` (npm: colorjs.io@0.5.2).
// colorjs deltaEOK is the Euclidean distance in OKLab: sqrt(dL^2 + da^2 + db^2).
// This is mathematically equivalent to the Rust oklab_delta_e chroma-hue decomposition
// (dL^2 + dC^2 + dH^2 expands to dL^2 + da^2 + db^2). All values verified externally.
const DeltaECase = struct { a: OklabAlpha, b: OklabAlpha, expected: f32 };
const deltaE_cases = [_]DeltaECase{
    // identical -> 0
    .{ .a = .{ .l = 0.5, .a = 0.0, .b = 0.0, .alpha = 1.0 }, .b = .{ .l = 0.5, .a = 0.0, .b = 0.0, .alpha = 1.0 }, .expected = 0.0 },
    // black vs white -> 1.0
    .{ .a = .{ .l = 0.0, .a = 0.0, .b = 0.0, .alpha = 1.0 }, .b = .{ .l = 1.0, .a = 0.0, .b = 0.0, .alpha = 1.0 }, .expected = 1.0 },
    // mid-range pair 1: colorjs=0.46904158
    .{ .a = .{ .l = 0.6, .a = 0.2, .b = -0.1, .alpha = 1.0 }, .b = .{ .l = 0.4, .a = -0.1, .b = 0.2, .alpha = 1.0 }, .expected = 0.46904158 },
    // mid-range pair 2: colorjs=0.78102497
    .{ .a = .{ .l = 0.8, .a = 0.1, .b = 0.1, .alpha = 1.0 }, .b = .{ .l = 0.2, .a = -0.2, .b = -0.3, .alpha = 1.0 }, .expected = 0.78102497 },
    // same L, opposite chroma: colorjs=0.72111026
    .{ .a = .{ .l = 0.5, .a = 0.3, .b = 0.2, .alpha = 1.0 }, .b = .{ .l = 0.5, .a = -0.3, .b = -0.2, .alpha = 1.0 }, .expected = 0.72111026 },
    // dark vs light: colorjs=0.81240384
    .{ .a = .{ .l = 0.1, .a = 0.05, .b = -0.05, .alpha = 1.0 }, .b = .{ .l = 0.9, .a = -0.05, .b = 0.05, .alpha = 1.0 }, .expected = 0.81240384 },
    // red vs blue (realistic OKLab coords): colorjs=0.44714112
    .{ .a = .{ .l = 0.6279554, .a = 0.2248, .b = -0.1258, .alpha = 1.0 }, .b = .{ .l = 0.5181, .a = -0.1403, .b = 0.1078, .alpha = 1.0 }, .expected = 0.44714112 },
    // nearly identical: colorjs=0.00017321
    .{ .a = .{ .l = 0.5, .a = 0.1, .b = 0.1, .alpha = 1.0 }, .b = .{ .l = 0.5001, .a = 0.1001, .b = 0.1001, .alpha = 1.0 }, .expected = 0.00017321 },
    // chromatic vs neutral: colorjs=0.25000000
    .{ .a = .{ .l = 0.7, .a = 0.25, .b = 0.0, .alpha = 1.0 }, .b = .{ .l = 0.7, .a = 0.0, .b = 0.0, .alpha = 1.0 }, .expected = 0.25 },
};

test "deltaE matches colorjs.io deltaEOK ground-truth values" {
    for (deltaE_cases) |c| {
        const got = deltaE(c.a, c.b);
        try std.testing.expectApproxEqAbs(c.expected, got, 1e-5);
    }
}

test "deltaE is symmetric" {
    for (deltaE_cases) |c| {
        try std.testing.expectApproxEqAbs(deltaE(c.a, c.b), deltaE(c.b, c.a), 1e-7);
    }
}

test "deltaESquared matches deltaE squared" {
    for (deltaE_cases) |c| {
        const de = deltaE(c.a, c.b);
        const de_sq = deltaESquared(c.a, c.b);
        try std.testing.expectApproxEqAbs(de * de, de_sq, 1e-6);
    }
}
