# HDR-preserving compose — design

Status: **iOS worklet-generated HDR landed (0.5.0); source-clip passthrough +
Android in progress.** Tracking: [#90]. Sub-tasks: the `output.colorRange` API
[#94] — **done**; the worklet-into-10-bit pixel contract [#99] — **done** (the
`'rgbaFp16'` `PixelFormat` + format-driven `writeBytes`/`readBytes`); iOS
10-bit pipeline [#92] — **worklet-generated (null-input) path landed**
(`Video.synthesize` with `colorRange: 'hdr'` → `rgbaFp16` target → HEVC Main10
HLG sink), source-clip (`Video.compose`) passthrough still open (blocked on the
`AVAssetExportSession`-can't-emit-Main10 problem — see below); Android 10-bit
pipeline [#93] — open (deferred: the CI/dev emulator has no HEVC Main10 encoder,
so it needs a physical HDR device to verify — `colorRange: 'hdr'` rejects on
Android until then).

**Worklet pixel contract ([#99], landed).** The worklet-facing HDR target is
`PixelFormat` `'rgbaFp16'` — 16-bit half-float RGBA, 8 bytes/pixel, **linear
Rec.2020, premultiplied, extended range** (values > 1.0 allowed). It is a
*separate, additive* format; the 8-bit SDR path is byte-for-byte unchanged and
`'rgbaFp16'` only appears under `output.colorRange: 'hdr'`. `writeBytes`/
`readBytes` are format-driven (FP16 = `w*h*8`). Architectural rule: the
**worklet buffer (FP16-linear) is not the encoder sink (platform-native
10-bit)** — each platform owns a final GPU pass converting FP16-linear → its
codec-native format (iOS: VideoToolbox converts `64RGBAHalf` → YUV Main10,
verified; Android: a final pass into the MediaCodec 10-bit input surface). The
8-bit helpers `drawWithRGBA`/`drawWithSkia` reject `'rgbaFp16'` rather than
silently downgrade; HDR drawing uses `drawWithFloat16` (the half-float CPU
counterpart — fills a `Float32Array`, converts to halves) or (later) an F16
Skia surface.

This document specifies how `Video.compose` could preserve an HDR source's
dynamic range end-to-end, and pins the API shape that gates it. It exists
because [#90] correctly observes that HDR passthrough "depends on the 10-bit
rendering work being designed for both iOS and Android" — this is that design.

---

## Where we are today (and why)

The compose pump is **8-bit** on both platforms:

- **iOS** materializes every source frame into a `kCVPixelFormatType_32BGRA`
  `CVPixelBuffer` (`VideoPipeline.mm` ~L2026–2078, L2218–2253), the worklet
  draws into that BGRA buffer, and `AVAssetWriterInputPixelBufferAdaptor`
  appends it.
- **Android** composites through an `RGBA_8888` GL surface and `ARGB_8888`
  bitmaps (`GLRgbaRenderer`, `TransformerRunner`), read back to 8-bit.

An HDR source (HLG/PQ, bt2020, 10-bit) carries luminance far outside the
8-bit sRGB range. [#86] fixed the immediate bug — rendering that signal into
8-bit BGRA with `colorSpace:nil` wrote the HLG/PQ code values straight through
with no transfer conversion, crushing mid-tones to a dark, washed-out frame.
The fix (`RNVPComposeRenderSourceToSDR`) hands CoreImage an explicit sRGB
output space so it **tone-maps HDR→SDR**. That is the correct *default*: the
whole pump is 8-bit, and an SDR Skia overlay drawn into HDR space would look
dim. But tone-mapping **discards** the HDR range. `RNVPComposeColor.h` says it
plainly: *"Tone-mapped SDR is the only viable compose output here without a
10-bit pixel pipeline."*

Preserving HDR therefore is not a tweak — it is a second, 10-bit pixel path
alongside the 8-bit one, on both platforms, plus a worklet/Skia story for
drawing into (or onto) HDR. Hence the split below.

---

## Public API — `output.colorRange` ([#94])

The knob a consumer sets to opt into passthrough. Proposed:

```ts
type ColorRange = 'sdr' | 'hdr';

interface OutputSpec {
  // ...existing fields...
  /** default: 'sdr' — tone-map HDR sources down to SDR (today's behavior). */
  colorRange?: ColorRange;
}
```

**Behavior**

- `'sdr'` (default): today's tone-map-to-SDR. No change; no regression.
- `'hdr'`: passthrough — requires the platform 10-bit pipeline below, and only
  on a path that materializes a worklet pixel buffer. Every unsupported
  combination **rejects up front** with a typed `InvalidSpecError` and an
  actionable message, *never* silently produces SDR — silent downgrade is
  exactly the discoverability gap [#90] is about.

**Resolved shape ([#94], landed).** `OutputSpec` is
`export type OutputSpec = NativeOutputSpec` — a direct alias of the Nitro-spec
struct (invariant #6) shared by `RenderSpec`, `ComposeSpec`, and
`SynthesizeOutputSpec`. The three candidate shapes were:

1. Add to shared `OutputSpec`; validate/act only on the worklet paths; reject
   elsewhere. Simplest spec, muddiest semantics.
2. Split a worklet-path-specific output type so the field only appears where it
   applies. Cleanest semantics, most type churn.
3. `sdr: boolean` instead of the `colorRange` enum ([#90] floated both).

**Decision: (1) + the enum.** `colorRange?: ColorRange` (`'sdr' | 'hdr'`) lives
on the shared struct; `validateColorRange` in `src/video.ts` gates it per path
+ platform. The enum (not a bool) leaves room for a future
`'hlg' | 'pq' | 'hdr10'` refinement. The library is pre-1.0, so splitting a
path-specific output type later stays reversible.

**Correction to the original #94 placement.** #94 first scoped `colorRange` as
"compose-only", rejecting it on `Video.synthesize` on the grounds that
synthesize "does not materialize a worklet buffer". That reasoning was wrong:
`Video.synthesize` is the *null-input compose* path — its `drawFrame` worklet
draws **every** pixel into a materialized buffer, so it is precisely where HDR
*is* meaningful and, as it turns out, first implementable (it owns the encoder
sink directly, unlike source-clip compose). The shipped gate (0.5.0):

| Path | `'hdr'` |
| --- | --- |
| `Video.synthesize` (null-input) | **iOS: implemented**; Android: rejects ([#93]). |
| `Video.compose` (source clip) | rejects both platforms — source-clip passthrough is unimplemented (iOS `AVAssetExportSession` can't emit Main10). |
| `Video.render` | rejects — no worklet buffer. |

HDR + an explicit `output.codec: 'h264'` also rejects (HDR needs HEVC/Main10).
`'sdr'` and omitted pass through unchanged everywhere they are accepted.

---

## iOS 10-bit pipeline ([#92])

**Landed (0.5.0): the null-input / worklet-generated path.** `Video.synthesize`
with `colorRange: 'hdr'` now routes `renderCompose`'s synthesize branch
(`VideoPipeline.mm`) through the Main10 sink: `RNVPComposeSynthesizePlanFor`
(host-tested in `RNVPComposeColor.mm`) selects a `kCVPixelFormatType_64RGBAHalf`
worklet target (`PixelFormat::RGBAFP16`) and `RNVPAVMuxer openHDRVideoOnlyAtPath:`
(HEVC Main10, bt2020 + HLG tags — proven by `testAVMuxerHDRWritesHEVCMain10…`).
The worklet draws with `drawWithFloat16`. HDR + `clips` (source-clip compose) and
HDR + explicit `h264` both reject with `InvalidSpecError`. Range survival +
Main10 output are host-verified; the linear→HLG **transfer photometry** is not
yet reference-validated (needs an HDR display) — see the open question below.

**Still open (source-clip passthrough).** The steps below describe the
source-materializing (`Video.compose`) path. It routes through
`RNVPExportSession` (`AVAssetExportSession`), which cannot be configured to emit
Main10 — closing it needs an `AVAssetReader`→`AVAssetWriter` re-architecture, so
it stays rejected for now.

Replace the 8-bit BGRA path (not the SDR default — add a parallel 10-bit
path selected when `colorRange === 'hdr'` and the source is HDR):

1. **Pixel buffers.** Allocate the source-materialization and worklet-target
   buffers as 10-bit: `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`
   (`'x420'`) for YUV, or 64-bit half-float RGBA
   (`kCVPixelFormatType_64RGBAHalf`) for a linear worklet target.
2. **CIContext working space.** Render into an extended-range / HDR working
   space — `kCGColorSpaceExtendedLinearITUR_2020` (the iOS 13-compatible
   choice). The named HLG/PQ spaces `kCGColorSpaceITUR_2100_HLG` /
   `kCGColorSpaceITUR_2100_PQ` are iOS 14.0+, so they need an availability
   guard given the iOS 13+ target — prefer extended-linear bt2020. Either way,
   no tone-map: a transfer-correct materialization into 10-bit, unlike the sRGB
   output space `RNVPComposeRenderSourceToSDR` uses today.
3. **Encoder.** Configure `AVAssetWriter` for **HEVC Main10** with the output
   track tagged bt2020 primaries + HLG (or PQ) transfer + bt2020 matrix, via
   `AVVideoColorPropertiesKey` carrying `AVVideoColorPrimariesKey`,
   `AVVideoTransferFunctionKey`, and `AVVideoYCbCrMatrixKey`. `codec` must
   resolve to `hevc`; reject `h264` + `hdr`.
4. **Worklet/Skia contract.** Decide how a worklet draws into a 10-bit HDR
   target and how an SDR overlay composites onto an HDR base (extended-range
   Skia surface, or restrict the first cut to "HDR base, no worklet draw" /
   "HDR base + SDR overlay tone-mapped up"). See `rendering-ios.md`.

**Gate:** extend the `ComposeRunner` / `RNVPComposeColor` host XCTests
(`yarn test:native`) with a **10-bit YUV** HDR buffer (an 8-bit BGRA + HLG tag
is ignored by CoreImage — see the HDR host-test note in [#86]), asserting the
HDR range survives to the encoded output; then `yarn smoke:ios`.

---

## Android 10-bit pipeline ([#93])

Media3 already has first-class HDR support, so the lift is smaller than iOS:

1. **GL/EGL.** A 10-bit compose surface (RGBA1010102 or FP16 pbuffer) and
   matching `ImageReader`/readback instead of `RGBA_8888`.
2. **Media3.** `Composition.Builder.setHdrMode(@Composition.HdrMode int)` —
   e.g. `.setHdrMode(Composition.HDR_MODE_KEEP_HDR)` — an HEVC Main10 encoder,
   and bt2020 color info on the output `Format`. Media3 will tone-map itself if
   the device can't keep HDR — surface that decision rather than hiding it.
3. **Y-flip discipline** preserved at every memory↔GL boundary (see
   `rendering-android.md`).
4. **Dimensions.** Reconcile with the `Presentation` coded-vs-displayed
   dimension quirk on API 36 (see the Android Presentation-dims note).

**Gate:** offline Kotlin compile (both source sets) + `connectedDebugAndroidTest`
on a booted emulator; the API 36 leg is load-bearing for HDR encode.

---

## Cross-platform parity

`__tests__/golden/{ios,android}/*.hash` covers SDR compose parity. HDR
passthrough needs its own golden fixtures (an HDR synthesize source, or a
committed-hash exception), tracked with the platform sub-issues — do not gate
HDR parity on the existing SDR hashes.
