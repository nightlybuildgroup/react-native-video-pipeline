# iOS rendering paths

iOS has three render paths, all funneled through `VideoPipeline.mm`'s
`renderCompose`. Which one runs depends on what the JS caller asks for and
which Skia features are available at runtime. The system is mostly built
around a single shared abstraction — `CVPixelBuffer` — which is the
universal pixel-data type that AVFoundation, Skia, and IOSurface all
interoperate on. That's why iOS rendering is comparatively simple: the
buffer crosses every layer without copies, just refcount changes.

```
                            ┌─────────────────────────┐
            JS callback ──► │  HybridFrameTarget      │
                            │  (wraps CVPixelBuffer)  │
                            └─────────────────────────┘
                                       │
                                       ▼
                            AVAssetWriterInput­
                            PixelBufferAdaptor
                                       │
                                       ▼
                              AVAssetWriter ──► .mp4
```

All three paths share this final segment — what differs is *how* the bytes
got into the `CVPixelBuffer` before the muxer appends.

---

## Path 1 — vanilla: `drawWithRGBA` + `writeBytes`

Used by the bootstrap fixture flow and any caller that doesn't depend on
Skia. The JS worklet allocates a `Uint8Array`, fills it pixel-by-pixel,
and calls `target.writeBytes(arrayBuffer)`. Native side just `memcpy`s the
bytes into the locked `CVPixelBuffer`.

Code locations:
- JS helper: `packages/react-native-video-pipeline/src/drawWithRGBA.ts`
- C++ writeBytes implementation: `packages/react-native-video-pipeline/ios/HybridFrameTarget.mm:writeBytes`

Per-frame data flow at 1080p:

| step | what | bytes copied |
|---|---|---|
| JS allocates `Uint8Array` | 8.3 MB on JS heap | 0 (alloc only) |
| JS fills pixel-by-pixel | per-pixel work in worklet | 0 |
| `target.writeBytes(ab)` | Nitro hands the ArrayBuffer across | 0 (pointer marshal) |
| C++ `memcpy` into `CVPixelBuffer` | one full-frame copy | 8.3 MB |
| `appendPixelBuffer` | adaptor retains, encoder reads | 0 (refcount) |

One full-frame `memcpy` per frame. Acceptable for fixture work; clearly
wasteful when the pixels were just produced from a structured source like
Skia.

---

## Path 2 — Skia, CPU readback

The default path when `drawWithSkia` runs and the GPU fast path isn't
available (or is forced off via `SMOKE_FORCE_CPU_READBACK`). The worklet
draws to a Skia `SkSurface`, reads pixels back, and writes them to the
target via the same `writeBytes` mechanism as path 1.

Code locations:
- JS helper: `packages/react-native-video-pipeline-skia/src/drawWithSkia.ts`
- The CPU readback branch: see the `snapshot.readPixels(...)` block (≈ line 71-87)

Per-frame data flow at 1080p:

| step | what | bytes copied |
|---|---|---|
| `Skia.Surface.MakeOffscreen` | Ganesh-Metal surface allocated | 0 |
| Skia draw commands | rendered on GPU | 0 (GPU local) |
| `surface.makeImageSnapshot()` | snapshot reference | 0 |
| `snapshot.readPixels(...)` | **GPU → CPU readback** | 8.3 MB |
| `pixels.buffer.slice(...)` | ArrayBuffer copy for Nitro | 8.3 MB |
| `target.writeBytes(ab)` → C++ memcpy | into `CVPixelBuffer` | 8.3 MB |
| `appendPixelBuffer` | refcount only | 0 |

Three full-frame copies per frame, one of them a GPU→CPU readback (the
expensive one — the GPU has to flush and stall while the encoder reads).
This is the "pure CPU" path; it works on every Skia version and every
device but pays the readback cost.

---

## Path 3 — Skia, GPU optimized

Active when `surface.getNativeTextureUnstable()` returns a usable Metal
texture pointer. The native pump uses `MTLBlitCommandEncoder
copyFromTexture:toTexture:` to copy directly between GPU memory regions:
Skia's offscreen surface texture → the `CVPixelBuffer`'s IOSurface,
wrapped as a second `MTLTexture` via `CVMetalTextureCacheCreateTexture­
FromImage`.

Code locations:
- JS feature-detect + dispatch: `packages/react-native-video-pipeline-skia/src/drawWithSkia.ts:tryBlitFromSkiaTexture` (≈ line 179)
- Texture-info shape extraction: `extractMtlTexturePtr` (≈ line 215). Skia's `getNativeTextureUnstable` now returns a `TextureInfo` object with the Metal pointer at `.mtlTexture`; older versions returned the bigint directly. We accept either.
- The native blit: `packages/react-native-video-pipeline/ios/MetalBlit.mm`
- Frame-target → blit dispatch: `HybridFrameTarget.mm:blitFromNativeTexture`

Per-frame data flow at 1080p:

| step | what | bytes copied |
|---|---|---|
| Skia draw commands | rendered on GPU | 0 |
| `getNativeTextureUnstable()` | returns `TextureInfo` object; we extract the bigint | 0 |
| `target.blitFromNativeTexture(ptr)` | crosses Nitro as `bigint` | 0 |
| `MetalBlit blitFromMetalTexturePtr:toPixelBuffer:` | GPU-to-GPU copy via `MTLBlitCommandEncoder` | 0 (GPU-local) |
| `appendPixelBuffer` | refcount only | 0 |

Zero CPU-visible copies. The Skia object stays on the JS side — only the
Metal texture pointer (`bigint`) crosses the Nitro boundary; the C++ side
re-wraps it as an `MTLTexture` and blits.

This is the path the production demo uses. It's about 10% faster than the
CPU path on the simulator (where the encoder is the dominant cost) and
substantially faster on real devices with hardware H.264 (where the JS
roundtrip would otherwise dominate).

---

## Source path (compose-on-clip)

Compose-on-clip — decoded source frames + JS Skia draw — uses
`AVAssetReader` with `kCVPixelFormatType_32BGRA` decompressed output. Each
decoded `CVPixelBuffer` is wrapped in a `HybridFrameSource` (read-only,
non-owning view) and handed to the JS worklet via the `source` argument
to `drawFrame`. Skia builds an `SkImage` from it directly via
`Skia.Image.MakeImageFromNativeBuffer(source.bufferAddr)` — Skia
reinterprets the bigint as a `CVPixelBufferRef` and reads format / width
/ height off the wrapper. Zero copy.

Code locations:
- Reader setup + per-frame pump: `packages/react-native-video-pipeline/ios/VideoPipeline.mm:renderCompose` compose-on-clip branch
- Source wrapper: `packages/react-native-video-pipeline/ios/HybridFrameSource.{h,mm}`
- JS-side Skia integration: `packages/react-native-video-pipeline-skia/src/drawWithSkia.ts:makeSourceImage` — picks the native-buffer path when `bufferAddr !== 0n`

Combined with path 3 (GPU output), the entire compose-on-clip flow runs
without a single full-frame `memcpy` on iOS. The encoder, decoder, and
Skia all share the same IOSurface-backed `CVPixelBuffer`s end-to-end.

---

## Why iOS is the easy platform

The story is: *one buffer abstraction, used by everyone*.

- `CVPixelBuffer` is what `AVAssetReader` produces (when configured for
  decompressed output) and what `AVAssetWriterInputPixelBufferAdaptor`
  consumes.
- Its IOSurface backing is also a `MTLTexture` after wrapping via
  `CVMetalTextureCacheCreateTextureFromImage`, so Metal can read/write it.
- Skia's `MakeImageFromNativeBuffer` accepts a `CVPixelBufferRef` and
  reads pixel data through its IOSurface as well.

The iOS pipeline therefore moves a *pointer* across every layer (decoder,
worklet, encoder); the actual pixel data never leaves the IOSurface.
Y-orientation is consistent (top-down raster) at every layer, so there
are no flip surprises either.

The contrast on Android — multiple buffer types, Y-up vs Y-down convention
mismatch at every memory↔GPU boundary — is documented in
`rendering-android.md`.
