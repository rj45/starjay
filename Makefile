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

public:
	@COMMIT=$$(git rev-list -1 --before="30 days ago" main); \
	if [ -n "$$COMMIT" ]; then \
		echo "Pushing up to $$COMMIT to public remote..."; \
		git push public "$$COMMIT":main; \
	else \
		echo "No commits older than 30 days"; \
	fi
