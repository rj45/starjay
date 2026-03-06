# sjtilemap Implementation Checklist

Status determined by comparing:
1. `plan.md` — the Zig design specification
2. The current Zig source in `src/` and `tests/`
3. The actual Rust reference at `/home/rj45/code/vdp/imgconv/src/` (all three files read)

Legend: `[x]` done · `[ ]` not done · `[~]` partially done

---

## RESOLVED: deltaE formula equivalence verified

The checklist previously flagged the Rust chroma-hue decomposition as different from plain
Euclidean, but they are **mathematically identical**:

```
dE = sqrt(dL^2 + dC^2 + dH^2)
   = sqrt(dL^2 + dC^2 + (da^2 + db^2 - dC^2))   [since dH^2 = da^2+db^2-dC^2]
   = sqrt(dL^2 + da^2 + db^2)
```

This was confirmed by running colorjs.io `deltaEOK` on 9 color pairs — all values matched
the plain Euclidean calculation exactly (within f32 precision). The `color.zig` comment
documents this equivalence. **No formula change needed.**

---

## CRITICAL: Rust tileset quantization format differs from Zig

The Rust code stores quantized tile data as `Vec<u16>` where **4 pixels are packed into
each u16** (4 bits per pixel, `BITS_PER_COLOR = 4`, `PIXELS_PER_CHUNK = 4`):
- pixel 0 in bits [3:0], pixel 1 in bits [7:4], pixel 2 in bits [11:8], pixel 3 in bits [15:12]
- Each tile row (8 pixels) = 2 × u16 chunks

The Zig `QuantizedTile` stores **one byte per pixel** (values 0–15, u8, not packed). The
packing only happens at output time in `hex.zig:packRow8()`.

This is **fine by design** — the Zig internal representation is unpacked for simplicity, and
the output writers pack it. But it means `calculate_reconstruction_error()` in the Rust
(which reads packed u16s) has no direct Zig equivalent. The Zig `assignPalettes()` works
directly on `Tile.pixels` (OKLab), which is correct. Document this deliberate difference.

---

## CRITICAL: Rust palette clustering algorithm — hue-sorted permutation feature vectors

`prepare_clustering_data()` (`imgconv.rs:422–449`) does **not** use raw tile pixels as
k-means input. It:
1. Sorts each tile's pixels by **hue angle** (`b.atan2(a)`)
2. Generates **all `tile_size` cyclic rotations** of the sorted pixel sequence
3. Concatenates all rotations' L, a, b channels as the feature vector

This makes the palette assignment **rotation-invariant** — two tiles with the same set
of colors in different spatial arrangements get the same palette. The Zig
`generatePalettes()` currently just sorts by hue (but does NOT generate all cyclic
rotations). The plan's Phase 6 TODO comment confirms this is known, but the impact is
significant: palette quality on real images will be lower than the Rust reference.

---

## CRITICAL: Rust tile deduplication pipeline order differs

The Rust pipeline (`convert()`, `imgconv.rs:260–308`) does:
1. `extract_tiles` → raw Oklab tiles
2. `generate_palettes` → k-means clustering of tiles → palettes
3. `assign_palettes` → best palette per tile
4. `quantize_tiles` → packed u16 quantized tiles (with dithering)
5. `cluster_quantized_tiles` → k-means on quantized color-space vectors → unique tiles
6. `find_best_tile_assignments` → for each original tile, find best (unique_tile, palette) combo
7. `generate_tilemap_from_assignments`

Step 6 is a **second pass** that re-evaluates every combination of (unique_tile × palette)
against every original tile using `calculate_reconstruction_error()`. This is O(N × U × P)
where N = total tiles, U = unique tiles, P = palettes. The Zig pipeline does **not** have
this second pass — it uses the initial palette assignment directly. The Rust approach finds
a globally better (unique_tile, palette) pairing.

---

## Phase 0 — Scaffolding & Build System

- [x] Directory structure matches plan (`src/`, `src/bench/`, `src/output/`, `tests/integration/`)
- [x] `build.zig`: `lib_mod`, `exe`, `test` step, `bench` step, integration test module
- [x] `lib.zig` re-exports all modules
- [x] All stub files compile; `zig build test` runs without missing-module errors

---

## Phase 1 — Verified deltaE

- [x] `color.zig`: `deltaESquared` and `deltaE` (plain Euclidean) implemented
- [x] `color.zig` delegates all sRGB ↔ OKLab to zigimg (no conversion math in `color.zig`)
- [x] **Formula verified equivalent to Rust** — plain Euclidean and Rust chroma-hue
  decomposition are mathematically identical (see RESOLVED note above).
- [x] **Tests use external ground-truth values** from colorjs.io `deltaEOK` (npm package
  colorjs.io@0.5.2). 9 color pairs with expected values hard-coded; also tests symmetry
  and `deltaESquared` vs `deltaE` consistency.

---

## Phase 2 — 8×8 single tile, 16 exact colors, pixel-perfect reconstruction

- [x] `input.zig`: `loadImage()` / `LoadedImage`
- [x] `tile.zig`: `extractTiles()`
- [x] `palette.zig`: `generatePaletteFromTiles()` via k-means
- [x] `quantize.zig`: `bestPaletteEntry()`, `quantizeTile()`
- [x] `pipeline.zig`: `run()` single-image happy path
- [x] `output/image.zig`: `saveOklabAsPng()`
- [x] Integration test: Phase 2 test present and passing
- [x] **Image dimension validation** — `cfg.validateImageDimensions(img.width, img.height)`
  is called at the start of `pipeline.run()` (see also Phase 11 / Structural section).

---

## Phase 3 — TilemapEntry bit layout

- [x] `tilemap.zig`: `TilemapEntry` packed struct — bits [7:0] tile_index, [13:8] palette_index,
  [14] transparent, [15] x_flip
- [x] `toU16()` / `fromU16()` round-trip
- [x] Concrete bit-pattern tests (0xFFFF, 0x0001, 0x15AB, fromU16 round-trip)
- [x] **Canonical type aliases added**: `TileIndex` (u8), `TileCount` (u9), `PaletteIndex` (u6),
  `PaletteCount` (u7) — all derived from `TilemapEntry` fields via comptime.

---

## Phase 4 — Tile deduplication: 4 identical tiles → 1 unique tile

- [x] `tileset.zig`: `deduplicateExact()` (exact hash dedup)
- [x] Integration test: Phase 4 test present and passing

---

## Phase 5 — 4 different tiles, 1 shared palette

- [x] `pipeline.zig`: `assignPalettes()` (best-fit palette per tile, by total deltaE sum)
- [x] Integration test: Phase 5 test present and passing
- [x] **Palette assignment uses plain Euclidean deltaE** — equivalent to Rust chroma-hue
  formula (see RESOLVED note). No sub-optimality vs Rust reference.

---

## Phase 6 — Multiple palettes: 1 tile shape, 4 color sets

- [~] `palette.zig`: `generatePalettes()` exists and does k-means clustering of tiles using
  hue-sorted feature vectors (implements the hue-sort step), BUT does **not** generate all
  cyclic rotations (see CRITICAL section). This is a partial implementation.
- [x] Integration test: Phase 6 test is present and passing (4 palettes / 1 unique tile)
- [x] **`reduce_colors()` (Rust `imgconv.rs:525–568`)** — frequency-weighted centroid
  computation after k-means is now implemented in `generatePaletteFromTiles()`. When unique
  colors exceed `colors_per_palette`, k-means clusters them and the representative for each
  cluster is computed as a frequency-weighted average (weight = how many image pixels matched
  that unique color). This matches the Rust `reduce_colors()` algorithm. Test: "Palette
  reduce_colors: frequency-weighted centroids for skewed distributions" verifies that a dominant
  color (60/64 pixels) gets a palette representative within deltaE < 0.005 instead of the
  unweighted midpoint (deltaE ≈ 0.025). Quality improvement: Gouldian Finch avg deltaE
  improved from ~0.024 → ~0.023 after implementing frequency weighting.
  The Rust computes frequency-weighted averages of colors within each cluster.
- [x] **Palette sorted by average luminance** after generation (`imgconv.rs:404–409`).
  `generatePalettes()` now sorts palettes by average OKLab luminance (ascending) after generating
  them. Colors within each palette remain sorted by individual luminance. Test "Phase 6 extended:
  palettes are sorted by average luminance (ascending)" verifies this using the 4-palette image
  (reds/greens/blues/yellows) where yellows (L≈0.9) must end up at palette[3].

---

## Phase 7 — Lossy quantization with Sierra dithering

- [x] Sierra kernel coefficients correct (5,3 / 2,4,5,4,2 / 2,3,2 — matches Rust `imgconv.rs:861–912`)
- [x] `sierra_error_divisor` = 32.0 (comptime constant in `pipeline.zig`, matches Rust `DITHER_ERROR_DIVISOR`)
- [x] Dither propagation across image-wide scan lines in correct row-major order (matches Rust `quantize_pixels`)
- [x] Integration test: Phase 7 test verifies Sierra changes output vs no-dither, and
  `dither_factor=0.0` equals no-dither
- [x] **Sierra implementation moved to `dither.zig`** — `dither.zig` now contains
  `sierra_pattern`, `sierra_error_divisor` (comptime sum), `applySierraDither()`, and
  `quantizeTilesWithSierra()`. `pipeline.zig` calls `dither_mod.quantizeTilesWithSierra()`.
- [x] **PSNR threshold assertions added to Phase 13 tests.** `LoadedImage` now stores
  `srgb_bytes: ?[]u8` (original u8 RGB values captured before OKLab conversion). `computeErrorMetrics()`
  accepts `orig_srgb_bytes: ?[]const u8` and uses them directly for PSNR to avoid the OKLab→sRGB
  round-trip precision loss. Both real-image tests now assert `psnr_avg` above a threshold.
  Rust baselines (dither_factor=1.0): Gouldian Finch 25.254 dB, Kodak 23 27.841 dB.
  Zig achieves ~24.7 dB / ~27.1 dB — about 0.6 dB below Rust because the optimizer minimizes
  OKLab deltaE, not sRGB MSE. Thresholds: 24.0 dB (Gouldian Finch), 26.5 dB (Kodak 23).

---

## Phase 8 — Transparency

- [x] `TransparencyMode` enum (`.none`, `.alpha`, `.color`)
- [x] `tile.zig`: `has_transparent` field; set during `extractTiles()`
- [x] `quantize.zig`: `quantizeTileWithTransparency()` (index 0 reserved)
- [x] `pipeline.zig`: `buildTilemap()` sets `transparent` flag; `reconstructPixels()` outputs
  alpha=0 for transparent pixels
- [x] Integration tests: 8A (mixed), 8B (all opaque → false), 8C (mode=none ignores alpha)
- [x] **`transparency_mode=.color` wired up**: pixels matching `transparent_color` sRGB are
  pre-processed to alpha=0 before pipeline. `pipeline.zig` uses `srgbToOklab()` helper.
- [x] **`Config.transparent_color: ?[3]u8`** field added to `config.zig`.
- [x] Integration test Phase 8D: `transparency_mode=.color` checkerboard test.
- [x] Palette fix: `generatePaletteFromTiles` normalizes all colors to alpha=1.0 (transparent
  pixel OKLab values no longer corrupt palette alpha channel).

---

## Phase 9 — x_flip tile deduplication

- [x] `tileset.zig`: `deduplicateExact()` checks horizontal flip before adding a new tile
- [x] `pipeline.zig`: `reconstructPixels()` applies x_flip when reading tile data
- [x] Integration test: Phase 9 test present (mirrored 16×8 → 1 unique tile, one x_flip=true)

---

## Phase 10 — Output formats

- [x] `output/hex.zig`: `writeTilemapHex()` (with/without logisim header)
- [x] `output/hex.zig`: `writeTilesetHexRowMajor()` (row-major, pads to `max_unique_tiles`)
- [x] `output/hex.zig`: `writeTilesetHexSequential()`
- [x] `output/hex.zig`: `writePaletteHex()` — OKLab→sRGB via zigimg, `{RR}{GG}{BB} ` format, pads to `colors_per_palette`
- [x] `output/binary.zig`: `writeTilemapBinary()` (little-endian u16)
- [x] `output/binary.zig`: `writeTilesetBinaryRowMajor()`
- [x] `output/binary.zig`: `writeTilesetBinarySequential()`
- [x] `output/binary.zig`: `writePaletteBinary()` (raw RGB bytes, 3 bytes/color)
- [x] `output/c_array.zig`: `writeTilemapCArray()` (include guard, type name, entries/line)
- [x] `output/c_array.zig`: `writeTilesetCArrayRowMajor()`
- [x] `output/c_array.zig`: `writeTilesetCArraySequential()` (tile-first order)
- [x] `output/c_array.zig`: `writePaletteCArray()` (packed 0x{RRGGBB} u32 entries)
- [x] `main.zig`: all formats write tilemap/tileset/palette outputs
- [x] Integration tests: all output formats with content assertions
- [ ] **`output/writer.zig` is a stub** — acceptable workaround, CLI dispatches directly.
- [ ] **Tileset hex uppercase** — currently lowercase, verify VDP toolchain expectation.

---

## Phase 11 — Config & CLI

- [x] `config.zig`: `Config` struct with all core fields and corrected defaults
- [x] `config.zig`: `palette_start_offset: u32 = 0` field
- [x] `config.zig`: `tileset_start_offset: u32 = 0` field
- [x] `config.zig`: `transparent_color: ?[3]u8 = null` field **NEW**
- [x] `config.zig`: `bitsPerColorIndex()` method **NEW**
- [x] `config.zig`: `Config.load(alloc, path)` - load ZON config from file **NEW**
- [x] `config.zig`: `validate()` checks palette/tile range, colors_per_palette
- [x] `config.zig`: `validateImageDimensions(w, h)` - validates image vs tilemap config **NEW**
- [x] `config.zig`: `generateDefault()` includes all fields incl. transparent_color
- [x] `pipeline.zig`: calls `cfg.validateImageDimensions()` at pipeline start **NEW**
- [x] `main.zig`: `-c/--config` flag wired to `Config.load()` **NEW**
- [x] `main.zig`: `--palette-offset`, `--tileset-offset` flags added **NEW**
- [x] `main.zig`: `--transparent-color` flag (RRGGBB hex) added **NEW**
- [x] Integration tests: all validate() cases, ZON round-trip, load(), bitsPerColorIndex(),
  validateImageDimensions(), palette_0_color_0_is_black
- [ ] **`loadAndMerge()` (ZON + CLI override struct)** — CLI currently applies overrides
  directly after `Config.load()`; formal `CliOverrides` struct not implemented.
- [ ] **`OutputTarget` struct** not in `config.zig`.
- [x] **C array CLI flags added**: `--c-var-prefix`, `--c-tilemap-type`,
  `--c-tileset-row-type`, `--c-entries-per-line`, `--no-c-include-stdint`,
  `--no-c-const`, `--no-c-uppercase-hex`. `CArrayConfig` also gained `tile_row_type`
  and `hex_uppercase` fields.
- [x] **CLI flags added**: `--preloaded-palette`, `--preloaded-tileset`, `--num-preloaded-tiles`,
  `--json-dump` all wired up. `--palette-strategy preloaded` and `--tileset-strategy preloaded`
  also added.
- [x] **CLI flags added**: `--num-preloaded-palettes`, `--palette-generator`, `--tile-reducer`.
  `Config` gained `num_preloaded_palettes: u32`, `palette_generator: PaletteGeneratorAlgorithm`,
  and `tile_reducer: TileReducerAlgorithm`. `PaletteGeneratorAlgorithm` (.kmeans) and
  `TileReducerAlgorithm` (.auto/.exact_hash/.kmeans_color) enums added to `config.zig`.
  `tile_reducer` is threaded through `pipeline.run()` and `runMulti()` to `deduplicateExact()`.
  `.exact_hash` returns `error.TooManyUniqueTiles` when unique tile count exceeds `max_unique_tiles`.
  Tests: "tile_reducer=exact_hash succeeds within limit" and "tile_reducer=exact_hash fails
  when unique tile count exceeds limit" both pass. `pipeline.run()` now has `errdefer arena.deinit()`
  to prevent memory leaks on error paths (e.g. TooManyUniqueTiles).

---

## Phase 12 — Multi-file processing

- [x] `pipeline.zig`: `runMulti()` with `.shared` and `.per_file` for both palette and tileset
- [x] Integration tests: all four strategy combinations present and passing
- [x] **`.preloaded` strategy implemented** for both palette and tileset. `pipeline.zig:runMulti()`
  reads hex files via `hex_out.loadPaletteFromHex()` / `hex_out.loadTilesetFromHex()` and assigns
  loaded palettes/tiles to each image. Tile assignment uses `calculateReconstructionError` to map
  each original tile to its closest loaded tile. Config fields `preloaded_palette`, `preloaded_tileset`,
  `num_preloaded_tiles` added to `Config`.
- [x] **Integration tests for `.preloaded` strategy**: Phase 12 preloaded palette and tileset
  tests present and passing. Verify loaded palettes produce correct reconstruction and loaded
  tileset tiles are reused with correct indices.
- [x] **Multi-file with Sierra dithering tested** — `Phase 12: multi-file shared pipeline with
  Sierra dithering` test added; verifies Sierra dithering over two images with shared palette/tileset.
- [x] **CLI flags for preloaded strategy added**: `--palette-strategy preloaded`,
  `--preloaded-palette <path>`, `--tileset-strategy preloaded`, `--preloaded-tileset <path>`,
  `--num-preloaded-tiles <n>` all wired up in `main.zig`.

---

## Phase 13 — Full integration with real images

- [x] **Slow image tests split into separate files** — `test_gouldian_finch.zig` and
  `test_kodak_23.zig` are compiled and run independently of `test_roundtrip.zig`. Each
  slow test is built with `fast_optimize` (ReleaseSafe or ReleaseFast) regardless of the
  main build mode. All three test binaries run in parallel under `zig build test` since
  they are independent `test_step` dependants.
- [x] **`computeErrorMetrics()` deduplicated to `pipeline.zig`** — The `ErrorMetrics` struct
  and `computeErrorMetrics(alloc, orig_pixels, out_pixels)` function now live in
  `pipeline.zig`, used by both the real-image test files and `main.zig:printErrorMetrics()`.
  `TODO` comment retained noting this is conceptually a metrics utility, not core pipeline.
- [x] Integration test: `Phase 13: Gouldian Finch 256x256` present and passing with tight
  threshold. Rust baseline established: `cargo run --release` gives avg deltaE = **0.02713**
  (2.713×100). Zig achieves **0.025**, beating the Rust baseline. Test asserts `< 0.030`
  (10% above Rust baseline to account for k-means randomness).
- [x] **deltaE formula equivalence confirmed** (see RESOLVED section). Plain Euclidean in
  OKLab = Rust chroma-hue decomposition, mathematically identical. No mismatch.
- [x] **`input.zig` uses `fromMemory`** — switched from `fromFilePath` to read-all-then-`fromMemory`
  to work around a zigimg `SeekError.Unseekable` bug on certain PNG files (e.g. Kodak 23).
- [x] **Second test image added**: `Phase 13: Kodak 23 256x256` passes. Rust baseline: avg
  deltaE = **0.02176**. Zig achieves **~0.018**, beating Rust by ~20%. Threshold: `< 0.025`.
- [x] **PSNR test assertions added** — see Phase 7 and Phase 13 entries. `input.zig:loadImage()`
  now captures original u8 sRGB bytes into `LoadedImage.srgb_bytes` before the OKLab conversion.
  `computeErrorMetrics()` uses these bytes directly for accurate PSNR (no round-trip loss).
- [x] **Error metrics printed to stdout** — `main.zig:printErrorMetrics()` prints delta-E
  percentiles (×100 display factor: Min/Mean/Median/p75/p90/p95/p99/Max) and PSNR per channel
  (R, G, B, Average in dB) matching the Rust output format. Called after single-file `run()`.
- [x] **JSON dump (`--json-dump`)** implemented. `src/output/json.zig:writeJsonDump()` writes
  structured JSON with `tilemap_width`, `tilemap_height`, `palette_count`, `tile_count`,
  `tilemap[]`, `palettes[][]`, `tileset[][]`. CLI flag `--json-dump <path>` wired in `main.zig`.
  Integration test verifies structure by round-tripping through `std.json.parseFromSlice`.

---

## Phase 14 — Benchmarks

- [x] `bench_main.zig`: entry point calling all bench modules
- [x] `bench_kmeans.zig`: k-means throughput
- [x] `bench_dither.zig`: Sierra pipeline on gradient image
- [x] `bench_tile_match.zig`: `bestPaletteEntry()` throughput
- [x] `bench_delta_e.zig`: standalone `deltaE()` microbenchmark (1M ops) **NEW**
- [x] **`bench_dither.zig` benchmarks the dithering kernel directly** — now calls
  `dither.quantizeTilesWithSierra()` on 1024 pre-built gradient tiles (equivalent to a 256×256
  image) instead of running the full pipeline. Reports ns/tile and ms/op. (previously ran full
  pipeline including palette generation, which is not the dithering hot path)
- [x] **`bench_kmeans.zig`** updated to 100 runs per plan specification (was 20 runs).

---

## Structural / Design Gaps (cross-cutting)

- [x] **`TileIndex` / `TileCount` / `PaletteIndex` / `PaletteCount` type aliases** added
  to `tilemap.zig`, derived from `TilemapEntry` fields via comptime.
- [ ] **`DitherAlgorithm` tagged union** (`dither.zig`) is a stub. Sierra logic lives
  in `pipeline.zig`. The single-dispatch-site design is not achieved.
- [ ] **`PaletteProcessor` tagged union** (`palette.zig`) is not implemented. The
  strategy (`shared`/`per_file`/`preloaded`) is a bare `switch` in `pipeline.zig`.
- [ ] **`TilesetProcessor` tagged union** (`tileset.zig`) is not implemented. Same issue.
- [ ] **`OutputWriter` tagged union** (`output/writer.zig`) is a stub.
- [ ] **`PaletteGenerator` tagged union** (`palette.zig`) is not implemented.
- [x] **`KmeansColorReducer` fallback implemented and fixed** — `tileset.zig:deduplicateExact()`
  now accepts `palette_assignments`, `palettes`, `max_unique_tiles`, and `tile_kmeans_max_iter`.
  After exact dedup, if unique tile count exceeds `max_unique_tiles`, k-means clusters the
  unique tiles using **OKLab color feature vectors** (L, a, b per pixel from palette lookup)
  — not raw palette index integers. The palette for each unique tile is tracked during exact
  dedup. All callers in `pipeline.zig` pass palettes and assignments. The `runMulti` shared
  tileset path now correctly flattens per-image palettes and offsets palette assignments.
  Integration test "Tileset k-means reducer" validates count, valid indices, ≥2 distinct
  tiles, and per-tile avg deltaE < 0.25 (catches cross-hue representative assignments).
- [x] **Fixed: 256-tile cap bug in `deduplicateExact()`** — The HashMap value type was `u8`,
  silently capping unique tile collection at 256. Tiles beyond the 256th unique tile were
  all assigned `tile_indices[i] = 0`, then remapped to cluster 0 after k-means — causing the
  bottom 4/5 of large images to render as solid-color blocks (all mapped to the same tile).
  Fix: HashMap value changed to `u32`, intermediate indices use `[]u32`, cap removed entirely.
  Converts to `[]u8` only after k-means reduces to ≤ `max_unique_tiles`. Phase 13 avg deltaE
  on Gouldian Finch improved from ~0.093 → ~0.041 (2×+ quality improvement).
  Regression test: "Tileset k-means: correctly handles > 256 unique tiles without capping"
  creates 300 unique tiles and asserts overflow tiles (256-299) get varied cluster assignments.
- [x] **QUALITY BUG FIXED: `find_best_tile_assignments()` implemented** — `pipeline.zig`
  now contains `findBestTileAssignments()` (equivalent to Rust `imgconv.rs:702–740`). After
  tile deduplication, every original tile is re-evaluated against all (unique_tile × palette ×
  {normal, x_flip}) combinations using `calculateReconstructionError()`. Transparent tiles skip
  x_flip (flipping shifts which pixels map to color index 0, which would corrupt transparency).
  Result: Gouldian Finch avg deltaE improved from **0.044 → 0.025**, now **beats Rust baseline
  0.027**. Phase 13 threshold tightened from 0.25 → 0.030.
- [~] **`TileReducer` tagged union** (`tileset.zig`) formal tagged-union interface is not
  implemented (the auto-dispatch design from plan.md). The `TileReducerAlgorithm` enum is
  added to config.zig and threaded through to `deduplicateExact()`, which switches on it
  internally. The `.exact_hash` and `.auto` paths work correctly; `.kmeans_color` currently
  behaves the same as `.auto` (k-means is always the fallback).
- [x] **k-means tile reducer uses multiple restarts** — `kmeansReduceTiles()` now runs k-means
  8 times and picks the result with minimum total inertia. Prevents bad local optima when
  random initialization splits naturally-grouped colors across different clusters (e.g. reds
  with blues). Fixes a flaky test failure: "Tileset k-means reducer: max_unique_tiles is
  respected when exceeded" previously failed ~50% of the time.
- [ ] **`ColorMapper` interface** (`quantize.zig`) is not present.
- [x] **`Config.transparent_color: ?[3]u8`** field present in `config.zig` (implemented in Phase 8).
- [ ] **`num_palettes` type**: plan specifies `PaletteCount` (u7); code uses `u32`.
- [ ] **`max_unique_tiles` type**: plan specifies `TileCount` (u9); code uses `u32`.
- [ ] **`colors_per_palette` type**: plan specifies `u8`; code uses `u32`.
- [ ] **`palette_start_offset` type**: plan specifies `PaletteIndex` (u6); code uses `u32`.
- [ ] **`tileset_start_offset` type**: plan specifies `TileIndex` (u8); code uses `u32`.
- [x] **Image dimension validation in `pipeline.run()`**: `cfg.validateImageDimensions()` is
  called at pipeline start (implemented in Phase 11).
- [x] **PANIC FIXED: Palette always padded to `colors_per_palette` entries** — `Palette` struct
  now has a `count: u32` field tracking valid colors. `generatePaletteFromTiles()` always
  allocates exactly `colors_per_palette` slots and pads unused slots with OKLab black. This
  eliminates the pre-existing panic in `reconstructPixels()` and `kmeansReduceTiles()` that
  occurred when a tile's quantized index (from palette A) was used to index into a shorter
  palette (palette B, with fewer unique colors). `bestPaletteEntry` / `bestPaletteEntrySkipFirst`
  and `assignPalettes` use `palette.colors[0..palette.count]` to search only real colors.
  Output writers use `palette.count` for the padding loop. Confirmed by Kodak 23 test no
  longer panicking.
