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
 * else (function-shape moved again, throw, null) drops to the CPU path
 * with a one-shot warning. The Skia object itself is never sent across
 * Nitro — we extract the primitive on the JS side.
 *
 * The `SMOKE_FORCE_CPU_READBACK` env var forces the CPU path even when the
 * GPU path is available — used by the `yarn smoke:ios` harness to compare
 * GPU-vs-CPU output bit-identically (closes one T053b-deferred verification
 * bullet). Read per-call because Jest flips the env across tests and the
 * per-frame cost is a single property lookup.
 */
function isCpuReadbackForced(): boolean {
  'worklet';
  try {
    // biome-ignore lint/suspicious/noExplicitAny: globalThis.process is Node-only; any cast keeps the file RN-runtime safe.
    const env = (globalThis as any)?.process?.env;
    const raw = env?.SMOKE_FORCE_CPU_READBACK;
    if (typeof raw !== 'string') return false;
    const v = raw.toLowerCase();
    return v === '1' || v === 'true' || v === 'yes';
  } catch {
    return false;
  }
}

function tryBlitFromSkiaTexture(surface: SkSurface, ctx: FrameDrawerContext): boolean {
  'worklet';
  if (isCpuReadbackForced()) {
    return false;
  }
  const getTex = surface.getNativeTextureUnstable;
  const blit = ctx.target.unstable_blitFromNativeTexture;
  if (typeof getTex !== 'function' || typeof blit !== 'function') {
    return false;
  }
  let raw: unknown;
  try {
    raw = getTex.call(surface);
  } catch {
    warnOnce('drawWithSkia: surface.getNativeTextureUnstable threw; falling back to CPU readback.');
    return false;
  }
  const handle = extractMtlTexturePtr(raw);
  if (handle === null) {
    warnOnce(
      'drawWithSkia: surface.getNativeTextureUnstable returned an unexpected shape; falling back to CPU readback. Got ' +
        describeShape(raw),
    );
    return false;
  }
  try {
    blit.call(ctx.target, handle);
    return true;
  } catch (err) {
    warnOnce(
      'drawWithSkia: FrameTarget.unstable_blitFromNativeTexture threw; falling back to CPU readback. ' +
        String(err),
    );
    return false;
  }
}

/**
 * Pull the iOS `id<MTLTexture>` pointer out of whatever shape Skia hands
 * back. Returns `null` for any shape we don't recognize so the caller
 * drops to the CPU path. The current expected shape is `{ mtlTexture:
 * bigint, ... }`; the older one was just `bigint`.
 */
function extractMtlTexturePtr(raw: unknown): bigint | null {
  'worklet';
  if (typeof raw === 'bigint') {
    return raw === 0n ? null : raw;
  }
  if (raw !== null && typeof raw === 'object') {
    // biome-ignore lint/suspicious/noExplicitAny: Skia's TextureInfo isn't typed in their public d.ts (return is `unknown`); narrow defensively here.
    const mtl = (raw as any).mtlTexture;
    if (typeof mtl === 'bigint' && mtl !== 0n) return mtl;
  }
  return null;
}

function describeShape(raw: unknown): string {
  'worklet';
  if (raw === null) return 'null';
  if (typeof raw !== 'object') return typeof raw;
  // List the keys so a future shape-drift surfaces in the warning message.
  // biome-ignore lint/suspicious/noExplicitAny: TextureInfo is untyped — Object.keys is the diagnostic primitive here.
  return 'object{' + Object.keys(raw as any).join(',') + '}';
}

/**
 * Warn at most once per process for a given message. Per-frame worklet
 * execution means a shape-drift condition would otherwise spam the console
 * at the output fps. Lives outside the worklet closure so the dedup set is
 * shared across every frame call.
 */
const warnedMessages: Set<string> = new Set();
function warnOnce(message: string): void {
  'worklet';
  if (warnedMessages.has(message)) {
    return;
  }
  warnedMessages.add(message);
  console.warn(message);
}
