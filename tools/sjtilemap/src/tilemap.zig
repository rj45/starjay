const std = @import("std");

/// A single tilemap entry encoding tile index, palette, transparency and flip flags.
pub const TilemapEntry = packed struct(u16) {
    tile_index: u8, // bits [7:0]
    unused: u1 = 0, // bits [8]
    transparent: bool, // bit [9]
    palette_index: u5, // bits [14:10]
    x_flip: bool, // bit [15]

    pub fn toU16(self: @This()) u16 {
        return @bitCast(self);
    }

    pub fn fromU16(v: u16) @This() {
        return @bitCast(v);
    }
};

/// Canonical tile index type — derived from TilemapEntry.tile_index. Single source of truth.
/// Changing tile_index from u8 to u10 here propagates everywhere automatically.
pub const TileIndex = @TypeOf(@as(TilemapEntry, undefined).tile_index); // u8

/// Tile count type — one bit wider than TileIndex to hold [0, maxInt(TileIndex)+1].
pub const TileCount = std.meta.Int(.unsigned, @bitSizeOf(TileIndex) + 1); // u9

/// Canonical palette index type — derived from TilemapEntry.palette_index.
pub const PaletteIndex = @TypeOf(@as(TilemapEntry, undefined).palette_index); // u6

/// Palette count type — one bit wider than PaletteIndex.
pub const PaletteCount = std.meta.Int(.unsigned, @bitSizeOf(PaletteIndex) + 1); // u7

test "TilemapEntry bit layout: all ones" {
    const entry = TilemapEntry{
        .tile_index = 0xFF,
        .unused = 1,
        .palette_index = 0x1F,
        .transparent = true,
        .x_flip = true,
    };
    try std.testing.expectEqual(@as(u16, 0xFFFF), entry.toU16());
}

test "TilemapEntry bit layout: tile_index=1 only" {
    const entry = TilemapEntry{
        .tile_index = 0x01,
        .palette_index = 0x00,
        .transparent = false,
        .x_flip = false,
    };
    try std.testing.expectEqual(@as(u16, 0x0001), entry.toU16());
}

test "TilemapEntry bit layout: tile=0xAB palette=0x15" {
    const entry = TilemapEntry{
        .tile_index = 0xAB,
        .palette_index = 0x15,
        .transparent = false,
        .x_flip = false,
    };
    try std.testing.expectEqual(@as(u16, 0x54AB), entry.toU16());
}

test "TilemapEntry fromU16 round-trip" {
    const entry = TilemapEntry.fromU16(0xFFFF);
    try std.testing.expectEqual(@as(u8, 0xFF), entry.tile_index);
    try std.testing.expectEqual(@as(u5, 0x1F), entry.palette_index);
    try std.testing.expectEqual(true, entry.transparent);
    try std.testing.expectEqual(true, entry.x_flip);
}
