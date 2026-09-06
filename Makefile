PREFIX ?= $(HOME)/.fx
BINDIR ?= $(HOME)/.local/bin

.PHONY: build install clean

build:
	zig build -Doptimize=ReleaseSafe

install: build
	mkdir -p "$(BINDIR)"
	tmp="$$(mktemp "$(BINDIR)/.kfx.XXXXXX")"; \
	trap 'rm -f "$$tmp"' EXIT HUP INT TERM; \
	cp zig-out/bin/fx "$$tmp"; \
	chmod 755 "$$tmp"; \
	mv -f "$$tmp" "$(BINDIR)/kfx"; \
	trap - EXIT HUP INT TERM

clean:
	rm -rf zig-out .zig-cache
