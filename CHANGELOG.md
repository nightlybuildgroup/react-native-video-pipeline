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

## [0.5.0] - 2026-07-10

### Added

- **HDR-preserving compose on iOS (worklet-generated).** `Video.synthesize` with `output.colorRange: 'hdr'` now preserves full HDR dynamic range end-to-end: the worklet draws into an `rgbaFp16` half-float target (via `drawWithFloat16`) that is encoded to **HEVC Main10 HLG** (bt2020 primaries + HLG transfer + bt2020 matrix), instead of tone-mapping down to 8-bit SDR (#92).
- `output.colorRange: 'sdr' | 'hdr'` API knob on the shared `OutputSpec` — opt into HDR preservation on the worklet paths (#94, #90).
- `'rgbaFp16'` `PixelFormat` — the worklet-into-10-bit pixel contract (8 bytes/pixel, linear Rec.2020, premultiplied, extended range) with format-driven `writeBytes`/`readBytes` (#99).
- `drawWithFloat16` — the half-float CPU worklet helper for drawing HDR frames into an `rgbaFp16` target (#102).

### Changed

- `output.colorRange` is now valid on the **worklet paths** (corrects the initial #94 "compose-only" scoping): `Video.synthesize` + `'hdr'` is supported on iOS and rejected on Android (#93, pending an HDR-capable device); `Video.compose` + `'hdr'` (source-clip passthrough) and `Video.render` + any `colorRange` reject with `InvalidSpecError`. `'hdr'` never silently produces SDR — every unsupported combination (including `'hdr'` + explicit `codec: 'h264'`) rejects up front with an actionable message.
- Publish and install all packages from a single npm registry (npmjs.org) (#97).

### Documentation

- Documented the shipped `output.colorRange` contract in `docs/api.md` and updated `docs/hdr-compose.md` with the iOS worklet-generated HDR design, the source-clip / Android deferrals, and the preview-grade transfer-photometry caveat (#90, #92).

## [0.4.2] - 2026-07-02

### Changed

- iOS export/mux errors now surface the underlying error domain + code and the full `NSUnderlyingError` chain (including the internal CoreMedia/Fig codes like `-17913`/`-12115`, with a hint for known ones) instead of only the generic `localizedDescription`, turning opaque "Cannot create file" failures into actionable messages (#85).
- Android Media3 export errors now always surface the symbolic `ExportException.errorCodeName` (+ raw `errorCode`) and the `cause` chain — previously the structured code was dropped whenever Media3 supplied a human message — with a hint for common IO / encoder-init / unsupported-format codes (#89, parity with #85).

### Added

- iOS `compose`/`synthesize` validate `output.path` up front and reject a missing parent directory as `IOError` with an actionable message, instead of failing deep inside AVFoundation/MediaToolbox with the opaque "Cannot create file" (#85).

### Fixed

- iOS `Video.compose` over an HDR source (HLG/PQ, bt2020, 10-bit) no longer produces dark, washed-out output: source frames are tone-mapped HDR→SDR (sRGB) when materialized for the worklet, instead of writing the HDR signal into 8-bit BGRA with no conversion (#86).

### Documentation

- Documented the compose HDR→SDR tone-map as a deliberate default (not a downgrade) in `docs/api.md`, and added `docs/hdr-compose.md` — the design for an opt-in HDR-preserving 10-bit compose pipeline and the `output.colorRange` API. The implementation is split into tracked sub-tasks: iOS 10-bit (#92), Android 10-bit (#93), and the color-range API (#94) (#90).

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

[Unreleased]: https://github.com/nightlybuildgroup/react-native-video-pipeline/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/nightlybuildgroup/react-native-video-pipeline/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/nightlybuildgroup/react-native-video-pipeline/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/nightlybuildgroup/react-native-video-pipeline/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/nightlybuildgroup/react-native-video-pipeline/releases/tag/v0.4.0
