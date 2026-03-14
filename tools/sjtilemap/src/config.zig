const std = @import("std");

pub const DitherAlgorithm = enum {
    none,
    sierra,
};

/// Selects the algorithm used to generate palette colors from tile pixel sets.
/// Currently only .kmeans is implemented.
pub const PaletteGeneratorAlgorithm = enum {
    /// K-means clustering in OKLab space (current default).
    kmeans,
};

/// Selects the tile deduplication/reduction algorithm.
pub const TileReducerAlgorithm = enum {
    /// Exact hash dedup first; if unique tile count exceeds max_unique_tiles, falls back to .kmeans_color.
    auto,
    /// Exact hash dedup only. If unique tile count exceeds max_unique_tiles, returns an error.
    exact_hash,
    /// Always cluster quantized tiles with k-means, regardless of count.
    kmeans_color,
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
    verbose: bool = false,

    // Tile geometry
    tile_width: u32 = 8,
    tile_height: u32 = 8,

    // Tilemap geometry (in tiles); null means derive from each input image.
    tilemap_width: ?u32 = null,
    tilemap_height: ?u32 = null,

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
    /// Error diffusion strength [0.0, 1.0].
    dither_factor: f32 = 0.75,

    // Transparency
    transparency_mode: TransparencyMode = .none,
    /// sRGB color (R, G, B) treated as transparent when transparency_mode == .color.
    /// Pixels with this exact sRGB value are assigned palette index 0 (transparent).
    transparent_color: ?[3]u8 = null,

    // Palette generation options
    /// Two colors closer than this deltaE threshold are treated as the same color.
    color_similarity_threshold: f32 = 0.005,
    /// When true, palette[0].color[0] is forced to OKLab black (L=0,a=0,b=0).
    palette_0_color_0_is_black: bool = true,

    // K-means settings
    /// Max k-means iterations for palette color generation.
    palette_kmeans_max_iter: u64 = 10_000,
    /// Max k-means iterations for tile color reduction.
    tile_kmeans_max_iter: u64 = 100_000,

    // Output
    tileset_storage_order: TilesetStorageOrder = .row_major,

    // Multi-file strategies
    palette_strategy: PaletteStrategy = .shared,
    tileset_strategy: TilesetStrategy = .shared,

    /// Path to a palette hex file to load when palette_strategy = .preloaded.
    /// The file must be in the format written by writePaletteHex (one palette per line,
    /// RRGGBB entries separated by spaces). All lines in the file are loaded as palettes.
    preloaded_palette: ?[]const u8 = null,

    /// Path to a tileset hex file to load when tileset_strategy = .preloaded.
    /// Must be row-major format (see writeTilesetHexRowMajor). The number of tiles
    /// to load is determined by num_preloaded_tiles (defaults to max_unique_tiles).
    preloaded_tileset: ?[]const u8 = null,

    /// How many tiles to load from preloaded_tileset (0 = use max_unique_tiles).
    /// Since the row-major format pads to max_unique_tiles, this tells the loader
    /// how many leading tiles were real (not padding).
    num_preloaded_tiles: u32 = 0,

    /// How many palettes to use from preloaded_palette (0 = load all lines in the file).
    /// Useful when a palette file contains more entries than are needed for this run.
    num_preloaded_palettes: u32 = 0,

    /// Palette-generation algorithm. Currently only .kmeans is supported.
    palette_generator: PaletteGeneratorAlgorithm = .kmeans,

    /// Tile deduplication algorithm.
    /// .auto: exact hash dedup first, k-means fallback if count exceeds max_unique_tiles.
    /// .exact_hash: exact only, returns error.TooManyUniqueTiles if count exceeds limit.
    /// .kmeans_color: always cluster with k-means after initial dedup.
    tile_reducer: TileReducerAlgorithm = .auto,

    /// Validate configuration settings.
    /// Bits required to index into a palette entry: log2(colors_per_palette).
    /// Single query site for all output writers that pack pixels.
    /// colors_per_palette must be a power of 2; validate() enforces this.
    pub fn bitsPerColorIndex(self: Config) u4 {
        return @intCast(std.math.log2_int(u32, self.colors_per_palette));
    }

    /// Load a Config from a ZON file. Missing fields use struct defaults.
    /// String fields (preloaded_palette, preloaded_tileset) are allocated with `alloc`
    /// and must be freed by the caller. All other fields are value types.
    pub fn load(alloc: std.mem.Allocator, zon_path: []const u8) !Config {
        // Use a parse-only arena so ZON internals don't leak, while we dupe strings
        // we need to outlive the parse buffer into alloc.
        var parse_arena = std.heap.ArenaAllocator.init(alloc);
        defer parse_arena.deinit();
        const parse_alloc = parse_arena.allocator();

        const source = try std.fs.cwd().readFileAllocOptions(parse_alloc, zon_path, 1 << 20, null, .@"1", 0);
        // The ZON parser uses inline for loops over struct fields; Config has many enum fields,
        // so we need a higher comptime branch quota to avoid "exceeded backwards branches" errors.
        @setEvalBranchQuota(10000);
        var cfg = try std.zon.parse.fromSlice(Config, parse_alloc, source, null, .{});
        // Dupe optional string fields into alloc before parse_arena is freed.
        if (cfg.preloaded_palette) |p| cfg.preloaded_palette = try alloc.dupe(u8, p);
        if (cfg.preloaded_tileset) |p| cfg.preloaded_tileset = try alloc.dupe(u8, p);
        return cfg;
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
    /// Image width/height must be exact multiples of tile_width/tile_height.
    /// If tilemap_width/tilemap_height are set, the image must also match exactly.
    pub fn validateImageDimensions(self: Config, image_width: u32, image_height: u32) !void {
        if (image_width % self.tile_width != 0 or image_height % self.tile_height != 0) {
            return error.ImageDimensionsNotMultipleOfTileSize;
        }
        if (self.tilemap_width) |tw| {
            if (image_width != tw * self.tile_width) return error.ImageWidthMismatch;
        }
        if (self.tilemap_height) |th| {
            if (image_height != th * self.tile_height) return error.ImageHeightMismatch;
        }
    }

    /// Write default config as ZON to the given writer.
    pub fn generateDefault(out: *std.io.Writer) !void {
        const defaults = Config{};
        try std.zon.stringify.serialize(defaults, .{}, out);
    }
};
