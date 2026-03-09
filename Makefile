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
SRC_APP       := $(BUILD_DIR)/term-mesh DEV $(TAG).app
BASE_APP      := $(BUILD_DIR)/term-mesh DEV.app
INSTALL_APP   := /Applications/term-mesh.app
BUNDLE_ID     := com.term-mesh.app.debug
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
		build 2>&1 | tee /tmp/cmux-xcodebuild.log | grep -E '(warning:|error:|BUILD|Compiling)'; \
		RESULT=$${PIPESTATUS[0]}; \
		if [ $$RESULT -ne 0 ]; then \
			echo "==> Xcode build FAILED (exit $$RESULT). Full log: /tmp/cmux-xcodebuild.log"; \
			tail -20 /tmp/cmux-xcodebuild.log; \
			exit 1; \
		fi
	@# Tag the app bundle (always refresh from latest build)
	@if [ -d "$(BASE_APP)" ]; then \
		rm -rf "$(SRC_APP)"; \
		cp -R "$(BASE_APP)" "$(SRC_APP)"; \
	else \
		echo "==> ERROR: $(BASE_APP) not found. Xcode build may have failed silently."; \
		echo "==> Check full log: /tmp/cmux-xcodebuild.log"; \
		exit 1; \
	fi
	@echo "==> Building Rust daemon (release)..."
	@cd daemon && cargo build --release 2>&1 | grep -v "Compiling " || true
	@echo "==> Build complete"

daemon:
	@echo "==> Building Rust daemon (release)..."
	@cd daemon && cargo build --release
	@echo "==> daemon: target/release/term-mesh-run, target/release/term-meshd"

test:
	@cd daemon && cargo test

deploy: build
	@echo "==> Stopping existing app + daemon..."
	@-pkill -f "term-mesh.app/Contents/MacOS" 2>/dev/null || true
	@# Also kill any tagged debug apps to avoid confusion
	@-pkill -f "term-mesh DEV" 2>/dev/null || true
	@-pkill term-meshd 2>/dev/null || true
	@sleep 1
	@# Ensure no stale daemon remains
	@-pkill -9 term-meshd 2>/dev/null || true
	@sleep 0.3
	@echo "==> Deploying to $(INSTALL_APP)..."
	@rm -rf "$(INSTALL_APP)"
	@cp -R "$(SRC_APP)" "$(INSTALL_APP)"
	@# Copy Rust binaries into app bundle (term-mesh-run = PTY wrapper, term-meshd = daemon)
	@# Note: term-mesh (Swift CLI, socket controller) is already in the bundle from Xcode "Copy CLI" phase
	@mkdir -p "$(INSTALL_APP)/Contents/Resources/bin"
	@cp "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$(INSTALL_APP)/Contents/Resources/bin/term-meshd"
	@cp "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" "$(INSTALL_APP)/Contents/Resources/bin/term-mesh-run"
	@# Update symlinks (term-mesh = Swift CLI from app bundle, term-mesh-run = Rust PTY wrapper)
	@ln -sf "$(INSTALL_APP)/Contents/Resources/bin/term-mesh" "$(HOME)/bin/term-mesh"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$(HOME)/bin/term-meshd"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" "$(HOME)/bin/term-mesh-run"
	@echo "==> Starting daemon..."
	@nohup "$(HOME)/bin/term-meshd" > /tmp/term-meshd.log 2>&1 & sleep 0.5
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
