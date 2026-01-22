# StarJay Fantasy Console

**Note:** The public repo is 30 days behind the private development repo in order to provide a perk for patrons. This repo has active ongoing work, it just won't appear here for 30 days. If you would like to support development and get access to the latest code, please consider becoming a patron.

StarJay is a 16-bit era fantasy console with a focus on understandability. The goal is to provide the resources and interfaces required to fully understand the system and how it works, including detailed manuals, circuit schematics and a debug GUI.

## Prerequisites / Dependencies

Install customasm from here: [`https://github.com/hlorenzi/customasm`](https://github.com/hlorenzi/customasm)

If you have rust installed, this can be as simple as:

```bash
cargo install customasm
```

You also need zig installed. See [`https://ziglang.org/download/`](https://ziglang.org/download/), 0.15.x is required until all dependecies support 0.16.x.

## Building

```bash
zig build
```

## Running Tests

```bash
make all
zig build test
```

## Sieve of Eratosthenes Example

```bash
make examples
zig build run -- --rom starjette/examples/sieve.bin --debugger
```

## Running a ROM with built-in debugger UI

You can build a rom for assembly with:

```bash
customasm -f binary -o <rom.bin> starjette/customasm/cpudef.asm starjette/customasm/test_kernel.asm <rom.asm>
```

```bash
zig build run -- --rom <rom.bin> --debugger
```

## Running RISC-V

There is a RISC-V emulator included, activated with the `--riscv` flag:

```bash
zig build run -- --riscv --rom <riscv_rom.bin> 
```

### Running Linux

You can run a minimal Linux system using the included RISC-V support:

```bash
make dllinux
zig build run --release=safe -- --riscv --rom LinuxImage
```

## License and Copyright

Copyright (c) 2026 Ryan "rj45" Sanche

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
