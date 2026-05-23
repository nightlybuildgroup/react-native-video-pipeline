// Nitro Module spec — SINGLE SOURCE OF TRUTH for every cross-boundary type in
// this library. JS, C++, Objective-C++ and Kotlin bindings are all generated
// from this file via `yarn nitrogen`. Never hand-edit files under `nitrogen/`;
// never hand-maintain parallel copies of these types anywhere else in the repo.
//
// Scope: type declarations + the HybridObject interface only. No runtime logic.

import type { HybridObject, UInt64 } from 'react-native-nitro-modules';

// ---------------------------------------------------------------------------
// Frame pump pointer types
// ---------------------------------------------------------------------------
//
// The compose / synthesize worklet path renders frames into a native
// IOSurface-backed pixel buffer (iOS CVPixelBuffer, Android AHardwareBuffer).
// The library does NOT import `@shopify/react-native-skia` — consumers who
// want a canvas helper reach for the sibling `react-native-video-pipeline-skia`
// package (T053a), which wraps the pointer API below. Framework-agnostic
// consumers can also write raw bytes directly.
//
// `bufferAddr` is a native pointer encoded as a `bigint` so it survives the
// worklets runtime boundary. The pointer is valid ONLY during the enclosing
// `FrameDrawer` call; the pump reclaims the buffer as soon as the drawer
// returns, so consumers must not retain it.

/** In-memory pixel layout of a FrameSource / FrameTarget buffer. */
export type PixelFormat = 'bgra8888' | 'rgba8888';

/**
 * Read-only view onto the current source frame (compose-on-clip path).
 * `undefined` on the null-input synthesize path — there is no source frame
 * to sample.
 *
 * Declared as a HybridObject (not just a TS shape) so the JS side can read
 * `bufferAddr` directly into Skia via
 * `Skia.Image.MakeImageFromNativeBuffer(source.bufferAddr)`. The native pump
 * holds a non-owning pointer to the decoded source pixel buffer; calling any
 * method after the per-frame callback returns throws `InvalidSpec`.
 */
export interface FrameSource extends HybridObject<{ ios: 'c++'; android: 'kotlin' }> {
  /**
   * Native handle to an IOSurface-backed (iOS) or AHardwareBuffer-backed
   * (Android, future) pixel buffer; pointer-width UInt64. On Android the
   * bare-example currently exposes 0 — consumers read pixels via `readBytes`
   * instead until the AHardwareBuffer + ImageReader plumbing lands.
   */
  readonly bufferAddr: UInt64;
  readonly width: number;
  readonly height: number;
  readonly format: PixelFormat;
  /**
   * Raster fallback for the source path: returns a freshly-allocated
   * ArrayBuffer with `width * height * 4` bytes of RGBA8888 pixel data,
   * top-down. Used by `drawWithSkia` on platforms where
   * `Skia.Image.MakeImageFromNativeBuffer(bufferAddr)` doesn't have a
   * cheap implementation (Android), so the helper drops to
   * `Skia.Image.MakeImage(info, data, stride)` instead.
   */
  readBytes(): ArrayBuffer;
}

/**
 * Write-only view onto the per-frame output pixel buffer the pump hands to
 * the worklet. The underlying buffer is the same CVPixelBuffer (iOS) /
 * AHardwareBuffer (Android) that the encoder appends on return — no
 * intermediate copy.
 *
 * Declared as a HybridObject so `writeBytes` and `blitFromNativeTexture` are
 * real JS-callable methods (not just a TS shape). The native pump allocates
 * one HybridObject per frame, hands it to the worklet, and invalidates it
 * when the worklet returns — calling either method on an invalidated handle
 * throws `InvalidSpec`.
 */
export interface FrameTarget extends HybridObject<{ ios: 'c++'; android: 'kotlin' }> {
  /** Native handle to the target pixel buffer; pointer-width UInt64. */
  readonly bufferAddr: UInt64;
  readonly width: number;
  readonly height: number;
  readonly format: PixelFormat;
  /**
   * Stable path: memcpy `bytes` into the target buffer. Length must match
   * `width * height * 4`; layout must match `format`.
   */
  writeBytes(bytes: ArrayBuffer): void;
  /**
   * iOS GPU fast path (T053b). Caller passes an `id<MTLTexture>` pointer
   * obtained via Skia's `getNativeTextureUnstable()`; the native pump uses
   * `CVMetalTextureCacheCreateTextureFromImage` to wrap this `FrameTarget`'s
   * backing `CVPixelBuffer` as a second `MTLTexture` on the same system
   * device Skia uses, then issues an `MTLBlitCommandEncoder
   * copyFromTexture:toTexture:` — zero CPU readback. The worklet-side helper
   * `drawWithSkia` feature-detects this method and falls back to
   * `writeBytes` on platforms where the pump has not implemented the fast
   * path (Android today; future native targets without Metal).
   */
  blitFromNativeTexture(mtlTexturePtr: UInt64): void;
}

// ---------------------------------------------------------------------------
// Spec (what the caller hands to render) — see `docs/api.md`.
// ---------------------------------------------------------------------------

export interface VideoSpec {
  output: OutputSpec;
  /** Omit or empty → synthesized (only valid via `Video.synthesize`, which carries `drawFrame` as a Nitro arg, not as an overlay). */
  clips?: Clip[];
  /** Native overlays — image + text. JS-side per-frame drawing goes through `Video.compose` / `Video.synthesize`, never through this list. */
  overlays?: NativeOverlay[];
  audio?: AudioSpec;
  metadata?: MetadataSpec;
  /** Required when `clips` is omitted or empty; ignored otherwise. */
  duration?: DurationSpec;
}

/** Controls when a render without source clips ends. */
export type DurationSpec = FixedDuration | OpenDuration;

/**
 * Shared discriminant for `DurationSpec`. Declared as a standalone enum-style
 * union (rather than inline `mode: 'fixed'` literals per struct) because
 * Nitrogen can only represent string literals when they are part of a named
 * enum-like union. Downstream public-API wrappers narrow `mode` back to its
 * specific literal so TypeScript `switch` exhaustiveness still works.
 */
export type DurationMode = 'fixed' | 'open';

export interface FixedDuration {
  mode: DurationMode;
  seconds: number;
}

export interface OpenDuration {
  mode: DurationMode;
  maxSeconds?: number;
}

export interface OutputSpec {
  path: string;
  /** Omit → inherit from first clip; REQUIRED when `clips` is empty. */
  width?: number;
  /** REQUIRED when `clips` is empty. */
  height?: number;
  /** REQUIRED when `clips` is empty. */
  fps?: number;
  /** bits per second. */
  bitrate?: number;
  /** default: `'h264'`. */
  codec?: VideoCodec;
  container?: VideoContainer;
}

export type VideoCodec = 'h264' | 'hevc';
export type VideoContainer = 'mp4' | 'mov';

export interface Clip {
  uri: string;
  /** seconds into source. */
  sourceStart: number;
  sourceDuration: number;
  /** seconds on output timeline. */
  outputStart: number;
  transform?: ClipTransform;
}

export interface ClipTransform {
  rotate?: Rotation;
  flipH?: boolean;
  flipV?: boolean;
  /** source-pixel coordinates. */
  crop?: CropRect;
}

export type Rotation = 0 | 90 | 180 | 270;

export interface CropRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** Overlay union — image + text. JS-drawn frames go through `renderCompose`, not through this list. */
export type Overlay = ImageOverlay | TextOverlay;

/** Alias retained for clarity at the native boundary; identical to `Overlay`. */
export type NativeOverlay = Overlay;

/**
 * Shared discriminant for `Overlay`. Same rationale as `DurationMode` — the
 * native boundary sees `kind` as a named enum, and the public-API wrapper
 * narrows it per-variant.
 */
export type OverlayKind = 'image' | 'text';

export interface ImageOverlay {
  kind: OverlayKind;
  uri: string;
  anchor: Anchor;
  size: Size;
  opacity?: number;
  timeRange?: TimeRange;
}

export interface TextOverlay {
  kind: OverlayKind;
  text: string;
  style: TextStyle;
  anchor: Anchor;
  timeRange?: TimeRange;
}

/**
 * At the native boundary, anchors are always normalized points. The public
 * `Overlay.*` builders (T010) and the `Video.*` wrapper (T012) expand the
 * user-friendly `AnchorPreset` ('tl', 'center', …) shorthand into a
 * `AnchorPoint` before crossing the Nitro boundary — Nitro cannot represent a
 * `'tl' | 'tr' | … | { x; y }` mixed union.
 */
export type Anchor = AnchorPoint;

/** Public-API shorthand; normalized client-side into `AnchorPoint`. */
export type AnchorPreset = 'tl' | 'tr' | 'bl' | 'br' | 'center';

/**
 * Normalized 0–1 slot position for an overlay within the *free space* of
 * the output frame (`outputDim - overlayDim`):
 *
 * - `(0, 0)` aligns the overlay's top-left with the frame's top-left
 * - `(1, 1)` aligns the overlay's bottom-right with the frame's bottom-right
 * - `(0.5, 0.5)` centers the overlay
 *
 * Values outside `[0, 1]` are honoured (the overlay can land partly or
 * wholly outside the frame). Anchors do *not* address an arbitrary point
 * on the overlay — they always align corresponding edges. To anchor by
 * the overlay's center, use `Anchor.center`.
 */
export interface AnchorPoint {
  x: number;
  y: number;
}

/** At least one of `w`/`h` must be provided; the other scales proportionally. */
export interface Size {
  w?: number;
  h?: number;
}

/**
 * `[startSec, endSec]` on the output timeline. Represented as a struct at the
 * Nitro boundary because Kotlin codegen does not yet support TypeScript tuple
 * types.
 */
export interface TimeRange {
  startSec: number;
  endSec: number;
}

/**
 * Rendered natively (CATextLayer on iOS, Media3 TextOverlay on Android).
 * Intentionally minimal — advanced typography is out of scope. Users who need
 * pixel-identical cross-platform text should rasterize a PNG themselves and
 * pass it as `Overlay.Image` (see `docs/api.md` recipe).
 */
export interface TextStyle {
  /** Falls back to platform default when omitted. */
  fontFamily?: string;
  fontSize: number;
  /** hex or rgba string. */
  color: string;
  weight?: FontWeight;
  align?: TextAlign;
  shadow?: TextShadow;
}

export type FontWeight = 'regular' | 'bold';
export type TextAlign = 'left' | 'center' | 'right';

export interface TextShadow {
  color: string;
  blur: number;
  dx: number;
  dy: number;
}

export interface AudioSpec {
  mode: AudioMode;
  /** Required when `mode === 'replace'`. */
  replaceUri?: string;
}

export type AudioMode = 'passthrough' | 'mute' | 'replace';

export interface MetadataSpec {
  location?: WGS84Coordinate;
  software?: string;
  creationDate?: Date;
  description?: string;
  custom?: Record<string, string>;
}

/**
 * Geographic coordinate in the WGS-84 reference system. Container muxers
 * (iOS AVAssetWriter, Android MediaMuxer) serialise this as an ISO 6709
 * string in the file's `udta/©xyz` (or `udta/loci`) atom — the same format
 * every consumer device writes. The field is named `location` to match
 * AVFoundation's `AVMetadataCommonKeyLocation` and the Photos / EXIF UI
 * vocabulary every consumer already knows.
 *
 * The TYPE keeps the `WGS84Coordinate` name because what's contractually
 * promised is the datum (WGS-84), not the sensor: the source can be any
 * GNSS constellation (GPS, GLONASS, Galileo, BeiDou, QZSS, …) or even a
 * non-satellite resolver (cell, WiFi) that has been corrected back to
 * WGS-84.
 */
export interface WGS84Coordinate {
  latitude: number;
  longitude: number;
  /**
   * Altitude in metres above the WGS-84 ellipsoid. Optional — both writers
   * (probe-callers writing via `MetadataSpec.location`) and probe consumers
   * should treat its absence as "no altitude in source", not "altitude is
   * zero". The ISO 6709 short form serialised into the file's `udta/©xyz`
   * atom encodes altitude as an optional third token.
   *
   * Android caveat: the Media3 muxer's `setLocation(lat, lon)` API only
   * accepts two coordinates. Stamping with altitude on Android currently
   * drops the altitude silently; iOS writes the full triple. Probing
   * altitude works on both platforms when the source carries it.
   */
  altitude?: number;
}

// ---------------------------------------------------------------------------
// Probe results
// ---------------------------------------------------------------------------

export interface VideoInfo {
  uri: string;
  durationSec: number;
  /**
   * Displayed dimensions — what a viewer sees, after the container's
   * rotation metadata is applied. For a portrait phone recording with
   * `rotation: 90`, `width` is the short side and `height` the long
   * side, matching what `AVPlayer` / `ExoPlayer` / Photos.app render.
   *
   * For the pre-rotation pixel grid (matches `AVAssetTrack.naturalSize`
   * on iOS and `MediaFormat.KEY_WIDTH/HEIGHT` on Android), use
   * `codedWidth` / `codedHeight`. Naming follows the WebCodecs
   * convention (`VideoFrame.codedWidth` vs `displayWidth`).
   */
  width: number;
  height: number;
  /**
   * Pre-rotation encoded sample grid — the "coded picture" dimensions
   * in H.264/H.265 spec language. Required when constructing
   * `ClipTransform.crop`, which is documented as source-pixel
   * coordinates (i.e. coded-space).
   *
   * For unrotated content `codedWidth === width` and
   * `codedHeight === height`; for `rotation: 90 | 270` they are
   * swapped relative to `width`/`height`.
   */
  codedWidth: number;
  codedHeight: number;
  fps: number;
  bitRate: number;
  /**
   * Size of the underlying file in bytes. Sourced from the filesystem
   * (`NSFileManager` on iOS, `File.length()` on Android), not from the
   * container — so this is the raw on-disk size including all metadata
   * atoms, not the size implied by `bitRate * durationSec`.
   */
  fileSizeBytes: number;
  codec: string;
  container: string;
  hasAudio: boolean;
  isHDR: boolean;
  rotation: Rotation;
  creationDate?: Date;
  location?: WGS84Coordinate;
  /**
   * Container-level description (`AVMetadataCommonKeyDescription` on iOS,
   * `udta/©cmt`-equivalent on Android). Read symmetric with the write side
   * via `MetadataSpec.description`.
   *
   * Android caveat: surfacing this requires walking the MP4 box tree
   * directly (MediaMetadataRetriever has no DESCRIPTION key) — currently
   * not implemented, so Android probes always return undefined here.
   */
  description?: string;
  custom?: Record<string, string>;
}

export interface EncoderCaps {
  codecs: VideoCodec[];
  maxWidth: number;
  maxHeight: number;
  maxFps: number;
  maxBitrate: number;
  hdr: boolean;
}

export interface ThumbnailOptions {
  atSec: number;
  outPath: string;
  resizeTo?: Size;
}

// ---------------------------------------------------------------------------
// Control surfaces
// ---------------------------------------------------------------------------

export interface RenderOptions {
  /** Abort → discard output and reject with `Cancelled`. */
  signal?: AbortSignal;
  /** Graceful finish for open-ended renders; see `VideoRenderController`. */
  controller?: VideoRenderController;
  onProgress?: (p: Progress) => void;
  /** default: `'interactive'`. */
  priority?: RenderPriority;
}

export type RenderPriority = 'interactive' | 'background';

/**
 * Handle for graceful end-of-stream on open-ended renders.
 *
 * Distinct from `AbortSignal`: `abort()` throws the file away, `finish()`
 * finalizes it. On fixed-duration renders `finish()` is a no-op.
 */
export interface VideoRenderController {
  /** Stop after the current frame; resolve the render promise normally. */
  finish(): void;
  /** Cancel and discard; render rejects with `Cancelled`. */
  abort(): void;
  readonly state: RenderControllerState;
}

export type RenderControllerState = 'running' | 'finishing' | 'aborted' | 'done';

export interface Progress {
  framesCompleted: number;
  /** `undefined` for open-ended renders until `finish()` is called. */
  nbFrames?: number;
  elapsedMs: number;
  /** `undefined` when `nbFrames` is unknown. */
  estimatedRemainingMs?: number;
}

// ---------------------------------------------------------------------------
// Worklet
// ---------------------------------------------------------------------------

export type FrameDrawer = (ctx: FrameDrawerContext) => void;

export interface FrameDrawerContext {
  /**
   * Pre-allocated per-frame write target backed by the same IOSurface /
   * AHardwareBuffer the native encoder will append on return — zero-copy.
   */
  target: FrameTarget;
  /**
   * Current source frame (compose-on-clip path only). `undefined` on the
   * null-input synthesize path.
   */
  source?: FrameSource;
  /** 0-based output frame counter. */
  frameIndex: number;
  /** Seconds on the output timeline — deterministic, `frameIndex / fps`. */
  timeSec: number;
  /**
   * Wall-clock milliseconds since render start. Useful for worklets that want
   * to self-terminate based on real time independent of output fps (offline
   * render speed ≠ output speed).
   */
  elapsedMs: number;
  width: number;
  height: number;
  /** Worklet-side graceful stop (open-ended renders only); no-op otherwise. */
  finish(): void;
}

// ---------------------------------------------------------------------------
// Errors — see `docs/api.md`. Exhaustive literal union on `code`; runtime class
// and helpers live in `src/errors.ts` (T009).
// ---------------------------------------------------------------------------

export type VideoPipelineErrorCode =
  | 'UnsupportedCodec'
  | 'DeviceCapabilityExceeded'
  | 'SourceCorrupted'
  | 'Cancelled'
  | 'IOError'
  | 'EncoderFailure'
  | 'InvalidSpec';

export interface VideoPipelineErrorShape {
  name: 'VideoPipelineError';
  code: VideoPipelineErrorCode;
  message: string;
  details?: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// HybridObject — the native-facing surface. JS-side `AbortSignal` and
// `VideoRenderController` from `RenderOptions` are translated by the wrapper
// in `src/video.ts` (T012) into the `renderToken` + `cancelRender` pair
// below; the worklet surfaces in `Video.compose`/`Video.synthesize` are wired
// through Reanimated and never cross the Nitro boundary as plain functions.
// ---------------------------------------------------------------------------

export interface VideoPipeline extends HybridObject<{ ios: 'c++'; android: 'kotlin' }> {
  // --- Probe --------------------------------------------------------------
  info(uri: string): Promise<VideoInfo>;
  thumbnail(uri: string, options: ThumbnailOptions): Promise<string>;
  capabilities(): Promise<EncoderCaps>;

  // --- Remux / transcode / compose (auto-routed) --------------------------
  /**
   * Token identifies the in-flight render for progress callbacks and for
   * `cancelRender`. Empty string when the caller does not need cancellation.
   */
  render(spec: VideoSpec, renderToken: string, onProgress?: (p: Progress) => void): Promise<void>;

  /** Cancel a running render keyed by its `renderToken`. Idempotent. */
  cancelRender(renderToken: string): void;

  /** Gracefully finish a running open-ended render. Idempotent. */
  finishRender(renderToken: string): void;

  // --- Convenience wrappers kept on the native side so routing decisions
  //     live in C++ (`docs/api.md` — Routing rules) rather than being split
  //     between JS and C++. ----------------------------------------------
  trim(
    uri: string,
    outPath: string,
    startSec: number,
    durationSec: number,
    transform: ClipTransform | undefined,
    renderToken: string,
  ): Promise<void>;

  flip(uri: string, outPath: string, axis: FlipAxis, renderToken: string): Promise<void>;

  stamp(
    uri: string,
    outPath: string,
    watermark: NativeOverlay | undefined,
    metadata: MetadataSpec | undefined,
    renderToken: string,
  ): Promise<void>;

  /**
   * Compose path — native pump invokes `drawFrame` per frame with a
   * live-for-this-call `FrameTarget` HybridObject and the current frame
   * index / time. The worklet writes into the target via `writeBytes` or
   * `blitFromNativeTexture`. `VideoRenderController.finish()` from JS
   * signals graceful end-of-stream for open-ended renders.
   *
   * The flat-argument shape (target + frameIndex + timeSec) is what crosses
   * Nitro; the richer consumer-facing `FrameDrawerContext` (source, finish,
   * elapsedMs, width, height) is reconstructed by the JS wrapper in
   * `src/video.ts` before invoking the user's `FrameDrawer`.
   *
   * `drawFrame` returns `boolean` (not `void`) so Nitro picks `SyncJSCallback`
   * — a `void`-returning function would be routed through `AsyncJSCallback`
   * which dispatches to JS asynchronously and the native pump would continue
   * before the worklet has actually written into the `FrameTarget`. The
   * return value is currently ignored; it's reserved for a future
   * "keep-rendering" signal on open-ended renders. The JS wrapper in
   * `src/video.ts` always returns `true` so consumer `FrameDrawer`s can keep
   * the documented `(ctx) => void` contract.
   */
  renderCompose(
    spec: VideoSpec,
    renderToken: string,
    drawFrame: (
      target: FrameTarget,
      source: FrameSource | undefined,
      frameIndex: number,
      timeSec: number,
    ) => boolean,
    onProgress?: (p: Progress) => void,
  ): Promise<void>;
}

export type FlipAxis = 'horizontal' | 'vertical';
