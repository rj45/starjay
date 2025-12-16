.PHONY: all clean bootstrap tests

all: bootstrap tests examples

bootstrap:
	make -C starjette bootstrap

tests:
	make -C starjette tests

examples:
	make -C starjette examples

clean:
	make -C starjette clean
