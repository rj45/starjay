.PHONY: all clean bootstrap tests public

all: bootstrap tests examples

bootstrap:
	make -C starjette bootstrap

tests:
	make -C starjette tests

examples:
	make -C starjette examples

clean:
	make -C starjette clean

dlimage:
	wget https://github.com/cnlohr/mini-rv32ima-images/raw/master/images/linux-6.1.14-rv32nommu-cnl-1.zip -O linux-6.1.14-rv32nommu-cnl-1.zip
	unzip linux-6.1.14-rv32nommu-cnl-1.zip
	mv Image LinuxImage
	rm linux-6.1.14-rv32nommu-cnl-1.zip

public:
	@COMMIT=$$(git rev-list -1 --before="30 days ago" main); \
	if [ -n "$$COMMIT" ]; then \
		echo "Pushing up to $$COMMIT to public remote..."; \
		git push public "$$COMMIT":main; \
	else \
		echo "No commits older than 30 days"; \
	fi
