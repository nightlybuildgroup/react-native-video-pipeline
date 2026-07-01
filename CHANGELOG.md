# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
(pre-1.0: minor and patch boundaries are advisory).

All three published packages — `react-native-video-pipeline`,
`babel-plugin-video-pipeline`, and `react-native-video-pipeline-skia` — are
versioned and released in lockstep. This log begins at `0.4.0`, the first
release in which all three were published to npm; the `v0.1.0`–`v0.3.7` git
tags predate that and were never published.

## [Unreleased]

### Changed

- iOS export/mux errors now surface the underlying error domain + code and the full `NSUnderlyingError` chain (including the internal CoreMedia/Fig codes like `-17913`/`-12115`, with a hint for known ones) instead of only the generic `localizedDescription`, turning opaque "Cannot create file" failures into actionable messages (#85).

### Added

- iOS `compose`/`synthesize` validate `output.path` up front and reject a missing parent directory as `IOError` with an actionable message, instead of failing deep inside AVFoundation/MediaToolbox with the opaque "Cannot create file" (#85).

### Fixed

- iOS `Video.compose` over an HDR source (HLG/PQ, bt2020, 10-bit) no longer produces dark, washed-out output: source frames are tone-mapped HDR→SDR (sRGB) when materialized for the worklet, instead of writing the HDR signal into 8-bit BGRA with no conversion (#86).

## [0.4.1] - 2026-06-30

### Added

- Batch thumbnail extraction via `Video.thumbnails` for filmstrips and scrubbers (#80).

### Fixed

- Accept `file://` URIs for `output.path` on Android (#79) and on the iOS compose/synthesize/render paths (#77).
- Skia: inline the GPU-blit worklet helpers so they survive `node_modules` consumption in published packages (#76).
- iOS: render text overlays upright via CoreText instead of `CATextLayer` (#68).
- npm packaging: ship `plugin/build/**` so `yarn pack` includes the compiled Expo config plugin (#69).
- Publishing: target the `registry.npmjs.org` write endpoint instead of the read-only `registry.yarnpkg.com` mirror, which 404s on the publish `PUT` (#83).

### Docs

- Correct the README setup section — dependencies, expo-example, filesystem, status (#72).
- Fix the `Overlay.Image` `size` shape in the README stamp examples (#70).

## [0.4.0] - 2026-06-29

First release published to npm for all three packages.

### Added

- **Android render compositor** (Media3): multi-track picture-in-picture overlay (#50), crossfade timeline overlaps (#51), composite-path audio replace and static overlays (#54), and base-overlap + PiP via a two-pass crossfade (#55).
- **iOS render**: multi-track picture-in-picture overlay compositing (#46) and crossfade timeline overlaps (#44).
- Multi-clip render and re-encode (#39), with timeline gaps filled by black frames and silence (#40).
- Audio modes `mute` (#36) and `replace` (#38) on every render path.
- Single-clip render with trim + transform (rotate/flip/crop) in one pass on both iOS and Android.
- Publishable builds for `babel-plugin-video-pipeline` and `react-native-video-pipeline-skia`, plus package READMEs (#61).

### Fixed

- Android single-dimension output parity with iOS (#53) and honoring a single output dimension on the non-overlay path (#26).
- Route `Video.flip` and trim+transform through Media3 Transformer on Android.
- Carry audio through the passthrough concat path (#37).
- Persist the full `MetadataSpec` on Android, handling a shrinking `moov` rewrite (#27, #28).
- Remove wall-clock timeout/deadline band-aids from the encode/mux paths (#33).

### Build

- Exclude `android/src/androidTest` from the published tarball (#63).
- Add a manual-dispatch Android instrumented-test workflow (#57).

[Unreleased]: https://github.com/nightlybuildgroup/react-native-video-pipeline/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/nightlybuildgroup/react-native-video-pipeline/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/nightlybuildgroup/react-native-video-pipeline/releases/tag/v0.4.0
