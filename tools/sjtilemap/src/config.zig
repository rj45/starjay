const std = @import("std");

pub const DitherAlgorithm = enum {
    none,
    sierra,
};

pub const TransparencyMode = enum {
    none,
    /// Use image alpha channel: pixels with alpha < 0.5 are transparent.
    alpha,
    /// Treat a specific sRGB color as transparent (see Config.transparent_color).
    color,
};

pub const TilesetStorageOrder = enum { row_major, sequential };

pub const PaletteStrategy = enum { shared, per_file, preloaded };
pub const TilesetStrategy = enum { shared, per_file, preloaded };

pub const Config = struct {
    // Tile geometry
    tile_width: u32 = 8,
    tile_height: u32 = 8,

    // Tilemap geometry (in tiles)
    tilemap_width: u32 = 32,
    tilemap_height: u32 = 32,

    // Palette settings
    /// Number of palettes this run generates. num_palettes + palette_start_offset must not exceed 64.
    num_palettes: u32 = 32,
    /// First palette slot this run may write into (0-based). Enables partial palette preloading.
    palette_start_offset: u32 = 0,
    colors_per_palette: u32 = 16,

    // Tileset settings
    /// Max unique tiles to generate. max_unique_tiles + tileset_start_offset must not exceed 256.
    max_unique_tiles: u32 = 256,
    /// First tile slot this run may write into (0-based).
    tileset_start_offset: u32 = 0,

    // Dithering
    dither_algorithm: DitherAlgorithm = .sierra,
    /// Error diffusion strength [0.0, 1.0]. Default 0.75 matches Rust imgconv reference.
    dither_factor: f32 = 0.75,

    // Transparency
    transparency_mode: TransparencyMode = .none,
    /// sRGB color (R, G, B) treated as transparent when transparency_mode == .color.
    /// Pixels with this exact sRGB value are assigned palette index 0 (transparent).
    transparent_color: ?[3]u8 = null,

    // Palette generation options
    /// Two colors closer than this deltaE threshold are treated as the same color.
    /// Default 0.005 matches Rust imgconv SIMILARITY_THRESHOLD.
    color_similarity_threshold: f32 = 0.005,
    /// When true, palette[0].color[0] is forced to OKLab black (L=0,a=0,b=0).
    palette_0_color_0_is_black: bool = true,

    // K-means settings
    /// Max k-means iterations for palette color generation. Default 10_000 matches Rust KMEANS_MAX_ITERATIONS.
    palette_kmeans_max_iter: u64 = 10_000,
    /// Max k-means iterations for tile color reduction. Default 100_000 matches Rust COLOR_REDUCTION_MAX_ITERATIONS.
    tile_kmeans_max_iter: u64 = 100_000,

    // Output
    tileset_storage_order: TilesetStorageOrder = .row_major,

    // Multi-file strategies
    palette_strategy: PaletteStrategy = .shared,
    tileset_strategy: TilesetStrategy = .shared,

    /// Validate configuration settings.
    /// Bits required to index into a palette entry: log2(colors_per_palette).
    /// Single query site for all output writers that pack pixels.
    /// colors_per_palette must be a power of 2; validate() enforces this.
    pub fn bitsPerColorIndex(self: Config) u4 {
        return @intCast(std.math.log2_int(u32, self.colors_per_palette));
    }

    /// Load a Config from a ZON file. Missing fields use struct defaults.
    pub fn load(alloc: std.mem.Allocator, zon_path: []const u8) !Config {
        const source = try std.fs.cwd().readFileAllocOptions(alloc, zon_path, 1 << 20, null, .@"1", 0);
        defer alloc.free(source);
        const parsed = try std.zon.parse.fromSlice(Config, alloc, source, null, .{});
        defer std.zon.parse.free(alloc, parsed);
        // Return a copy (fromSlice may return references into the source buffer)
        return parsed;
    }

    pub fn validate(self: Config) !void {
        // colors_per_palette must be power of 2 and <= 16
        if (self.colors_per_palette == 0 or
            (self.colors_per_palette & (self.colors_per_palette - 1)) != 0)
        {
            return error.ColorsPerPaletteNotPowerOfTwo;
        }
        if (self.colors_per_palette > 16) {
            return error.ColorsPerPaletteTooLarge;
        }

        // Palette slot range: [palette_start_offset, palette_start_offset + num_palettes) must fit in u6 (max 64 slots)
        if (self.num_palettes + self.palette_start_offset > 64) {
            return error.PaletteRangeExceedsMax;
        }

        // Tile slot range: [tileset_start_offset, tileset_start_offset + max_unique_tiles) must fit in u8 (max 256 slots)
        if (self.max_unique_tiles + self.tileset_start_offset > 256) {
            return error.TileRangeExceedsMax;
        }

        // transparent_color only valid with transparency_mode=.color
        if (self.transparent_color != null and self.transparency_mode != .color) {
            return error.TransparentColorWithoutColorMode;
        }
    }

    /// Validate that an image's pixel dimensions are consistent with this config.
    /// Image width/height must be exact multiples of tile_width/tile_height and
    /// must equal tilemap_width * tile_width and tilemap_height * tile_height.
    pub fn validateImageDimensions(self: Config, image_width: u32, image_height: u32) !void {
        if (image_width % self.tile_width != 0 or image_height % self.tile_height != 0) {
            return error.ImageDimensionsNotMultipleOfTileSize;
        }
        if (image_width != self.tilemap_width * self.tile_width) {
            return error.ImageWidthMismatch;
        }
        if (image_height != self.tilemap_height * self.tile_height) {
            return error.ImageHeightMismatch;
        }
    }

    /// Write default config as ZON to the given writer.
    /// Accepts any writer that provides a `print` method (GenericWriter, AnyWriter, etc.).
    pub fn generateDefault(out: anytype) !void {
        const defaults = Config{};
        try out.print(
            \\.{{
            \\    .tile_width = {d},
            \\    .tile_height = {d},
            \\    .tilemap_width = {d},
            \\    .tilemap_height = {d},
            \\    .num_palettes = {d},
            \\    .palette_start_offset = {d},
            \\    .colors_per_palette = {d},
            \\    .max_unique_tiles = {d},
            \\    .tileset_start_offset = {d},
            \\    .dither_algorithm = .{s},
            \\    .dither_factor = {d},
            \\    .transparency_mode = .{s},
            \\    .transparent_color = null,
            \\    .color_similarity_threshold = {d},
            \\    .palette_0_color_0_is_black = {s},
            \\    .palette_kmeans_max_iter = {d},
            \\    .tile_kmeans_max_iter = {d},
            \\    .tileset_storage_order = .{s},
            \\    .palette_strategy = .{s},
            \\    .tileset_strategy = .{s},
            \\}}
        , .{
            defaults.tile_width,
            defaults.tile_height,
            defaults.tilemap_width,
            defaults.tilemap_height,
            defaults.num_palettes,
            defaults.palette_start_offset,
            defaults.colors_per_palette,
            defaults.max_unique_tiles,
            defaults.tileset_start_offset,
            @tagName(defaults.dither_algorithm),
            defaults.dither_factor,
            @tagName(defaults.transparency_mode),
            defaults.color_similarity_threshold,
            if (defaults.palette_0_color_0_is_black) "true" else "false",
            defaults.palette_kmeans_max_iter,
            defaults.tile_kmeans_max_iter,
            @tagName(defaults.tileset_storage_order),
            @tagName(defaults.palette_strategy),
            @tagName(defaults.tileset_strategy),
        });
    }
};
