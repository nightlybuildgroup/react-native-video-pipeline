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
  OutputSpec as NativeOutputSpec,
  Progress,
  TimeRange,
  WGS84Coordinate,
} from './nitro/VideoPipeline.nitro';

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
