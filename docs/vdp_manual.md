# StarJeet VDP Manual

**Caution!**
This manual is at a very rough draft stage and is very incomplete. Many stats and figures are wrong, and many statements are factually incorrect. Bear this in mind as you read through this document.
**Caution!**

## 1.1. Introduction

The StarJeet Video Display Processor (VDP) is responsible for rendering graphics to the display. The VDP is designed to be simple in that everything is a sprite, and sprites are tilemaps. This simple design provides sprites, tilemaps and even text modes and GUIs with one simple primitive.

### 1.2. Acknowledgements and Inspirations

This design is heavily inspired by the Neo Geo's VDP, with some ideas taken from the NES, SNES and Gameboy PPUs, as well as the Amiga.

### 1.2. Feature List

**These are preliminary and subject to change.**

- 640x360 effective resolution with 512 colors of 24 bits each
    - 1280x720 actual display resolution -- pixels are doubled when drawn.
- Up to 512 sprites.
- Each sprite can be any arbitrary NxM rectangle of tiles from a tilemap.
- Sprite X/Y coordinates are given at the 1280x720 resolution, allowing sub-pixel positioning.
    - Note: This feature may be removed, but is currently implemented and working.
- Tilemaps can be from 32 up to 256 tiles in width.
    - The formula for tilemap width is (1 << (a+4))+(1 << (b+4)) where a and b can be 0-3.
    - This allows several useful widths including 80 and 160 for textmodes.
- Tilemap height is arbitrary up to 512 tiles.
- Designed to work well with SDRAM and its RAS/CAS latencies.
    - Tile sets are stored row-major such that one row of all tiles in the set is a single SDRAM "page" or "row"
    - This allows a SDRAM row to be activated and random access limited to that row, and the row for the tilemap for that sprite.
    - Unfortunately this limits a tile set to be 256 tiles (could be revisited in the future).
    - The design is pipelined to allow multiple requests to SDRAM to be in flight at once.
- Each sprite can configure its own tilemap and tile set pointers in main memory.
- Each tile can use up to 16 colors from up to 32 palettes, yielding 512 colors.
    - The palette is double buffered and the buffers may be swapped to give more colors.
- Utilizes a line buffer, rather than a frame buffer, to draw up to 512 sprites per line.
    - Double buffered: one is displayed and cleared while the other buffer is drawn.
    - Sprites have the entire scanline including hblank to be drawn on the linebuffer.
    - Up to 4 doubled pixels, half a tile, can be drawn per clock cycle.
- Tiles per scanline is anywhere from 300 up to 720 depending on number of sprites and memory latencies.
- A text mode with 8x16 (or 8x12) font may be done by setting up 2 sprites per text line:
    - Two sprites each text line, one for each half of the font
    - Both sprites point at the same tilemap but different tile sets
    - The tilemap becomes the text buffer with character in lower 8 bits and attributes in the upper 8 bits.

        
## 2.1. Tilemaps

- Tilemap cells are 16 bits wide, with the following format:
    - `[7:0]`: Tile Index (0-255)
    - `[12:8]`: Palette Index (0-31)
    - `[13:14]`: Unused (potentially a tile permutation value)
    - `[15]`: Horizontal (X) Flip
- The width of a tilemap is given by `(1 << (a+4)) + (1 << (b+4))` where `a` and `b` can be `0`-`3`.
- The height can be arbitrary from 1 to 512 tiles.
- Tilemaps can be stored anywhere in main memory, but the start address has a granularity of 1024 bytes.
    - These pointers may overlap if desired.
- Each sprite can specify its own tilemap start address.
  
## 3.1. Tile Sets

- Each tile is 8x8 pixels, with each pixel represented by 4 bits (16 colors).
- Tile pixel data is stored in main memory starting at a specified address, with each tile occupying 32 bytes (8 rows x 4 bytes per row).
- Tiles are stored in row-major format:
    - 8 rows of 256 tiles of 8 pixels of 4 bits per pixel
    - This limits random access of memory to a single 1 KB block, which is a typical row size for SDRAM
- Tile set sets may be stored anywhere in main memory, with an alignment/granularity of 1 KB.
    - These pointers can overlap if desired, allowing tilesets to share rows.
- Each sprite has its own independent tile set pointer.

## 4.1. Sprite Attributes

Each sprite is defined by a set of attributes stored in a specific address range in VRAM, which is mapped into the IO space of main memory. There are 512 entries. 

Each entry is 9 words (18 bytes) long, with the following format:

- Tilemap Y and height:
    - `[7:0]` - Sprite tilemap Y position
    - `[15:8]` - Sprite height in tiles
- Screen Y position in 12.4 fixed point format:
    - `[3:0]` - Fraction part (ignored when drawing)
    - `[15:4]` - Signed sprite Y position @ 720 lines per screen.
- Tilemap X and width:
    - `[7:0]` - Sprite width
    - `[15:8]` - Sprite tilemap X position
- Screen X position in 12.4 fixed point format:
    - `[3:0]` - Fraction part (ignored when drawing)
    - `[15:4]` - Signed sprite X position @ 1280 positions per line.
- Bits `[25:10]` of the tilemap address
- Bits `[25:10]` of the tile set address
- Screen Y velocity in 12.4 fixed point (added to screen Y once per frame)
- Screen X velocity in 12.4 fixed point (added to screen X once per frame)
- Misc extra bits:
    - `[15:14]` - `a` value of tilemap width
    - `[13:12]` - `b` value of tilemap width (see tilemap section for formula)
    - `[11:10]` - Unused
    - `[9]` - Draw flipped in Y direction
    - `[8]` - Draw flipped in X direction
    - `[7:6]` - Upper 2 bits(`[27:26]`) of tilemap address
    - `[5:4]` - Upper 2 bits(`[27:26]`) of tile set address
    - `[3:0]` - Unused

Sprites are drawn in order from lowest to highest index, so higher index sprites will be drawn over top of lower index sprites in the line buffer.

## 5.1. Theory of Operation

The VDP is deeply pipelined and separated into two "timing domains" by a double buffered line buffer: the draw domain and the pixel domain. A line buffer is similar to a frame buffer except for only one line. For each line sent to the monitor in the pixel domain, the line buffer gets flipped. For the entire duration of the line being drawn to the screen in the pixel domain, including the horizontal blanking, the draw domain gets to draw in the off-screen line buffer.

The pipeline of the pixel domain is to read a byte from the line buffer, look up its palette entry, and send the 24 bit color to the screen. Because the line buffer has two ports: a read port and a write port, the write port is used to zero out the line buffer after sending the data to the screen.

The pipeline of the draw domain is a lot more complex, and so could run at a different clock rate. There's two different "state machines" that operate in this pipeline:

There is the sprite scanner, which acts with a Y coordinate two lines ahead of the one being drawn. This state machine scans through each sprite looking for sprites that intersect the Y coordinate and that would be visible. When it finds one, it calculates the address ranges of the tilemap data for the visible portion to be loaded and copies the relevant sprite attributes into a separate double buffer that's flipped each line.

The other state machine scans through the sprite buffer one by one, "activating" each sprite by sending its data to the draw pipeline and waiting for the draw pipeline to finish before sending the next sprite to it.

For each tile in the activated sprite, the draw pipeline loads the tilemap entry, then twice it loads 4 4-bit "texels" of the tile data. The texels are combined with the palette entry from the tilemap data to form 8 bit pixels. The 8 bit pixels are then doubled from 4 to 8 pixels. The pixels are then "aligned" such that they can be written to the line buffer 8 pixels per cycle with a possible extra cycle required to clear the alignment buffer after the sprite finishes drawing. After alignment, the pixels are drawn up to 8 pixels per clock into the draw buffer at the specific offset.

There is 1360 pixel clocks per scan line (including blanking time). Four pixels can be drawn per cycle. A tile is 8 pixels, so takes 2 cycles to draw. That means as much as 680 tiles can be drawn per line. However, that presumes large sprites since it takes an extra cycle between sprites. It also assumes the tilemap data can be read from a separate memory than the tile texel data. This also assumes the draw domain is clocked at the same clock rate as the pixel domain. If all 256 sprites are drawn on a single line, and the tilemap data and texel data are in the same memory, then it could be as low as 368 tiles per line.

There is an idea for making this system more efficient: A one bit z-buffer line-buffer could be implemented, where the transparency masks are stored in a separate block RAM for fast access. Sprites would first be drawn into the z-buffer and only texels which are actually drawn would get loaded from memory and blitted to the line buffer. The draw pipeline would then be a series of fifos: the tilemap data would be read, the mask data it points to would be read 16 bits at a time, and any of the 8 texels matching would be fed into a fifo to have the texel data loaded and blitted to the line buffer in the relavent locations. Any sprites entirely occluded would not even have their texel data loaded. The mask could even be at the sub-pixel level allowing portions of the doubled pixels to be masked since 16 pixels can be loaded at once. However the zbuffer and masking system is a significant amount of extra complexity.
