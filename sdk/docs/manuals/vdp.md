# StarJeet VDP Manual

**Caution!**
The VDP is not yet complete, and so some of the following may be subject to change.
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
    - This allows several useful widths including 80 for textmodes.
- Tilemap height is arbitrary up to 512 tiles (max sprite height + max sprite tilemap Y)
- Designed to work well with SDRAM and its RAS/CAS latencies.
    - Tile sets are stored row-major such that one row of all tiles in the set is a single SDRAM "page" or "row"
    - This allows an SDRAM row to be activated and random access limited to that row, and the row for the tilemap for that sprite.
    - Unfortunately this limits a tile set to be 256 tiles (could be revisited in the future).
    - The design is pipelined to allow multiple requests to SDRAM to be in flight at once.
- Each sprite can configure its own tilemap and tile set pointers in main memory.
    - They are limited to 1kB granularity, but can overlap
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

### 2.1.1. Tilemap Entry Format

```
    +---------------------------------+
    | 1 1 1 1 1 1                     |
    | 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 |
    +---------------------------------+
    | x p p p p p t r i i i i i i i i |
    +---------------------------------+
    
    x - X-Flip
    p - Palette Index (0-31)
    t - Transparent bit (0 = color 0 is opaque, 1 = color 0 is transparent)
    r - Reserved bit (not used)
    i - Tile Index (0-255)
```

## 3.1. Tile Sets

- Each tile is 8x8 pixels, with each pixel represented by 4 bits (16 colors).
- Tile set sets may be stored anywhere in main memory, with an alignment/granularity of 1 KB.
    - These pointers can overlap if desired, allowing tilesets to share rows.
- Each sprite has its own independent tile set pointer.

### 3.1.1 Tile Set Layout

```
    | tile 0, row 0 | tile 1, row 0 | tile 2, row 0 | ... | tile 255, row 0 |
    | tile 0, row 1 | tile 1, row 1 | tile 2, row 1 | ... | tile 255, row 1 |
    .
    .
    .
    | tile 0, row 7 | tile 1, row 7 | tile 2, row 7 | ... | tile 255, row 7 |
```

Tiles are stored in row-major format, with each row containing the same row of all tiles in the set. This arrangement ensures that all pixels for a row of a tileset fit within a single open SDRAM row. This is also why tilesets can only be 256 tiles. This ensures that an SDRAM row only needs to be opened once per sprite drawn.

## 4.1. Sprite Attributes

Each sprite is defined by a set of attributes stored in a specific address range in VRAM, which is mapped into the IO space of main memory. There are 512 entries split into two blocks.

Note that screen X/Y positions are in screen pixels at the 1280x720 resolution. Each pixel of the sprite is drawn twice, and each line of the sprite is also drawn twice. 

The first block contains 4 32-bit words, one for each of the 512 sprites, as follows:

```
    +---+---------------------------------+
    |   | 1 1 1 1 1 1                     |
    |   | 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 |
    +---+---------------------------------+
    | 0 | y y y y y y y y y y y y f f f f | Sprite Y
    | 1 | t t t t t t t t h h h h h h h h | Tilemap Y / Height
    +---+---------------------------------+
    
    y - 12 bit signed screen Y coordinate (in screen pixels)
    f - 4 bit Fixed point Y coord fraction
    t - 8 bit Tilemap Y coordinate (in tiles)
    h - 8 bit Sprite Height (in tiles)
    
    Note: To disable the sprite, set the height to 0.
    
    +---+---------------------------------+
    |   | 1 1 1 1 1 1                     |
    |   | 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 |
    +---+---------------------------------+
    | 0 | x x x x x x x x x x x x g g g g | Sprite X
    | 1 | s s s s s s s s w w w w w w w w | Tilemap X / Width
    +---+---------------------------------+
    
    x - 12 bit signed screen X coordinate (in screen pixels)
    g - 4 bit Fixed point X coord fraction
    s - 8 bit Tilemap X coordinate (in tiles)
    w - 8 bit Sprite Width (in tiles)
    
    +---+---------------------------------+
    |   | 1 1 1 1 1 1                     |
    |   | 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 |
    +---+---------------------------------+
    | 0 | s s s s s s s s s s s s s s s s | Tile Set Address
    | 1 | m m m m m m m m m m m m m m m m | Tilemap Address
    +---+---------------------------------+
    
    s - 16 bit Tile Set address (in 1 kB increments)
    m - 16 bit Tilemap address (in 1 kB increments)
    
    +---+---------------------------------+
    |   | 1 1 1 1 1 1                     |
    |   | 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 |
    +---+---------------------------------+
    | 0 | y y y y y y y y y y y y f f f f | Y Velocity
    | 1 | x x x x x x x x x x x x g g g g | X Velocity
    +---+---------------------------------+

    y.f - 12.4 bit fixed point Y velocity (added to Y each frame)
    x.g - 12.4 bit fixed point X velocity (added to X each frame)
```

The second block is 512 words long, one for each sprite, and contains these bits:

```
    +---+---------------------------------+
    |   | 1 1 1 1 1 1                     |
    |   | 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 |
    +---+---------------------------------+
    | 0 | . . . . . . . . . . x y a a b b | Tilemap Size, X/Y Flip
    | 1 | . . . . . . . . . . . . . . . . | Unused
    +---+---------------------------------+

    a, b - Tilemap Width / Stride in formula `(1 << (a+4)) + (1 << (b+4))`
    x - Sprite X flip / mirror (not yet implemented)
    y - Sprite Y flip / mirror (not yet implemented)
```

## 5.1. Theory of Operation

The VDP is deeply pipelined and separated into two "timing domains" by a double buffered line buffer: the draw domain and the pixel domain. A line buffer is similar to a frame buffer except for only one line. For each line sent to the monitor in the pixel domain, the line buffer gets flipped. For the entire duration of the line being drawn to the screen in the pixel domain, including the horizontal blanking, the draw domain gets to draw in the off-screen line buffer.

The pipeline of the pixel domain is to read a byte from the line buffer, look up its palette entry, and send the 24 bit color to the screen. Because the line buffer has two ports: a read port and a write port, the write port is used to zero out the line buffer after sending the data to the screen.

The pipeline of the draw domain is a lot more complex, and so could run at a different clock rate. There's two different "state machines" that operate in this pipeline:

There is the sprite scanner, which acts with a Y coordinate two lines ahead of the one being drawn. This state machine scans through each sprite looking for sprites that intersect the Y coordinate and that would be visible. When it finds one, it calculates the address ranges of the tilemap data for the visible portion to be loaded and copies the relevant sprite attributes into a separate double buffer that's flipped each line.

The other state machine scans through the sprite buffer one by one, "activating" each sprite by sending its data to the draw pipeline and waiting for the draw pipeline to finish before sending the next sprite to it.

For each tile in the activated sprite, the draw pipeline loads the tilemap entry, then twice it loads 4 4-bit "texels" of the tile data. The texels are combined with the palette entry from the tilemap data to form 8 bit pixels. The 8 bit pixels are then doubled from 4 to 8 pixels. The pixels are then "aligned" such that they can be written to the line buffer 8 pixels per cycle with a possible extra cycle required to clear the alignment buffer after the sprite finishes drawing. After alignment, the pixels are drawn up to 8 pixels per clock into the draw buffer at the specific offset.

There is 1360 pixel clocks per scan line (including blanking time). Four pixels can be drawn per cycle. A tile is 8 pixels, so takes 2 cycles to draw. That means as much as 680 tiles can be drawn per line. However, that presumes large sprites since it takes an extra cycle between sprites. It also assumes the tilemap data can be read from a separate memory than the tile texel data. This also assumes the draw domain is clocked at the same clock rate as the pixel domain. If all 256 sprites are drawn on a single line, and the tilemap data and texel data are in the same memory, then it could be as low as 368 tiles per line.

There is an idea for making this system more efficient: A one bit z-buffer line-buffer could be implemented, where the transparency masks are stored in a separate block RAM for fast access. Sprites would first be drawn into the z-buffer and only texels which are actually drawn would get loaded from memory and blitted to the line buffer. The draw pipeline would then be a series of fifos: the tilemap data would be read, the mask data it points to would be read 16 bits at a time, and any of the 8 texels matching would be fed into a fifo to have the texel data loaded and blitted to the line buffer in the relavent locations. Any sprites entirely occluded would not even have their texel data loaded. The mask could even be at the sub-pixel level allowing portions of the doubled pixels to be masked since 16 pixels can be loaded at once. However the zbuffer and masking system is a significant amount of extra complexity.
