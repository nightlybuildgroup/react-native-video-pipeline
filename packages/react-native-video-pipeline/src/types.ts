/**
 * Public-facade types with literal discriminants and stricter constraints
 * than the Nitro spec can express. These are the types consumers see; the
 * wrapper in `./video.ts` is structurally compatible with the Nitro
 * `VideoSpec` because every public literal is a subtype of the Nitro
 * named-union (e.g. `'fixed'` is a subtype of `'fixed' | 'open'`), so no
 * runtime conversion is required at the boundary.
 */

import type { VideoRenderController } from './controller';
import type {
  ClipTransform,
  MetadataSpec,
  OutputSpec as NativeOutputSpec,
  Progress,
  TimeRange,
  TrackFrame,
  WGS84Coordinate,
} from './nitro/VideoPipeline.nitro';
import type { Overlay } from './overlay';

// ---------------------------------------------------------------------------
// Duration
// ---------------------------------------------------------------------------

export interface FixedDuration {
  mode: 'fixed';
  seconds: number;
}

export interface OpenDuration {
  mode: 'open';
  maxSeconds?: number;
}

export type DurationSpec = FixedDuration | OpenDuration;

// ---------------------------------------------------------------------------
// Audio — discriminated so `mode: 'replace'` requires `replaceUri`.
// ---------------------------------------------------------------------------

export type AudioSpec =
  | { mode: 'passthrough' }
  | { mode: 'mute' }
  | { mode: 'replace'; replaceUri: string };

// ---------------------------------------------------------------------------
// Size — at least one of `w`/`h` required. Pixel-only; used by
// `ThumbnailOptions.resizeTo`. Overlay sizing uses the richer
// `OverlaySize` (tagged px/ratio) below.
// ---------------------------------------------------------------------------

export type Size = { w: number; h?: number } | { w?: number; h: number };

// ---------------------------------------------------------------------------
// OverlaySize — tagged units for ImageOverlay sizing. Each axis carries
// an explicit unit so callers don't have to guess whether the library
// reads numbers as pixels or as ratios.
// ---------------------------------------------------------------------------

/** One dimension expressed as either absolute output pixels or a fraction
 *  of the corresponding output canvas dimension. */
export type Dim = { unit: 'px'; value: number } | { unit: 'ratio'; value: number };

/**
 * Width/height for `Overlay.Image.size`. Public-facade keys are
 * `width`/`height` (matching CSS-style vocabulary); the builder in
 * `./overlay` normalizes these into the Nitro `{ w, h }` boundary shape.
 * At least one axis must be provided.
 */
export type OverlaySize = { width: Dim; height?: Dim } | { width?: Dim; height: Dim };

// ---------------------------------------------------------------------------
// Output — stricter variant for synthesize where w/h/fps are mandatory.
// ---------------------------------------------------------------------------

export type OutputSpec = NativeOutputSpec;

export type SynthesizeOutputSpec = OutputSpec & {
  width: number;
  height: number;
  fps: number;
};

// ---------------------------------------------------------------------------
// Spec facades — narrower than the Nitro `VideoSpec` so the type system
// distinguishes the three public entry points (`render`, `compose`,
// `synthesize`) instead of relying on runtime rejection.
// ---------------------------------------------------------------------------

/**
 * Compile-time non-empty array. Used by `RenderSpec.clips` and
 * `ComposeSpec.clips` so callers cannot construct a clip-less spec at the
 * type level — the equivalent runtime check used to reject those at
 * `Video.render` / `Video.compose`. Built as a tuple so element access at
 * index `0` is `T`, not `T | undefined` under `noUncheckedIndexedAccess`.
 */
export type NonEmptyArray<T> = [T, ...T[]];

/**
 * Concat-style clip input. Clips are stitched end-to-end in array order:
 * the first clip starts at output time `0`, the next picks up where the
 * previous one ended, and so on. The library normalizes `ClipInput[]`
 * into the Nitro boundary shape (`sourceStart`, `sourceDuration`,
 * `outputStart`) at the JS layer.
 *
 * - `startSec` defaults to `0` — start at the beginning of the source.
 * - `durationSec` defaults to "remaining source duration", which the
 *   library resolves by probing the source via `Video.info`. Provide it
 *   explicitly to skip the probe.
 */
export interface ClipInput {
  uri: string;
  /** Seconds into the source. Defaults to `0`. */
  startSec?: number;
  /** Seconds of source to include. Defaults to "rest of source". */
  durationSec?: number;
  transform?: ClipTransform;

  // --- Forward-compatibility timeline hooks --------------------------------
  // These three fields reserve public field names for a richer timeline
  // (gaps, multi-track, transitions, clip-targeted overlays) without
  // committing to that feature surface yet. v0.1 accepts only
  // concat-compatible values and rejects everything else with
  // `InvalidSpecError` — field *presence* is not a feature flag.

  /**
   * Stable identifier for this clip. Surfaced as `FrameDrawerContext.clipId`
   * on the compose path and reserved for future clip-targeted features
   * (overlays bound to a clip, transition endpoints). Must be unique within
   * a single spec. Optional — most callers can omit it.
   */
  id?: string;
  /**
   * Explicit position on the output timeline, in seconds.
   *
   * Omit it to accept the computed concat position (each clip picks up where
   * the previous ended). A value **beyond** the cumulative position opens a
   * **gap**, filled with black + silence. A value **before** it is an
   * **overlap**: on iOS the clips are crossfade-dissolved over the overlap
   * window; on Android overlaps reject for now. Only adjacent-pair overlaps
   * are allowed — an overlap reaching back before the previous clip's own
   * start (spanning two clips) rejects with `InvalidSpecError`.
   */
  outputStartSec?: number;
  /**
   * Track index for multi-track composition (#17). `undefined`/`0` is the base
   * timeline; a higher index is an overlay/PiP track composited on top in
   * ascending z-order (**iOS + Android**). An overlay-track clip plays over its
   * own `[outputStartSec, +durationSec]` window on top of the base timeline.
   */
  track?: number;
  /**
   * Output placement for an overlay-track clip (`track` > 0), in normalized
   * output coordinates (0..1, origin top-left). Omitted = fill the frame.
   * Ignored on the base track. Example: a quarter-size top-right PiP is
   * `{ x: 0.7, y: 0.05, w: 0.25, h: 0.25 }`.
   */
  frame?: TrackFrame;
}

/**
 * Public spec accepted by `Video.render`. The library normalizes
 * `clips` (concat-style `ClipInput`s) into the Nitro `VideoSpec` shape
 * before crossing the boundary. The shape intentionally omits
 * `duration`: clip-backed renders always derive duration from `clips`,
 * and synthesized renders go through `Video.synthesize` with a
 * `SynthesizeOptions` instead.
 */
export interface RenderSpec {
  output: OutputSpec;
  clips: NonEmptyArray<ClipInput>;
  overlays?: Overlay[];
  audio?: AudioSpec;
  metadata?: MetadataSpec;
}

/**
 * Public spec accepted by `Video.compose`. Same shape as `RenderSpec` —
 * separate name because the underlying execution path is the worklet
 * compose-on-clip path, not native remux/transcode, and a future change
 * to either may diverge their public types (e.g. compose-only knobs).
 */
export interface ComposeSpec {
  output: OutputSpec;
  clips: NonEmptyArray<ClipInput>;
  overlays?: Overlay[];
  audio?: AudioSpec;
  metadata?: MetadataSpec;
}

// ---------------------------------------------------------------------------
// Render options — public facade.
// ---------------------------------------------------------------------------

/**
 * Options accepted by every `Video.*` method that runs an asynchronous
 * render. `controller` is typed as the concrete exported
 * `VideoRenderController` class (not a structural interface): the
 * implementation calls internal `_bind` / `_markDone` methods on it that a
 * hand-rolled object would not satisfy at runtime.
 */
export interface RenderOptions {
  /** Abort → discard output and reject with `Cancelled`. */
  signal?: AbortSignal;
  /** Graceful finish for open-ended renders; see `VideoRenderController`. */
  controller?: VideoRenderController;
  onProgress?: (p: Progress) => void;
}

// ---------------------------------------------------------------------------
// Re-export passthrough types that don't need a facade.
// ---------------------------------------------------------------------------

export type { TimeRange, WGS84Coordinate };
