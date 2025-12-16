# StarJeet VDP Manual

**Caution!**
This manual is at a very rough draft stage and is very incomplete. Many stats and figures are wrong, and many statements are factually incorrect. Bare this in mind as you read through this document.
**Caution!**

## 1.1. Introduction

The StarJeet Video Display Processor (VDP) is responsible for rendering graphics to the display. It supports a sprite-based graphics system with a resolution of 640x360 pixels and 24-bit color depth. The VDP is designed to be simple yet flexible in that everything is a sprite, and sprites are tilemaps. So, text modes can be achieved by using sprite's tilemaps as text buffers, complete with smooth scrolling. You could also build GUIs with sprites. In theory, hundreds of sprites can be on screen at the same time.

### 1.2. Feature List

- Similar to the NeoGeo in how it functions, with some nods to the SNES and Gameboy.
- Everything (including the text modes) are sprites.
- Sprites are drawn to a double buffered line-buffer, where the next line's data is drawn into one buffer while the other buffer is being drawn to the screen and cleared.
- Sprites are an NxM rectangle (where N, M <= 32) of tiles from a 128x8, 64x16 or 32x32 tilemap of 8x8 pixel tiles.
- Tile maps, tile pixel data, sprite attributes, and palettes are all stored in VRAM.
- Tile pixel data is stored as 4 bits per pixel (16 colors per tile), with each tile being 8x8 pixels (32 bytes per tile).
- Text mode is achived by setting up two sprites per line, one for the upper half of the character pointed at a tile pixel set for that half, and one for the lower half pointed at the lower half of the character pixel data, and then pointing all the sprites at the same tilemap. The tilemap then becomes the text buffer.
- Sprites have indepenently defined tilemap address, tile pixel data address, position, size, palette, and attributes (priority, flip, visibility).
- Resolution is 640x360, 24-bit color (16 palettes of 16 colors each, 256 total colors on screen at once).
- Up to 256 sprites can be drawn at once, with a limit of between 368 and 680 total tiles drawn per line.
- Actual display resolution is 1280x720, with each pixel being drawn twice horizontally and vertically.
  - The line buffer is 2048 pixels wide with a configurable offset, and allowing sprites to be drawn at any position therein, allowing sub-pixel positioning. Note: this functionality may be removed.
- Sprites can be drawn with horizontal and vertical flipping.
        
## 2.1. Tilemaps

- Tilemap cells are 16 bits wide, with the following format:
  - Bits 0-9: Tile Index (0-1023)
  - Bits 10-13: Palette Index (0-15)
  - Bit 14: Horizontal Flip
  - Bit 15: Vertical Flip
  
## 3.1. Tile Pixel Data

- Each tile is 8x8 pixels, with each pixel represented by 4 bits (16 colors).
- Tile pixel data is stored in VRAM starting at a specified address, with each tile occupying 32 bytes (8 rows x 4 bytes per row).
- Tiles are indexed from 0 to 1023.

## 4.1. Sprite Attributes

Each sprite is defined by a set of attributes stored in a specific address range in VRAM. Each sprite attribute entry is 6 words (12 bytes) long, with the following format:

- 16 bit tilemap y and height:
    - Bits 0-5: Tilemap Y (0-63)
    - Bits 6-11: Height in tiles - 1 (0-63)
    - Bit 12-13: Tilemap size (00=64x64, 01=128x32, 10=256x16, 11=reserved)
    - Bit 14: X Flip
    - Bit 15: Y Flip
- 16 bits screen y position
    - Bits 0-3: sub-pixel Y (0-15)
    - Bits 4-15: pixel Y (-2048 to 2047)
- 16 bit sprite x and width:
    - Bits 0-7: Tilemap X (0-255)
    - Bits 8-15: Width in tiles - 1 (0-255)
- 16 bits screen x position
    - Bits 0-3: sub-pixel X (0-15)
    - Bits 4-15: pixel X (-2048 to 2047)
- 16 bit tilemap page (in units of 4096 bytes)
- 16 bit tile pixel data address (in units of 4096 bytes)

There are 256 such sprite entries, however there is a limit to how many sprite-tiles that can be drawn on a single line. Somewhere between 368 and 680 tiles may be drawn per line. In order to get closer to the 680 tiles per line, one must ensure the tilemap data and tile pixel data are inseparate memory devices and can be read simultaneously. Additionally, one must use as few sprites as possible.

Sprites are drawn in order from lowest to highest index, so higher index sprites can be drawn over top of lower index sprites in the line buffer.

## 5.1. Theory of Operation

The VDP is deeply pipelined and separated into two "timing domains" by a double buffered line buffer: the draw domain and the pixel domain. A line buffer is similar to a frame buffer except for only one line. For each line sent to the monitor in the pixel domain, the line buffer gets flipped. For the entire duration of the line being drawn to the screen in the pixel domain, including the horizontal blanking, the draw domain gets to draw in the off-screen line buffer.

The pipeline of the pixel domain is to read a byte from the line buffer, look up its palette entry, and send the 24 bit color to the screen. Because the line buffer has two ports: a read port and a write port, the write port is used to zero out the line buffer after sending the data to the screen.

The pipeline of the draw domain is a lot more complex, and so could run at a different clock rate. There's two different "state machines" that operate in this pipeline:

There is the sprite scanner, which acts with a Y coordinate two lines ahead of the one being drawn. This state machine scans through each sprite looking for sprites that intersect the Y coordinate and that would be visible. When it finds one, it calculates the address ranges of the tilemap data for the visible portion to be loaded and copies the relevant sprite attributes into a separate double buffer that's flipped each line.

The other state machine scans through the sprite buffer one by one, "activating" each sprite by sending its data to the draw pipeline and waiting for the draw pipeline to finish before sending the next sprite to it.

For each tile in the activated sprite, the draw pipeline loads the tilemap entry, then twice it loads 4 4-bit "texels" of the tile data. The texels are combined with the palette entry from the tilemap data to form 8 bit pixels. The 8 bit pixels are then doubled from 4 to 8 pixels. The pixels are then "aligned" such that they can be written to the line buffer 8 pixels per cycle with a possible extra cycle required to clear the alignment buffer after the sprite finishes drawing. After alignment, the pixels are drawn up to 8 pixels per clock into the draw buffer at the specific offset.

There is 1360 pixel clocks per scan line (including blanking time). Four pixels can be drawn per cycle. A tile is 8 pixels, so takes 2 cycles to draw. That means as much as 680 tiles can be drawn per line. However, that presumes large sprites since it takes an extra cycle between sprites. It also assumes the tilemap data can be read from a separate memory than the tile texel data. This also assumes the draw domain is clocked at the same clock rate as the pixel domain. If all 256 sprites are drawn on a single line, and the tilemap data and texel data are in the same memory, then it could be as low as 368 tiles per line.

There is an idea for making this system more efficient: A one bit z-buffer line-buffer could be implemented, where the transparency masks are stored in a separate block RAM for fast access. Sprites would first be drawn into the z-buffer and only texels which are actually drawn would get loaded from memory and blitted to the line buffer. The draw pipeline would then be a series of fifos: the tilemap data would be read, the mask data it points to would be read 16 bits at a time, and any of the 8 texels matching would be fed into a fifo to have the texel data loaded and blitted to the line buffer in the relavent locations. Any sprites entirely occluded would not even have their texel data loaded. The mask could even be at the sub-pixel level allowing portions of the doubled pixels to be masked since 16 pixels can be loaded at once. However the zbuffer and masking system is a significant amount of extra complexity.
