# Makefile for starj test suite

# Auto-detect Python command
PYTHON := $(shell command -v python3 2>/dev/null || command -v python 2>/dev/null)

# ISA CPU definition (instruction encodings and bank definitions only)
ISA := customasm/starj_cpudef.asm

# Test kernel for the tests
KERNEL := customasm/test_kernel.asm

# Find all test .asm files (regular and bootstrap)
TEST_SRCS := $(wildcard tests/*.asm)
BOOT_SRCS := $(wildcard tests/bootstrap/*.asm)
TEST_BINS := $(TEST_SRCS:.asm=.bin)
TEST_HEXS := $(TEST_SRCS:.asm=.hex)
TEST_LISTINGS := $(TEST_SRCS:.asm=_listing.txt)
BOOT_BINS := $(BOOT_SRCS:.asm=.bin)
BOOT_HEXS := $(BOOT_SRCS:.asm=.hex)
BOOT_LISTINGS := $(BOOT_SRCS:.asm=_listing.txt)

.PHONY: all generate clean bootstrap tests

all: bootstrap tests

# Build just bootstrap tests (for early development)
bootstrap: $(BOOT_BINS) $(BOOT_HEXS) $(BOOT_LISTINGS)

# Build regular tests (requires generate first)
tests: generate $(TEST_BINS) $(TEST_HEXS) $(TEST_LISTINGS)

# Generate test .asm files from Python script
generate:
	$(PYTHON) tests/generate_tests.py

# Build .bin from .asm (regular tests - use full kernel)
tests/%.bin: tests/%.asm $(ISA) $(KERNEL)
	customasm -q -f binary -o $@ $(ISA) $(KERNEL) $<

# Build .hex from .asm (regular tests - use full kernel)
tests/%.hex: tests/%.asm $(ISA) $(KERNEL)
	customasm -q -f intelhex,addr_unit:8 -o $@ $(ISA) $(KERNEL) $<

# Build _listing.txt from .asm (regular tests - use full kernel)
tests/%_listing.txt: tests/%.asm $(ISA) $(KERNEL)
	customasm -q -f annotated,base:16,group:2,addr_base:16,labels:true -o $@ $(ISA) $(KERNEL) $<

# Build .bin from .asm (bootstrap tests - ISA only, no kernel)
tests/bootstrap/%.bin: tests/bootstrap/%.asm $(ISA)
	customasm -q -f binary -o $@ $(ISA) $<

# Build .hex from .asm (bootstrap tests - ISA only, no kernel)
tests/bootstrap/%.hex: tests/bootstrap/%.asm $(ISA)
	customasm -q -f intelhex,addr_unit:8 -o $@ $(ISA) $<

# Build _listing.txt from .asm (regular tests - use full kernel)
tests/bootstrap/%_listing.txt: tests/bootstrap/%.asm $(ISA) $(KERNEL)
	customasm -q -f annotated,base:16,group:2,addr_base:16,labels:true -o $@ $(ISA) $<

# Special rule for boot_09 which needs the full kernel
tests/bootstrap/boot_09_syscall.bin: tests/bootstrap/boot_09_syscall.asm $(ISA) $(KERNEL)
	customasm -q -f binary -o $@ $(ISA) $(KERNEL) $<

tests/bootstrap/boot_09_syscall.hex: tests/bootstrap/boot_09_syscall.asm $(ISA) $(KERNEL)
	customasm -q -f intelhex,addr_unit:8 -o $@ $(ISA) $(KERNEL) $<

tests/bootstrap/boot_09_syscall_listing.txt: tests/bootstrap/boot_09_syscall.asm $(ISA) $(KERNEL)
	customasm -q -f annotated,base:16,group:2,addr_base:16,labels:true -o $@ $(ISA) $(KERNEL) $<

clean:
	rm -f tests/*.bin tests/*.hex tests/*_listing.txt tests/bootstrap/*.bin tests/bootstrap/*.hex tests/bootstrap/*_listing.txt
