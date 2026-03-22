# term-mesh Makefile
# Usage:
#   make build          — Xcode Debug build + Rust daemon release build
#   make prod           — Xcode Release build + Rust daemon release build
#   make deploy         — Debug build + copy to /Applications + launch
#   make deploy-prod    — Release build + copy to /Applications + launch
#   make dmg            — Release build + create distributable DMG
#   make run            — launch from /Applications (no build)
#   make stop           — stop running app + daemon
#   make clean          — remove build artifacts
#   make daemon         — build only the Rust daemon (release)
#   make test           — run daemon tests

TAG           ?= term-mesh
DERIVED_DATA  := /tmp/term-mesh-$(TAG)
BUILD_DIR     := $(DERIVED_DATA)/Build/Products/Debug
PROD_DIR      := /tmp/term-mesh-prod/Build/Products/Release
SRC_APP       := $(BUILD_DIR)/term-mesh DEV $(TAG).app
BASE_APP      := $(BUILD_DIR)/term-mesh DEV.app
PROD_APP      := $(PROD_DIR)/term-mesh.app
INSTALL_APP   := /Applications/term-mesh.app
BUNDLE_ID     := com.term-mesh.app.debug
APP_VERSION   := $(shell grep 'MARKETING_VERSION' GhosttyTabs.xcodeproj/project.pbxproj | head -1 | sed 's/.*= *//;s/ *;.*//')
DMG_NAME      := term-mesh-macos-$(APP_VERSION).dmg
PROJECT_DIR   := $(shell pwd)

.PHONY: build prod deploy deploy-prod dmg run stop clean daemon test install-commands

build:
	@echo "==> Building Xcode (Debug)..."
	@xcodebuild \
		-project GhosttyTabs.xcodeproj \
		-scheme term-mesh \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath "$(DERIVED_DATA)" \
		build 2>&1 | tee /tmp/term-mesh-xcodebuild.log | grep -E '(warning:|error:|BUILD|Compiling)'; \
		RESULT=$${PIPESTATUS[0]}; \
		if [ $$RESULT -ne 0 ]; then \
			echo "==> Xcode build FAILED (exit $$RESULT). Full log: /tmp/term-mesh-xcodebuild.log"; \
			tail -20 /tmp/term-mesh-xcodebuild.log; \
			exit 1; \
		fi
	@# Tag the app bundle (always refresh from latest build)
	@if [ -d "$(BASE_APP)" ]; then \
		rm -rf "$(SRC_APP)"; \
		cp -R "$(BASE_APP)" "$(SRC_APP)"; \
	else \
		echo "==> ERROR: $(BASE_APP) not found. Xcode build may have failed silently."; \
		echo "==> Check full log: /tmp/term-mesh-xcodebuild.log"; \
		exit 1; \
	fi
	@echo "==> Building Rust daemon (release)..."
	@cd daemon && cargo build --release 2>&1 | tee /tmp/term-mesh-cargo.log | grep -v "Compiling "; \
		RESULT=$${PIPESTATUS[0]}; \
		if [ $$RESULT -ne 0 ]; then \
			echo "==> Rust daemon build FAILED (exit $$RESULT). Full log: /tmp/term-mesh-cargo.log"; \
			tail -20 /tmp/term-mesh-cargo.log; \
			exit 1; \
		fi
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
	@-cp "$(PROJECT_DIR)/daemon/target/release/tm-agent" "$(INSTALL_APP)/Contents/Resources/bin/tm-agent" 2>/dev/null || true
	@echo "==> Re-signing app bundle (binaries added after initial sign)..."
	@codesign --force --deep --sign - "$(INSTALL_APP)"
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

prod:
	@echo "==> Building Xcode (Release)..."
	@xcodebuild \
		-project GhosttyTabs.xcodeproj \
		-scheme term-mesh \
		-configuration Release \
		-destination 'platform=macOS' \
		-derivedDataPath /tmp/term-mesh-prod \
		ONLY_ACTIVE_ARCH=YES \
		build 2>&1 | tee /tmp/term-mesh-xcodebuild-prod.log | grep -E '(warning:|error:|BUILD|Compiling)'; \
		RESULT=$${PIPESTATUS[0]}; \
		if [ $$RESULT -ne 0 ]; then \
			echo "==> Release build FAILED (exit $$RESULT). Full log: /tmp/term-mesh-xcodebuild-prod.log"; \
			tail -20 /tmp/term-mesh-xcodebuild-prod.log; \
			exit 1; \
		fi
	@echo "==> Building Rust daemon (release)..."
	@cd daemon && cargo build --release 2>&1 | tee /tmp/term-mesh-cargo.log | grep -v "Compiling "; \
		RESULT=$${PIPESTATUS[0]}; \
		if [ $$RESULT -ne 0 ]; then \
			echo "==> Rust daemon build FAILED (exit $$RESULT). Full log: /tmp/term-mesh-cargo.log"; \
			tail -20 /tmp/term-mesh-cargo.log; \
			exit 1; \
		fi
	@echo ""
	@echo "================================================"
	@echo "  Release build complete!"
	@echo "================================================"
	@echo "  App:     $(PROD_APP)"
	@echo "  Daemon:  $(PROJECT_DIR)/daemon/target/release/term-meshd"
	@echo ""
	@echo "  Install:"
	@echo "    cp -R \"$(PROD_APP)\" /Applications/"
	@echo "    xattr -cr /Applications/term-mesh.app"
	@echo ""
	@echo "  Or use:  make deploy-prod   (auto install + launch)"
	@echo "           make dmg           (create distributable DMG)"
	@echo "================================================"

deploy-prod: prod
	@echo "==> Stopping existing app + daemon..."
	@-pkill -f "term-mesh.app/Contents/MacOS" 2>/dev/null || true
	@-pkill -f "term-mesh DEV" 2>/dev/null || true
	@-pkill term-meshd 2>/dev/null || true
	@sleep 1
	@-pkill -9 term-meshd 2>/dev/null || true
	@sleep 0.3
	@echo "==> Deploying Release to $(INSTALL_APP)..."
	@rm -rf "$(INSTALL_APP)"
	@cp -R "$(PROD_APP)" "$(INSTALL_APP)"
	@mkdir -p "$(INSTALL_APP)/Contents/Resources/bin"
	@cp "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$(INSTALL_APP)/Contents/Resources/bin/term-meshd"
	@cp "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" "$(INSTALL_APP)/Contents/Resources/bin/term-mesh-run"
	@-cp "$(PROJECT_DIR)/daemon/target/release/tm-agent" "$(INSTALL_APP)/Contents/Resources/bin/tm-agent" 2>/dev/null || true
	@echo "==> Re-signing app bundle (binaries added after initial sign)..."
	@codesign --force --deep --sign - "$(INSTALL_APP)"
	@ln -sf "$(INSTALL_APP)/Contents/Resources/bin/term-mesh" "$(HOME)/bin/term-mesh"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$(HOME)/bin/term-meshd"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" "$(HOME)/bin/term-mesh-run"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/tm-agent" "$(HOME)/bin/tm-agent" 2>/dev/null || true
	@echo "==> Starting daemon..."
	@nohup "$(HOME)/bin/term-meshd" > /tmp/term-meshd.log 2>&1 & sleep 0.5
	@echo "==> Launching term-mesh..."
	@open "$(INSTALL_APP)"
	@echo "==> Deployed Release to $(INSTALL_APP)"
	@$(MAKE) install-commands

dmg: prod
	@echo "==> Verifying daemon binaries..."
	@test -f "$(PROJECT_DIR)/daemon/target/release/term-meshd" || \
		(echo "ERROR: term-meshd not found. Run 'cd daemon && cargo build --release' first." && exit 1)
	@test -f "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" || \
		(echo "ERROR: term-mesh-run not found. Run 'cd daemon && cargo build --release' first." && exit 1)
	@test -f "$(PROJECT_DIR)/daemon/target/release/tm-agent" || \
		(echo "ERROR: tm-agent not found. Run 'cd daemon && cargo build --release' first." && exit 1)
	@echo "==> Creating DMG (version $(APP_VERSION))..."
	@rm -f "$(DMG_NAME)"
	@if command -v create-dmg >/dev/null 2>&1; then \
		STAGING=$$(mktemp -d) && \
		cp -R "$(PROD_APP)" "$$STAGING/term-mesh.app" && \
		mkdir -p "$$STAGING/term-mesh.app/Contents/Resources/bin" && \
		cp "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$$STAGING/term-mesh.app/Contents/Resources/bin/term-meshd" && \
		cp "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" "$$STAGING/term-mesh.app/Contents/Resources/bin/term-mesh-run" && \
		cp "$(PROJECT_DIR)/daemon/target/release/tm-agent" "$$STAGING/term-mesh.app/Contents/Resources/bin/tm-agent" && \
		echo "==> Re-signing app bundle for DMG..." && \
		codesign --force --deep --sign - "$$STAGING/term-mesh.app" && \
		echo "==> Bundled binaries:" && \
		ls -la "$$STAGING/term-mesh.app/Contents/Resources/bin/" && \
		create-dmg \
			--volname "term-mesh" \
			--window-pos 200 120 \
			--window-size 600 400 \
			--icon-size 100 \
			--icon "term-mesh.app" 150 185 \
			--app-drop-link 450 185 \
			--no-internet-enable \
			"$(DMG_NAME)" "$$STAGING"; \
		rm -rf "$$STAGING"; \
	else \
		echo "==> create-dmg not found, using hdiutil fallback..."; \
		STAGING=$$(mktemp -d) && \
		cp -R "$(PROD_APP)" "$$STAGING/term-mesh.app" && \
		mkdir -p "$$STAGING/term-mesh.app/Contents/Resources/bin" && \
		cp "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$$STAGING/term-mesh.app/Contents/Resources/bin/term-meshd" && \
		cp "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" "$$STAGING/term-mesh.app/Contents/Resources/bin/term-mesh-run" && \
		cp "$(PROJECT_DIR)/daemon/target/release/tm-agent" "$$STAGING/term-mesh.app/Contents/Resources/bin/tm-agent" && \
		echo "==> Re-signing app bundle for DMG..." && \
		codesign --force --deep --sign - "$$STAGING/term-mesh.app" && \
		echo "==> Bundled binaries:" && \
		ls -la "$$STAGING/term-mesh.app/Contents/Resources/bin/" && \
		ln -s /Applications "$$STAGING/Applications" && \
		hdiutil create -volname "term-mesh" -srcfolder "$$STAGING" -ov -format UDZO "$(DMG_NAME)"; \
		rm -rf "$$STAGING"; \
	fi
	@echo ""
	@echo "================================================"
	@echo "  DMG created: $(DMG_NAME)"
	@echo "  Version:     $(APP_VERSION)"
	@echo "  Size:        $$(du -h "$(DMG_NAME)" | cut -f1)"
	@echo "================================================"
	@echo "  Install: open $(DMG_NAME), drag term-mesh to Applications"
	@echo "  Unsigned: run 'xattr -cr /Applications/term-mesh.app' after install"
	@echo "================================================"
	@$(MAKE) install-commands

install-commands:
	@echo "==> Installing Claude commands to ~/.claude/commands/..."
	@mkdir -p "$(HOME)/.claude/commands"
	@for cmd in tm-op team team-up tm-bench; do \
		SRC="$(PROJECT_DIR)/.claude/commands/$$cmd.md"; \
		if [ -f "$$SRC" ]; then \
			cp "$$SRC" "$(HOME)/.claude/commands/$$cmd.md"; \
		fi; \
	done
	@echo "==> Claude commands installed (tm-op, team, team-up, tm-bench)"

clean:
	@echo "==> Cleaning build artifacts..."
	@rm -rf "$(DERIVED_DATA)" /tmp/term-mesh-prod
	@cd daemon && cargo clean
	@echo "==> Clean complete"
