# Plan: sjtilemap -- Production Zig Port of imgconv

## Context

`/home/rj45/code/vdp/imgconv` is a Rust prototype that converts PNG images into tileset/palette/tilemap data for a VDP (Video Display Processor). It works but has hardcoded constants, single-file-only input, a limited set of output formats, and no config file support. The goal is to rewrite it in idiomatic, production-quality Zig in `/home/rj45/code/starjay/tools/sjtilemap`, preserving all algorithms, exposing every parameter, adding multi-file processing with strategy-based palette/tileset sharing, four output formats, ZON config file support, and a full TDD test suite with benchmarks.

**Foundation already in place:** zigimg (image loading + OKLab conversion), clap (CLI), and a SIMD-optimized `kmeans.zig` are all configured and working.

---

## Rust Reference Implementation

The canonical reference is `/home/rj45/code/vdp/imgconv` (3 source files, ~1600 lines total). Read this when implementing each phase — the algorithms are correct and tested.

### Running the Binary

```bash
cd /home/rj45/code/vdp/imgconv

# Full output: preview PNG + all hex files + PSNR/delta-E stats printed to stdout
cargo run --release -- \
  -i /path/to/input.png \
  -o /tmp/golden-out.png \
  --palette-hex /tmp/palette.hex \
  --tiles-hex /tmp/tiles.hex \
  --tilemap-hex /tmp/tilemap.hex

# With JSON dump for complete metadata (tiles, palettes, tilemap, raw Oklab pixels)
cargo run --release -- \
  -i /path/to/input.png \
  -o /tmp/golden-out.png \
  --palette-hex /tmp/palette.hex \
  --tiles-hex /tmp/tiles.hex \
  --tilemap-hex /tmp/tilemap.hex \
  --json /tmp/dump.json

# Disable dithering (for pixel-perfect comparisons)
cargo run --release -- \
  -i /path/to/input.png \
  -o /tmp/golden-out.png \
  --no-dither

# Custom tile/tilemap dimensions
cargo run --release -- \
  -i /path/to/input.png \
  -o /tmp/golden-out.png \
  --tile-size 8x8 \
  --tilemap-size 32x32 \
  --palettes 32 \
  --colors 16
```

**IMPORTANT:** Always use `--release` — debug builds are ~100× slower due to k-means.

### CLI Arguments (Complete)

| Flag | Argument | Default | Notes |
|------|----------|---------|-------|
| `-i, --input` | FILE | `imgconv/Gouldian_Finch_256x256.png` | Input image |
| `-o, --output` | FILE | `imgconv/out.png` | Preview PNG output |
| `--palette-hex` | FILE | `rtl/palette.hex` | Palette hex file |
| `--tiles-hex` | FILE | `rtl/tiles.hex` | Tiles hex file |
| `--tilemap-hex` | FILE | `rtl/tile_map.hex` | Tilemap hex file |
| `--json` | FILE | (optional) | Full JSON metadata dump |
| `--tile-size` | WIDTHxHEIGHT | `8x8` | Tile pixel dimensions |
| `--tilemap-size` | WIDTHxHEIGHT | `32x32` | Tilemap grid in tiles |
| `--palettes` | NUM | `32` | Number of palettes |
| `--colors` | NUM | `16` | Max colors per palette |
| `--no-dither` | flag | (dithering enabled) | Disable Sierra dithering |
| `--dither-factor` | FLOAT | `0.75` | Error scaling factor |

### Output Metrics Printed

After conversion, the Rust binary prints to stdout:
- **Delta-E percentiles** (×100 display factor): Min, Mean, Median, p75, p90, p95, p99, Max — lower is better
- **PSNR per channel** (dB): Red, Green, Blue, Average — higher is better (30–50 dB is good)
- Min/max colors per palette
- Number of clustered unique tiles

### Source File Index

All paths relative to `/home/rj45/code/vdp/imgconv/src/`.

| Feature | File | Lines |
|---------|------|-------|
| CLI argument parsing | `main.rs` | 13–187 |
| Constants & magic numbers | `imgconv.rs` | 16–56 |
| Config struct & defaults | `imgconv.rs` | 58–143 |
| Tile / Palette / TilemapEntry structs | `imgconv.rs` | 154–217 |
| **Main pipeline** (`convert()`) | `imgconv.rs` | 260–308 |
| Image reading | `imgconv.rs` | 310–340 |
| **Tile extraction** (`extract_tiles()`) | `imgconv.rs` | 342–373 |
| **Palette k-means** (`generate_palettes()`) | `imgconv.rs` | 376–419 |
| Clustering data prep | `imgconv.rs` | 422–449 |
| Palette color extraction | `imgconv.rs` | 452–486 |
| Palette processing & color reduction | `imgconv.rs` | 489–568 |
| **Palette assignment** (`assign_palettes()`, `find_best_palette_for_tile()`) | `imgconv.rs` | 571–620 |
| **Tile dedup k-means** (`cluster_quantized_tiles()`) | `imgconv.rs` | 622–700 |
| Best tile+palette assignment | `imgconv.rs` | 702–740 |
| Reconstruction error calculation | `imgconv.rs` | 742–766 |
| **Tile quantization** (`quantize_tiles()`) | `imgconv.rs` | 768–800 |
| **Pixel quantization + dithering** (`quantize_pixels()`) | `imgconv.rs` | 803–858 |
| **Sierra dithering kernel** (`apply_sierra_dithering()`) | `imgconv.rs` | 861–912 |
| **Tilemap entry encoding** | `imgconv.rs` | 915–922 |
| Palette hex file writer | `imgconv.rs` | 924–942 |
| Tilemap hex file writer | `imgconv.rs` | 944–956 |
| Tiles hex file writer (**row-major** storage order) | `imgconv.rs` | 958–991 |
| Output image reconstruction | `imgconv.rs` | 993–1041 |
| **Error metrics** (PSNR + delta-E) | `imgconv.rs` | 1043–1158 |
| JSON output | `imgconv.rs` | 1195–1200 |
| **Delta-E / oklab_delta_e()** | `color.rs` | 125–146 |
| OklabDistance (SIMD k-means distance) | `color.rs` | 148–203 |
| find_similar_color() | `color.rs` | 205–217 |
| sRGB ↔ Oklab conversion | `color.rs` | 1–123 |

> **Tilemap bit layout note:** The Rust version uses `PALETTE_INDEX_SHIFT = 10` (bits [15:10] = palette, bits [9:0] = tile). The Zig version uses a different layout per the VDP hardware contract — see `TilemapEntry` in Phase 3. Do not copy the Rust bit layout.

> **Transparency / x_flip note:** Neither transparency nor x_flip is implemented in the Rust version. Those features are Zig-only additions defined by the VDP hardware spec.

---

## EXTREMELY IMPORTANT GUIDING PRINCIPLES

### Single Source of Truth

There must be EXACTLY ONE source of truth for every fact, datum, figure, algorithm, procedure and peice of knowledge. The location of this single source of truth must be well named, discoverable and easily searched for. Put some extra thought into naming and making sure keywords you would search for are in documentation comments.

For example, the fact that tilemap entries have 8 bits for the index of the tile in the tileset should be in exactly one place in the code, and using comptime everything else (like the max configurable number of tiles) should be derived from that single source of truth. Changing that single type from u8 to u10 should update everything that relies on that value (for example, the max tiles should now be 1024) and it should just work with no further modifications to the code.

Another example: the knowledge about converting from sRGB to oklab or from oklab to sRGB should be in the zigimg library and in that library alone.

### Test features not facts or figures

All tests must have assertions that test the human-facing feature that the code is supposed to perform. No mocks alowed. No "proxy" stats alowed like checking the length of the result array unless the code is just allocating an array. Assertions must assert the "meat" of the algorithm under test. If it's unclear how to test the meat, do some research and see if you can build test cases from that research.

For example, deltaE tests should make sure the deltaE comparison matches the deltaE computed by other libraries in other languages. For example, you could build a temporary node.js app (delete after) and gather some facts and figures from an npm library for the tests, and use those to build up a comprehensive test suite of specific colors and the delta-E comparison using actual gathered numbers.

Another example: end to end tests should be built that convert simple generated images that you can be confident should be converted pixel perfect into the result, and then check that actually happens and the result image is identical to the input.

For the images that cannot be losslessly converted, set up PSNR and/or oklab delta-E tests that verify the results are visually similar enough. Use the Rust version of the project (built in `--release`) to get the thresholds for these tests. The Zig version should generate as good or better results.

### Build in incremental well tested steps

Determine the smallest amount of code that can be used to make an end-to-end test pass, make sure to run the tests and verify it fails in the expected way, then implement only the minimum code to make that test pass according to the structure and design in this plan. Do not implement any features not currently covered by tests, though. Repeat this process until all features are implemented and have one or more end-to-end tests for each feature.

An example of test progression:

- Convert an 8x8 image with exactly 16 colors in it. Should result in a 1x1 tile tilemap with exactly the same colors when checked with the generated palette. This will also verify configuration parameters and preferably also command line arguments, etc all work and are wired up correctly.
- Convert a 16x16 image with 4 copies of the previous generated image. Make sure it generates the same tileset and palette, and that the tilemap is just essentially 4 zeros.
- Convert a 16x16 image with 4 different patterns, all using the same 16 colors. Make sure it generates the same palette but with 4 tiles in the tileset and a tilemap with the 4 tile indices in it.
- Generate a 16x16 image that produces 4 copies of the same pattern but with 16 very different RGB values for each pixel, verify that the resulting tilemap re-uses the tile 4 times with different palette indices, and that the palette now has 64 colors with 4 palettes used, and the tileset only has one tile in it.
- Etc. In each scenario add one more feature/aspect of the algorithm to test and make sure it fails first before modifying the code to make it pass.

- UNDER NO CIRCUMSTANCES SHOULD ANY FEATURE BE IMPLEMENTED WITHOUT A FAILING END-TO-END TEST FIRST. 
- NEVER MODIFY A TEST CASE TO MAKE IT PASS WITHOUT EXHAUSTIVELY VERIFYING THE BUG IS NOT IN THE CODE UNDER TEST.
- NEVER COPY PASTE CODE UNDER TESTS INTO TEST FILES -- MODIFY CODE FOR API REQUIRED BY TESTS.

### Data Oriented Design

Allocate up front as much as possible, prefer arena allocators where that is not possible, focus on transforming data from one form to another rather than object oriented approaches, build easily vectorized tight hot loops over arrays where possible.

---

## File Structure

```
src/
  main.zig              Entry point: GPA, parse config+CLI, call pipeline.run()
  config.zig            Config struct, std.zon.parse.fromSlice(), CLI merge, --generate-config
  pipeline.zig          Stage orchestration with arena hierarchy
  color.zig             OKLab arithmetic: deltaE -- delegates to zigimg for all sRGB <-> oklab conversions
  tile.zig              Tile/QuantizedTile types, extractTiles(), toKmeansVector()
  palette.zig           PaletteProcessor tagged union + Shared/PerFile/Preloaded strategies
  tileset.zig           TilesetProcessor tagged union + Shared/PerFile/Preloaded strategies
  dither.zig            DitherAlgorithm tagged union: Sierra impl + None passthrough
  quantize.zig          bestPaletteEntry(), bestPaletteForTile() -- single Delta E query site
  tilemap.zig           TilemapEntry packed struct (single source of bit layout), buildTilemap()
  output/
    writer.zig          OutputWriter tagged union: dispatch to format writers
    hex.zig             Space-separated hex, newlines per record, optional logisim "v2.0 raw\n" header
    binary.zig          Raw little-endian binary
    c_array.zig         C array defs with CArrayConfig (var prefix, type, include guard)
    image.zig           Reconstructed image output from just the tilemap, tileset and palette data (zigimg)
  input.zig             zigimg loading -- returns LoadedImage{pixels []OklabAlpha, width, height}
  kmeans.zig            UNCHANGED -- reused as-is
  lib.zig               Re-exports all modules (used by tests and bench)
  bench/
    bench_main.zig      Benchmark entry point, prints ns/op per benchmark
    bench_kmeans.zig    K-means throughput
    bench_dither.zig    Sierra dithering throughput
    bench_tile_match.zig  bestPaletteForTile throughput
tests/
  integration/
    test_roundtrip.zig  Full pipeline tests using real test_assets/ images and generated image test cases
```

---

## Interface Designs (Tagged Unions -- Single Dispatch Site Each)

### PaletteProcessor (`src/palette.zig`)
```zig
pub const PaletteProcessor = union(enum) {
    shared:    SharedPaletteState,
    per_file:  PerFilePaletteState,
    preloaded: PreloadedPaletteState,

    // One dispatch site -- inline else eliminates all scattered switch statements
    pub fn generatePalettes(self: *@This(), arena: Allocator, all_tiles: []const []const Tile, cfg: *const Config) ![]Palette {
        return switch (self.*) { inline else => |*s| s.generate(arena, all_tiles, cfg) };
    }
    pub fn assignTile(self: *const @This(), tile: *const Tile) u8 {
        return switch (self.*) { inline else => |*s| s.assign(tile) };
    }
};
```

### TilesetProcessor (`src/tileset.zig`)
Same pattern. Methods: `deduplicate(arena, quantized_tiles, cfg) !UniqueTileset`, `lookupTile(tile) u8`.
// Returns u8 -- the same type as TilemapEntry.tile_index, the single source of truth for tile index width.
// max_unique_tiles (u9) is one bit wider to represent the count; indices themselves are always u8.

### OutputWriter (`src/output/writer.zig`)
```zig
pub const OutputWriter = union(enum) {
    hex: HexWriter, binary: BinaryWriter, c_array: CArrayWriter,

    pub fn writeHeader(self: @This(), name: []const u8, out: AnyWriter) !void { ... inline else }
    pub fn writeBytes(self: @This(), data: []const u8, out: AnyWriter) !void { ... inline else }
    pub fn writeWords(self: @This(), data: []const u16, out: AnyWriter) !void { ... inline else }
    pub fn writeFooter(self: @This(), name: []const u8, out: AnyWriter) !void { ... inline else }
};
```

### DitherAlgorithm (`src/dither.zig`)
```zig
pub const DitherAlgorithm = union(enum) {
    sierra: SierraState,
    none:   void,

    // Quantize a tile using error diffusion. Uses a ColorMapper internally for per-pixel lookup.
    pub fn dither(self: @This(), arena: Allocator, tile: []OklabAlpha, palette: *const Palette, mapper: ColorMapper, cfg: *const Config) ![]u4 {
        return switch (self) { inline else => |*d| d.dither(arena, tile, palette, mapper, cfg) };
    }
};
```

### PaletteGenerator (`src/palette.zig`) -- pluggable palette-from-colors algorithm
```zig
// Answers: "given N pixel colors, produce K representative palette entries"
pub const PaletteGenerator = union(enum) {
    kmeans: KmeansPaletteGenerator,   // current: k-means in OKLab
    // Future: median_cut, octree, neural, etc.

    pub fn generate(self: *@This(), arena: Allocator, colors: []OklabAlpha, num_colors: u8, cfg: *const Config) !Palette {
        return switch (self.*) { inline else => |*g| g.generate(arena, colors, num_colors, cfg) };
    }
};
```
`PaletteProcessor` strategies hold a `PaletteGenerator` -- the multi-file strategy (shared/per_file/preloaded) is orthogonal to how palettes are generated.

### TileReducer (`src/tileset.zig`) -- pluggable tile deduplication/matching algorithm
```zig
// Answers: "given M quantized tiles, produce a canonical set of at most K unique tiles"
pub const TileReducer = union(enum) {
    exact_hash:   ExactHashReducer,    // exact dedup via HashMap (when count <= max_unique_tiles)
    kmeans_color: KmeansColorReducer,  // k-means on quantized color feature vectors (current fallback)
    // Future: texture_pattern, perceptual_hash, allocation, etc.

    // max_tiles is u9 (one bit wider than tile_index u8) so the count [0, 256] is expressible.
    // Use: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(TilemapEntry.tile_index)) + 1)
    pub fn reduce(self: *@This(), arena: Allocator, tiles: []const QuantizedTile, max_tiles: u9, cfg: *const Config) !UniqueTileset {
        return switch (self.*) { inline else => |*r| r.reduce(arena, tiles, max_tiles, cfg) };
    }
    // Returns u8 -- same type as TilemapEntry.tile_index. Single source of truth for tile index width.
    pub fn findBest(self: *const @This(), tile: *const QuantizedTile, tileset: *const UniqueTileset) u8 {
        return switch (self.*) { inline else => |*r| r.findBest(tile, tileset) };
    }
};
```
`TilesetProcessor` strategies hold a `TileReducer` -- the multi-file strategy is orthogonal to the matching algorithm.

**Summary of algorithm pluggability:**
| What | Interface | Default | Lives in |
|------|-----------|---------|---------|
| Per-pixel palette lookup | `ColorMapper` | `.nearest_oklab` | `quantize.zig` |
| Error diffusion pattern | `DitherAlgorithm` | `.sierra` | `dither.zig` |
| Palette generation from pixels | `PaletteGenerator` | `.kmeans` | `palette.zig` |
| Tile dedup / reduction | `TileReducer` | `.exact_hash` + `.kmeans_color` fallback | `tileset.zig` |
| Multi-file palette sharing | `PaletteProcessor` | `.shared` | `palette.zig` |
| Multi-file tileset sharing | `TilesetProcessor` | `.shared` | `tileset.zig` |
| Output format | `OutputWriter` | `.binary` | `output/writer.zig` |
| Tileset output layout | `TilesetStorageOrder` (config field) | `.row_major` | `config.zig`, used by all tileset writers |

---

## Config Struct (`src/config.zig`)

All fields named, none hardcoded anywhere else. Single source of truth.

```zig
pub const Config = struct {
    // Input
    input_files:          [][]const u8     = &.{},

    // Tile geometry
    tile_width:           u32              = 8,
    tile_height:          u32              = 8,
    tilemap_width:        u32              = 32,
    tilemap_height:       u32              = 32,

    // Palette
    palette_strategy:     PaletteStrategy  = .shared,  // .shared | .per_file | .preloaded
    num_palettes:         PaletteCount     = 32,  // u7 -- max = std.math.maxInt(PaletteIndex)+1 = 64; derived from TilemapEntry
    preloaded_palette:    ?[]const u8      = null,
    palette_start_offset: PaletteIndex     = 0,   // first palette slot this run may write into
    palette_0_color_0_is_black: bool       = true,
    color_similarity_threshold: f32        = 0.005,
    kmeans_max_iterations:      u32        = 10_000,
    color_reduction_max_iterations: u32    = 100_000,

    // Palette color count -- primary configurable field.
    // Enables offset-based palette sharing: e.g. two images can each use 4 colors at different
    // palette offsets (palette_start_offset) within the same 16-color palette slot.
    // When transparency is enabled, color 0 is reserved → effective usable colors = colors_per_palette - 1.
    // validate() enforces: colors_per_palette is a power of 2, and colors_per_palette <= 16
    //   (bounded by QuantizedTile's u4 pixel index type -- changing that type relaxes this bound).
    colors_per_palette:   u8               = 16,

    // Tileset
    tileset_strategy:     TilesetStrategy  = .shared,
    max_unique_tiles:     TileCount         = 256,  // u9 -- derived from TilemapEntry.tile_index type via std.meta
    preloaded_tileset:    ?[]const u8      = null,
    tileset_start_offset: TileIndex        = 0,   // first tile slot this run may write into

    // Algorithm selection (pluggable -- tagged union variants match the algorithm enums)
    palette_generator:    PaletteGeneratorAlgorithm = .kmeans,
    tile_reducer:         TileReducerAlgorithm    = .auto,  // .auto = exact_hash if count fits, kmeans_color otherwise

    // Dithering
    dither_algorithm:     DitherAlgorithmTag = .sierra, // or .none if disabled
    dither_factor:        f32              = 0.75,
    // dither_error_divisor is NOT a config field -- it is a comptime constant in dither.zig,
    // derived from the sum of Sierra kernel coefficients. See dither.zig:sierra_error_divisor.

    // Transparency
    // .none = no transparency support; .alpha = use image alpha channel; .color = treat specific sRGB color as transparent
    transparency_mode:    TransparencyMode = .none,
    transparent_color:    ?[3]u8           = null,  // sRGB R,G,B -- valid when transparency_mode == .color

    // Output
    output_dir:           []const u8       = ".",
    output_targets:       []OutputTarget   = &.{},
    write_preview_png:    bool             = false,
    write_json_dump:      bool             = false,
    // Tileset storage order -- controls how tile pixel data is laid out in the output.
    // .row_major: all tiles' row 0, then all tiles' row 1, ..., then all tiles' row N-1 (VDP hardware default)
    // .sequential: tile 0 complete, then tile 1 complete, ... (useful for manual post-processing / tileset merging)
    tileset_storage_order: TilesetStorageOrder = .row_major,

    /// Derived from colors_per_palette. Single query site -- all output writers call this for pixel packing.
    /// colors_per_palette must be a power of 2; validate() enforces this.
    pub fn bitsPerColorIndex(self: Config) u4 { return std.math.log2_int(u8, self.colors_per_palette); }

    pub fn validate(self: Config) !void { ... }     // enforces: colors_per_palette is power of 2,
                                                    // num_palettes + palette_start_offset <= TilemapEntry.palette_index max,
                                                    // max_unique_tiles + tileset_start_offset <= TilemapEntry.tile_index max + 1
    pub fn loadAndMerge(alloc, zon_path, cli) !Config { ... }
    pub fn generateDefault(writer: AnyWriter) !void { ... }  // emits ZON text
};

pub const TransparencyMode = enum {
    none,    // no transparency; all colors_per_palette colors usable
    alpha,   // pixels with alpha < 0.5 are transparent; color 0 reserved when tile has any
    color,   // pixels matching transparent_color are transparent; color 0 reserved when tile has any
};

/// Controls the byte layout of tile pixel data in output files.
/// Single source of truth: changing this enum changes layout everywhere output is written.
pub const TilesetStorageOrder = enum {
    /// Row-major (VDP hardware default): all tiles' pixel row 0 contiguous, then all tiles' row 1, etc.
    /// For 8×8 tiles, max_unique_tiles=256: output has 8 lines, each containing 256 × 2 u16 chunks.
    /// Matches the Rust imgconv output format (imgconv.rs:958-991).
    row_major,
    /// Sequential (tile-first): tile 0 fully (all 8 rows), then tile 1 fully, etc.
    /// Convenient for manual post-processing, tileset merging, or loading into non-VDP targets.
    sequential,
};

pub const OutputTarget = struct {
    format:  OutputFormat,
    path:    []const u8,
    c_opts:  ?CArrayConfig = null,
};

pub const CArrayConfig = struct {
    var_prefix:         []const u8 = "tilemap",
    tile_row_tpe:       []const u8 = "uint32_t",
    tilemap_entry_type: []const u8 = "uint16_t",
    include_guard:      []const u8 = "TILEMAP_H",
    add_stdint_include: bool       = true,
    use_const:          bool       = true,
    entries_per_line:   u32        = 16,
    hex_uppercase:      bool       = true,
};
```

**ZON parsing:** `std.zon.parse.fromSlice(Config, gpa, source_z, &diag, .{})` (Zig 0.15.1 API).
**ZON generation:** Custom writer in `generateDefault()` -- `std.zon` has no serializer.
**CLI overrides** a `CliOverrides` struct of `?T` optionals, merged after ZON parse.

---

## Key Data Structures

### TilemapEntry -- single source of bit layout
```zig
pub const TilemapEntry = packed struct(u16) {
    tile_index:    u8,    // bits [7:0]   -- max 256 unique tiles
    palette_index: u6,    // bits [13:8]  -- max 64 palettes
    transparent:   bool,  // bit  [14]    -- tile contains transparent pixels; color 0 = transparent, colors_per_palette-1 colors usable
    x_flip:        bool,  // bit  [15]    -- tile is horizontally flipped

    pub fn toU16(self: @This()) u16 { return @bitCast(self); }
    pub fn fromU16(v: u16) @This() { return @bitCast(v); }
};

// Canonical tile index and count types -- derived from TilemapEntry fields, single source of truth.
// Changing TilemapEntry.tile_index from u8 to u10 automatically updates both.
pub const TileIndex = @TypeOf(@as(TilemapEntry, undefined).tile_index);   // u8
pub const TileCount = std.meta.Int(.unsigned, @bitSizeOf(TileIndex) + 1); // u9 -- one extra bit for count up to maxInt(TileIndex)+1
pub const PaletteIndex = @TypeOf(@as(TilemapEntry, undefined).palette_index); // u6
pub const PaletteCount = std.meta.Int(.unsigned, @bitSizeOf(PaletteIndex) + 1); // u7
```

**Transparency semantics:**
- If `Config.transparency_mode != .none` and a tile contains at least one transparent pixel → `transparent = true`, color index 0 is reserved for transparency, tile has `colors_per_palette - 1` usable colors.
- If the tile has no transparent pixels → `transparent = false`, all `colors_per_palette` colors available.
- Transparent pixels are always assigned palette index 0 (regardless of palette content).
- `x_flip` is set when a horizontally-flipped version of another tile is used

### QuantizedTile
Packed 4-bit indices: `data: [(tile_w * tile_h + 1) / 2]u8`. For 8×8: 32 bytes.
Provides `getIndex(x,y,w) u4`, `setIndex(x,y,w,u4)`, `eql()`, `hash()` (for HashMap dedup).

### Palette
`colors: [colors_per_palette]OklabAlpha`, `count: u8`. Comptime-sized; instantiated as `Palette(cfg.colors_per_palette)`.
// Single source of truth: Config.colors_per_palette. The Palette type is a comptime function Palette(n: u8) type.
// IMPORTANT: QuantizedTile stores pixel indices as u4 (4 bits, max value 15).
// validate() must enforce colors_per_palette <= 1 << 4 = 16 (i.e. fits in u4 index).
// Changing QuantizedTile's index width (u4 → u8) and validate()'s bound is the single change needed to support larger palettes.

---

## Algorithms to Preserve

### Delta E (`color.zig`) -- one place, used everywhere
```zig
pub inline fn deltaESquared(a: OklabAlpha, b: OklabAlpha) f32 {
    const dl = a.l-b.l; const da = a.a-b.a; const db = a.b-b.b;
    return dl*dl + da*da + db*db;
}
pub inline fn deltaE(a: OklabAlpha, b: OklabAlpha) f32 { return @sqrt(deltaESquared(a,b)); }
```
Thresholds use `deltaESquared < threshold*threshold` (avoids sqrt in tight loops).

### Sierra Dithering coefficients (`dither.zig`)
```zig
const SierraCoeff = struct { dx: i32, dy: i32, num: f32 };
const sierra_pattern = [_]SierraCoeff{
    .{.dx= 1,.dy=0,.num=5}, .{.dx= 2,.dy=0,.num=3},
    .{.dx=-2,.dy=1,.num=2}, .{.dx=-1,.dy=1,.num=4}, .{.dx=0,.dy=1,.num=5}, .{.dx=1,.dy=1,.num=4}, .{.dx=2,.dy=1,.num=2},
    .{.dx=-1,.dy=2,.num=2}, .{.dx= 0,.dy=2,.num=3}, .{.dx=1,.dy=2,.num=2},
};
// Single source of truth: the error divisor IS the sum of kernel coefficients (= 32).
// It is NOT a Config field -- that would create two sources of truth for the same mathematical fact.
pub const sierra_error_divisor: f32 = comptime blk: {
    var sum: f32 = 0;
    for (sierra_pattern) |c| sum += c.num;
    break :blk sum;
};
// factor = Config.dither_factor (default 0.75)
```
Operates on a `[tile_w*tile_h]OklabAlpha` scratch buffer (arena, reset between tiles). All three L/a/b channels are dithered; alpha is not.

### K-means interface (`kmeans.zig` -- unchanged)
```zig
// KMeans is a comptime function: KMeans(f32, allocator, k, tol, max_it) type
var km = KMeans(f32, arena, num_palettes, null, kmeans_max_iterations){};
try km.fit(feature_vectors);   // [][]f32 -- flattened tile pixels
const centers = try km.getCenters();
```

### Tile Deduplication
Fast path: `std.HashMap(QuantizedTile, u8, Context, 80)` -- exact match.
// Value type u8 = TilemapEntry.tile_index type. Tile indices are always u8; max_unique_tiles (u9) is the count.
If `unique_count > max_unique_tiles`: k-means fallback -- tile as flat f32 vector, k = `max_unique_tiles`.

---

## Memory Management

Prefer up-front pre-allocation, falling back to arenas when that is not possible.

```
GPA (root -- leak detection in debug)
├── Config + input paths (lifetime = process)
└── pipeline.run():
    ├── load_arena      freed after tile extraction
    ├── palette_arena   freed after quantization
    ├── quantize_scratch  arena.reset(.retain_capacity) per tile (avoids alloc churn)
    └── result_arena    lives until output complete (holds tileset, tilemap)
```

---

## CLI Design

```
sjtilemap [OPTIONS] [INPUT_FILES...]

  -h, --help                        Display help
  -i, --input <str>...              Input file(s) (repeatable or positional)
  -o, --output-dir <str>            Output directory (default: ".")
  -c, --config <str>                Load ZON config file
      --generate-config <str>       Write default config ZON to file and exit
      -f, --format <str>...         hex|logisim|binary|c_array (repeatable)
      --tile-width <u32>            (default: 8)
      --tile-height <u32>           (default: 8)
      --tilemap-width <u32>         (default: image width / 8)
      --tilemap-height <u32>        (default: image height / 8)
      --num-palettes <u8>           (default: 32 - palette-offset)
      --palette-offset <u8>         First usable palette index (default: 0)
      --colors-per-palette <u8>     (default: 16)
      --palette-strategy <str>      shared|per_file|preloaded
      --preloaded-palette <str>     Path to existing palette file
      --num-preloaded-palettes <u8> Number of preloaded palettes that can be used (default: 32) 
      --num-tiles <u16>             Max number of tiles to use (1–256, default: 256; validated by Config.validate())
      --tileset-offset <u8>         First usable tile offset (default: 0)
      --tileset-strategy <str>      shared|per_file|preloaded
      --tileset-storage-order <str> row_major|sequential (default: row_major)
      --transparency <str>          none|alpha|color (default: none)
      --transparent-color <str>     RRGGBB hex -- transparent color when --transparency=color
      --preloaded-tileset <str>     Path to existing tileset file
      --num-preloaded-tiles <u8>    Number of preloaded tiles that can be used (default: 256)
      --palette-generator <str>     kmeans (default; others TBD)
      --tile-reducer <str>          auto|exact_hash|kmeans_color (default: auto)
      --no-dither                   Disable dithering
      --dither-factor <f32>         (default: 0.75)
      --c-var-prefix <str>          C array variable prefix (default: "tilemap")
      --c-tilemap-type <str>        C tilemap entry type (default: "uint16_t")
      --c-tileset-row-type <str>    C tileset row type (default: "uint32_t")
      --c-entries-per-line <u32>    Number of entries per line in tilemap/tileset
      --no-c-include-stdint         Disable C `#include <stdint.h>`
      --no-c-const                  Disable C `const` keyword usage
      --no-c-uppercase-hex          Disable C hex being uppercase
      --preview                 Write preview PNG reconstruction
      --json-dump                   Write full JSON dump
      -v, --verbose                 Progress output to stderr
```

---

## Phase-by-Phase Implementation (TDD)

Each phase follows this ritual without exception:
1. Write the test(s) -- they must fail for the right reason
2. Run `zig build test`, read the failure message, confirm it says what you expect
3. Implement **only** the minimum code needed to make those tests pass
4. Run `zig build test`, confirm green
5. Move to the next phase

Phases are ordered by capability/scenario, not by module. Modules are implemented in whatever order the tests demand. No feature is coded before a failing test exists for it.

### Phase 0 -- Scaffolding & Build System

Create directories and empty stub files, configure `build.zig` with `lib_mod`, the `bench` executable (`ReleaseFast`+LLVM), and the integration test module. Each stub file contains exactly one `@compileError("not yet implemented")` test so that `zig build test` fails with a clear, expected error for every module. Verify every stub fails, then replace the compile errors with `return error.NotImplemented` so the build succeeds and all tests fail at runtime. This confirms the test runner reaches every module before any real code is written.

### Phase 1 -- Verified deltaE: known values from an external library

**Why first:** every downstream test that judges color match quality depends on `deltaE` being correct. A bug here would silently corrupt all later tests.

**Rust reference:** `color.rs:125–146` (`oklab_delta_e()`). Note: the Rust version uses the `oklab` crate for sRGB↔Oklab; the Zig version delegates to zigimg. The formula is identical: √(ΔL² + Δa² + Δb²).

Write the test cases by running a temporary Node.js script (delete it after) using the `colorjs` npm library to compute deltaE for a set of specific OKLab color pairs. Hard-code the gathered `(a, b, expected_deltaE)` triples directly in the test. Assert that `color.deltaE(a, b)` is within 1e-5 of each expected value. Include pairs that span: identical colors (deltaE = 0), maximally distant colors, and several mid-range pairs.

Implement `color.zig`: `deltaE` and `deltaESquared` only. Delegate all OKLab ↔ sRGB conversion to zigimg -- `color.zig` must contain zero conversion math of its own.

### Phase 2 -- 8×8 single tile, 16 exact colors, pixel-perfect reconstruction

**Scenario:** an 8×8 PNG with exactly 16 distinct sRGB colors (one unique color per pixel in a known pattern) is converted with `transparency_mode=.none` and `dither_algorithm=.none`.

**Rust reference:**
- Main pipeline order: `imgconv.rs:260–308` (`convert()`)
- Image reading: `imgconv.rs:310–340`
- Tile extraction: `imgconv.rs:342–373` (`extract_tiles()`)
- Palette k-means: `imgconv.rs:376–419` (`generate_palettes()`) and `452–568`
- Pixel quantization (no dither): `imgconv.rs:803–858` (`quantize_pixels()`)
- Output image reconstruction: `imgconv.rs:993–1041`
- Config struct defaults: `imgconv.rs:96–116`

Write the test: generate the PNG programmatically in the test, run the full pipeline, reconstruct the preview PNG. Assert:
- Every (x, y) pixel in the reconstructed PNG matches the original input exactly (pixel-for-pixel, no tolerance)
- The tileset contains exactly 1 tile
- The tilemap is a single entry: `tile_index=0`, `palette_index=0`

This drives the first complete vertical slice: `input/`, `tile.zig` (extraction only), `palette.zig` (k-means with k=16 on 16 distinct colors converges to exact colors), `quantize.zig` (bestPaletteEntry), `tilemap.zig` (buildTilemap), `output/image.zig` (preview PNG), `config.zig` (defaults only), `pipeline.zig` (happy path). Do not implement any feature not required to make this one test pass.

### Phase 3 -- TilemapEntry bit layout: the VDP hardware contract

The VDP hardware reads specific bits at specific positions. This test verifies that contract is met -- it is a feature test, not a property test.

**Rust reference:** `imgconv.rs:200–217` (struct definition) and `imgconv.rs:915–922` (encoding). **Critical difference:** the Rust version uses `PALETTE_INDEX_SHIFT = 10` (bits [15:10] = palette, bits [9:0] = tile). The Zig VDP hardware contract uses a different layout: bits [7:0] = tile (u8), bits [13:8] = palette (u6), bit [14] = transparent, bit [15] = x_flip. Do NOT copy the Rust encoding. Use the Zig bit layout exclusively.

Write the test with concrete bit-pattern examples (not a round-trip loop):
- `tile_index=0xFF, palette_index=0x3F, transparent=true, x_flip=true` → `toU16() == 0xFFFF`
- `tile_index=0x01, palette_index=0x00, transparent=false, x_flip=false` → `toU16() == 0x0001`
- `tile_index=0xAB, palette_index=0x15, transparent=false, x_flip=false` → `toU16() == 0x15AB`
- `fromU16(0xFFFF)` → fields match the first case above

Implement `TilemapEntry` packed struct. No other code changes.

### Phase 4 -- Tile deduplication: 16×16 with 4 identical tiles

**Scenario:** a 16×16 PNG = 4 tiled copies of the Phase 2 pattern (same 16 colors, same layout in each quadrant).

**Rust reference:** `imgconv.rs:622–700` (`cluster_quantized_tiles()`) — the Rust uses k-means for dedup; the Zig fast path is `ExactHashReducer` (exact hash dedup), which is strictly better when tile count ≤ `max_unique_tiles`. See also `imgconv.rs:742–766` (`calculate_reconstruction_error()`) for how the Rust selects representative tiles.

Write the test: generate the PNG, run the full pipeline. Assert:
- Reconstructed PNG is pixel-for-pixel identical to input
- Tileset contains exactly 1 unique tile
- Tilemap is 2×2 with all 4 entries having `tile_index=0`, `palette_index=0`

Implement `ExactHashReducer` in `tileset.zig`. No other new code.

### Phase 5 -- 4 different tiles, 1 shared palette

**Scenario:** a 16×16 PNG with 4 distinct 8×8 patterns, all drawn using the same 16 sRGB colors.

**Rust reference:**
- Palette assignment: `imgconv.rs:571–620` (`assign_palettes()`, `find_best_palette_for_tile()`)
- Best tile+palette matching: `imgconv.rs:702–740` (`find_best_tile_assignments()`)
- Reconstruction error: `imgconv.rs:742–766` (`calculate_reconstruction_error()`)

Write the test. Assert:
- Reconstructed PNG is pixel-for-pixel identical to input
- Tileset contains exactly 4 unique tiles
- Tilemap is 2×2 with 4 distinct `tile_index` values (each of 0–3 appears exactly once)
- All tilemap entries have `palette_index=0`
- The palette contains exactly 16 colors and each input color appears in it (order-independent check)

### Phase 6 -- Multiple palettes: 1 tile, 4 color sets

**Scenario:** a 16×16 PNG with 4 copies of the same 8×8 tile pattern, but each quadrant uses a completely different 16-color set (64 distinct colors total, no overlap between quadrants). The test must use `palette_0_color_0_is_black = false` (override the default) so that black is not force-injected into palette 0; this keeps the assertion that each palette contains exactly the 16 colors from its quadrant straightforward.

**Rust reference:**
- Palette k-means over all tiles: `imgconv.rs:376–419` (`generate_palettes()`) — clusters tiles by hue content to assign each tile to a palette cluster
- Clustering data prep (hue sorting, permutations): `imgconv.rs:422–449` (`prepare_clustering_data()`)
- Palette color extraction per cluster: `imgconv.rs:452–486` (`extract_palette_colors()`)
- Palette processing and sorting: `imgconv.rs:489–568` (`process_palettes()`)
- Force palette[0].color[0] = black: `imgconv.rs:411–413`

Write the test. Assert:
- Reconstructed PNG is pixel-for-pixel identical to input
- Tileset contains exactly 1 unique tile
- Tilemap is 2×2 with `tile_index=0` for all entries but 4 distinct `palette_index` values
- 4 palettes are generated, each containing exactly the 16 colors from its quadrant (order-independent check)

Implement multi-palette support in `palette.zig` and palette assignment in `quantize.zig` (`bestPaletteForTile`).

### Phase 7 -- Lossy quantization with Sierra dithering

**Scenario:** an 8×8 tile with 64 distinct colors across a smooth gradient, palette limited to 16 colors. Exact reconstruction is impossible; dithering must improve visual quality.

**Rust reference:**
- Sierra kernel weights: `imgconv.rs:861–912` (`apply_sierra_dithering()`) -- canonical weights are in `dither.zig:sierra_pattern` (see "Algorithms to Preserve"), not re-listed here.
- Error divisor: `imgconv.rs:30` (`DITHER_ERROR_DIVISOR = 32.0`) -- in Zig this is `dither.sierra_error_divisor`, a comptime constant derived from the kernel sum. Not a config field.
- Pixel quantization loop with dithering: `imgconv.rs:803–858` (`quantize_pixels()`)
- Dither factor default: `imgconv.rs:112` (`dither_factor: 0.75`)
- Error metrics (PSNR + delta-E): `imgconv.rs:1043–1158` (`generate_error_metrics()`)

**Generating baseline thresholds:**
```bash
# Generate the gradient test image programmatically (e.g., Python PIL), save to /tmp/gradient_8x8.png
# Then run Rust to get baseline PSNR and delta-E:
cargo run --release -- \
  -i /tmp/gradient_8x8.png \
  -o /tmp/gradient_golden.png \
  --palette-hex /tmp/gradient_palette.hex \
  --tiles-hex /tmp/gradient_tiles.hex \
  --tilemap-hex /tmp/gradient_tilemap.hex \
  --tile-size 8x8 --tilemap-size 1x1
# Read stdout for: PSNR (dB) and delta-E percentiles (×100 display factor)
# Hard-code Rust PSNR and mean delta-E as minimum thresholds in the Zig test.
```

Write the test. Assert:
- Zig version PSNR ≥ Rust PSNR
- Zig version average per-pixel deltaE ≤ Rust average per-pixel deltaE
- With `dither_factor=0.0`, output is identical to `dither_algorithm=.none` on the same image

Note: `dither.sierra_error_divisor` is a comptime constant derived by summing the kernel coefficients — it cannot diverge from the actual kernel. Do not write a test that asserts its value (that would test an internal figure, not a feature). The PSNR/deltaE assertions above are the feature tests; if a coefficient were accidentally changed, quality would degrade and those assertions would catch it.

Implement Sierra dithering in `dither.zig`.

### Phase 8 -- Transparency

**Rust reference:** Transparency is **not implemented** in the Rust version — it processes RGB only, no alpha channel. This feature is Zig-only per the VDP hardware spec. There are no Rust baselines to compare against for these tests; the correctness criteria are the VDP hardware contract and pixel-level assertions described below.

Write three tests:

**Test A:** 8×8 PNG with a mix of fully opaque and fully transparent pixels, `transparency_mode=.alpha`. Assert:
- Reconstructed PNG transparent pixels have alpha=0 at exact same positions as input
- Reconstructed opaque pixels match input colors exactly
- The tilemap entry has `transparent=true`
- Palette color index 0 is not used for any opaque color

**Test B:** 8×8 PNG with all opaque pixels, `transparency_mode=.alpha`. Assert: tilemap entry has `transparent=false`.

**Test C:** Same alpha-channel PNG but `transparency_mode=.none`. Assert: `transparent=false` for every tilemap entry; the alpha channel is ignored entirely.

Implement transparency handling threaded through `quantize.zig`, `tilemap.zig`, and `pipeline.zig`.

### Phase 9 -- x_flip tile deduplication

**Rust reference:** x_flip is **not implemented** in the Rust version. This feature is Zig-only per the VDP hardware spec (`TilemapEntry.x_flip` bit 15). No Rust baselines exist; correctness is verified purely by the pixel-level assertions below.

**Scenario:** a 16×16 PNG where the left 8×8 half is the exact horizontal mirror of the right 8×8 half.

Write the test. Assert:
- Reconstructed PNG is pixel-for-pixel identical to input
- Tileset contains exactly 1 unique tile
- The tilemap entry for the mirrored tile has `x_flip=true`; the original has `x_flip=false`

### Phase 10 -- Output formats

- Hex output has a flag to enable the logisim header or not
- C-array and binary output should be idential to hex, but with different encoding (and never has logisim header)
- All output formats for tilesets can be either row-major order for the values, or sequential
- Row-major tilesets must be padded with zero bytes if there are less than 256 tiles

**Rust reference:**
- Palette hex format: `imgconv.rs:924–942` — RGB triplets `{RR}{GG}{BB} `, one palette per line, padded to `colors_per_palette` entries
- Tilemap hex format: `imgconv.rs:944–956` — 4-digit hex `{XXXX} `, one row per line (note: Rust uses `PALETTE_INDEX_SHIFT=10`; Zig encoding differs)
- Tiles hex format: `imgconv.rs:958–991` — **row-major**: outer loop = pixel row (0..tile_height), inner loop = tile. Each output line contains all tiles' data for that pixel row, 2 u16 chunks per tile, padded to `max_unique_tiles`. The Zig version supports both `.row_major` (default, matches this) and `.sequential` (tile 0 fully, then tile 1, etc.) via `Config.tileset_storage_order`.
- No logisim/binary/C-array formats in Rust — those are Zig additions

Write a separate test for each output format, each asserting actual content at specific positions -- not just "the file exists" or "the file is non-empty".

- **Hex:** write a known two-entry tilemap (e.g., `[0x0001, 0xFFFF]`); assert the output string matches `"0001 FFFF\n"` (or whatever the exact format requires) character-by-character
- **Logisim:** assert output begins with exactly `"v2.0 raw\n"`; assert the same two entries follow in the correct encoding
- **Binary:** write known u16 values; read back raw bytes; assert little-endian encoding at specific byte offsets (byte 0 = LSB of first entry, byte 1 = MSB of first entry, etc.) -- binary should be identical to the hex output if the hex output is converted to binary first (but never has a logisim header)
- **C array:** assert the output contains the exact include guard string; assert the tilemap array declaration uses the configured type name; assert entries_per_line is respected by checking newline positions in the output
- **Tileset storage order — row_major:** use a 2-tile tileset where tile 0 has a known row 0 and tile 1 has a different known row 0. Assert that the first line of tileset output contains tile 0's row 0 chunks followed immediately by tile 1's row 0 chunks, and the second line contains both tiles' row 1 chunks, etc. This verifies the outer-loop-over-rows, inner-loop-over-tiles order.
- **Tileset storage order — sequential:** same 2-tile tileset. Assert that the output contains tile 0's complete data (all rows) before any data from tile 1. Verify that switching `tileset_storage_order` from `.row_major` to `.sequential` on the same input produces a different but deterministic byte sequence.

### Phase 11 -- Config & CLI

**Rust reference:**
- CLI arg parsing (manual, no clap): `main.rs:13–187`
- Config struct with all defaults: `imgconv.rs:58–143` (struct) and `imgconv.rs:96–116` (defaults)
- Key defaults to match: `color_similarity_threshold=0.005`, `kmeans_max_iterations=10000`, `color_reduction_max_iterations=100000`, `dither_factor=0.75`
- `dither_error_divisor` is **not** a config field in Zig -- it is `dither.sierra_error_divisor`, a comptime constant
- Force palette[0].color[0] = black: `imgconv.rs:411–413`
- The Zig version uses ZON config + clap; the Rust parsing is reference only for defaults and semantics

Write tests that exercise the full config pathway, not just field assignment:

- `generateDefault()` output round-trips: parse it back with `std.zon.parse.fromSlice`, verify all fields equal the documented defaults
- A ZON file setting `tile_width = 16` is loaded; assert the pipeline produces tiles with 16-pixel-wide pixel data in the tileset output
- `validate()` called on a config where `num_palettes + palette_start_offset > 64` (exceeds TilemapEntry.palette_index u6 max) returns an error; the error message names the offending fields
- CLI `--tile-width 16 --tile-height 16` on a programmatically generated 16×16 image (one unique tile) produces a 1×1 tilemap entry where the single tile's pixel data spans 16 columns × 16 rows (verify by checking the tileset output byte count = 16×16 pixels packed at `bitsPerColorIndex()` bits each)
- `palette_0_color_0_is_black = true` in config → the OKLab value at `palettes[0].colors[0]` is black (L=0, a=0, b=0) in the output

### Phase 12 -- Multi-file processing

**Rust reference:** Multi-file processing is **not implemented** in the Rust version — it processes exactly one input image. This entire feature is Zig-only. No Rust baselines exist; verify correctness via the assertions below and by running two images independently through the Rust version to confirm expected tile/palette counts for each.

Write tests using two programmatically generated 16×16 images (A and B) with overlapping and non-overlapping tile patterns and color sets:

- **Shared palette, shared tileset:** tiles common to both images appear once in the tileset; the single palette covers all colors; each image gets its own tilemap with correct indices into the shared palette and tileset
- **Per-file palette, shared tileset:** each image has its own palette; common tiles still appear once in the tileset
- **Shared palette, per-file tileset:** single palette; each image has its own tileset with its own tile indices
- **Per-file palette, per-file tileset:** fully independent pipeline per file; verify no cross-contamination between outputs

### Phase 13 -- Full integration with real images

**Rust reference:**
- Full pipeline: `imgconv.rs:260–308` (`convert()`)
- Error metrics output: `imgconv.rs:1043–1158` (`generate_error_metrics()`) — prints delta-E percentiles (×100) and PSNR per channel

**Generating baselines:**
```bash
cd /home/rj45/code/vdp/imgconv

# Gouldian Finch (256×256 = 32×32 tilemap)
cargo run --release -- \
  -i /home/rj45/code/starjay/tools/sjtilemap/test_assets/Gouldian_Finch_256x256.png \
  -o /tmp/golden_finch.png \
  --palette-hex /tmp/palette_finch.hex \
  --tiles-hex /tmp/tiles_finch.hex \
  --tilemap-hex /tmp/tilemap_finch.hex
# Record stdout: PSNR (dB avg) and delta-E mean (divide display value by 100)

# Kodak image (crop/resize to 256×256 first if needed)
cargo run --release -- \
  -i /path/to/kodak_23_256x256.png \
  -o /tmp/golden_kodak.png \
  --palette-hex /tmp/palette_kodak.hex \
  --tiles-hex /tmp/tiles_kodak.hex \
  --tilemap-hex /tmp/tilemap_kodak.hex
# Record stdout: PSNR and delta-E mean
```

Gather baseline thresholds by running the Rust version (`cargo build --release`) on `test_assets/Gouldian_Finch_256x256.png` and at least one Kodak image. Record PSNR and average per-pixel deltaE. Hard-code as minimum-acceptable thresholds.

Write the tests. Assert for each image:
- Zig version PSNR ≥ Rust baseline PSNR
- Zig version average per-pixel deltaE ≤ Rust baseline average per-pixel deltaE
- Number of unique tiles in tileset ≤ `max_unique_tiles`
- Tilemap dimensions = (image_width / tile_width) × (image_height / tile_height)

### Phase 14 -- Benchmarks

**Rust reference:** No benchmark harness exists in the Rust version. Use the Rust binary's wall-clock time on large images as a rough upper-bound reference for the Zig benchmarks — the Zig version should be faster in all hot paths given SIMD k-means.

`zig build bench` runs and prints `name: N ns/op` for: `deltaE` 1M ops, k-means (16 colors, 1000 points, 100 runs), Sierra dithering 100K 8×8 tiles, `bestPaletteForTile` 10K tiles. No correctness assertions -- timing output only.

---

## Build System Changes (`build.zig`)

```zig
/////////////////////////////////////////////////////////////////
// lib_mod: shared module (no main), used by exe, tests, bench
/////////////////////////////////////////////////////////////////
const lib_mod = b.createModule(.{
    .root_source_file = b.path("src/lib.zig"),
    .target = target, .optimize = optimize,
    .imports = &.{ .{.name="zigimg",...}, .{.name="clap",...} },
});

/////////////////////////////////////////////////////////////////
// exe_mod: executable's module
/////////////////////////////////////////////////////////////////

// exe and test_mod use lib_mod

/////////////////////////////////////////////////////////////////
// Bench executable: always ReleaseFast
/////////////////////////////////////////////////////////////////
const bench_exe = b.addExecutable(.{
    .name = "sjtilemap-bench", .use_llvm = true,
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/bench/bench_main.zig"),
        .target = target, .optimize = .ReleaseFast,
        .imports = &.{ .{.name="lib", .module=lib_mod} },
    }),
});
const bench_step = b.step("bench", "Run benchmarks");
bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

/////////////////////////////////////////////////////////////////
// Integration tests
///////////////////////////////////////////////////////////////////
const integ_mod = b.createModule(.{
    .root_source_file = b.path("tests/integration/test_roundtrip.zig"),
    .imports = &.{ .{.name="lib", .module=lib_mod} },
});
test_step.dependOn(&b.addRunArtifact(b.addTest(.{.root_module=integ_mod})).step);
```

---

## Verification

```bash
# Build
zig build

# Unit + integration tests (all phases)
zig build test

# Run on a real image
zig build run -- -i test_assets/Gouldian_Finch_256x256.png -f hex -f c_array --preview -o /tmp/out

# Benchmarks
zig build bench

# Multi-file with shared palette, per-file tilesets
zig build run -- -i test_assets/test_pattern_128x128.png -i test_assets/test_pattern_256x256.png \
  --palette-strategy shared --tileset-strategy per_file -f logisim -o /tmp/out

# Generate default config
zig build run -- --generate-config > /tmp/default_config.zon

# Load config from ZON
zig build run -- --config /tmp/default_config.zon -i test_assets/kodak_23_256x256.png
```

---

## Critical Files

- `src/kmeans.zig` -- Reuse unchanged. Interface: `KMeans(f32, alloc, k, tol, max_it){}`, `.fit([][]f32)`, `.getCenters() ![][]f32`
- `src/main.zig` -- Replace entirely; becomes ~30-line entry point
- `build.zig` -- Extend (do not replace) with lib_mod, bench step, integration test options
- `build.zig.zon` -- No changes needed
- zigimg `color.zig` at cache path -- Reference for `OklabAlpha = extern struct { l, a, b, alpha: f32 }` layout
  - /home/rj45/.cache/zig/p/zigimg-0.1.0-8_eo2qWHFwA-S24SH7x7NplPii0EbIQiUfDrimgA6rzN/src/color.zig
- ZON parse API: `std.zon.parse.fromSlice(T, gpa, [:0]const u8, ?*Diagnostics, Options) !T` and `std.zon.parse.free(gpa, value)`
