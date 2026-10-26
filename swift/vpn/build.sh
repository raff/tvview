#!/bin/sh
# Builds swift/build/TVVPN.xcframework: the in-process WireGuard library
# (export/) for macOS (arm64 + x86_64), iPhone/iPad (arm64) and the simulator.
#
# Go's c-archive mode needs cgo, so each slice is compiled with the matching
# Apple SDK's clang. Needs Xcode and Go; takes a few minutes the first time.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out="$root/swift/build/vpn"
GO=${GO:-go}
mkdir -p "$out"

# build NAME GOOS GOARCH CLANG-ARCH SDK CLANG-FLAGS...
build() {
	name=$1 goos=$2 goarch=$3 arch=$4 sdk=$5
	shift 5
	flags="-arch $arch -isysroot $(xcrun --sdk "$sdk" --show-sdk-path) $*"
	echo "== $name"
	(cd "$root" && CGO_ENABLED=1 GOOS=$goos GOARCH=$goarch \
		CC="$(xcrun --sdk "$sdk" --find clang)" \
		CGO_CFLAGS="$flags" CGO_LDFLAGS="$flags" \
		$GO build -buildmode=c-archive -o "$out/$name.a" ./swift/vpn/export)
	rm -f "$out/$name.h" # Go's own header; the hand-written one in include/ is shipped
}

build macos-arm64   darwin arm64 arm64  macosx          -mmacosx-version-min=14.0
build macos-amd64   darwin amd64 x86_64 macosx          -mmacosx-version-min=14.0
build ios-arm64     ios    arm64 arm64  iphoneos        -miphoneos-version-min=17.0
build iossim-amd64  ios    amd64 x86_64 iphonesimulator -mios-simulator-version-min=17.0

# The arm64 simulator slice (Apple Silicon Macs) is built with a simulator
# target triple; Go itself tags ios/arm64 as a device, so this may not link.
sims="$out/iossim-amd64.a"
if build iossim-arm64 ios arm64 arm64 iphonesimulator -target arm64-apple-ios17.0-simulator 2>/dev/null; then
	sims="$sims $out/iossim-arm64.a"
else
	echo "note: no arm64 simulator slice; on Apple Silicon run the simulator under Rosetta"
fi

lipo -create "$out/macos-arm64.a" "$out/macos-amd64.a" -output "$out/macos.a"
lipo -create $sims -output "$out/iossim.a"

rm -rf "$root/swift/build/TVVPN.xcframework"
xcodebuild -create-xcframework \
	-library "$out/macos.a"     -headers "$here/include" \
	-library "$out/ios-arm64.a" -headers "$here/include" \
	-library "$out/iossim.a"    -headers "$here/include" \
	-output "$root/swift/build/TVVPN.xcframework"
echo "built swift/build/TVVPN.xcframework"
