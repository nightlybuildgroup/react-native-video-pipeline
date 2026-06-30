import type { SkCanvas, SkImage, SkSurface } from '@shopify/react-native-skia';
import { AlphaType, ColorType, Skia } from '@shopify/react-native-skia';
import type { FrameDrawerContext } from 'react-native-video-pipeline';

/**
 * Consumer callback: receives the Skia canvas and the frame context; may
 * issue any Skia drawing commands. Must be a worklet — the helper runs on
 * the Worklets UI runtime because Ganesh (Skia's GPU backend) is single-
 * threaded and all Skia calls must stay on the same thread.
 */
export type SkiaDrawCallback = (canvas: SkCanvas, ctx: FrameDrawerContext) => void;

/**
 * Wrap a Skia drawing callback into a `FrameDrawer` compatible with
 * `Video.compose` / `Video.synthesize`. Hides the offscreen surface,
 * snapshot, `readPixels`, and `writeBytes` boilerplate so consumer code
 * stays ~4 lines.
 *
 * Two backends share the same consumer API — the helper picks one per frame:
 *
 *   - **GPU fast path (T053b, iOS):** when `surface.getNativeTextureUnstable`
 *     is available and returns a usable `bigint` pointer, call
 *     `ctx.target.unstable_blitFromNativeTexture(ptr)`. Zero CPU readback —
 *     the native pump `MTLBlit`s Skia's backing texture straight into the
 *     IOSurface-backed `CVPixelBuffer` that the encoder will append.
 *   - **CPU readback path (T053, any platform):** `makeImageSnapshot()` →
 *     `readPixels()` → `ctx.target.writeBytes(bytes)`. Stable, portable.
 *
 * Feature detection is per-frame because a Skia version upgrade or a
 * synthetic-override test harness can change availability at runtime.
 * If `getNativeTextureUnstable` returns something that isn't a non-zero
 * `bigint`, the helper warns once and falls back to the CPU path rather
 * than passing a bogus handle into native.
 *
 * Source handling is shared: when `ctx.source !== undefined` the source
 * `SkImage` is drawn at `(0, 0)` before the user callback, so consumers
 * layer on top rather than fighting a default-clear. On the GPU path the
 * source draw lands in Skia's texture before the blit picks it up.
 *
 * Dispose order in `finally`: snapshot (if created) → sourceImage (if
 * created) → surface. Each `dispose` is guarded by a `typeof ===
 * 'function'` check because Skia v1 and very old v2 builds expose a subset
 * of the dispose surface.
 */
export function drawWithSkia(draw: SkiaDrawCallback): (ctx: FrameDrawerContext) => void {
  return (ctx: FrameDrawerContext) => {
    'worklet';
    const surface: SkSurface | null = Skia.Surface.MakeOffscreen(ctx.width, ctx.height);
    if (surface === null) {
      throw new Error(
        `drawWithSkia: Skia.Surface.MakeOffscreen returned null for ${ctx.width}x${ctx.height}`,
      );
    }
    let sourceImage: SkImage | null = null;
    let snapshot: SkImage | null = null;
    try {
      const canvas = surface.getCanvas();
      if (ctx.source !== undefined) {
        sourceImage = makeSourceImage(ctx.source);
        if (sourceImage !== null) {
          canvas.drawImage(sourceImage, 0, 0);
        }
      }
      draw(canvas, ctx);
      surface.flush();

      if (tryBlitFromSkiaTexture(surface, ctx)) {
        return;
      }

      snapshot = surface.makeImageSnapshot();
      const colorType =
        ctx.target.format === 'bgra8888' ? ColorType.BGRA_8888 : ColorType.RGBA_8888;
      const pixels = snapshot.readPixels(0, 0, {
        width: ctx.width,
        height: ctx.height,
        colorType,
        alphaType: AlphaType.Premul,
      });
      if (pixels === null) {
        throw new Error('drawWithSkia: snapshot.readPixels returned null');
      }
      const ab = pixels.buffer.slice(
        pixels.byteOffset,
        pixels.byteOffset + pixels.byteLength,
      ) as ArrayBuffer;
      ctx.target.writeBytes(ab);
    } finally {
      if (snapshot !== null && typeof snapshot.dispose === 'function') {
        snapshot.dispose();
      }
      if (sourceImage !== null && typeof sourceImage.dispose === 'function') {
        sourceImage.dispose();
      }
      if (typeof surface.dispose === 'function') {
        surface.dispose();
      }
    }
  };
}

/**
 * Build an SkImage for the current source frame. Two paths:
 *
 *   - **Native-buffer path** (iOS, optimal): Skia reinterprets
 *     `unstable_bufferAddr` as a `CVPixelBufferRef` and reads format/dims
 *     off the wrapper. Zero-copy — the SkImage references the IOSurface
 *     directly.
 *   - **Raster fallback** (Android, today): `unstable_bufferAddr === 0`
 *     indicates the platform doesn't expose a Skia-friendly native handle; pull
 *     RGBA bytes via `readBytes()` and build a raster SkImage with
 *     `Skia.Image.MakeImage(info, data, stride)`. One memcpy per frame.
 *
 * Either way the consumer's worklet sees a regular SkImage.
 */
// biome-ignore lint/suspicious/noExplicitAny: FrameSource is a Nitro HybridObject — its dynamic shape is platform-specific.
function makeSourceImage(source: any): SkImage | null {
  'worklet';
  if (typeof source.unstable_bufferAddr === 'bigint' && source.unstable_bufferAddr !== 0n) {
    // The native side returns a signed 64-bit Long. Skia's
    // `MakeImageFromNativeBuffer` calls `asUint64` and rejects negative
    // BigInts ("Lossy truncation"), which trips on Android AHardwareBuffer
    // pointers in the high half of the address space (high bit set →
    // negative when interpreted signed). `asUintN(64, …)` reinterprets the
    // bits as unsigned without changing the underlying pointer value, so
    // this is a no-op for iOS CVPixelBufferRefs that already fit in 63 bits.
    return Skia.Image.MakeImageFromNativeBuffer(BigInt.asUintN(64, source.unstable_bufferAddr));
  }
  if (typeof source.readBytes !== 'function') return null;
  const bytes = source.readBytes();
  if (!(bytes instanceof ArrayBuffer)) return null;
  const data = Skia.Data.fromBytes(new Uint8Array(bytes));
  const w = Math.round(source.width);
  const h = Math.round(source.height);
  const colorType = source.format === 'bgra8888' ? ColorType.BGRA_8888 : ColorType.RGBA_8888;
  const img = Skia.Image.MakeImage(
    {
      width: w,
      height: h,
      colorType,
      alphaType: AlphaType.Premul,
    },
    data,
    w * 4,
  );
  return img;
}

/**
 * Warn at most once per process for a given message. Per-frame worklet
 * execution means a shape-drift condition would otherwise spam the console
 * at the output fps. A plain module-scope `Set` (captured by value into the
 * worklet closure, like `Skia` itself) — NOT a cross-worklet function call,
 * which is exactly the thing that breaks below.
 */
const warnedMessages: Set<string> = new Set();

/**
 * GPU fast path (T053b). Returns `true` when the blit succeeded and the
 * caller should skip the `readPixels` / `writeBytes` CPU path.
 *
 * `surface.getNativeTextureUnstable()` is intentionally undocumented and
 * has changed shape across Skia releases. Two known shapes:
 *
 *   1. Older Skia: returned a raw `bigint` containing the `id<MTLTexture>`
 *      pointer directly.
 *   2. Newer Skia (current): returns a `TextureInfo`-style object with the
 *      Metal pointer under the `mtlTexture` key plus a handful of GL fields
 *      we don't care about on iOS.
 *
 * We accept either, extract the bigint, and pass it across Nitro. Anything
 * else (function-shape moved again, throw, null) drops to the CPU path with
 * a one-shot warning. The Skia object itself is never sent across Nitro — we
 * extract the primitive on the JS side.
 *
 * The `SMOKE_FORCE_CPU_READBACK` env var forces the CPU path even when the
 * GPU path is available — used by the `yarn smoke:ios` harness to compare
 * GPU-vs-CPU output bit-identically. Read per-call because Jest flips the env
 * across tests and the per-frame cost is a single property lookup.
 *
 * **Everything is inlined into this one worklet body — no calls out to other
 * module-scope helpers.** react-native-worklets-core drops nested
 * worklet-to-worklet references when this package is consumed pre-built from
 * `node_modules`: a helper that is itself a `'worklet'` and is called from
 * inside another worklet resolves to `undefined` on the UI runtime and
 * throws at frame 0 (issue #75 — `extractMtlTexturePtr is not a function`).
 * Capturing a value (the `warnedMessages` Set, `Skia`, `console`) is fine;
 * *calling* a sibling worklet is not. Keep this self-contained.
 */
function tryBlitFromSkiaTexture(surface: SkSurface, ctx: FrameDrawerContext): boolean {
  'worklet';

  // SMOKE_FORCE_CPU_READBACK forces the CPU path even when GPU is wired.
  // Checked first so `getNativeTextureUnstable` is not even invoked.
  try {
    // biome-ignore lint/suspicious/noExplicitAny: globalThis.process is Node-only; any cast keeps the file RN-runtime safe.
    const env = (globalThis as any)?.process?.env;
    const raw = env?.SMOKE_FORCE_CPU_READBACK;
    if (typeof raw === 'string') {
      const v = raw.toLowerCase();
      if (v === '1' || v === 'true' || v === 'yes') return false;
    }
  } catch {
    // Ignore — absence of process.env just means "not forced".
  }

  const getTex = surface.getNativeTextureUnstable;
  const blit = ctx.target.unstable_blitFromNativeTexture;
  if (typeof getTex !== 'function' || typeof blit !== 'function') {
    return false;
  }

  // Extract the iOS `id<MTLTexture>` pointer out of whatever shape Skia hands
  // back: a raw `bigint` (older Skia) or `{ mtlTexture: bigint, ... }`
  // (current). Anything else → CPU fallback. Inlined; see header note.
  let handle: bigint | null = null;
  let raw: unknown;
  let threw = false;
  try {
    raw = getTex.call(surface);
  } catch {
    threw = true;
  }
  if (typeof raw === 'bigint') {
    handle = raw === 0n ? null : raw;
  } else if (raw !== null && typeof raw === 'object') {
    // biome-ignore lint/suspicious/noExplicitAny: Skia's TextureInfo isn't typed in their public d.ts (return is `unknown`); narrow defensively here.
    const mtl = (raw as any).mtlTexture;
    if (typeof mtl === 'bigint' && mtl !== 0n) handle = mtl;
  }

  if (handle === null) {
    let msg: string;
    if (threw) {
      msg = 'drawWithSkia: surface.getNativeTextureUnstable threw; falling back to CPU readback.';
    } else {
      // Inline shape description so a future shape-drift surfaces in the warning.
      let shape: string;
      if (raw === null) shape = 'null';
      else if (raw === undefined) shape = 'undefined';
      else if (typeof raw !== 'object') shape = typeof raw;
      // biome-ignore lint/suspicious/noExplicitAny: TextureInfo is untyped — Object.keys is the diagnostic primitive here.
      else shape = `object{${Object.keys(raw as any).join(',')}}`;
      msg =
        'drawWithSkia: surface.getNativeTextureUnstable returned an unexpected shape; falling back to CPU readback. Got ' +
        shape;
    }
    if (!warnedMessages.has(msg)) {
      warnedMessages.add(msg);
      console.warn(msg);
    }
    return false;
  }

  try {
    blit.call(ctx.target, handle);
    return true;
  } catch (err) {
    const msg =
      'drawWithSkia: FrameTarget.unstable_blitFromNativeTexture threw; falling back to CPU readback. ' +
      String(err);
    if (!warnedMessages.has(msg)) {
      warnedMessages.add(msg);
      console.warn(msg);
    }
    return false;
  }
}
