# Android rendering paths

The compose-on-clip source side runs zero-copy via AHardwareBuffer; the
synthesize path and compose-on-clip output side still pay full-frame
copies because v2.6.2 of `@shopify/react-native-skia` doesn't expose an
AHardwareBuffer-backed `SkSurface` factory. Closing those copies needs
either Skia patches or shared EGL — separate work.

```
                                                          ┌────► encoder texture
                                                          │      (glTexSubImage2D)
   decoder ── ImageReader ── AHardwareBuffer ── JS Skia ── ByteBuffer
   (MediaCodec)             (zero-copy)         (CPU)     (host mem)
                                                          │
                                                          └────► encoder input surface
                                                                 (MediaCodec)
```

Each `──` between two unlike primitives is a memory boundary that costs a
full-frame copy. The decoder→Skia leg crosses no such boundary on the
compose-on-clip path: `Skia.Image.MakeImageFromNativeBuffer` reads the
decoder's hardware buffer in place via an EGLImage.

---

## Synthesize (no source clip)

The simplest path. Used by the perf-test buttons and any
`Video.synthesize({ drawFrame: drawWithSkia(...) })` call.

Code: `packages/react-native-video-pipeline/android/src/main/java/com/margelo/nitro/videopipeline/HybridVideoPipeline.kt:composeSynthesize`

Per frame:

1. Allocate a direct `ByteBuffer(width*height*4)` on the Kotlin side. Wrap
   it in a `HybridFrameTarget` and hand to JS.
2. JS Skia worklet draws onto its own offscreen `SkSurface`, then
   `surface.makeImageSnapshot().readPixels(...)` (GPU readback) →
   `target.writeBytes(arrayBuffer)` → C++ memcpys into the ByteBuffer.
3. `VideoEncoder.writeRgbaFrame(buffer, ptsNs)` uploads the ByteBuffer to
   a 2D GL texture via `glTexSubImage2D` and draws a fullscreen
   textured quad onto the encoder's input EGL surface
   (`MediaCodec.createInputSurface()` → `eglSwapBuffers`).

Code: `GLRgbaRenderer.kt`, `VideoEncoder.kt:writeRgbaFrame`, `HybridFrameTarget.kt:writeBytes`

Per-frame data flow at 1080p:

| step | what | bytes copied |
|---|---|---|
| Skia draw on GPU | offscreen surface | 0 |
| `snapshot.readPixels(...)` | **GPU → CPU readback** | 8.3 MB |
| `pixels.buffer.slice(...)` | ArrayBuffer copy for Nitro | 8.3 MB |
| `target.writeBytes(ab)` → memcpy into ByteBuffer | full-frame copy | 8.3 MB |
| `glTexSubImage2D` upload | **CPU → GPU** | 8.3 MB |
| GL render to encoder surface | textured quad → MediaCodec captures | 0 (GPU local) |

Four full-frame copies per frame. Two of them cross the GPU↔CPU boundary
(the expensive ones).

---

## Compose-on-clip

The frame-number-overlay flow. The source decode is fully zero-copy via
AHardwareBuffer; only the encoder side still moves pixel bytes through
host memory.

Code: `HybridVideoPipeline.kt:composeOnClip`, `ClipDecoder.kt`,
`HybridFrameSource.kt`, `AHardwareBufferBridge.kt`,
`cpp-hardware-buffer.cpp`.

Per frame the source side (steps 1–3 below) feeds an `SkImage` straight
into the worklet without ever touching CPU pixels:

1. `MediaCodec` decoder writes a frame to an `ImageReader.surface`
   configured with `ImageFormat.PRIVATE` + `USAGE_GPU_SAMPLED_IMAGE`.
   The decoder fills a slot in the ImageReader's pool when it has output.
2. `imageReader.acquireNextImage()` returns an `Image`. Calling
   `image.getHardwareBuffer()` returns a Java `HardwareBuffer` whose
   refcount keeps the underlying `AHardwareBuffer` alive even after we
   `image.close()` (which releases the ImageReader slot back to the pool).
3. `AHardwareBufferBridge.nativePtr(hwb)` resolves the JNI shim
   (`AHardwareBuffer_fromHardwareBuffer` via `dlsym`) and returns the
   raw `AHardwareBuffer*` as a `Long`. We expose it on `HybridFrameSource`
   as `unstable_bufferAddr` (a `bigint` across Nitro). On the Skia side,
   `Skia.Image.MakeImageFromNativeBuffer(BigInt.asUintN(64, unstable_bufferAddr))`
   wraps the AHardwareBuffer in an `SkImage` via
   `eglCreateImageKHR(EGL_NATIVE_BUFFER_ANDROID)` — Skia's EGLImage
   refcount keeps the buffer alive across the worklet body. After the
   worklet's `sourceImage.dispose()` releases Skia's ref, the pump closes
   the Java `HardwareBuffer`, and the underlying buffer is freed once
   the last ref drops.
4. JS Skia worklet draws `sourceImage` at `(0, 0)`, runs the user's
   draw on top, calls `surface.flush()`.
5. The synthesize path resumes (`readPixels` → `writeBytes` → encoder).

Per-frame data flow at 1080p, *new copies on top of synthesize*:

| step | what | bytes copied |
|---|---|---|
| ImageReader holds decoder buffer | (zero-copy) | 0 |
| `Skia.Image.MakeImageFromNativeBuffer(addr)` | EGLImage import — Skia samples in place | 0 |

Plus the four from synthesize. Total: about four full-frame 8.3 MB copies
per frame (was six before AHardwareBuffer), all on the encoder side. On
the emulator we measured ~75 ms/frame in JS at 1080p (was ~118 ms with
the bytes path), with the rest split between AHWB acquisition, Skia
sampling/draw, output readback, GL upload, GL render, decode, and
encode.

### Constraint: minSdk 26+

Skia's `MakeImageFromNativeBuffer` is gated on `__ANDROID_API__ >= 26`
in its prefab build. Apps that consume this library and want the
zero-copy compose-on-clip path must compile with `minSdkVersion = 26`
(see `apps/bare-example/android/build.gradle`). The library itself
keeps `minSdkVersion = 24`; on devices below O the Kotlin pump throws
"AHardwareBuffer requires API 26+" before reaching Skia.

The C++ JNI shim (`cpp-hardware-buffer.cpp`) resolves
`AHardwareBuffer_fromHardwareBuffer` lazily via `dlsym(libandroid.so,
…)` so the shared library loads on every supported device — only the
resolved symbol is invoked, and the Kotlin call site is gated by
`@RequiresApi(26)`.

---

## Y orientation: who flips and why

Each memory↔GPU boundary that involves CPU pixel data on Android performs
a Y inversion (raster bytes are top-down, GL is Y-up). The compose-on-clip
pipeline crosses two such boundaries on the encoder side; the source side
is in-place GPU sampling and needs no flip:

| boundary | flip mechanism |
|---|---|
| decoder → AHardwareBuffer → Skia | none — `MakeImageFromNativeBuffer` uses `kTopLeft_GrSurfaceOrigin`, so the SkImage's `(0,0)` is the source's visual top-left without any compensation |
| Skia surface → `snapshot.readPixels` → ByteBuffer | implicit (`readPixels` reads top-down); no compensation needed |
| ByteBuffer → encoder texture (`glTexSubImage2D`) → encoder surface | implicit (upload inverts); we compensate with V-flipped UVs in `GLRgbaRenderer`'s vertex setup |

If the user draws at Skia coord `(0,0)` (top-left of the SkSurface), the
red rect ends up at the top-left of the encoded video. That's the
empirical contract — bare-example's frame-number-overlay button leaves
a small red marker at top-left as a visual canary.

---

## Render with transform (Media3 Transformer)

`Video.render` with a single-clip `transform` (rotate / flip / crop), an
output-side change (size / fps / codec / bitrate), or a trim window runs through
**Media3 Transformer** (`TransformerRunner.kt`) — the canonical Jetpack editing
engine. It owns the decode → effects → encode lifecycle, so there is no
hand-rolled MediaCodec/EOS plumbing:

- **Trim** → `MediaItem.ClippingConfiguration` (start/end ms). Only a real trim
  sets a clip range, so a rotation-only edit can still transmux.
- **Crop / rotate / flip** → `Effects`: `Crop` (source-pixel rect mapped to
  NDC), `ScaleAndRotateTransformation` (rotation is clockwise per the public
  contract → negated for Media3; flips are scale ±1).
- **Explicit output size** → `Presentation` with `LAYOUT_STRETCH_TO_FIT`. Either
  dimension alone is enough: the router resolves
  `(output.width ?: fallbackW, output.height ?: fallbackH)` where the fallback is
  the crop rect (or source), swapped for a quarter-turn rotation — so a single
  requested dimension stretches that axis and keeps the other at content size,
  matching iOS `makeTranscodeTarget`. The layout is **stretch**, not scale-to-fit:
  the content is scaled non-uniformly to *fill* the canvas (no letterbox /
  pillarbox bars when the canvas aspect differs from the source), matching the
  iOS transcoder's non-uniform `CGAffineTransformMakeScale` to the render size.
  The output frame size is the requested width×height under either layout — only
  the in-frame content scaling differs. When neither dimension is pinned (and
  there is no overlay), no `Presentation` is added and Media3 derives the size (a
  90° rotation yields portrait output without the caller pinning dimensions). A
  single dimension already forces a re-encode, so honoring it never costs the
  transmux fast path.
  - **Coded vs displayed dimensions:** a hardware AVC encoder may store a
    portrait frame as a coded landscape frame plus a rotation flag (observed on
    the API 36 emulator: a displayed 80×120 output is coded 120×80 + rotation 90).
    The displayed size is correct; tests reading dimensions must apply rotation
    (e.g. decode a frame) rather than trusting `METADATA_KEY_VIDEO_WIDTH/HEIGHT`,
    which report the pre-rotation coded grid.
- **Target fps** → `FrameDropEffect` when `output.fps` is **below** the source
  rate. Media3 has no frame interpolation, so it can only drop frames: a target
  equal to the source is a no-op, and a target *above* the source rate is
  rejected (`InvalidSpec`) instead of silently keeping the source cadence. This
  differs from iOS, which resamples both directions as `outputIndex / fps`.
- **Audio** → preserved automatically (Transformer copies the audio through),
  unless `audio.mode: 'mute'` is set, which drops the track via
  `EditedMediaItem.Builder.setRemoveAudio(true)`.
- **Transmux fast path** → when the requested edit needs no pixel work, Media3
  copies compressed samples without re-encoding.

Transformer must be constructed, started, cancelled, and progress-polled on a
thread with a `Looper`. The render worker (`Promise.parallel`) has none, so the
session is driven on the main `Looper` and the worker blocks on a latch.

**Why Media3 and not a DIY pump.** An earlier hand-rolled MediaCodec
decode→GL→encode pump (still used by the watermark-stamp path) deadlocked on
back-to-back renders in one process — the second export hung in the decode loop.
Media3's managed lifecycle eliminates that class of bug; the instrumented
`backToBackTranscodesBothComplete` test guards it.

**Overlays on render** run on Media3 `OverlayEffect` too — one `BitmapOverlay`
per overlay, composited last (on the transformed + resized frame), so overlay +
trim + transform happen in a single pass with the audio preserved. Each overlay
maps to a Media3 `OverlaySettings`: the public `anchor` (image-space, treated as
the overlay's center) becomes `backgroundFrameAnchor` in NDC; the resolved pixel
size becomes `scale` (Media3 renders a bitmap at its native pixel size by
default, so `scale = targetPx / bitmapPx`); `opacity` becomes `alphaScale`; and a
`timeRange` is honored by a `BitmapOverlay` subclass that drops `alphaScale` to 0
outside the window. Image overlays decode a bitmap; text overlays rasterize
through `OverlayTextRasterizer` — both flatten to the same `ResolvedOverlay`.

### Multi-track / PiP overlay tracks (#45, parity with iOS #17)

An overlay clip (`clip.track > 0`, with a normalized `clip.frame` rect) is
composited as a Picture-in-Picture box on top of the base timeline. This is a
**video-on-video** composite, so it can't use `OverlayEffect` (that takes a
bitmap, not a second decoded stream). Instead `TransformerRunner.runCompositePip`
builds a Media3 **multi-sequence `Composition`** — one `EditedMediaItemSequence`
per layer:

- the **base** track (the `track == 0` clips, built exactly like the multi-clip
  `runMulti` sequence, gaps included) as the **back** layer, and
- one sequence per **overlay** track, each padded with a transparent image
  (`authorTransparentImage`) before and after its `[outputStart, +duration]`
  window so every sequence spans the full output duration (otherwise the
  Composition would be truncated to a single overlay's window).

Media3's `DefaultVideoCompositor` draws the **first-registered** sequence on top
and later ones beneath (reverse registration order). To match the iOS z-order
(base at the back, higher track index more on top) the sequences are registered
**topmost-overlay-first, base last**. A `VideoCompositorSettings` then positions
each overlay input: `getOverlaySettings(inputId, …)` returns `setScale(w, h)`
(the overlay input is presented at the full canvas, so a `w × h` fraction shrinks
it to the rect) plus `setBackgroundFrameAnchor` at the rect centre, mapped to NDC
(origin centre, **y up** — so the top-left `frame.y` is flipped, the same flip
the iOS `CGAffineTransform` does). The base input is left full-frame. During a
transparent-pad frame the overlay contributes alpha 0, so the base shows through.

Audio + static overlays on the PiP path (`renderCompositePip`): overlay-track
audio is always dropped (mirrors iOS multi-track). The base track honours all
three `audio.mode`s — `passthrough` keeps the base clips' audio, `mute` drops it,
and `replace` (#52) strips the base audio and muxes a separate soundtrack on a
**parallel audio-only sequence** appended after the video sequences (so it isn't a
video-compositor input and doesn't shift the `inputId`→layer mapping). Spec-level
overlays (watermarks) compose on top of the whole PiP output via a
**composition-level** `OverlayEffect` (`Composition.Builder.setEffects`) — the
natural z-order for a watermark (#52). A **base-track overlap** combined with PiP
overlay tracks is handled in **two passes** (#52, mirroring iOS): pass 1
crossfade-dissolves the overlapping base clips to a temp via
`runCompositeCrossfade` — which resolves the `audio.mode` (mute / replace /
passthrough-ramp) into the temp — and pass 2 composites the overlay tracks on top
of that single temp base via `runCompositePip` (passthrough, so the temp's audio
carries through). The temp is written to `cacheDir` and deleted on exit; a
non-overlapping base skips pass 1. Unlike iOS — whose `HighestQuality` export
preset is H.264-only — the Android Transformer re-encodes the composite directly,
so an HEVC output and an explicit bitrate are honoured for PiP too.

### Timeline-overlap crossfade (#43, parity with iOS #18)

A clip whose `outputStartSec` is **before** the previous clip's end overlaps it;
the overlap window is crossfade-dissolved. `TransformerRunner.runCompositeCrossfade`
builds **two ping-pong `EditedMediaItemSequence`s** — clip `i` goes on sequence
`i % 2`, so an overlapping adjacent pair always lands on distinct sequences and
can coexist in time (a single sequence is gapless/non-overlapping by
construction). Each sequence is transparent-padded to span the full output
duration, exactly like the PiP path.

Media3 draws sequence 0 on top, so a `VideoCompositorSettings` ramps **sequence
0's** alpha across each overlap window: `1→0` when sequence 0 holds the
**outgoing** (earlier-index) clip, `0→1` when it holds the **incoming** clip —
either way the visible result dissolves outgoing→incoming (`out·α + in·(1−α)` vs
`in·α + out·(1−α)` are the same blend). Sequence 1 stays opaque. Because the
z-order is fixed by registration (sequence 0 always on top), the ramp direction —
not the layer order — is what flips with the clip's parity; this is the one place
the Android compositor differs in mechanism from the iOS `setOpacityRamp` (which
reorders layers per region so the outgoing clip is always in front).

**Audio.** Passthrough audio rides **two more** ping-pong sequences, separate from
the video ones. The video sequences are always audio-stripped: a sequence that
leads with a transparent image pad and then has an audio-bearing clip throws a
Media3 asset-loader error (it can't reconcile a no-audio first item with a later
audio one, with or without a forced audio track). The audio sequences instead use
`addGap` for proper silent positioning — clip `i`'s audio (video stripped) is
preceded by an `addGap` so it lands at its `outputStart`, and a clip with no audio
track becomes a plain silence gap so the envelope on the audio-bearing clips stays
aligned. Each audio clip carries a `VolumeRampAudioProcessor` (a `BaseAudioProcessor`
on PCM 16-bit) whose head ramps `0→1` when the clip is the incoming side of an
overlap and whose tail ramps `1→0` when it is the outgoing side, so the two
overlapping audio sequences sum to a crossfade rather than a doubled-volume bump —
the same envelope the iOS `AVMutableAudioMix` applies. The audio sequences are only
built when at least one clip actually has audio. `mute` drops audio entirely;
`audio.mode = 'replace'` (#52) drops the per-clip ramped soundtracks and muxes a
single replacement on one parallel audio-only sequence instead (the same helper
the PiP / single / multi paths use). Spec-level overlays (watermarks) likewise
compose on top of the dissolved output via a composition-level `OverlayEffect`
(#52).

Only **adjacent-pair** overlaps are supported (a clip overlapping two neighbours
or fully containing another rejects — enforced in JS and re-checked in
`renderCompositeCrossfade`). As with PiP, an HEVC output and explicit bitrate are
honoured on Android (iOS rejects HEVC overlaps — its crossfade preset is H.264).

Container metadata (`spec.metadata`) can't be authored by Media3 Transformer, so
when present it's applied in a second compressed-passthrough pass via
`Remuxer.remuxStamp` (both tracks copied, no re-encode) — the same path the
metadata-only `stamp` uses. `location` is written natively with
`MediaMuxer.setLocation`; the rest of the `MetadataSpec` (`software`,
`creationDate`, `description`, `custom`) is persisted as `moov.udta.meta` mdta
items by `Mp4MetadataInjector` after the muxer closes — the same store iOS's
AVAssetWriter writes, so the fields round-trip through `ProbeRunner`
(`description`/`creationDate` into the dedicated `VideoInfo` fields,
`software` + `custom` into `VideoInfo.custom`). The legacy hand-rolled GL
`Transcoder` is now used only by the watermark-`stamp` path.

> Parity note: `location` is still **not** written on the compose/synthesize
> path (no `setLocation` there yet) — only the mdta fields are. The `loci`
> altitude triple is also dropped on Android (`setLocation` takes lat/lon only).

## Potential improvements

The remaining four per-frame copies all live on the encoder/output side:
`snapshot.readPixels`, the `writeBytes` ArrayBuffer→ByteBuffer memcpy,
the `Skia.Data.fromBytes` style internal copy that Skia does inside
`readPixels`, and the `glTexSubImage2D` upload to the encoder texture.
Closing them needs *one* of:

### AHardwareBuffer-backed Skia surface (preferred)

If `@shopify/react-native-skia` exposed a
`Skia.Surface.MakeFromNativeBuffer(addr)` (the natural symmetric of
`Skia.Image.MakeImageFromNativeBuffer`), Skia would draw directly into
an AHardwareBuffer we own — and we'd push that buffer into the encoder
via `ImageWriter.queueInputImage`. Zero remaining copies; matches the
iOS `CVPixelBuffer` story. Today (v2.6.2) the public API only goes the
other way: `Skia.NativeBuffer.MakeFromImage(image)` exists but its
Android implementation does `image.readPixels` *plus* a CPU memcpy
into a freshly-allocated buffer, so it's worse than what we have.

Path forward: a small upstream PR adding
`MakeSurfaceFromNativeBuffer(addr)` that creates an `SkSurface` whose
GR backend texture is bound to an existing AHardwareBuffer (mechanism
already exists on `MakeImageFromNativeBuffer`'s read side). About 50
lines of native code on Skia's side.

### Stay-in-GL output path

Alternative if Skia upstream rejects the surface-from-buffer API: share
an EGL context between Skia and our encoder. After Skia draws,
`surface.getNativeTextureUnstable()` returns `{glID, glTarget, ...}`;
since we'd be in the same GL context, we can render that texture
directly onto the encoder's input EGL surface — no `readPixels`, no
`writeBytes`, no `glTexSubImage2D`.

What's needed: when constructing the encoder's EGL via
`EGL14.eglCreateContext`, pass a `share_context` referring to Skia's
GL context. Skia's context becomes accessible via the per-thread EGL
state when we're inside a worklet, but extracting it cleanly from
outside the worklet is the open problem; may require a small JNI
patch into `react-native-skia`.

### Why not `Skia.NativeBuffer.MakeFromImage`?

It exists and looks like it would help, but its Android impl
(`RNSkAndroidPlatformContext::makeNativeBuffer`) does:

1. `image.readPixels(...)` — GPU→CPU readback (1 copy)
2. `AHardwareBuffer_allocate` + `AHardwareBuffer_lock` + `memcpy` (1 copy)
3. Allocates a fresh AHWB per call

Two copies plus an allocation — net loss vs. the current `readPixels`
+ `writeBytes` path. Not viable until Skia's impl uses
`SkImages::AsyncRescaleAndReadPixelsYUV420` or a GPU-side blit into a
pre-allocated AHWB.

### Trade-offs for the encoder-side rewrite

| approach | code volume | requires | wins |
|---|---|---|---|
| `MakeSurfaceFromNativeBuffer` upstream PR | small (Skia patch + ~30 lines our side) | upstream Skia change; consumers on patched skia | matches iOS architecture; closes all encoder-side copies |
| stay-in-GL via shared EGL context | medium | extracting Skia's EGL context cleanly (currently undocumented) | no upstream dep; fastest if extraction works |
| current bytes-everywhere encoder | (already shipped) | nothing | works on every API ≥ 26 |

Source-side AHardwareBuffer is shipped in this repo (commit `f02dbd0`).
On the emulator we measured 76 s for a 1080p 638-frame compose-on-clip
render after the change vs 119 s before — ~1.6× speedup, dominated by
the source-side becoming zero-copy. A real hardware encoder (rather
than the emulator's software h264) would benefit even more from
closing the encoder side, since the encoder is no longer the
bottleneck.
