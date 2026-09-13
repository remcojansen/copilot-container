IMAGE      ?= copilot-container
PREFIX     ?= /usr/local
BINDIR     := $(PREFIX)/bin
ENGINE     ?= $(shell if command -v podman >/dev/null 2>&1; then echo podman; elif command -v docker >/dev/null 2>&1; then echo docker; fi)

.PHONY: build install uninstall clean test help validate-engine

validate-engine:
	@if [ -z "$(ENGINE)" ]; then \
		echo "error: neither podman nor docker was found on PATH" >&2; \
		exit 1; \
	fi
	@if ! command -v "$(ENGINE)" >/dev/null 2>&1; then \
		echo "error: container engine not found on PATH: $(ENGINE)" >&2; \
		exit 1; \
	fi

help:
	@echo "Targets:"
	@echo "  build     Build the container image ($(IMAGE)) with $(ENGINE)"
	@echo "  install   Copy bin/copilot-container into $(BINDIR)"
	@echo "  uninstall Remove it from $(BINDIR)"
	@echo "  clean     Remove the built image"
	@echo ""
	@echo "Override with e.g. 'make install PREFIX=$$HOME/.local' or 'make build ENGINE=docker'"

build: validate-engine
	$(ENGINE) build -t $(IMAGE) .

install:
	install -d "$(BINDIR)"
	install -m 0755 bin/copilot-container "$(BINDIR)/copilot-container"
	@echo "Installed: $(BINDIR)/copilot-container"

uninstall:
	rm -f "$(BINDIR)/copilot-container"

clean: validate-engine
	$(ENGINE) image rm $(IMAGE)

test:
	bash tests/test-shell.sh
