# Builds TVView.app.
#
# The Go binary is self-contained: the webview native library is embedded by
# go-webview, and channels.yaml by go:embed. The bundle therefore carries no
# resources of its own — it exists for the things a bare binary cannot have:
# a name in the menubar, a Dock icon, and no terminal window behind it.

GO ?= go

BINARY   := tvview
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

.PHONY: all build app universal run install clean

all: build

build:
	$(GO) build -ldflags '$(LDFLAGS)' -o $(BINARY) .

## app: bundle for this machine's architecture.
app: build
	@$(MAKE) --no-print-directory bundle EXE=$(BINARY)
	@echo "built $(APP) ($(shell uname -m), $(VERSION))"

## universal: one bundle that runs on both Intel and Apple Silicon.
#
# Each slice is compiled separately because go-webview selects its embedded
# native library by GOARCH at compile time — a slice carries the dylib for its
# own architecture, so lipo has to join finished binaries rather than the Go
# build producing a fat one.
universal:
	GOARCH=amd64 $(GO) build -ldflags '$(LDFLAGS)' -o $(BINARY)-amd64 .
	GOARCH=arm64 $(GO) build -ldflags '$(LDFLAGS)' -o $(BINARY)-arm64 .
	lipo -create -output $(BINARY)-universal $(BINARY)-amd64 $(BINARY)-arm64
	@$(MAKE) --no-print-directory bundle EXE=$(BINARY)-universal
	@rm -f $(BINARY)-amd64 $(BINARY)-arm64 $(BINARY)-universal
	@echo "built $(APP) (universal, $(VERSION))"
	@lipo -archs $(APP)/Contents/MacOS/$(BINARY)

## bundle: assemble $(APP) around an already-built EXE. Shared by app and
## universal; not meant to be called directly.
bundle:
	@test -n "$(EXE)" || { echo "bundle: EXE not set"; exit 1; }
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(EXE) $(CONTENTS)/MacOS/$(BINARY)
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
	@# Ad-hoc signature. Enough for this machine; not a distributable one —
	@# other Macs still need a Developer ID and notarisation.
	codesign --force --sign - $(APP)

run: app
	open $(APP)

install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "installed /Applications/$(APP)"

config:
	-mkdir -p $(HOME)/.config/tvview
	cp channels.yaml $(HOME)/.config/tvview/channels.yaml

diff-config:
	diff channels.yaml $(HOME)/.config/tvview/channels.yaml

clean:
	rm -rf $(APP) $(BINARY) $(BINARY)-amd64 $(BINARY)-arm64 $(BINARY)-universal

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
