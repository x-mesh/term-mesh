# term-mesh Makefile
# Usage:
#   make build          — Xcode Debug build + Rust daemon release build
#   make deploy         — build + copy to /Applications + launch
#   make run            — launch from /Applications (no build)
#   make stop           — stop running app + daemon
#   make clean          — remove build artifacts
#   make daemon         — build only the Rust daemon (release)
#   make test           — run daemon tests

TAG           ?= term-mesh
DERIVED_DATA  := /tmp/cmux-$(TAG)
BUILD_DIR     := $(DERIVED_DATA)/Build/Products/Debug
SRC_APP       := $(BUILD_DIR)/cmux DEV $(TAG).app
BASE_APP      := $(BUILD_DIR)/cmux DEV.app
INSTALL_APP   := /Applications/term-mesh.app
BUNDLE_ID     := com.cmuxterm.app.debug.term.mesh
PROJECT_DIR   := $(shell pwd)

.PHONY: build deploy run stop clean daemon test

build:
	@echo "==> Building Xcode (Debug)..."
	@xcodebuild \
		-project GhosttyTabs.xcodeproj \
		-scheme cmux \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath "$(DERIVED_DATA)" \
		build 2>&1 | grep -E '(warning:|error:|BUILD|Compiling)' || true
	@# Tag the app bundle
	@if [ ! -d "$(SRC_APP)" ] && [ -d "$(BASE_APP)" ]; then \
		cp -R "$(BASE_APP)" "$(SRC_APP)"; \
	fi
	@echo "==> Building Rust daemon (release)..."
	@cd daemon && cargo build --release 2>&1 | grep -v "Compiling " || true
	@echo "==> Build complete"

daemon:
	@echo "==> Building Rust daemon (release)..."
	@cd daemon && cargo build --release
	@echo "==> daemon: target/release/term-mesh, target/release/term-meshd"

test:
	@cd daemon && cargo test

deploy: build
	@echo "==> Stopping existing app..."
	@-pkill -f "term-mesh.app/Contents/MacOS" 2>/dev/null || true
	@sleep 0.5
	@echo "==> Deploying to $(INSTALL_APP)..."
	@rm -rf "$(INSTALL_APP)"
	@cp -R "$(SRC_APP)" "$(INSTALL_APP)"
	@# Symlink Rust binaries into app bundle
	@mkdir -p "$(INSTALL_APP)/Contents/Resources/bin"
	@cp "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$(INSTALL_APP)/Contents/Resources/bin/term-meshd"
	@cp "$(PROJECT_DIR)/daemon/target/release/term-mesh" "$(INSTALL_APP)/Contents/Resources/bin/term-mesh"
	@echo "==> Launching term-mesh..."
	@open "$(INSTALL_APP)"
	@echo "==> Deployed to $(INSTALL_APP)"

run:
	@open "$(INSTALL_APP)"

stop:
	@-pkill -f "term-mesh.app/Contents/MacOS" 2>/dev/null || true
	@-pkill -f term-meshd 2>/dev/null || true
	@echo "==> Stopped"

clean:
	@echo "==> Cleaning build artifacts..."
	@rm -rf "$(DERIVED_DATA)"
	@cd daemon && cargo clean
	@echo "==> Clean complete"
