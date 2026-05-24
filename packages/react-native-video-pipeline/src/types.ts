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
  Clip,
  MetadataSpec,
  OutputSpec as NativeOutputSpec,
  Progress,
  TimeRange,
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
// Size — at least one of `w`/`h` required.
// ---------------------------------------------------------------------------

export type Size = { w: number; h?: number } | { w?: number; h: number };

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
 * Public spec accepted by `Video.render`. Structurally compatible with the
 * Nitro `VideoSpec` — every field is a subtype of the boundary type, so
 * the wrapper hands it across without a runtime conversion. The shape
 * intentionally omits `duration`: clip-backed renders always derive
 * duration from `clips`, and synthesized renders go through
 * `Video.synthesize` with a `SynthesizeOptions` instead.
 */
export interface RenderSpec {
  output: OutputSpec;
  clips: NonEmptyArray<Clip>;
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
  clips: NonEmptyArray<Clip>;
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
