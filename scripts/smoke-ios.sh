#!/usr/bin/env bash
#
# smoke-ios.sh — local end-to-end iOS smoke (T022).
#
# The "first end-to-end green milestone" of the project:
#
#   1. yarn lint                — Biome + ESLint
#   2. yarn typecheck           — strict, zero suppressions
#   3. yarn test                — JS unit tests (the mocked "JS test suite"
#                                 that exercises src/**/*.ts end-to-end)
#   4. yarn test:native         — macOS-host XCTests (T018–T021, ~3s)
#   5. pod install              — apps/bare-example/ios (idempotent)
#   6. xcodebuild build         — bareexample scheme on an iOS simulator:
#                                 confirms pod install + auto-linking +
#                                 end-to-end build. Library-internals
#                                 XCTests live in yarn test:native (step 4)
#                                 which compiles the same Obj-C++ sources
#                                 against the macOS SDK in ~3s; re-running
#                                 them on the simulator would duplicate
#                                 coverage at 100x the cost. JS-driven
#                                 integration tests arrive in T048 (Maestro).
#
# Any failure short-circuits the script with a non-zero exit and a log-tail
# pointing at the per-step log in build/ (gitignored).
#
# Idempotent — re-runnable without manual cleanup:
#   - pod install is a no-op when Podfile.lock is unchanged;
#   - xcodebuild uses a stable -derivedDataPath so subsequent runs are
#     incremental;
#   - the simulator pick is "any already-booted device" first, else the
#     named device at $SMOKE_IOS_DEVICE (default: iPhone 15), booted in
#     place.
#
# CI wiring of this same flow lives in T005 at the very end of the project.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/apps/bare-example"
DERIVED="$ROOT/build/smoke-ios-derived"
LOG_DIR="$ROOT/build"
mkdir -p "$LOG_DIR"

SIM_NAME="${SMOKE_IOS_DEVICE:-iPhone 15}"

say() { printf "\033[1;34m[smoke:ios]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[smoke:ios]\033[0m %s\n" "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode command-line tools"
command -v yarn       >/dev/null || die "yarn not found"
command -v pod        >/dev/null || die "CocoaPods ('pod') not found — gem install cocoapods"

# 1. JS checks
say "yarn lint"
(cd "$ROOT" && yarn lint)

say "yarn typecheck"
(cd "$ROOT" && yarn typecheck)

say "yarn test"
(cd "$ROOT" && yarn test)

# 2. Host-side native XCTests (T052) — fast cross-check before we commit to a
# simulator boot.
say "yarn test:native"
(cd "$ROOT" && yarn test:native)

# 3. Pods
POD_LOG="$LOG_DIR/smoke-ios-pod.log"
say "pod install → $POD_LOG"
(cd "$APP_DIR/ios" && pod install >"$POD_LOG" 2>&1) \
  || { tail -n 60 "$POD_LOG" >&2; die "pod install failed"; }

# 4. Pick a simulator (or boot SIM_NAME in place)
SIM_UDID=$(xcrun simctl list devices booted 2>/dev/null \
  | awk -F '[()]' '/\(Booted\)/ && $2 ~ /^[-0-9A-F]{36}$/ {print $2; exit}')
if [[ -z "$SIM_UDID" ]]; then
  SIM_UDID=$(xcrun simctl list devices available 2>/dev/null \
    | awk -v name="$SIM_NAME" -F '[()]' '$0 ~ ("    " name " \\([-0-9A-F]") {print $2; exit}')
  [[ -n "$SIM_UDID" ]] || die "no available simulator matching '$SIM_NAME' (override via SMOKE_IOS_DEVICE)"
  say "booting simulator '$SIM_NAME' ($SIM_UDID)"
  xcrun simctl boot "$SIM_UDID"
fi
say "simulator: $SIM_UDID"

# 5. xcodebuild build — builds the bareexample app for the simulator. This
# confirms pod install + auto-linking works and the app compiles + links
# against the pod end-to-end. Library-internals XCTests run earlier via
# `yarn test:native` (macOS host, ~3s) — re-running them in the simulator
# would duplicate the coverage at 100x the cost.
XCB_LOG="$LOG_DIR/smoke-ios-xcodebuild-build.log"
say "xcodebuild build → $XCB_LOG"
xcodebuild \
  -workspace "$APP_DIR/ios/bareexample.xcworkspace" \
  -scheme bareexample \
  -configuration Debug \
  -destination "id=$SIM_UDID" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -allowProvisioningUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_IDENTITY="" \
  build >"$XCB_LOG" 2>&1 \
  || { tail -n 120 "$XCB_LOG" >&2; die "xcodebuild build failed"; }

say "✅ all checks passed"
