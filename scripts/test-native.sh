#!/usr/bin/env bash
#
# test-native.sh — run the library's Obj-C++/C++ XCTests directly on macOS,
# without a simulator or an RN app bundle.
#
# Compiles packages/react-native-video-pipeline/{cpp,ios}/** against the
# macosx SDK, links an XCTest bundle, and runs it with `xcrun xctest`.
# The tests in packages/react-native-video-pipeline/ios/__tests__/LibraryTests.m
# use forward declarations for library headers so they link straight against
# the compiled archive here.
#
# Build output goes to build/native/ at the repo root (gitignored). End-to-
# end wall time is ~3s on a warm machine.
#
# This is the single source of truth for the library's native unit tests.
# `yarn smoke:ios` builds the bareexample app for the simulator to confirm
# pod install + linking, but does NOT re-run these tests (would be redundant).
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO_ROOT/packages/react-native-video-pipeline"
LIB_TESTS="$PKG/ios/__tests__"
OUT="$REPO_ROOT/build/native"
BUNDLE="$OUT/RNVPCoreTests.xctest"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
PLATFORM="$(xcrun --sdk macosx --show-sdk-platform-path)"
PLATFORM_FW="$PLATFORM/Developer/Library/Frameworks"

CXX_SOURCES=(
  "$PKG/cpp/compose/ComposeRunner.cpp"
  "$PKG/cpp/compose/ProgressEmitter.cpp"
  "$PKG/cpp/compose/RenderTokenRegistry.cpp"
  "$PKG/cpp/engine/Remuxer.cpp"
  "$PKG/cpp/engine/Transcoder.cpp"
)

OBJCXX_SOURCES=(
  "$PKG/ios/AVMuxer.mm"
  "$PKG/ios/AVDemuxer.mm"
  "$PKG/ios/BackgroundTaskGuard.mm"
  "$PKG/ios/Capabilities.mm"
  "$PKG/ios/ExportSessionStamp.mm"
  "$PKG/ios/MetalBlit.mm"
  "$PKG/ios/OverlayRenderer.mm"
  "$PKG/ios/Remuxer.mm"
  "$PKG/ios/Transcoder.mm"
  "$PKG/ios/WorkletFrameBridge.mm"
  "$PKG/ios/SynthesizeRunner.mm"
  "$PKG/ios/Thumbnailer.mm"
)

OBJC_SOURCES=(
  "$LIB_TESTS/LibraryTests.m"
)

COMMON_FLAGS=(
  -isysroot "$SDK"
  -I "$PKG/cpp"
  -I "$PKG/ios"
  -F "$PLATFORM_FW"
  -Wall -Wno-deprecated-declarations
  -O0 -g
)

CXX_FLAGS=(-std=c++20 -stdlib=libc++)
OBJC_FLAGS=(-fobjc-arc)

mkdir -p "$OUT/obj"

compile() {
  local src="$1"; shift
  local out="$OUT/obj/$(basename "$src").o"
  clang++ -c "${COMMON_FLAGS[@]}" "$@" -o "$out" "$src"
  echo "$out"
}

OBJS=()
for src in "${CXX_SOURCES[@]}"; do
  OBJS+=("$(compile "$src" "${CXX_FLAGS[@]}")")
done
for src in "${OBJCXX_SOURCES[@]}"; do
  OBJS+=("$(compile "$src" "${CXX_FLAGS[@]}" "${OBJC_FLAGS[@]}")")
done
for src in "${OBJC_SOURCES[@]}"; do
  OBJS+=("$(compile "$src" "${OBJC_FLAGS[@]}")")
done

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>RNVPCoreTests</string>
  <key>CFBundleIdentifier</key><string>com.foldleft.RNVPCoreTests</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleName</key><string>RNVPCoreTests</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
PLIST

clang++ -bundle -isysroot "$SDK" -stdlib=libc++ \
  -F "$PLATFORM_FW" \
  -framework Foundation \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreAudio \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework AudioToolbox \
  -framework ImageIO \
  -framework CoreText \
  -framework Metal \
  -framework QuartzCore \
  -framework VideoToolbox \
  -framework XCTest \
  -Wl,-rpath,"$PLATFORM_FW" \
  -o "$BUNDLE/Contents/MacOS/RNVPCoreTests" \
  "${OBJS[@]}"

exec xcrun --sdk macosx xctest "$BUNDLE"
