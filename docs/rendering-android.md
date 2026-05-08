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
   as `bufferAddr` (a `bigint` across Nitro). On the Skia side,
   `Skia.Image.MakeImageFromNativeBuffer(BigInt.asUintN(64, bufferAddr))`
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
