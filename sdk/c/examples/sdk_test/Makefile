STARJAY_SDK_PATH = ../..
CC = riscv32-unknown-linux-musl-gcc
CFLAGS = -march=rv32im_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -nostartfiles
LDFLAGS = -T src/linker.ld
INCLUDES = "-I${STARJAY_SDK_PATH}/libs"
BIN = sdk_test

.PHONY: all
all: $(BIN)

$(BIN): src/main.c src/start.s
	$(CC) $(CFLAGS) $(LDFLAGS) $(INCLUDES) -o $@ src/start.s src/main.c

.PHONY: clean
clean:
	rm -f $(BIN)
