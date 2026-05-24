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
