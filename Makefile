# Builds TVView.app.
#
# The Go binary is self-contained: the webview native library is embedded by
# go-webview, and channels.yaml by go:embed. The bundle therefore carries no
# resources of its own — it exists for the things a bare binary cannot have:
# a name in the menubar, a Dock icon, and no terminal window behind it.

GO ?= go

BINARY   := tvview
HELPER   := vpnhelper
APP      := TVView.app
CONTENTS := $(APP)/Contents

# CFBundleName is what AppKit puts in the application menu. It is deliberately
# the same string as window.title in channels.yaml, so the menu reads
# "TV View" next to "Quit TV View" rather than the process name.
BUNDLE_NAME := TV View
BUNDLE_ID   := io.github.raff.tvview
MIN_MACOS   := 14.0
VERSION     := $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)

LDFLAGS := -s -w

.PHONY: all build app universal run install install-vpn-helper uninstall-vpn-helper config diff-config edit-config clean test swift-gen swift-vpn swift-test swift-mac swift-ios swift-run swift-release swift-install swift-clean

all: build

build:
	$(GO) build -ldflags '$(LDFLAGS)' -o $(BINARY) .
	$(GO) build -ldflags '$(LDFLAGS)' -o $(HELPER) ./cmd/vpnhelper

## app: bundle for this machine's architecture.
app: build
	@$(MAKE) --no-print-directory bundle EXE=$(BINARY) HELPER_EXE=$(HELPER)
	@echo "built $(APP) ($(shell uname -m), $(VERSION))"

## universal: one bundle that runs on both Intel and Apple Silicon.
#
# Each slice is compiled separately because go-webview selects its embedded
# native library by GOARCH at compile time — a slice carries the dylib for its
# own architecture, so lipo has to join finished binaries rather than the Go
# build producing a fat one. vpnhelper carries no such native dependency, but
# it's joined the same way for consistency and a single lipo pass.
universal:
	GOARCH=amd64 $(GO) build -ldflags '$(LDFLAGS)' -o $(BINARY)-amd64 .
	GOARCH=arm64 $(GO) build -ldflags '$(LDFLAGS)' -o $(BINARY)-arm64 .
	GOARCH=amd64 $(GO) build -ldflags '$(LDFLAGS)' -o $(HELPER)-amd64 ./cmd/vpnhelper
	GOARCH=arm64 $(GO) build -ldflags '$(LDFLAGS)' -o $(HELPER)-arm64 ./cmd/vpnhelper
	lipo -create -output $(BINARY)-universal $(BINARY)-amd64 $(BINARY)-arm64
	lipo -create -output $(HELPER)-universal $(HELPER)-amd64 $(HELPER)-arm64
	@$(MAKE) --no-print-directory bundle EXE=$(BINARY)-universal HELPER_EXE=$(HELPER)-universal
	@rm -f $(BINARY)-amd64 $(BINARY)-arm64 $(BINARY)-universal $(HELPER)-amd64 $(HELPER)-arm64 $(HELPER)-universal
	@echo "built $(APP) (universal, $(VERSION))"
	@lipo -archs $(APP)/Contents/MacOS/$(BINARY)

## bundle: assemble $(APP) around an already-built EXE and HELPER_EXE. Shared
## by app and universal; not meant to be called directly.
bundle:
	@test -n "$(EXE)" || { echo "bundle: EXE not set"; exit 1; }
	@test -n "$(HELPER_EXE)" || { echo "bundle: HELPER_EXE not set"; exit 1; }
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(EXE) $(CONTENTS)/MacOS/$(BINARY)
	cp $(HELPER_EXE) $(CONTENTS)/MacOS/$(HELPER)
	printf 'APPL????' > $(CONTENTS)/PkgInfo
	echo "$$INFO_PLIST" > $(CONTENTS)/Info.plist
	@plutil -lint $(CONTENTS)/Info.plist
	@# icon.icns in the project root is a placeholder; replace that file and
	@# rebuild to change the icon. Nothing else needs touching.
	@if [ -f icon.icns ]; then \
		cp icon.icns $(CONTENTS)/Resources/AppIcon.icns; \
	else \
		echo "note: no icon.icns found, the bundle gets the generic icon"; \
	fi
	@# vpnhelper is signed on its own, before the bundle: it's invoked
	@# directly by osascript (not launched as part of the app), so it's the
	@# name macOS's admin-privileges prompt actually shows the user.
	@# Ad-hoc signatures throughout — enough for this machine; not
	@# distributable ones, other Macs still need a Developer ID and
	@# notarisation.
	codesign --force --sign - $(CONTENTS)/MacOS/$(HELPER)
	codesign --force --sign - $(APP)

run: app
	open $(APP)

install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "installed /Applications/$(APP)"

## install-vpn-helper: let vpnhelper run without a password prompt every
## time, by installing a sudoers.d rule scoped to this exact binary path.
## One-time (needs re-running only if the app moves); see the script for
## details, and uninstall-vpn-helper to undo it.
## No argument: it covers every app of ours in /Applications (this Go app and the
## Swift "TV View.app"), so installing one never drops the other's rule.
install-vpn-helper:
	sudo ./scripts/install-vpn-helper.sh

uninstall-vpn-helper:
	sudo ./scripts/uninstall-vpn-helper.sh

# The config lives in iCloud Drive so every Mac on this Apple ID shares it;
# the app looks there before ~/.config/tvview.
CONFIG_DIR := $(HOME)/Library/Mobile Documents/com~apple~CloudDocs/tvview

# Editor for edit-config. Override with e.g. EDITOR="open -t" for TextEdit.
EDITOR ?= vim

## config: install channels.yaml into the iCloud config folder (creating it
## and wireguard/ if needed). Overwrites an existing one; see diff-config.
config:
	mkdir -p "$(CONFIG_DIR)/wireguard"
	cp channels.yaml "$(CONFIG_DIR)/channels.yaml"

diff-config:
	diff channels.yaml "$(CONFIG_DIR)/channels.yaml"

## edit-config: open the iCloud channels.yaml in $(EDITOR).
edit-config:
	mkdir -p "$(CONFIG_DIR)/wireguard"
	$(EDITOR) "$(CONFIG_DIR)/channels.yaml"

# --- The Swift app (swift/): macOS and iPad -------------------------------

SWIFT_DIR  := swift
XCODEBUILD := xcodebuild -project $(SWIFT_DIR)/TVView.xcodeproj -configuration Debug -derivedDataPath $(SWIFT_DIR)/build
XCODEBUILD_RELEASE := xcodebuild -project $(SWIFT_DIR)/TVView.xcodeproj -configuration Release -derivedDataPath $(SWIFT_DIR)/build
SWIFT_APP := TV View.app

## test: Go tests, then the Swift core tests. Both run the cases in
## testdata/golden, so a change to saving that only one app picks up fails here.
test:
	$(GO) test ./...
	$(MAKE) --no-print-directory swift-test

## swift-gen: regenerate swift/TVView.xcodeproj from swift/project.yml (needs
## xcodegen). Run after editing project.yml or adding source files.
swift-gen:
	cd $(SWIFT_DIR) && xcodegen generate

swift-test:
	cd $(SWIFT_DIR)/TVCore && swift test

## swift-vpn: the in-process WireGuard library the Swift app links (Go, built
## for macOS, iPhone and the simulator; a few minutes). Built once; rebuild it
## with this target after changing swift/vpn.
swift-vpn:
	$(SWIFT_DIR)/vpn/build.sh

$(SWIFT_DIR)/build/TVVPN.xcframework:
	$(SWIFT_DIR)/vpn/build.sh

swift-mac: $(SWIFT_DIR)/build/TVVPN.xcframework swift-gen
	$(XCODEBUILD) -scheme TVView-macOS build

## swift-ios: builds for the simulator; a device build needs DEVELOPMENT_TEAM
## set in swift/project.yml.
swift-ios: $(SWIFT_DIR)/build/TVVPN.xcframework swift-gen
	$(XCODEBUILD) -scheme TVView-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

swift-run: swift-mac
	open "$(SWIFT_DIR)/build/Build/Products/Debug/TV View.app"

## swift-release: the Mac app as a Release build for both Apple Silicon and Intel, ad-hoc
## signed, in swift/build/Build/Products/Release.
swift-release: $(SWIFT_DIR)/build/TVVPN.xcframework swift-gen
	$(XCODEBUILD_RELEASE) -scheme TVView-macOS ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
	@lipo -archs "$(SWIFT_DIR)/build/Build/Products/Release/$(SWIFT_APP)/Contents/MacOS/TV View"

## swift-install: replace /Applications/TV View.app with the Release build. Run
## `make install-vpn-helper` (with sudo) after this once, for no password prompts.
swift-install: swift-release
	rm -rf "/Applications/$(SWIFT_APP)"
	cp -R "$(SWIFT_DIR)/build/Build/Products/Release/$(SWIFT_APP)" /Applications/
	@echo "installed /Applications/$(SWIFT_APP)"

swift-clean:
	rm -rf $(SWIFT_DIR)/build $(SWIFT_DIR)/TVCore/.build $(SWIFT_DIR)/TVView.xcodeproj

clean:
	rm -rf $(APP) $(BINARY) $(BINARY)-amd64 $(BINARY)-arm64 $(BINARY)-universal
	rm -rf $(HELPER) $(HELPER)-amd64 $(HELPER)-arm64 $(HELPER)-universal

define INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleInfoDictionaryVersion</key>	<string>6.0</string>
	<key>CFBundlePackageType</key>			<string>APPL</string>
	<key>CFBundleName</key>				<string>$(BUNDLE_NAME)</string>
	<key>CFBundleDisplayName</key>			<string>$(BUNDLE_NAME)</string>
	<key>CFBundleIdentifier</key>			<string>$(BUNDLE_ID)</string>
	<key>CFBundleExecutable</key>			<string>$(BINARY)</string>
	<key>CFBundleIconFile</key>			<string>AppIcon</string>
	<key>CFBundleShortVersionString</key>		<string>$(VERSION)</string>
	<key>CFBundleVersion</key>			<string>$(VERSION)</string>
	<key>LSMinimumSystemVersion</key>		<string>$(MIN_MACOS)</string>
	<key>LSApplicationCategoryType</key>		<string>public.app-category.entertainment</string>
	<key>NSHighResolutionCapable</key>		<true/>
</dict>
</plist>
endef
export INFO_PLIST
