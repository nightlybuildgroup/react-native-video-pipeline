# API Reference

The complete public surface of `react-native-video-pipeline`. The Nitro spec at `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` is the single source of truth — this page is a curated, prose-friendly view of the same types.

For runnable scenarios see [`docs/examples/`](./examples/). For architectural deep-dives see [`docs/rendering-ios.md`](./rendering-ios.md) and [`docs/rendering-android.md`](./rendering-android.md).

## Contents

- [Choosing a method](#choosing-a-method) — decision tree, when to use each entry point
- [`Video`](#video) — top-level operations
  - [`Video.info`](#videoinfo)
  - [`Video.thumbnail`](#videothumbnail)
  - [`Video.thumbnails`](#videothumbnails)
  - [`Video.capabilities`](#videocapabilities)
  - [`Video.trim`](#videotrim)
  - [`Video.flip`](#videoflip)
  - [`Video.stamp`](#videostamp)
  - [`Video.render`](#videorender)
  - [`Video.compose`](#videocompose)
  - [`Video.synthesize`](#videosynthesize)
- [`Overlay`](#overlay) — overlay builders
- [`drawWithRGBA`](#drawwithrgba) — plain-pixel (8-bit) worklet helper
- [`drawWithFloat16`](#drawwithfloat16) — half-float (HDR `rgbaFp16`) worklet helper
- [`VideoRenderController`](#videorendercontroller) — graceful end-of-stream
- [Errors](#errors) — `VideoPipelineError` and subclasses
- [Types](#types) — specs, options, frame contexts
- [Routing rules](#routing-rules) — when each execution path is used

---

## Choosing a method

Start here. The decision tree is shallow:

**1. Probing or reading metadata?** → `Video.info`, `Video.thumbnail`, `Video.capabilities`.

**2. Editing video?** Ask: *am I writing pixels from JavaScript?*

- **No** — the operation can be expressed as "the native side does X to this clip":
  - Single-clip lossless cut (no transform) → `Video.trim`.
  - Single-clip horizontal/vertical flip → `Video.flip`.
  - Cut **and** transform (rotate/flip/crop) in one pass → `Video.render`.
  - Add a watermark image/text and/or write metadata onto one clip → `Video.stamp`.
  - **A single clip with several of these at once** — trim + transform + overlays + a custom output codec/bitrate/dimensions, in one re-encode pass — → `Video.render` with a full `RenderSpec`. (Multi-clip specs support both passthrough concat and re-encode — see [`Video.render`](#videorender) scope.)
- **Yes**, I want a worklet drawing on every frame:
  - Drawing *on top of* one or more source clips → `Video.compose`.
  - Generating frames from scratch with no source → `Video.synthesize`.

### Sugar vs `Video.render`

`Video.trim` / `Video.flip` / `Video.stamp` are fixed-signature sugar for the common single-clip cases. They exist because `Video.render({ clips: [{ uri, startSec, durationSec }], output: { ... } })` is verbose when all you want is one trim.

Use `Video.render` directly the moment your spec needs *anything* the sugar doesn't carry — for example, a single-clip trim + crop + overlay + codec change in one re-encode pass:

```ts
// Trim, crop, watermark, and re-encode one clip — one decode/encode pass.
await Video.render({
  clips: [
    {
      uri: 'main.mp4',
      startSec: 5,
      durationSec: 30,
      transform: { crop: { x: 0, y: 0, w: 1920, h: 1080 } },
    },
  ],
  overlays: [
    Overlay.Image({
      uri: 'logo.png',
      anchor: 'tl',
      size: { width: { unit: 'ratio', value: 0.15 } }, // 15% of output width
    }),
    Overlay.Text({ text: '@username', anchor: 'br', style: { fontSize: 24, color: '#fff' } }),
  ],
  output: { path: '/tmp/out.mp4', width: 1920, height: 1080, fps: 30, codec: 'h264', bitrate: 8_000_000 },
});
```

> **Multi-clip note.** Per-clip transforms, overlays, and output-side changes work on both single-clip **and** multi-clip renders: a multi-clip spec that needs a re-encode transcodes each clip to the shared output and concatenates them in one pass. A multi-clip spec with no re-encode stays on the lossless passthrough concat. A timeline **gap** (`clip.outputStartSec` past the previous clip's end) is filled with black + silence (forces a re-encode); **overlaps** still reject — see [`Clip`](#clip).

Chaining `trim` → `stamp` → `render` through temp files would re-encode at every step (slow + lossy). One `Video.render` call decodes and encodes exactly once.

### `render` vs `compose`/`synthesize`

`Video.render` covers **remux and transcode** — the native side decodes/encodes (or passthrough-copies) frames without ever calling back into JavaScript. Overlays on this path are native (`CIFilter` + `CoreText` on iOS, Media3 `BitmapOverlay` + `TextOverlay` on Android).

`Video.compose` and `Video.synthesize` are the **only** entry points where your JS worklet draws into each frame. The native pump invokes `drawFrame` per frame with a live `FrameTarget`. That has different cost (per-frame JS overhead), different requirements (worklet directive, see [`babel-plugin-video-pipeline`](#worklet-directive-enforcement)), and different capabilities (arbitrary drawing via plain RGBA, Skia, or Metal texture blit) than the native overlay path.

If you need pixels drawn from JS, you must use `compose` or `synthesize`. There is no way to inject a worklet into `Video.render` — that's a deliberate split, not an oversight.

---

## `Video`

Imported as a single namespace:

```ts
import { Video } from 'react-native-video-pipeline';
```

### `Video.info`

```ts
Video.info(uri: string): Promise<VideoInfo>
```

Probe a video file. Returns container, codec, dimensions, frame rate, duration, audio presence, HDR, rotation, plus any `creationDate`, `location`, and `custom` metadata previously written by `Video.stamp` (or by another tool that wrote to the standard `udta` atoms).

`width` / `height` are the **displayed** dimensions — what a viewer sees, after the container's rotation metadata is applied. The pre-rotation pixel grid is exposed as `codedWidth` / `codedHeight` (matches `AVAssetTrack.naturalSize` on iOS and `MediaFormat.KEY_WIDTH/HEIGHT` on Android, and follows the WebCodecs `codedWidth` vs `displayWidth` naming convention). `ClipTransform.crop` is expressed in source-pixel coordinates (coded-space), so consumers building crops should reach for `codedWidth` / `codedHeight`; everything else (overlay sizing, aspect ratios, UI layout) wants `width` / `height`.

### `Video.thumbnail`

```ts
Video.thumbnail(uri: string, options: ThumbnailOptions): Promise<string>
```

Extract one JPEG frame at `options.atSec` and write it to `options.outPath`. Resolves to the absolute output path. `options.resizeTo` is optional; provide one of `w` or `h` to scale proportionally.

### `Video.thumbnails`

```ts
Video.thumbnails(uri: string, options: BatchThumbnailOptions): Promise<string[]>
```

Extract **N JPEG frames in a single native decode session** — the right primitive for a filmstrip or scrubber strip. `options.atSecs` and `options.outPaths` are parallel arrays (equal, non-zero length): `outPaths[i]` receives the frame nearest `atSecs[i]`. Resolves to one path per requested time, **in `atSecs` order**.

Why this exists instead of looping `Video.thumbnail`: a JS-side loop pays the full per-frame cost every iteration — iOS spins up a fresh `AVAssetImageGenerator` and re-parses the asset; Android re-acquires a `MediaMetadataRetriever` and seeks from scratch — all run strictly serially because each `await` blocks the next. `thumbnails` opens the asset, walks the decoder forward **once** over the (internally sorted) times, and tears it down once. On a long 4K clip this is the dominant cost of opening an analyze/scrubber screen.

- **`options.toleranceSec`** is the big perf lever. A non-zero tolerance lets the native generator snap to the nearest already-decoded keyframe instead of exact-seek decoding every frame. Filmstrips rarely need exact frames, so a small tolerance (e.g. `0.5`) is usually the right call. `0` (or omitted) means exact-frame seeking, matching `Video.thumbnail`. **Platform note:** iOS honors the magnitude (it maps to `requestedTimeTolerance{Before,After}`, so the frame lands within ±`toleranceSec`). Android has no numeric-tolerance API on `MediaMetadataRetriever`, so any value > 0 means "snap to nearest keyframe" (`OPTION_CLOSEST_SYNC`) regardless of magnitude — on a long-GOP clip the chosen keyframe may be further from the request than the same `toleranceSec` would allow on iOS.
- **Partial success:** a single frame that fails to extract resolves to an **empty string** in its slot rather than rejecting the whole batch — one bad timestamp can't kill the strip. Batch-level failures (missing source, mismatched arrays, no video track) still reject.
- `options.resizeTo` applies uniformly to every frame (same semantics as `Video.thumbnail`).

```ts
const dur = (await Video.info(sourceUri)).durationSec;
const COUNT = 24;
const atSecs = Array.from({ length: COUNT }, (_, i) => (i / COUNT) * dur);
const outPaths = atSecs.map((_, i) => `${dir}/strip-${i}.jpg`);

const frames = await Video.thumbnails(sourceUri, {
  atSecs,
  outPaths,
  resizeTo: { w: 100 },
  toleranceSec: 0.5, // snap to keyframes — cheap, fine for a scrubber strip
});
// frames[i] === outPaths[i] for each frame that was written ('' if that one failed)
```

### `Video.capabilities`

```ts
Video.capabilities(): Promise<EncoderCaps>
```

Cached encoder capability snapshot — supported codecs, max dimensions and fps, max bitrate, HDR support. Use this to decide whether to ask for `hevc` or fall back to `h264` before calling `Video.render`.

### `Video.trim`

```ts
Video.trim(uri: string, options: TrimOptions): Promise<void>
```

Lossless-cut a single clip. **Always remuxes** (passthrough — no re-encode), on both iOS and Android. `trim` deliberately takes no transform: it is the fast-cut primitive. To trim **and** transform (rotate/flip/crop) in one pass, use [`Video.render`](#videorender) — it produces the correct output on both platforms, taking the fast remux path where the platform allows (iOS rotation/flip) and transcoding otherwise (crop everywhere; flip on Android). See [Routing rules](#routing-rules) and the [trim + transform example](./examples/render.md).

End-past-EOF requests (`startSec + durationSec > source duration`) are silently clamped to the source's actual duration — matches `AVAssetExportSession` and ffmpeg leniency. This absorbs muxer-vs-encoder rounding drift (e.g. recorders that report a target duration ~10ms shorter than the bytes they actually wrote). Only `startSec` past EOF rejects with `InvalidSpec`.

### `Video.flip`

```ts
Video.flip(uri: string, options: FlipOptions): Promise<void>
```

Flip horizontally or vertically. Uses a rotation-flag remux when the container supports it (mp4 ↔ mov); transcodes otherwise.

### `Video.stamp`

```ts
Video.stamp(uri: string, options: StampOptions): Promise<void>
```

Add a watermark and/or write metadata. Metadata-only stamps remux (fast); a `watermark` falls into transcode. `StampOptions` is typed so that at least one of `watermark` or `metadata` is required at compile time:

```ts
type StampOptions = { outPath: string } & (
  | { watermark: Overlay; metadata?: MetadataSpec }
  | { watermark?: Overlay; metadata: MetadataSpec }
);
```

### `Video.render`

```ts
Video.render(spec: RenderSpec, options?: RenderOptions): Promise<void>
```

The full-spec native editing entry point. The native side picks the cheapest path that satisfies `spec`, identically on iOS and Android:

- **Passthrough spec** — one or more clips, no overlays, no pixel-altering transform, no output-side change → **remux** (no re-encode).
- **Single clip + transform / overlay / output change** → the cheapest path that works:
  - rotation/flip-only (no crop) → **remux** on iOS (lossless `preferredTransform`); **transcode** on Android (its container can't store a mirror, and rotation is baked in the same pass).
  - crop, a native overlay, or an output-side change (`width`/`height`/`fps`/`codec`/`bitrate`) → **transcode** (re-encode), on both platforms.
  - A trim window (`startSec`/`durationSec` on the clip) composes with any of the above — render trims **and** transforms in one pass. Source audio is preserved through the transcode path on both platforms.

**Scope today.** Per-clip transforms, overlays, and output-side changes are supported on both single-clip and **multi-clip** specs. A multi-clip spec that needs a re-encode (any per-clip transform, an overlay, or an output-side change) transcodes each clip to the shared output and concatenates them; a multi-clip spec with no re-encode stays on the lossless passthrough concat. A **gap** (`clip.outputStartSec` past the previous clip's end) is filled with black + silence (this forces a re-encode). An **overlap** (a clip starting before the previous one ends) is crossfade-dissolved over the overlap window on **both platforms** (an opacity/alpha ramp on the outgoing clip plus a matching audio volume ramp) — iOS via `AVMutableVideoComposition`, Android via a two-sequence ping-pong Media3 `Composition` with a time-ramped alpha; only adjacent-pair overlaps are supported (a clip overlapping two neighbours at once, or fully containing another, rejects). **Gaps** with an HEVC output reject for now (the black fill is authored as H.264), as do **overlaps on iOS** (the crossfade export preset is H.264); **Android** overlaps re-encode directly and accept an HEVC output. When the output size is unpinned, multi-clip re-encode (and the crossfade) derive it from the first clip. Audio handling (`audio.mode`) — `passthrough` (default), `mute` (drop the track), and `replace` (swap in `replaceUri`) — is wired on every audio-carrying render path on both platforms; see [`AudioSpec`](#audiospec).

`RenderSpec` requires a non-empty `clips` array at compile time — synthesized renders go through [`Video.synthesize`](#videosynthesize) instead.

`Video.render` does **not** do compose. To draw pixels from JS, use [`Video.compose`](#videocompose) (with source clips) or [`Video.synthesize`](#videosynthesize) (from scratch). See [Choosing a method](#choosing-a-method).

### `Video.compose`

```ts
Video.compose(spec: ComposeSpec, options: ComposeOptions): Promise<void>
```

Per-frame worklet drawing on top of source clips. The `options.drawFrame` callback runs on the Reanimated UI runtime once per output frame and writes pixels into a pre-allocated `FrameTarget`. The same `CVPixelBuffer` (iOS) / `AHardwareBuffer` (Android) is then handed to the encoder — no intermediate copy.

`drawFrame` must be a worklet. The recommended way to enforce this is the build-time [`babel-plugin-video-pipeline`](#worklet-directive-enforcement) check; without it, the first frame crashes at runtime with a directive-missing error.

Mix native overlays (`Overlay.Image`, `Overlay.Text`) freely on `spec.overlays`; they composite under your `drawFrame` output.

**HDR sources.** The compose pump is 8-bit end-to-end (BGRA on iOS, RGBA on Android). An HDR source (HLG/PQ, bt2020, 10-bit) is **tone-mapped down to SDR (sRGB)** as it is materialized for your worklet — this is a deliberate default (`output.colorRange: 'sdr'`), not a downgrade bug: writing the HDR signal into an 8-bit buffer with no transfer conversion crushes it to dark output (the bug [#86] fixed). The opt-in for HDR-*preserving* compose is the `output.colorRange: 'hdr'` knob ([above](#outputspec-and-synthesizeoutputspec)); the 10-bit pipeline it selects is not yet implemented, so `'hdr'` currently **rejects with `InvalidSpecError`** rather than silently downgrading — see [`docs/hdr-compose.md`](./hdr-compose.md) and [#90].

### `Video.synthesize`

```ts
Video.synthesize(options: SynthesizeOptions): Promise<void>
```

Null-input compose: no source clips, the entire frame stream comes from `options.drawFrame`. `output.width`, `output.height`, `output.fps`, and `duration` are all required. Use `duration: { mode: 'open' }` plus an `AbortSignal` or `VideoRenderController` for indeterminate-length renders.

`ctx.source` is always `undefined` on this path — there is no source frame to sample.

---

## `Overlay`

```ts
import { Overlay } from 'react-native-video-pipeline';
```

Builder functions for the two overlay variants. They normalize `anchor` presets (`'tl' | 'tr' | 'bl' | 'br' | 'center'`) into normalized `{ x, y }` points before crossing the Nitro boundary, which is why they exist as functions rather than plain object literals.

The normalized anchor is a **slot position within the free space** (output frame minus overlay): `(0, 0)` aligns the overlay's top-left with the frame's top-left; `(1, 1)` aligns its bottom-right with the frame's; `(0.5, 0.5)` centers it. Anchors always align corresponding edges — they do not address an arbitrary point on the overlay. Pixel-from-edge layouts can be expressed as `anchor.x = inset / (outputW - overlayW)`.

```ts
Overlay.Image({ uri, anchor, size, opacity?, timeRange? }): ImageOverlay
Overlay.Text({ text, style, anchor, timeRange? }): TextOverlay
```

Both variants are rendered natively (`CIFilter` + `CoreText` on iOS, Media3 `BitmapOverlay` + `TextOverlay` on Android). Advanced typography is intentionally out of scope; if you need pixel-identical cross-platform text, rasterize a PNG and use `Overlay.Image`.

For per-frame JS drawing, use [`Video.compose`](#videocompose) / [`Video.synthesize`](#videosynthesize) — they take `drawFrame` as a first-class argument, not as an overlay.

---

## `drawWithRGBA`

```ts
import { drawWithRGBA, type RGBADrawer } from 'react-native-video-pipeline';

drawWithRGBA(draw: RGBADrawer): FrameDrawer
```

Wraps a plain `(pixels, ctx) => void` callback into a `FrameDrawer`. The helper allocates a `Uint8Array` of length `ctx.width * ctx.height * 4`, calls your drawer, and copies the bytes into the native target. On iOS it swizzles RGBA → BGRA to match `kCVPixelFormatType_32BGRA`; on Android the bytes match the native layout directly.

**8-bit only.** `drawWithRGBA` fills a `Uint8Array` and cannot target an `'rgbaFp16'` HDR buffer ([#99]); it throws on one. That only happens under `output.colorRange: 'hdr'` — use [`drawWithFloat16`](#drawwithfloat16) for HDR targets (or write half-float pixels via `target.writeBytes` directly, or draw through an F16 Skia surface).

Alpha is **premultiplied** RGBA. On `Video.synthesize` (H.264 output has no alpha channel) you can write `a = 255` and ignore alpha. On `Video.compose` over a clip, alpha is the blend key.

For Skia-based drawing, the sibling package `react-native-video-pipeline-skia` provides `drawWithSkia`, which can reach zero-copy on iOS via `MTLBlitCommandEncoder`.

---

## `drawWithFloat16`

```ts
import { drawWithFloat16, type Float16Drawer } from 'react-native-video-pipeline';

drawWithFloat16(draw: Float16Drawer): FrameDrawer
```

The half-float (`rgbaFp16`) counterpart to `drawWithRGBA` — the ergonomic CPU worklet path for **HDR compose** (`output.colorRange: 'hdr'`, [#99]). Your drawer fills a `Float32Array` of length `ctx.width * ctx.height * 4` with RGBA channels; the helper converts each to an IEEE half-float (round-to-nearest-even) and copies the `width * height * 8`-byte buffer into the target.

```ts
drawFrame: drawWithFloat16((pixels, ctx) => {
  'worklet';
  const i = (y * ctx.width + x) * 4;
  pixels[i]     = 2.5; // R — an HDR highlight above SDR white (1.0)
  pixels[i + 1] = 1.0; // G
  pixels[i + 2] = 1.0; // B
  pixels[i + 3] = 1.0; // A (premultiplied)
})
```

- **Color contract:** **linear Rec.2020, premultiplied, extended range** — channel values may exceed `1.0` for highlights (that headroom is the point of HDR). The helper transports bytes only; producing correct linear Rec.2020 values is the caller's job.
- **Channel order:** `R, G, B, A` — no BGRA swizzle (`rgbaFp16` is RGBA-ordered on both platforms).
- **Requires an `rgbaFp16` target** and throws on an 8-bit one — the inverse of `drawWithRGBA`. An `rgbaFp16` target only appears under `output.colorRange: 'hdr'`.

> **Availability:** the `'hdr'` color range is not reachable end-to-end until the platform 10-bit pipelines land ([#92]/[#93]); until then `output.colorRange: 'hdr'` rejects up front, so no `rgbaFp16` target reaches this helper. The float32→float16 conversion itself is complete and tested.

---

## `VideoRenderController`

```ts
import { VideoRenderController } from 'react-native-video-pipeline';

const controller = new VideoRenderController();
const promise = Video.synthesize({ ..., controller });
// later:
controller.finish(); // graceful end-of-stream — promise resolves
controller.abort();  // discard output — promise rejects with CancelledError
```

Distinct from `AbortSignal`:

- `abort()` cancels and **discards** the output. The render promise rejects with `CancelledError`.
- `finish()` stops after the current frame and **finalizes** the output. The render promise resolves normally. No-op on fixed-duration renders — use `AbortSignal` to stop a fixed render early.

State transitions:

```
running → finishing → done    (graceful: finish() then native flush)
running → done                (fixed-duration natural end)
running → aborted             (hard cancel)
finishing → aborted           (abort wins over in-flight finish)
```

Both methods are idempotent. A controller maps 1:1 to a render — pass a fresh instance per `Video.*` call. Reuse throws.

`AbortSignal` and `VideoRenderController` can be combined; either one cancelling causes the render to stop.

---

## Errors

All errors thrown by the library extend `VideoPipelineError`, which extends `Error` with two extra fields:

- `code: VideoPipelineErrorCode` — discriminant
- `details?: Record<string, unknown>` — diagnostic context

```ts
import {
  VideoPipelineError,
  UnsupportedCodecError,
  DeviceCapabilityExceededError,
  SourceCorruptedError,
  CancelledError,
  IOError,
  EncoderFailureError,
  InvalidSpecError,
  errorForCode,
} from 'react-native-video-pipeline';
```

| Code                       | Class                           | When                                                                |
| -------------------------- | ------------------------------- | ------------------------------------------------------------------- |
| `UnsupportedCodec`         | `UnsupportedCodecError`         | Source codec unsupported by the platform decoder                    |
| `DeviceCapabilityExceeded` | `DeviceCapabilityExceededError` | Output exceeds `EncoderCaps` (max dims, fps, bitrate, HDR)          |
| `SourceCorrupted`          | `SourceCorruptedError`          | File could not be parsed                                            |
| `Cancelled`                | `CancelledError`                | `AbortSignal.abort()` or `VideoRenderController.abort()`            |
| `IOError`                  | `IOError`                       | Read / write failed (path missing, permissions, disk full)          |
| `EncoderFailure`           | `EncoderFailureError`           | Native encoder error not classifiable as one of the above           |
| `InvalidSpec`              | `InvalidSpecError`              | The spec or options object failed JS-side or native-side validation       |

`errorForCode(code, options?)` constructs the right subclass for a code — useful when relaying an error across boundaries.

`assertNever(x: never): never` is exported for exhaustiveness checks in consumer code that switches on a discriminated union from this library.

### Diagnosable native errors

When a render fails inside the AVFoundation/MediaToolbox export or muxer layer on iOS, the thrown `error.message` now carries the underlying **error domain + code** and the full **`NSUnderlyingError` chain**, not just the generic `localizedDescription` (which is the same `"Cannot create file"` string regardless of root cause). For example:

```
Cannot create file (AVFoundationErrorDomain -11820; underlying NSOSStatusErrorDomain -17913; hint: MediaToolbox could not create the output file — verify the parent directory exists and output.path is a filesystem path, not a file:// URI)
```

The internal CoreMedia/Fig codes (e.g. `-17913`, `-12115`) are undocumented but invaluable for searching/triaging, so they are always included; a small set of known ones also get a human hint. This turns ~30 minutes of native-`os_log` spelunking into an actionable message.

On **Android** the same treatment applies to Media3 export failures: the thrown message now always carries the symbolic **`ExportException.errorCodeName`** (+ the raw `errorCode`) and the full **`cause` chain** — previously the structured code was dropped whenever Media3 supplied a human message (the common case), leaving only the opaque string. For example:

```
Export error (Media3 ExportException ERROR_CODE_IO_FILE_NOT_FOUND [2001]; cause: java.io.FileNotFoundException: /bad/dir/out.mp4; hint: Media3 could not open the output file — verify the parent directory exists and output.path is a writable filesystem path, not a content:// or asset URI)
```

The symbolic name (e.g. `ERROR_CODE_ENCODER_INIT_FAILED`, `ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED`) is far more greppable than the raw int, so it is always included; the IO and encoder-init/format codes a consumer is most likely to hit also get a human hint (#89).

---

## Types

The full type list is exported from the package root and re-exported from the Nitro spec. The most load-bearing ones:

### `RenderSpec` and `ComposeSpec`

```ts
type NonEmptyArray<T> = [T, ...T[]];

interface RenderSpec {
  output: OutputSpec;
  clips: NonEmptyArray<ClipInput>;
  overlays?: Overlay[];     // Overlay.Image | Overlay.Text
  audio?: AudioSpec;
  metadata?: MetadataSpec;
}

interface ComposeSpec {
  output: OutputSpec;
  clips: NonEmptyArray<ClipInput>;
  overlays?: Overlay[];
  audio?: AudioSpec;
  metadata?: MetadataSpec;
}
```

Both facades require at least one clip at the type level — `Video.render` and `Video.compose` will not accept a clip-less spec. Synthesized renders (no clips, an explicit `duration`) go through `Video.synthesize` with its own [`SynthesizeOptions`](#videosynthesize) shape and the stricter `SynthesizeOutputSpec` below.

`RenderSpec` and `ComposeSpec` are structurally identical today. They are kept as distinct types so consumer code documents which execution path it targets — the underlying engines (native remux/transcode vs. the worklet compose pump) differ, and their public surfaces are free to diverge.

### `OutputSpec` and `SynthesizeOutputSpec`

```ts
interface OutputSpec {
  path: string;
  width?: number;
  height?: number;
  fps?: number;
  bitrate?: number;           // bits per second
  codec?: VideoCodec;         // 'h264' | 'hevc'; default 'h264'
  container?: VideoContainer; // 'mp4' | 'mov'
  colorRange?: ColorRange;    // 'sdr' | 'hdr'; compose-only; default 'sdr'
}

type ColorRange = 'sdr' | 'hdr';

type SynthesizeOutputSpec = OutputSpec & {
  width: number;
  height: number;
  fps: number;
};
```

`Video.synthesize` requires `SynthesizeOutputSpec`; the three required fields are enforced at compile time.

**`output.colorRange` (compose-only).** Selects how an HDR source's dynamic range is treated on the [`Video.compose`](#videocompose) path:

- `'sdr'` (default, or omitted): tone-map an HDR (HLG/PQ, bt2020) source down to SDR sRGB — see [HDR sources](#videocompose). No behavior change.
- `'hdr'`: preserve the source's dynamic range through a 10-bit pixel pipeline. This requires the platform HDR-compose implementation (iOS [#92] / Android [#93]); **until it lands on the current platform, `'hdr'` rejects up front with `InvalidSpecError`** rather than silently producing SDR.

The field rides the shared `OutputSpec` struct, but it is **only** meaningful on `Video.compose`. Setting it on `Video.render` or `Video.synthesize` is rejected with `InvalidSpecError` — those paths do not materialize frames into a worklet pixel buffer, so there is no HDR range to preserve. See [`docs/hdr-compose.md`](./hdr-compose.md) and [#90].

**Frame rate (`output.fps`) on `Video.render`.** Setting `fps` re-times the output. iOS resamples in both directions (PTS becomes `outputIndex / fps`, so it can both drop and duplicate frames). Android runs on Media3, which can only **drop** frames (no interpolation): a target **below** the source rate is applied via `FrameDropEffect`; a target **equal to** the source is a no-op; a target **above** the source rate is **rejected** with `InvalidSpec` rather than silently keeping the source rate. The Android frame-drop strategy approximates the target from the real frame timestamps, so the resulting rate is close to — but not an exact `outputIndex / fps` resampling of — the requested value. (`Video.synthesize` always produces an exact `output.fps` on both platforms, since it authors every frame.)

#### Output file semantics

`path` is the on-disk destination for every operation that writes a file (`trim`, `flip`, `stamp`, `render`, `compose`, `synthesize`, `thumbnail`, `thumbnails`). The contract:

- **Form.** Must be a non-empty filesystem path or a `file://` URI. Other schemes (`http://`, `content://`, `data:`, …) are rejected at the JS boundary. Plain absolute paths and `file:///…` URIs are equivalent.
- **Overwrite.** If a file already exists at `path`, it is deleted before the new file is written. There is no `overwrite: false` option.
- **Parent directories.** Are **not** created automatically. The caller is responsible for ensuring the directory exists (e.g. via React Native's `RNFS.mkdir` or `expo-file-system`'s `makeDirectoryAsync`). Writing to a non-existent directory rejects with `IOError` — on the iOS `compose`/`synthesize` paths this is validated up front (with an actionable `"parent directory does not exist"` message) rather than surfacing as the opaque MediaToolbox "Cannot create file" deep in the export (#85).
- **Atomicity.** Writes are **not** atomic. While the operation is in flight, `path` may exist as a partial / not-yet-finalized file. Readers that observe the path mid-render will see incomplete data.
- **Failure / cancellation.** On rejection (any cause — `InvalidSpec`, `EncoderFailure`, `Cancelled`, …), the partial output at `path` is best-effort deleted by the native side. Don't rely on a partial file being present after a failed render.
- **Container vs. extension.** The output container is determined by `output.container` if provided, otherwise inferred from the file extension. There is no enforcement that `path`'s extension matches `output.container` — providing `path: 'out.mov'` with `container: 'mp4'` is accepted and produces an MP4 inside a `.mov` filename. Avoid relying on the extension alone for downstream tooling.

These semantics apply uniformly across iOS (AVFoundation) and Android (Media3 Transformer).

### `ClipInput` and `ClipTransform`

```ts
interface ClipInput {
  uri: string;
  startSec?: number;       // seconds into source; default 0
  durationSec?: number;    // seconds of source to use; default "rest of source"
  transform?: ClipTransform;

  // Forward-compatibility timeline hooks — see "Reserved timeline fields".
  id?: string;             // stable clip id; surfaced as FrameDrawerContext.clipId
  outputStartSec?: number; // explicit output position; past the previous clip opens a black gap, before it crossfades (iOS + Android)
  track?: number;          // 0/undefined = base timeline; >0 = overlay/PiP track (iOS + Android)
  frame?: { x: number; y: number; w: number; h: number }; // PiP placement, normalized 0..1 (overlay tracks only)
}

interface ClipTransform {
  rotate?: 0 | 90 | 180 | 270;
  flipH?: boolean;
  flipV?: boolean;
  crop?: { x: number; y: number; w: number; h: number }; // source-pixel coords
}
```

The timeline model stitches clips in array order. By default each clip picks up where the previous ended (`outputStartSec` omitted). An explicit `outputStartSec` past the previous clip's end opens a **gap**, filled with black + silence. A value before it is an **overlap**: on **both platforms** the two clips are crossfade-dissolved over the overlap window (opacity/alpha ramp + audio volume ramp), limited to adjacent-pair overlaps.

#### Multi-track (PiP) and reserved timeline fields

`id` reserves a public field name for a future richer timeline (transitions, clip-targeted overlays). `outputStartSec`, `track`, and `frame` are live. Rejected cases surface as `InvalidSpecError`:

- **`id`** — optional stable identifier, surfaced as `FrameDrawerContext.clipId` on the compose path. Must be unique within a single spec.
- **`outputStartSec`** — when provided, a value at/after the previous clip's end opens a **gap** (filled with black + silence; forces a re-encode). A smaller value is an **overlap**: crossfade-dissolved on **both platforms** (adjacent-pair only — an overlap spanning two clips, or fully containing one, rejects). Omit it for the contiguous position.
- **`track`** — `0`/`undefined` is the base timeline. A value **> 0** is an **overlay/PiP track** composited on top of the base, in ascending z-order (**iOS + Android** — iOS via `AVMutableVideoComposition`, Android via a Media3 multi-sequence `Composition`). An overlay-track clip **requires** an explicit `outputStartSec` (it has no implicit concat slot), a base-track clip to composite onto, and must **fit within the base timeline** (it can't extend the output past the base). Must be a non-negative integer. Overlay audio is dropped in v1 on both platforms. **iOS** re-encodes the composite as H.264 at the encoder's quality default, so an HEVC output or an explicit `output.bitrate` rejects on the overlay path there; **Android** re-encodes the composite directly and honours both. On **Android**, `audio.mode = 'replace'` (a separate soundtrack on a parallel sequence), a spec-level static overlay (watermark, composited on top of the whole frame), and a **base-track overlap** (crossfade-dissolved in a first pass, then the overlay tracks composite on top) are all supported with overlay tracks ([#52](https://github.com/nightlybuildgroup/react-native-video-pipeline/issues/52)) — at parity with iOS.
- **`frame`** — placement for an overlay-track clip, in normalized output coordinates (`0..1`, origin top-left). Omitted = fill the frame. Only valid on an overlay track; must lie within the output (`x+w` and `y+h ≤ 1`). Example PiP: `{ x: 0.7, y: 0.05, w: 0.25, h: 0.25 }`.

Code written against these fields today keeps working as the timeline model grows; the validation rules will loosen, not the field shapes.

When `durationSec` is omitted, the library calls `Video.info(uri)` to probe the source duration and uses `sourceDuration - startSec`. Provide `durationSec` explicitly to skip the probe.

The native Nitro boundary still receives `{ sourceStart, sourceDuration, outputStart }` — the library normalizes `ClipInput[]` into that shape before crossing. Direct consumers of the Nitro spec see the underlying form.

**Transform routing.** On a single-clip render, both platforms produce the correct output and preserve source audio; the path differs:

- **iOS** — rotation/flip-only stays in **remux** (lossless `preferredTransform`); `crop`, an output-side change, or an overlay forces **transcode**.
- **Android** — the single-clip transform/trim/output/overlay path runs on **Media3 Transformer**, which transmuxes (copies compressed samples) when no pixel work is needed and re-encodes otherwise. Native overlays composite via Media3 `OverlayEffect` in the same pass as trim + transform (audio preserved); `spec.metadata` is applied in a follow-up compressed-passthrough remux.

A trim window composes with the transform in the same pass on both.

### `DurationSpec`

```ts
type DurationSpec =
  | { mode: 'fixed'; seconds: number }
  | { mode: 'open'; maxSeconds?: number };
```

`'open'` requires either an `AbortSignal` or a `VideoRenderController` so the render can be stopped.

### `RenderOptions`

```ts
interface RenderOptions {
  signal?: AbortSignal;
  controller?: VideoRenderController;
  onProgress?: (p: Progress) => void;
}
```

### `Progress`

```ts
interface Progress {
  framesCompleted: number;
  nbFrames?: number;            // undefined for open-ended until finish() is called
  elapsedMs: number;
  estimatedRemainingMs?: number;
}
```

**When `onProgress` fires.** `Video.render`, `Video.compose`, and `Video.synthesize` always report progress when the operation decodes/encodes frames. For convenience methods, the rule is "transcode reports, remux doesn't":

| Operation                             | Underlying path | Reports progress? |
| ------------------------------------- | --------------- | ----------------- |
| `Video.trim`                          | remux           | No                |
| `Video.flip`                          | remux (iOS) / transcode (Android) | No (iOS — passthrough remux); Yes (Android — re-encode via Media3) |
| `Video.stamp` (metadata only)         | remux           | No                |
| `Video.stamp` (with image watermark)  | transcode       | Yes               |

Remux paths complete in seconds and don't decode/encode individual frames, so per-frame progress is not meaningful — `onProgress` is accepted on the type for API uniformity and silently not invoked. If you need progress on these paths, the operation completes fast enough that just awaiting the promise is the right pattern.

### `MetadataSpec`

```ts
interface MetadataSpec {
  location?: { latitude: number; longitude: number }; // WGS-84
  software?: string;
  creationDate?: Date;
  description?: string;
  custom?: Record<string, string>;
}
```

`location` matches the standard media-metadata vocabulary (`AVMetadataCommonKeyLocation` on iOS, EXIF/IPTC GPSInfo, Photos.app UI). The TYPE is `WGS84Coordinate` to make the datum contract explicit — the source can be any GNSS constellation (GPS, GLONASS, Galileo, BeiDou, QZSS, …) or a non-satellite resolver corrected back to WGS-84. Container muxers serialize it to the standard `udta/©xyz` atom.

`custom` keys round-trip through the library — caller owns the keys; no namespace prefix is added.

### `AudioSpec`

```ts
type AudioSpec =
  | { mode: 'passthrough' }
  | { mode: 'mute' }
  | { mode: 'replace'; replaceUri: string };
```

Discriminated by `mode`, so `replaceUri` is required at compile time when (and only when) `mode === 'replace'`.

> **Status.** All three modes are wired into both native engines across every source-backed render path. `'passthrough'` (keep the source audio — also the default when `audio` is omitted) carries the source soundtrack through the transcode re-encode, the rotation/flip transform-remux (iOS), and the concat — multi-clip (and plain single-clip-trim) renders carry each clip's audio onto the joined timeline (a clip with no audio leaves a silent gap). `'mute'` drops the audio track (iOS omits it; Android `EditedMediaItem.setRemoveAudio`). `'replace'` swaps the soundtrack for `replaceUri`, capped to the output video duration — a shorter replacement leaves a silent tail, a longer one is truncated. A `replace` spec must carry a non-empty **file-URI** `replaceUri` whose file actually contains an audio track (a missing or audio-less replacement **rejects** rather than silently producing video-only). `replace` requires source clips — it is **rejected on a synthesized render** (no source timeline to mux onto; render first, then replace in a second pass). Implemented in [#29](https://github.com/nightlybuildgroup/react-native-video-pipeline/issues/29). On Android's **composite** render paths (PiP overlay tracks and crossfade overlaps), `replace` is supported too ([#52](https://github.com/nightlybuildgroup/react-native-video-pipeline/issues/52)): the base / per-clip audio is dropped and the replacement is muxed on a parallel audio-only sequence (a crossfade's *passthrough* audio is instead volume-ramped per clip).

### `Size`

```ts
type Size = { w: number; h?: number } | { w?: number; h: number };
```

Pixel-only. Used by `ThumbnailOptions.resizeTo` and `BatchThumbnailOptions.resizeTo`. At least one of `w` / `h` is required; the other scales proportionally.

### `BatchThumbnailOptions`

```ts
interface BatchThumbnailOptions {
  atSecs: number[];      // capture times; non-empty, each >= 0
  outPaths: string[];    // one per time, parallel to atSecs
  resizeTo?: Size;       // applied uniformly to every frame
  toleranceSec?: number; // seek tolerance; 0 (default) = exact frame
}
```

Options for [`Video.thumbnails`](#videothumbnails). `atSecs` and `outPaths` must be parallel arrays of equal, non-zero length. `toleranceSec > 0` trades exactness for speed by snapping to the nearest keyframe — the right tradeoff for filmstrips. A frame that fails to extract resolves to an empty string in its slot.

### `OverlaySize`

```ts
type Dim =
  | { unit: 'px'; value: number }
  | { unit: 'ratio'; value: number };

type OverlaySize =
  | { width: Dim; height?: Dim }
  | { width?: Dim; height: Dim };
```

Used by `Overlay.Image.size`. Each axis carries an explicit unit:

- `{ unit: 'px', value: N }` — absolute output pixels.
- `{ unit: 'ratio', value: R }` — fraction of the corresponding output canvas dimension (resolved natively at render time, so inherited / synthesized output dims are honored).

At least one of `width` / `height` is required; the missing axis scales proportionally from the overlay image's natural aspect ratio.

### `FrameDrawerContext`

The argument to `drawFrame` on the compose / synthesize path:

```ts
interface FrameDrawerContext {
  target: FrameTarget;            // write here
  source?: FrameSource;           // current source frame (compose-on-clip only)
  frameIndex: number;             // 0-based output frame counter
  timeSec: number;                // frameIndex / fps — output PTS
  elapsedMs: number;              // wall-clock since render start
  width: number;
  height: number;

  // Timeline context. fps is set whenever the wrapper knows it (always on
  // synthesize; on compose only when output.fps was passed explicitly). The
  // clip* / source* fields are populated on the compose-on-clip path and are
  // undefined on the synthesize path.
  fps?: number;                   // output frame rate, when known
  clipIndex?: number;             // index of the active source clip
  clipId?: string;                // ClipInput.id of the active clip, if set
  sourceUri?: string;             // uri of the active source clip
  sourceTimeSec?: number;         // time within the active source clip

  finish(): void;                 // graceful stop on open-ended renders
}
```

The `clipIndex` / `clipId` / `sourceUri` / `sourceTimeSec` fields are derived by the JS wrapper from the normalized concat timeline, so worklets don't have to duplicate the library's timeline math. They track which source clip is producing the current output frame.

The `target` and `source` HybridObjects are **valid only during the enclosing `drawFrame` call**. The native pump invalidates them on return. Don't retain the pointer; don't pass them to async work.

### `FrameTarget` / `FrameSource`

Pixel-buffer handles backed by `CVPixelBuffer` (iOS) or `AHardwareBuffer` (Android). Both expose `width`, `height`, and `format: PixelFormat`.

```ts
type PixelFormat = 'bgra8888' | 'rgba8888' | 'rgbaFp16';
```

- `'bgra8888'` / `'rgba8888'` — 8-bit SDR, 4 bytes/pixel. `writeBytes`/`readBytes` operate on `width * height * 4` bytes. The default compose path.
- `'rgbaFp16'` — **HDR ([#99]).** 16-bit half-float RGBA, 8 bytes/pixel, **linear Rec.2020, premultiplied, extended range** (channels may exceed 1.0). Only appears when a consumer opts into `output.colorRange: 'hdr'`; `writeBytes`/`readBytes` operate on `width * height * 8` bytes. It never appears on the SDR path — an SDR compose is byte-for-byte unchanged.

**Most consumers should not touch these directly.** Use one of the high-level helpers instead:

- `drawWithRGBA(draw)` — plain `Uint8Array` pixel writing. Stable, CPU-only, cross-platform. **8-bit only** — it throws on an `'rgbaFp16'` target.
- `drawWithFloat16(draw)` — the half-float (`rgbaFp16`) HDR counterpart: fills a `Float32Array` (linear Rec.2020, premultiplied, extended range) that the helper converts to half-floats. Requires an `'rgbaFp16'` target (`output.colorRange: 'hdr'`).
- `drawWithSkia(draw)` (from `react-native-video-pipeline-skia`) — Skia drawing with automatic feature detection of the iOS Metal fast path. This is the recommended worklet entry point for anything beyond raw RGBA. The `'rgbaFp16'` (HDR) target is not yet supported by this helper (the F16 Skia surface path lands with the platform pipelines, [#92]/[#93]) — it throws rather than silently downgrade to SDR.

The remaining members of `FrameTarget` / `FrameSource` are advanced escape hatches:

| Member                                          | Stability    | Purpose                                                                                                                    |
| ----------------------------------------------- | ------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `target.writeBytes(bytes)`                      | **Stable**   | `memcpy` of `width * height * 4` bytes into the target. Reached transparently by `drawWithRGBA`.                           |
| `target.unstable_bufferAddr` / `source.unstable_bufferAddr`       | Unstable | Raw native pointer (`bigint`). Used by `drawWithSkia` to hand the buffer to Skia. Pointer semantics are platform-specific.   |
| `target.unstable_blitFromNativeTexture(mtlTexturePtr)`            | Unstable | iOS-only Metal-to-buffer fast path. `drawWithSkia` feature-detects this and falls back to `writeBytes` on Android.           |
| `source.readBytes()`                                              | Stable   | Fresh RGBA8888 copy of the current source frame.                                                                             |

The `unstable_` prefix is the stability signal: those members are not covered by the v1.0 stability contract — pointer ABI may change, names may be moved under a dedicated namespace, or the surface may be removed in favor of a more portable signature. Building consumer code on top of them is supported, but prefer the high-level helpers (`drawWithRGBA`, `drawWithSkia`) so a future ABI change is invisible to your code.

### `EncoderCaps`

```ts
interface EncoderCaps {
  codecs: VideoCodec[];
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
  maxBitrate: number;
  hdr: boolean;
}
```

---

## Routing rules

Each top-level operation maps to one of three internal execution paths. The decision is made on the native side from the (loose) Nitro `VideoSpec` shape that crosses the boundary:

| Path        | When                                                                                | Speed   |
| ----------- | ----------------------------------------------------------------------------------- | ------- |
| **remux**   | Passthrough — no overlays, output codec/container match, and either no transform or a rotation/flip-only transform on iOS (lossless, with optional trim window) | Fastest |
| **transcode** | Native overlays (`image`, `text`), `crop`, an output-side change (size/fps/codec/bitrate), or any rotation/flip on Android — re-encodes; preserves source audio and honors a trim window | Medium  |
| **compose** | Worklet overlay or `drawFrame` callback present, OR no source clips (synthesize)    | Slowest |

Per-clip transforms / overlays / output-side changes apply to both single-clip and multi-clip renders; a multi-clip spec needing a re-encode transcodes each clip to the shared output and concatenates them, while a no-re-encode multi-clip spec stays on the lossless passthrough concat.

The `Video.trim` / `Video.flip` / `Video.stamp` convenience wrappers exist so the routing decision lives in C++, not split across JS and native. `Video.render` is the explicit form.

---

## Worklet directive enforcement

`Video.compose` and `Video.synthesize` accept callbacks that run on the Reanimated UI runtime. Reanimated requires every such function to begin with `'worklet';` so it can be lifted to the UI thread.

`babel-plugin-video-pipeline` enforces this **at build time**:

- Inline function literals passed as `drawFrame` / `draw` must start with `'worklet';`. Missing directive → bundle fails.
- Named identifiers (`drawFrame: myDrawer`) are passed through — declare the directive on the function itself.

The library never runs the directive check at runtime; the guarantee is entirely build-time.

---

## See also

- [`docs/examples/`](./examples/) — runnable scenarios per operation
- [`docs/architecture.md`](./architecture.md) — repo layout, tech stack, locked-in design decisions
- [`docs/rendering-ios.md`](./rendering-ios.md), [`docs/rendering-android.md`](./rendering-android.md) — render-pipeline architecture
- `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` — Nitro spec (single source of truth)
