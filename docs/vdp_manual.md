# StarJ VDP Manual

Note: This manual is at a very rough draft stage and is very incomplete.

## 1.1. Introduction

The StarJ Video Display Processor (VDP) is responsible for rendering graphics to the display. It supports a sprite-based graphics system with a resolution of 640x360 pixels and 24-bit color depth. The VDP is designed to be simple yet flexible in that everything is a sprite, and sprites are tilemaps. So, text modes can be achieved by using sprite's tilemaps as text buffers, complete with smooth scrolling. You could also build GUIs with sprites. In theory, hundreds of sprites can be on screen at the same time.

### 1.2. Feature List

- Similar to the NeoGeo in how it functions, with some nods to the SNES and Gameboy.
- Everything (including the text modes) are sprites.
- Sprites are drawn to a double buffered line-buffer, where the next line's data is drawn into one buffer while the other buffer is being drawn to the screen and cleared.
- Sprites are an NxM rectangle (where N, M <= 32) of tiles from a 128x8, 64x16 or 32x32 tilemap of 8x8 pixel tiles.
- Tile maps, tile pixel data, sprite attributes, and palettes are all stored in VRAM.
- Tile pixel data is stored as 4 bits per pixel (16 colors per tile), with each tile being 8x8 pixels (32 bytes per tile).
- Text mode is achived by setting up two sprites per line, one for the upper half of the character pointed at a tile pixel set for that half, and one for the lower half pointed at the lower half of the character pixel data, and then pointing all the sprites at the same tilemap. The tilemap then becomes the text buffer.
- Sprites have indepenently defined tilemap address, tile pixel data address, position, size, palette, and attributes (priority, flip, visibility).
- Resolution is 640x360, 24-bit color (32 palettes of 16 colors each, 512 total colors on screen at once).
- Actual display resolution is 1280x720, with each pixel being drawn twice horizontally and vertically.
  - The line buffer is 2048 pixels wide with a configurable offset, and allowing sprites to be drawn at any position therein, allowing sub-pixel positioning.
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

Each sprite is defined by a set of attributes stored in VRAM. Each sprite attribute entry is 6 words (12 bytes) long, with the following format:

- 16 bit tilemap y and height:
    - Bits 0-6: Tilemap Y (0-127)
    - Bits 7-13: Height in tiles (1-128)
    - Bit 14-15: Tilemap size (00=32x32, 01=64x16, 10=128x8, 11=reserved)
- 16 bits screen y position
    - Bits 0-3: sub-pixel Y (0-15)
    - Bits 4-15: pixel Y (-2048 to 2047)
- 16 bit sprite x and width:
    - Bits 0-6: Tilemap X (0-127)
    - Bits 7-13: Width in tiles (1-128)
    - Bit 14: X Flip
    - Bit 15: Y Flip
- 16 bits screen x position
    - Bits 0-3: sub-pixel X (0-15)
    - Bits 4-15: pixel X (-2048 to 2047)
- 16 bit tilemap address (upper bits)
- 16 bit tile pixel data address (upper bits)

There are 512 such sprite entries, however there is a limit to how many sprite-tiles that can be drawn on a single line. It is expected to be somewhere around 680 sprite-tiles per line. The emulator will stop drawing at exactly 640 sprite-tiles per line to simulate this limitation and err on the side of caution.

Sprites are drawn in order from lowest to highest index, so higher index sprites can be drawn over top of lower index sprites in the line buffer.
