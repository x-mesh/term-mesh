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
#   make init           — submodule sync + GhosttyKit build, only if out of date
#   make doctor         — diagnose submodule / xcframework / toolchain state
#   make sync           — force ghostty submodule sync (scripts/sync-submodules.sh)
#   make setup          — build/cache GhosttyKit.xcframework + symlink (scripts/setup.sh)

TAG           ?= term-mesh
DERIVED_DATA  := /tmp/term-mesh-$(TAG)
BUILD_DIR     := $(DERIVED_DATA)/Build/Products/Debug
PROD_DERIVED_DATA ?= /tmp/term-mesh-prod
PROD_DIR      := $(PROD_DERIVED_DATA)/Build/Products/Release
SRC_APP       := $(BUILD_DIR)/term-mesh DEV $(TAG).app
BASE_APP      := $(BUILD_DIR)/term-mesh DEV.app
PROD_APP      := $(PROD_DIR)/term-mesh.app
INSTALL_APP   := /Applications/term-mesh.app
BUNDLE_ID     := com.term-mesh.app.debug
APP_VERSION   := $(shell grep 'MARKETING_VERSION' GhosttyTabs.xcodeproj/project.pbxproj | head -1 | sed 's/.*= *//;s/ *;.*//')
DMG_NAME      := term-mesh-macos-$(APP_VERSION).dmg
PROJECT_DIR   := $(shell pwd)
CACHE_ROOT    := $(or $(TERMMESH_GHOSTTYKIT_CACHE_DIR),$(HOME)/.cache/term-mesh/ghosttykit)
XCFW          := GhosttyKit.xcframework

# Single source of truth for daemon binaries shipped inside the app
# bundle's Contents/Resources/bin. Adding a new Rust workspace member
# that needs to ship with the app? Append it here — every install/dmg
# target picks it up automatically. `verify-daemon-binaries` enforces
# that each one was actually built before any packaging step runs.
DAEMON_BINS   := term-meshd term-mesh-run tm-agent term-mesh-peer-relay tm-agent-bridge

.PHONY: init doctor sync setup build prod deploy deploy-prod dmg dmg-package run stop clean daemon test install-commands sentry-upload-dsym verify-daemon-binaries

# One-shot onboarding: sync the ghostty submodule and build/cache GhosttyKit
# only when out of date. Safe to run repeatedly — no-op when everything matches.
init:
	@set -e; \
	if git submodule status ghostty | grep -qE '^[+-]'; then \
		echo "==> ghostty submodule out of sync — running sync-submodules.sh"; \
		./scripts/sync-submodules.sh; \
	else \
		echo "==> ghostty submodule in sync"; \
	fi; \
	sha="$$(git -C ghostty rev-parse HEAD)"; \
	want="$(CACHE_ROOT)/$$sha/$(XCFW)"; \
	have="$$(readlink $(XCFW) 2>/dev/null || true)"; \
	if [ "$$have" = "$$want" ] && [ -e "$(XCFW)/macos-arm64_x86_64/libghostty.a" ]; then \
		echo "==> GhosttyKit.xcframework ready ($$sha)"; \
	else \
		echo "==> GhosttyKit.xcframework not ready for $$sha — running setup.sh"; \
		./scripts/setup.sh; \
	fi; \
	echo "==> init complete (run 'make build' next)"

# Read-only diagnosis of submodule / xcframework / toolchain state.
doctor:
	@echo "term-mesh doctor"; \
	st="$$(git submodule status ghostty 2>/dev/null)"; \
	case "$$st" in \
		" "*) echo "  [ok]   ghostty submodule in sync";; \
		"+"*) echo "  [warn] ghostty submodule SHA mismatch     -> make sync";; \
		"-"*) echo "  [warn] ghostty submodule not initialized  -> make init";; \
		*)    echo "  [warn] ghostty submodule status unknown   -> make init";; \
	esac; \
	sha="$$(git -C ghostty rev-parse HEAD 2>/dev/null)"; \
	want="$(CACHE_ROOT)/$$sha/$(XCFW)"; \
	have="$$(readlink $(XCFW) 2>/dev/null || true)"; \
	if [ "$$have" = "$$want" ] && [ -e "$(XCFW)/macos-arm64_x86_64/libghostty.a" ]; then \
		echo "  [ok]   GhosttyKit.xcframework ready ($$sha)"; \
	else \
		echo "  [warn] GhosttyKit.xcframework stale/missing   -> make setup"; \
	fi; \
	zig16=""; \
	for z in "$${ZIG:-}" "$$(command -v zig 2>/dev/null)" /opt/homebrew/opt/zig/bin/zig /usr/local/opt/zig/bin/zig /opt/homebrew/opt/zig@0.16/bin/zig /usr/local/opt/zig@0.16/bin/zig $$HOME/.local/zig-0.16*/zig $$HOME/zig/zig-*-0.16*/zig; do \
		[ -n "$$z" ] && [ -x "$$z" ] && "$$z" version 2>/dev/null | grep -q '^0\.16\.' && { zig16="$$z"; break; }; \
	done; \
	if [ -n "$$zig16" ]; then \
		echo "  [ok]   zig 0.16.x available ($$zig16)"; \
	else \
		echo "  [warn] zig 0.16.x missing                     -> brew install zig (or set ZIG=...)"; \
	fi; \
	if [ -x /opt/homebrew/opt/llvm/bin/llvm-libtool-darwin ] || [ -x /usr/local/opt/llvm/bin/llvm-libtool-darwin ] || command -v llvm-libtool-darwin >/dev/null 2>&1; then \
		echo "  [ok]   llvm-libtool-darwin available"; \
	else \
		echo "  [warn] llvm-libtool-darwin missing            -> brew install llvm"; \
	fi

# Force submodule sync / GhosttyKit build (init runs these only when needed).
sync:
	@./scripts/sync-submodules.sh

setup:
	@./scripts/setup.sh

build:
	@echo "==> Generating BuildInfo.swift..."
	@./scripts/generate-build-info.sh
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
	@# Copy Rust binaries into app bundle. Set defined by DAEMON_BINS:
	@#   term-meshd          = peer/local daemon
	@#   term-mesh-run       = PTY wrapper
	@#   tm-agent            = team agent CLI
	@#   term-mesh-peer-relay= Ghostty PTY shim used by PeerRelaySession
	@# `term-mesh` (Swift CLI) is already bundled from the Xcode "Copy CLI" phase.
	@$(MAKE) verify-daemon-binaries
	@mkdir -p "$(INSTALL_APP)/Contents/Resources/bin"
	@for b in $(DAEMON_BINS); do \
		cp "$(PROJECT_DIR)/daemon/target/release/$$b" "$(INSTALL_APP)/Contents/Resources/bin/$$b" || exit 1; \
	done
	@echo "==> Re-signing app bundle (binaries added after initial sign)..."
	@codesign --force --deep --sign - "$(INSTALL_APP)"
	@"$(PROJECT_DIR)/scripts/check-bundle-binaries.sh" "$(INSTALL_APP)"
	@# Update symlinks (term-mesh = Swift CLI from app bundle, term-mesh-run = Rust PTY wrapper)
	@mkdir -p "$(HOME)/.local/bin"
	@ln -sf "$(INSTALL_APP)/Contents/Resources/bin/term-mesh" "$(HOME)/.local/bin/term-mesh"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$(HOME)/.local/bin/term-meshd"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" "$(HOME)/.local/bin/term-mesh-run"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/tm-agent" "$(HOME)/.local/bin/tm-agent" 2>/dev/null || true
	@echo "==> Starting daemon..."
	@nohup "$(HOME)/.local/bin/term-meshd" > /tmp/term-meshd.log 2>&1 & sleep 0.5
	@echo "==> Launching term-mesh..."
	@open "$(INSTALL_APP)"
	@echo "==> Deployed to $(INSTALL_APP)"
	@$(MAKE) install-commands

run:
	@open "$(INSTALL_APP)"

stop:
	@-pkill -f "term-mesh.app/Contents/MacOS" 2>/dev/null || true
	@-pkill -f term-meshd 2>/dev/null || true
	@echo "==> Stopped"

# Report stale term-meshd daemons, sockets, tag dirs, and debug logs (dry run).
cleanup-dry:
	@./scripts/cleanup-daemons.sh

# Remove stale leftovers only — active daemons/sockets/open logs are kept.
cleanup:
	@./scripts/cleanup-daemons.sh --kill

# Kill ALL term-meshd processes and remove their sockets. Destructive.
cleanup-all:
	@./scripts/cleanup-daemons.sh --all

prod:
	@echo "==> Generating BuildInfo.swift..."
	@./scripts/generate-build-info.sh
	@echo "==> Building Xcode (Release)..."
	@xcodebuild \
		-project GhosttyTabs.xcodeproj \
		-scheme term-mesh \
		-configuration Release \
		-destination 'platform=macOS' \
		-derivedDataPath "$(PROD_DERIVED_DATA)" \
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
	@if [ "$(SENTRY_UPLOAD_DSYM)" = "0" ]; then \
		echo "==> dSYM upload deferred to strict release verification"; \
	else \
		$(MAKE) sentry-upload-dsym DSYM_DIR="$(PROD_DIR)"; \
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

deploy-prod: daemon prod
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
	@$(MAKE) verify-daemon-binaries
	@mkdir -p "$(INSTALL_APP)/Contents/Resources/bin"
	@for b in $(DAEMON_BINS); do \
		cp "$(PROJECT_DIR)/daemon/target/release/$$b" "$(INSTALL_APP)/Contents/Resources/bin/$$b" || exit 1; \
	done
	@echo "==> Re-signing app bundle (binaries added after initial sign)..."
	@codesign --force --deep --sign - "$(INSTALL_APP)"
	@mkdir -p "$(HOME)/.local/bin"
	@ln -sf "$(INSTALL_APP)/Contents/Resources/bin/term-mesh" "$(HOME)/.local/bin/term-mesh"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/term-meshd" "$(HOME)/.local/bin/term-meshd"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/term-mesh-run" "$(HOME)/.local/bin/term-mesh-run"
	@ln -sf "$(PROJECT_DIR)/daemon/target/release/tm-agent" "$(HOME)/.local/bin/tm-agent" 2>/dev/null || true
	@echo "==> Starting daemon..."
	@nohup "$(HOME)/.local/bin/term-meshd" > /tmp/term-meshd.log 2>&1 & sleep 0.5
	@echo "==> Launching term-mesh..."
	@open "$(INSTALL_APP)"
	@echo "==> Deployed Release to $(INSTALL_APP)"
	@$(MAKE) install-commands

# Upload dSYMs for Sentry symbolication. Non-fatal: skipped gracefully if
# sentry-cli is missing, auth is absent, or DSYM_DIR contains no .dSYM bundles.
# DSYM_DIR defaults to the Release build dir; override when uploading elsewhere.
DSYM_DIR ?= $(PROD_DIR)
SENTRY_UPLOAD_DSYM ?= 1
sentry-upload-dsym:
	@if ! command -v sentry-cli >/dev/null 2>&1; then \
		echo "==> sentry-cli not installed; skipping dSYM upload"; \
		exit 0; \
	fi
	@if ! sentry-cli info >/dev/null 2>&1; then \
		echo "==> sentry-cli not authenticated; skipping dSYM upload"; \
		exit 0; \
	fi
	@APP_DSYM="$(DSYM_DIR)/term-mesh.app.dSYM"; \
	CLI_DSYM="$(DSYM_DIR)/term-mesh.dSYM"; \
	ARGS=""; \
	[ -d "$$APP_DSYM" ] && ARGS="$$ARGS $$APP_DSYM"; \
	[ -d "$$CLI_DSYM" ] && ARGS="$$ARGS $$CLI_DSYM"; \
	if [ -z "$$ARGS" ]; then \
		echo "==> No term-mesh dSYMs found in $(DSYM_DIR); skipping upload"; \
		exit 0; \
	fi; \
	echo "==> Uploading dSYMs to Sentry..."; \
	sentry-cli debug-files upload --include-sources $$ARGS || \
		echo "==> dSYM upload failed (non-fatal)"

verify-daemon-binaries:
	@for b in $(DAEMON_BINS); do \
		if [ ! -f "$(PROJECT_DIR)/daemon/target/release/$$b" ]; then \
			echo "ERROR: $$b not found at daemon/target/release/$$b"; \
			echo "       Run 'cd daemon && cargo build --release' first."; \
			exit 1; \
		fi; \
	done

dmg: prod
	@$(MAKE) dmg-package
	@$(MAKE) install-commands

dmg-package:
	@$(MAKE) verify-daemon-binaries
	@echo "==> Creating DMG (version $(APP_VERSION))..."
	@# Ensure no stale mount from a previous run blocks create-dmg's detach step
	@-hdiutil detach "/Volumes/term-mesh" -force >/dev/null 2>&1 || true
	@rm -f "$(DMG_NAME)" rw.*.$(DMG_NAME)
	@if command -v create-dmg >/dev/null 2>&1; then \
		STAGING=$$(mktemp -d) && \
		cp -R "$(PROD_APP)" "$$STAGING/term-mesh.app" && \
		mkdir -p "$$STAGING/term-mesh.app/Contents/Resources/bin" && \
		for b in $(DAEMON_BINS); do \
			cp "$(PROJECT_DIR)/daemon/target/release/$$b" "$$STAGING/term-mesh.app/Contents/Resources/bin/$$b" || exit 1; \
		done && \
		echo "==> Re-signing app bundle for DMG..." && \
		codesign --force --deep --sign - "$$STAGING/term-mesh.app" && \
		echo "==> Bundled binaries:" && \
		ls -la "$$STAGING/term-mesh.app/Contents/Resources/bin/" && \
		"$(PROJECT_DIR)/scripts/check-bundle-binaries.sh" "$$STAGING/term-mesh.app" && \
		create-dmg \
			--volname "term-mesh" \
			--window-pos 200 120 \
			--window-size 600 400 \
			--icon-size 100 \
			--icon "term-mesh.app" 150 185 \
			--app-drop-link 450 185 \
			--no-internet-enable \
			"$(DMG_NAME)" "$$STAGING"; \
		status=$$?; \
		rm -rf "$$STAGING"; \
		exit $$status; \
	else \
		echo "==> create-dmg not found, using hdiutil fallback..."; \
		STAGING=$$(mktemp -d) && \
		cp -R "$(PROD_APP)" "$$STAGING/term-mesh.app" && \
		mkdir -p "$$STAGING/term-mesh.app/Contents/Resources/bin" && \
		for b in $(DAEMON_BINS); do \
			cp "$(PROJECT_DIR)/daemon/target/release/$$b" "$$STAGING/term-mesh.app/Contents/Resources/bin/$$b" || exit 1; \
		done && \
		echo "==> Re-signing app bundle for DMG..." && \
		codesign --force --deep --sign - "$$STAGING/term-mesh.app" && \
		echo "==> Bundled binaries:" && \
		ls -la "$$STAGING/term-mesh.app/Contents/Resources/bin/" && \
		"$(PROJECT_DIR)/scripts/check-bundle-binaries.sh" "$$STAGING/term-mesh.app" && \
		ln -s /Applications "$$STAGING/Applications" && \
		hdiutil create -volname "term-mesh" -srcfolder "$$STAGING" -ov -format UDZO "$(DMG_NAME)"; \
		status=$$?; \
		rm -rf "$$STAGING"; \
		exit $$status; \
	fi
	@# The staging cleanup above used to be the last command in each branch, so
	@# the recipe reported `rm -rf`'s status and a failed create-dmg exited 0.
	@# A release then failed one step later with only "DMG missing" and none of
	@# the packaging output that said why. Both branches propagate their own
	@# status now, and this proves the artifact exists before the banner claims
	@# it does.
	@test -f "$(DMG_NAME)" || { echo "ERROR: $(DMG_NAME) was not created" >&2; exit 1; }
	@# create-dmg occasionally leaves the read-write intermediate behind when
	@# Finder detach is slow; clean it up so only the final UDZO remains.
	@rm -f rw.*.$(DMG_NAME)
	@-hdiutil detach "/Volumes/term-mesh" -force >/dev/null 2>&1 || true
	@echo ""
	@echo "================================================"
	@echo "  DMG created: $(DMG_NAME)"
	@echo "  Version:     $(APP_VERSION)"
	@echo "  Size:        $$(du -h "$(DMG_NAME)" | cut -f1)"
	@echo "================================================"
	@echo "  Install: open $(DMG_NAME), drag term-mesh to Applications"
	@echo "  Unsigned: run 'xattr -cr /Applications/term-mesh.app' after install"
	@echo "================================================"
# 이 목록은 scripts/copy-claude-commands.sh 의 COMMANDS 배열과 동기화 유지.
# tests/test_release_distribution.py 가 두 목록이 어긋나면 실패한다.
install-commands:
	@echo "==> Installing Claude commands to ~/.claude/commands/..."
	@mkdir -p "$(HOME)/.claude/commands"
	@for cmd in tm team team-up tm-op tm-bench watch release rc; do \
		SRC="$(PROJECT_DIR)/.claude/commands/$$cmd.md"; \
		if [ -f "$$SRC" ]; then \
			cp "$$SRC" "$(HOME)/.claude/commands/$$cmd.md"; \
		fi; \
	done
	@echo "==> Claude commands installed (tm, team, team-up, tm-op, tm-bench, watch, release, rc)"

clean:
	@echo "==> Cleaning build artifacts..."
	@rm -rf "$(DERIVED_DATA)" /tmp/term-mesh-prod
	@cd daemon && cargo clean
	@echo "==> Clean complete"
