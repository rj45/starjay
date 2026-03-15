# sjtilemap

This is a mostly AI written tool to help convert images into the format required by StarJay's VDP. 

It should work losslessly if you stay below 32 palettes and 16 colours per tile, and stay under 256 total tiles. After that and it starts to do intelligent quantization that may or may not do justice to your art.

This is based on an original tool in Go in the [`github.com/rj45/rj32`](https://github.com/rj45/rj32/tree/main/tilemap) repo called `tilemap` which I myself wrote (no AI). 

This was adapted and translated to Rust in the [`github.com/rj45/vdp`](https://github.com/rj45/vdp/tree/main/imgconv) repo as `imgconv`. The translation was originally done by me but many enhancements were added to it with AI and the code got a bit messy (as it does).

This version was an attempt to get the AI to produce better quality code, add a proper test suite to make refactoring easier, as well as converting to Zig for consistency with StarJay. Jury is out on success but it appears to work. Please report any bugs you find, I would rather this be working slop rather than vapourware slop.

One day I will delete the AI code and write it by hand, but it's too much of a sidequest right now.

## Design and Features

See [plan.md](./plan.md) for the original prompt used to guide the AI. It should be roughly:

- Generate tilemap, tileset and palette files in hex, binary, logisim (for Digital) and C array formats (for embedding in a C project -- Zig can just embed the binary), as well as JSON for passing through another tool.
- Allow batch processing of multiple files with any permutation of sharing the tileset and/or palette between files
- Config file and CLI options for all useful knobs that could be tweaked (don't think loading the config file works yet)
- Can preload a palette and it will use that (untested, AI says it should work)
