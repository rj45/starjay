const std = @import("std");
const clap = @import("clap");
const zigimg = @import("zigimg");
const lib = @import("lib");
const hex_out = lib.output.hex;
const binary_out = lib.output.binary;
const c_array_out = lib.output.c_array;
const json_out = lib.output.json;
const color_mod = lib.color;
const OklabAlpha = color_mod.OklabAlpha;

pub fn main() !void {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();
    defer if (gpa_instance.deinit() != .ok) @panic("Memory leak on exit!");

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                         Display help and exit.
        \\-i, --input <str>...               Input file(s).
        \\-o, --output-dir <str>             Output directory (default: ".").
        \\-c, --config <str>                 Load ZON config file (not yet implemented).
        \\    --generate-config <str>        Write default config ZON to file and exit.
        \\-f, --format <str>...              Output format(s): hex|logisim|binary|c_array (repeatable).
        \\    --tile-width <u32>             Tile width in pixels (default: 8).
        \\    --tile-height <u32>            Tile height in pixels (default: 8).
        \\    --tilemap-width <u32>          Tilemap width in tiles (default: image_width/tile_width).
        \\    --tilemap-height <u32>         Tilemap height in tiles (default: image_height/tile_height).
        \\    --num-palettes <u32>           Number of palettes (default: 32).
        \\    --palette-offset <u32>         First usable palette index (default: 0).
        \\    --colors-per-palette <u32>     Colors per palette (default: 16).
        \\    --num-tiles <u32>              Max unique tiles (default: 256).
        \\    --tileset-offset <u32>         First usable tile index (default: 0).
        \\    --tileset-storage-order <str>  row_major|sequential (default: row_major).
        \\    --transparency <str>           none|alpha|color (default: none).
        \\    --transparent-color <str>      RRGGBB hex color treated as transparent (use with --transparency=color).
        \\    --no-dither                    Disable dithering.
        \\    --dither-factor <f32>          Dither strength 0.0-1.0 (default: 0.75).
        \\    --palette-strategy <str>       shared|per_file|preloaded (default: shared).
        \\    --preloaded-palette <str>      Path to palette hex file (use with --palette-strategy=preloaded).
        \\    --tileset-strategy <str>       shared|per_file|preloaded (default: shared).
        \\    --preloaded-tileset <str>      Path to tileset hex file (use with --tileset-strategy=preloaded).
        \\    --num-preloaded-tiles <u32>    Number of real tiles in preloaded tileset (0 = use --num-tiles).
        \\    --num-preloaded-palettes <u32> Number of palettes to use from preloaded palette (0 = load all).
        \\    --palette-generator <str>      Palette generation algorithm: kmeans (default).
        \\    --tile-reducer <str>           Tile dedup algorithm: auto|exact_hash|kmeans_color (default: auto).
        \\    --c-var-prefix <str>           C array variable name prefix (default: "tilemap").
        \\    --c-tilemap-type <str>         C type for tilemap entries (default: "uint16_t").
        \\    --c-tileset-row-type <str>     C type for tileset row words (default: "uint32_t").
        \\    --c-entries-per-line <u32>     Entries per line in C arrays (default: 16).
        \\    --no-c-include-stdint          Omit #include <stdint.h> from C output.
        \\    --no-c-const                   Omit const qualifier from C array declarations.
        \\    --no-c-uppercase-hex           Use lowercase hex in C array output.
        \\    --json-dump <str>              Write full JSON dump to file.
        \\    --preview                      Write preview PNG reconstruction.
        \\    --preview-palette              Write palette squares to an output PNG.
        \\-v, --verbose                      Progress output to stderr.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        return;
    }

    // --generate-config: write defaults to file and exit
    if (res.args.@"generate-config") |path| {
        var writer = std.io.Writer.Allocating.init(gpa);
        defer writer.deinit();

        try lib.config.Config.generateDefault(&writer.writer);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(writer.written());
        std.debug.print("Wrote default config to {s}\n", .{path});
        return;
    }

    // Collect input files from -i flags
    if (res.args.input.len == 0) {
        try clap.helpToFile(.stderr(), clap.Help, &params, .{});
        return;
    }

    const output_dir = res.args.@"output-dir" orelse ".";

    // Build config: start from ZON file if -c is given, otherwise use defaults
    var cfg = if (res.args.config) |config_path|
        try lib.config.Config.load(gpa, config_path)
    else
        lib.config.Config{};

    if (res.args.verbose != 0) cfg.verbose = true;
    if (res.args.@"tile-width") |v| cfg.tile_width = v;
    if (res.args.@"tile-height") |v| cfg.tile_height = v;
    if (res.args.@"tilemap-width") |v| cfg.tilemap_width = v;
    if (res.args.@"tilemap-height") |v| cfg.tilemap_height = v;
    if (res.args.@"num-palettes") |v| cfg.num_palettes = v;
    if (res.args.@"palette-offset") |v| cfg.palette_start_offset = v;
    if (res.args.@"colors-per-palette") |v| cfg.colors_per_palette = v;
    if (res.args.@"num-tiles") |v| cfg.max_unique_tiles = v;
    if (res.args.@"tileset-offset") |v| cfg.tileset_start_offset = v;
    if (res.args.@"dither-factor") |v| cfg.dither_factor = v;

    if (res.args.@"no-dither" != 0) {
        cfg.dither_algorithm = .none;
    }

    if (res.args.@"tileset-storage-order") |v| {
        if (std.mem.eql(u8, v, "sequential")) {
            cfg.tileset_storage_order = .sequential;
        } else if (std.mem.eql(u8, v, "row_major")) {
            cfg.tileset_storage_order = .row_major;
        } else {
            std.debug.print("Unknown tileset-storage-order: {s}\n", .{v});
            return error.InvalidArgument;
        }
    }

    if (res.args.transparency) |v| {
        if (std.mem.eql(u8, v, "alpha")) {
            cfg.transparency_mode = .alpha;
        } else if (std.mem.eql(u8, v, "color")) {
            cfg.transparency_mode = .color;
        } else if (std.mem.eql(u8, v, "none")) {
            cfg.transparency_mode = .none;
        } else {
            std.debug.print("Unknown transparency mode: {s}\n", .{v});
            return error.InvalidArgument;
        }
    }

    if (res.args.@"transparent-color") |hex_str| {
        if (hex_str.len != 6) {
            std.debug.print("--transparent-color must be exactly 6 hex digits (RRGGBB), got: {s}\n", .{hex_str});
            return error.InvalidArgument;
        }
        const r = std.fmt.parseInt(u8, hex_str[0..2], 16) catch {
            std.debug.print("--transparent-color: invalid hex in R component: {s}\n", .{hex_str[0..2]});
            return error.InvalidArgument;
        };
        const g = std.fmt.parseInt(u8, hex_str[2..4], 16) catch {
            std.debug.print("--transparent-color: invalid hex in G component: {s}\n", .{hex_str[2..4]});
            return error.InvalidArgument;
        };
        const b = std.fmt.parseInt(u8, hex_str[4..6], 16) catch {
            std.debug.print("--transparent-color: invalid hex in B component: {s}\n", .{hex_str[4..6]});
            return error.InvalidArgument;
        };
        cfg.transparent_color = .{ r, g, b };
    }

    if (res.args.@"palette-strategy") |v| {
        if (std.mem.eql(u8, v, "shared")) {
            cfg.palette_strategy = .shared;
        } else if (std.mem.eql(u8, v, "per_file")) {
            cfg.palette_strategy = .per_file;
        } else if (std.mem.eql(u8, v, "preloaded")) {
            cfg.palette_strategy = .preloaded;
        } else {
            std.debug.print("Unknown palette-strategy: {s}\n", .{v});
            return error.InvalidArgument;
        }
    }
    if (res.args.@"preloaded-palette") |v| cfg.preloaded_palette = v;

    if (res.args.@"tileset-strategy") |v| {
        if (std.mem.eql(u8, v, "shared")) {
            cfg.tileset_strategy = .shared;
        } else if (std.mem.eql(u8, v, "per_file")) {
            cfg.tileset_strategy = .per_file;
        } else if (std.mem.eql(u8, v, "preloaded")) {
            cfg.tileset_strategy = .preloaded;
        } else {
            std.debug.print("Unknown tileset-strategy: {s}\n", .{v});
            return error.InvalidArgument;
        }
    }
    if (res.args.@"preloaded-tileset") |v| cfg.preloaded_tileset = v;
    if (res.args.@"num-preloaded-tiles") |v| cfg.num_preloaded_tiles = v;
    if (res.args.@"num-preloaded-palettes") |v| cfg.num_preloaded_palettes = v;

    if (res.args.@"palette-generator") |v| {
        if (std.mem.eql(u8, v, "kmeans")) {
            cfg.palette_generator = .kmeans;
        } else {
            std.debug.print("Unknown palette-generator: {s} (only 'kmeans' is supported)\n", .{v});
            return error.InvalidArgument;
        }
    }

    if (res.args.@"tile-reducer") |v| {
        if (std.mem.eql(u8, v, "auto")) {
            cfg.tile_reducer = .auto;
        } else if (std.mem.eql(u8, v, "exact_hash")) {
            cfg.tile_reducer = .exact_hash;
        } else if (std.mem.eql(u8, v, "kmeans_color")) {
            cfg.tile_reducer = .kmeans_color;
        } else {
            std.debug.print("Unknown tile-reducer: {s} (use auto, exact_hash, or kmeans_color)\n", .{v});
            return error.InvalidArgument;
        }
    }

    try cfg.validate();

    // Build C array config from CLI flags
    var c_cfg = c_array_out.CArrayConfig{};
    if (res.args.@"c-var-prefix") |v| c_cfg.var_prefix = v;
    if (res.args.@"c-tilemap-type") |v| c_cfg.tilemap_entry_type = v;
    if (res.args.@"c-tileset-row-type") |v| c_cfg.tile_row_type = v;
    if (res.args.@"c-entries-per-line") |v| c_cfg.entries_per_line = v;
    if (res.args.@"no-c-include-stdint" != 0) c_cfg.add_stdint_include = false;
    if (res.args.@"no-c-const" != 0) c_cfg.use_const = false;
    if (res.args.@"no-c-uppercase-hex" != 0) c_cfg.hex_uppercase = false;

    const write_preview = res.args.@"preview" != 0;
    const write_preview_palette = res.args.@"preview-palette" != 0;
    const formats = res.args.format;
    const input_paths = res.args.input;

    // Load all images.
    const images = try gpa.alloc(lib.input.LoadedImage, input_paths.len);
    defer {
        for (images) |*img| img.deinit();
        gpa.free(images);
    }
    for (input_paths, 0..) |path, i| {
        if (cfg.verbose) std.debug.print("Loading {s}\n", .{path});
        images[i] = try lib.input.loadImage(gpa, path);
    }

    // Override tilemap dimensions from first image if not explicitly set.
    if (res.args.@"tilemap-width" == null)
        cfg.tilemap_width = images[0].width / cfg.tile_width;
    if (res.args.@"tilemap-height" == null)
        cfg.tilemap_height = images[0].height / cfg.tile_height;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const results = try lib.pipeline.runMulti(arena.allocator(), cfg, images);

    if (input_paths.len > 1) std.debug.print("Processed {} files\n", .{results.len});

    for (results, input_paths, images, 0..) |r, input_path, orig_img, i| {
        if (input_paths.len > 1) {
            std.debug.print("  [{d}] {s}: unique_tiles={} palettes={} tilemap={}x{}\n", .{
                i, std.fs.path.basename(input_path), r.unique_tiles.len, r.palettes.len, r.tilemap_width, r.tilemap_height,
            });
        } else {
            if (cfg.verbose) std.debug.print("Processing {}x{} image\n", .{ orig_img.width, orig_img.height });
            std.debug.print("Unique tiles: {}\n", .{r.unique_tiles.len});
            std.debug.print("Palettes:     {}\n", .{r.palettes.len});
            std.debug.print("Tilemap:      {}x{}\n", .{ r.tilemap_width, r.tilemap_height });
        }

        try printErrorMetrics(gpa, orig_img.pixels, orig_img.srgb_bytes, r.output_pixels);

        const stem = std.fs.path.stem(input_path);

        try writeOutputs(gpa, r, stem, output_dir, cfg, c_cfg, formats);

        if (res.args.@"json-dump") |json_path| {
            var jbuf: std.ArrayList(u8) = .empty;
            defer jbuf.deinit(gpa);
            try json_out.writeJsonDump(jbuf.writer(gpa).any(), &r);
            // Single file: use specified path. Multiple files: derive from stem.
            if (input_paths.len == 1) {
                try writeFile(&jbuf, json_path);
                if (cfg.verbose) std.debug.print("Wrote JSON dump: {s}\n", .{json_path});
            } else {
                const out_path = try std.fmt.allocPrint(gpa, "{s}/{s}_dump.json", .{ output_dir, stem });
                defer gpa.free(out_path);
                try writeFile(&jbuf, out_path);
                if (cfg.verbose) std.debug.print("Wrote JSON dump: {s}\n", .{out_path});
            }
        }

        if (write_preview) {
            const out_path = try std.fmt.allocPrint(gpa, "{s}/{s}_preview.png", .{ output_dir, stem });
            defer gpa.free(out_path);
            try lib.output.image.saveOklabAsPng(gpa, r.output_pixels, r.output_width, r.output_height, out_path);
            if (cfg.verbose) std.debug.print("Wrote preview: {s}\n", .{out_path});
        }

        if (write_preview_palette) {
            const out_path = try std.fmt.allocPrint(gpa, "{s}/{s}_palette.png", .{ output_dir, stem });
            defer gpa.free(out_path);

            const square_size = 32;
            const image_width = cfg.colors_per_palette * square_size;
            const image_height = cfg.num_palettes * square_size;

            const pixels: []OklabAlpha = try gpa.alloc(OklabAlpha, image_width * image_height);
            defer gpa.free(pixels);

            for (r.palettes, 0..) |palette, sy| {
                for (palette.colors, 0..) |color, sx| {
                    for (0..square_size) |ty| {
                        for (0..square_size) |tx| {
                            const y = (sy * square_size) + ty;
                            const x = (sx * square_size) + tx;
                            if (sx < palette.count) {
                                pixels[(y * image_width) + x] = color;
                            } else {
                                pixels[(y * image_width) + x] = .{ .alpha = 0 };
                            }
                        }
                    }
                }
            }

            try lib.output.image.saveOklabAsPng(gpa, pixels, image_width, image_height, out_path);
            if (cfg.verbose) std.debug.print("Wrote palette preview: {s}\n", .{out_path});
        }
    }
}

/// Print image quality metrics to stdout.
/// Delta-E is reported with the ×100 display factor.
/// PSNR is computed in sRGB u8 space (MAX=255).
fn printErrorMetrics(
    allocator: std.mem.Allocator,
    orig_pixels: []const OklabAlpha,
    orig_srgb_bytes: ?[]const u8,
    out_pixels: []const OklabAlpha,
) !void {
    const metrics = try lib.pipeline.computeErrorMetrics(allocator, orig_pixels, orig_srgb_bytes, out_pixels);

    std.debug.print("\nImage Quality 100x Delta E Comparison (lower is better):\n", .{});
    std.debug.print("  Min:     {d:.3}\n", .{metrics.min_de * 100.0});
    std.debug.print("  Mean:    {d:.3}\n", .{metrics.mean_de * 100.0});
    std.debug.print("  Median:  {d:.3}\n", .{metrics.median_de * 100.0});
    std.debug.print("  p75:     {d:.3}\n", .{metrics.p75_de * 100.0});
    std.debug.print("  p90:     {d:.3}\n", .{metrics.p90_de * 100.0});
    std.debug.print("  p95:     {d:.3}\n", .{metrics.p95_de * 100.0});
    std.debug.print("  p99:     {d:.3}\n", .{metrics.p99_de * 100.0});
    std.debug.print("  Max:     {d:.3}\n", .{metrics.max_de * 100.0});

    std.debug.print("\nPSNR Quality Metrics (higher is better, 30.0-50.0 is good):\n", .{});
    std.debug.print("  Red channel:   {d:.3} dB\n", .{metrics.psnr_r});
    std.debug.print("  Green channel: {d:.3} dB\n", .{metrics.psnr_g});
    std.debug.print("  Blue channel:  {d:.3} dB\n", .{metrics.psnr_b});
    std.debug.print("  Average PSNR:  {d:.3} dB\n", .{metrics.psnr_avg});
}

/// Write buf contents to a file at path, then clear buf for reuse.
fn writeFile(buf: *std.ArrayList(u8), path: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(buf.items);
    buf.clearRetainingCapacity();
}

fn writeOutputs(
    gpa: std.mem.Allocator,
    result: lib.pipeline.PipelineResult,
    stem: []const u8,
    output_dir: []const u8,
    cfg: lib.config.Config,
    c_cfg: c_array_out.CArrayConfig,
    formats: []const []const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    for (formats) |fmt| {
        if (std.mem.eql(u8, fmt, "hex") or std.mem.eql(u8, fmt, "logisim")) {
            const logisim = std.mem.eql(u8, fmt, "logisim");

            // Tilemap hex
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_tilemap.hex", .{ output_dir, stem });
                defer gpa.free(path);
                try hex_out.writeTilemapHex(buf.writer(gpa).any(), result.tilemap, result.tilemap_width, logisim);
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }

            // Tileset hex
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_tileset.hex", .{ output_dir, stem });
                defer gpa.free(path);
                switch (cfg.tileset_storage_order) {
                    .row_major => try hex_out.writeTilesetHexRowMajor(
                        buf.writer(gpa).any(), result.unique_tiles, cfg.tile_height, cfg.tile_width, cfg.max_unique_tiles, cfg.bitsPerColorIndex(), logisim,
                    ),
                    .sequential => try hex_out.writeTilesetHexSequential(
                        buf.writer(gpa).any(), result.unique_tiles, cfg.tile_height, cfg.tile_width, cfg.bitsPerColorIndex(), logisim,
                    ),
                }
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }

            // Palette hex
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_palette.hex", .{ output_dir, stem });
                defer gpa.free(path);
                try hex_out.writePaletteHex(buf.writer(gpa).any(), result.palettes, cfg.colors_per_palette);
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }
        } else if (std.mem.eql(u8, fmt, "binary")) {
            // Tilemap binary
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_tilemap.bin", .{ output_dir, stem });
                defer gpa.free(path);
                try binary_out.writeTilemapBinary(buf.writer(gpa).any(), result.tilemap);
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }

            // Tileset binary
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_tileset.bin", .{ output_dir, stem });
                defer gpa.free(path);
                switch (cfg.tileset_storage_order) {
                    .row_major => try binary_out.writeTilesetBinaryRowMajor(
                        buf.writer(gpa).any(), result.unique_tiles, cfg.tile_height, cfg.tile_width, cfg.max_unique_tiles, cfg.bitsPerColorIndex(),
                    ),
                    .sequential => try binary_out.writeTilesetBinarySequential(
                        buf.writer(gpa).any(), result.unique_tiles, cfg.tile_height, cfg.tile_width, cfg.bitsPerColorIndex(),
                    ),
                }
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }

            // Palette binary
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_palette.bin", .{ output_dir, stem });
                defer gpa.free(path);
                try binary_out.writePaletteBinary(buf.writer(gpa).any(), result.palettes, cfg.colors_per_palette);
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }
        } else if (std.mem.eql(u8, fmt, "c_array")) {
            // Tilemap C array
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_tilemap.h", .{ output_dir, stem });
                defer gpa.free(path);
                try c_array_out.writeTilemapCArray(buf.writer(gpa).any(), result.tilemap, c_cfg);
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }

            // Tileset C array
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_tileset.h", .{ output_dir, stem });
                defer gpa.free(path);
                switch (cfg.tileset_storage_order) {
                    .row_major => try c_array_out.writeTilesetCArrayRowMajor(
                        buf.writer(gpa).any(), result.unique_tiles, cfg.tile_height, cfg.tile_width, cfg.max_unique_tiles, cfg.bitsPerColorIndex(), c_cfg,
                    ),
                    .sequential => try c_array_out.writeTilesetCArraySequential(
                        buf.writer(gpa).any(), result.unique_tiles, cfg.tile_height, cfg.tile_width, cfg.bitsPerColorIndex(), c_cfg,
                    ),
                }
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }

            // Palette C array (use c_cfg but with palette-specific guard/prefix)
            {
                const path = try std.fmt.allocPrint(gpa, "{s}/{s}_palette.h", .{ output_dir, stem });
                defer gpa.free(path);
                var pal_c_cfg = c_cfg;
                pal_c_cfg.var_prefix = "palette";
                pal_c_cfg.include_guard = "PALETTE_H";
                try c_array_out.writePaletteCArray(buf.writer(gpa).any(), result.palettes, cfg.colors_per_palette, pal_c_cfg);
                try writeFile(&buf, path);
                if (cfg.verbose) std.debug.print("Wrote: {s}\n", .{path});
            }
        } else {
            std.debug.print("Unknown format: {s} (use hex, logisim, binary, or c_array)\n", .{fmt});
            return error.UnknownFormat;
        }
    }
}
