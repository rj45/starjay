STARJAY := "../starjay/zig-out/bin/starjay"
# TODO: change this
BIN_NAME := "starjay_template"

.PHONY: build
build:
	zig build

.PHONY: run
run: build
	$(STARJAY) --riscv --vdp --rom zig-out/bin/${BIN_NAME}

.PHONY: clean
clean:
	rm -rf zig-out

.PHONY: distclean
distclean: clean
	rm -rf .zig-cache
