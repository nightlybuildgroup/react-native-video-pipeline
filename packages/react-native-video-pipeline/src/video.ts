import type { VideoRenderController } from './controller';
import { CancelledError, InvalidSpecError } from './errors';
import { getNativeVideoPipeline } from './native';
import type {
  AudioSpec,
  ClipTransform,
  DurationSpec,
  EncoderCaps,
  FlipAxis,
  FrameDrawer,
  FrameDrawerContext,
  FrameSource,
  FrameTarget,
  MetadataSpec,
  NativeOverlay,
  VideoSpec as NativeVideoSpec,
  OutputSpec,
  RenderOptions,
  ThumbnailOptions,
  VideoInfo,
} from './nitro/VideoPipeline.nitro';
import type { OverlayValue, WorkletOverlayValue } from './overlay';

/**
 * Public render spec. Mirrors the Nitro `VideoSpec` but accepts the wider
 * `OverlayValue[]` so that worklet overlays from `Overlay.Worklet(...)` are
 * representable on the JS side. The wrapper strips worklets before crossing
 * Nitro — the worklet data path is wired separately by the compose tasks
 * (T019 / T020 / T041).
 */
export interface VideoSpec extends Omit<NativeVideoSpec, 'overlays'> {
  overlays?: OverlayValue[];
}

export interface TrimOptions {
  startSec: number;
  durationSec: number;
  outPath: string;
  transform?: ClipTransform;
}

export interface FlipOptions {
  outPath: string;
  axis: FlipAxis;
}

export interface StampOptions {
  outPath: string;
  watermark?: OverlayValue;
  metadata?: MetadataSpec;
}

export interface ComposeOptions extends RenderOptions {
  drawFrame: FrameDrawer;
}

export interface SynthesizeOptions extends RenderOptions {
  output: OutputSpec;
  duration: DurationSpec;
  drawFrame: FrameDrawer;
  audio?: AudioSpec;
  metadata?: MetadataSpec;
}

let tokenCounter = 0;

function nextRenderToken(): string {
  tokenCounter += 1;
  return `vp_${Date.now().toString(36)}_${tokenCounter.toString(36)}`;
}

function fail(message: string, details?: Record<string, unknown>): never {
  throw new InvalidSpecError(details !== undefined ? { message, details } : { message });
}

function requireNonNeg(name: string, value: number): void {
  if (!Number.isFinite(value) || value < 0) {
    fail(`${name} must be a non-negative finite number`, { value });
  }
}

function requirePositive(name: string, value: number): void {
  if (!Number.isFinite(value) || value <= 0) {
    fail(`${name} must be a positive finite number`, { value });
  }
}

function validateOutputForSynthesis(output: OutputSpec): void {
  if (output.width === undefined)
    fail('synthesize: output.width is required when there are no clips');
  if (output.height === undefined)
    fail('synthesize: output.height is required when there are no clips');
  if (output.fps === undefined) fail('synthesize: output.fps is required when there are no clips');
}

function validateAudio(audio: AudioSpec | undefined): void {
  if (audio?.mode === 'replace') {
    if (audio.replaceUri === undefined || audio.replaceUri === '') {
      fail("audio.mode='replace' requires a non-empty replaceUri");
    }
  }
}

function isSynthesized(spec: VideoSpec): boolean {
  return spec.clips === undefined || spec.clips.length === 0;
}

function hasWorkletOverlay(spec: VideoSpec): boolean {
  return spec.overlays?.some((o) => o.kind === 'worklet') ?? false;
}

function validateRenderSpec(
  spec: VideoSpec,
  options: RenderOptions | undefined,
  { drawFrameIsArgument = false }: { drawFrameIsArgument?: boolean } = {},
): void {
  const synth = isSynthesized(spec);

  if (synth) {
    // When `drawFrame` crosses the Nitro boundary as a separate argument
    // (runCompose path), the spec doesn't need a worklet overlay — the
    // drawFrame is dispatched by the native pump directly.
    if (!drawFrameIsArgument && !hasWorkletOverlay(spec)) {
      fail(
        'render: synthesized specs (no clips) require a worklet overlay — pass one via Overlay.Worklet or use Video.synthesize / Video.compose',
      );
    }
    if (spec.duration === undefined) {
      fail('render: synthesized specs require a duration');
    }
    validateOutputForSynthesis(spec.output);
  } else if (spec.duration !== undefined) {
    fail('render: duration is only valid when clips is empty or omitted');
  }

  if (spec.duration?.mode === 'open') {
    if (options?.signal === undefined && options?.controller === undefined) {
      fail(
        'render: open-ended duration requires either an AbortSignal or a VideoRenderController so the render can be stopped',
      );
    }
  }

  validateAudio(spec.audio);
}

function toNativeSpec(spec: VideoSpec): NativeVideoSpec {
  const native: NativeVideoSpec = { output: spec.output };
  if (spec.clips !== undefined) native.clips = spec.clips;
  if (spec.audio !== undefined) native.audio = spec.audio;
  if (spec.metadata !== undefined) native.metadata = spec.metadata;
  if (spec.duration !== undefined) native.duration = spec.duration;
  if (spec.overlays !== undefined) {
    const filtered = spec.overlays.filter(
      (o): o is Exclude<OverlayValue, WorkletOverlayValue> => o.kind !== 'worklet',
    );
    if (filtered.length > 0) native.overlays = filtered as NativeOverlay[];
  }
  return native;
}

async function runCompose(
  spec: VideoSpec,
  drawFrame: FrameDrawer,
  options: RenderOptions | undefined,
): Promise<void> {
  validateRenderSpec(spec, options, { drawFrameIsArgument: true });

  const native = getNativeVideoPipeline();
  const token = nextRenderToken();
  const nativeSpec = toNativeSpec(spec);

  const controller = options?.controller;
  if (controller !== undefined) {
    const durationMode = spec.duration?.mode ?? 'fixed';
    (controller as VideoRenderController)._bind({
      durationMode,
      finishRender: () => native.finishRender(token),
      cancelRender: () => native.cancelRender(token),
    });
  }

  const signal = options?.signal;
  let onAbort: (() => void) | undefined;
  if (signal !== undefined) {
    if (signal.aborted) {
      native.cancelRender(token);
      throw new CancelledError({ message: 'compose aborted before it started' });
    }
    onAbort = () => {
      native.cancelRender(token);
    };
    signal.addEventListener('abort', onAbort);
  }

  // Nitro callback shape is flat (target, source, frameIndex, timeSec); the
  // consumer-facing FrameDrawer takes a richer FrameDrawerContext. Wrap here
  // so consumer worklets stay on the documented (ctx) => void contract and
  // the Nitro boundary stays on primitive args + the HybridObjects.
  // `source` is undefined on the synthesize path and the FrameSource handle
  // on the compose-on-clip path.
  const renderStartMs = Date.now();
  const wrapped = (
    target: FrameTarget,
    source: FrameSource | undefined,
    frameIndex: number,
    timeSec: number,
  ): boolean => {
    const ctx: FrameDrawerContext = {
      target,
      ...(source !== undefined ? { source } : {}),
      frameIndex,
      timeSec,
      elapsedMs: Date.now() - renderStartMs,
      width: target.width,
      height: target.height,
      finish: () => {
        if (controller !== undefined) {
          (controller as VideoRenderController).finish();
        }
      },
    };
    drawFrame(ctx);
    // Return `true` so the Nitro JSIConverter picks SyncJSCallback (sync
    // dispatch). A `void` return would route through AsyncJSCallback and
    // the native pump would invalidate the FrameTarget before JS writes
    // into it — see the Nitro spec comment on renderCompose.drawFrame.
    return true;
  };

  try {
    await native.renderCompose(nativeSpec, token, wrapped, options?.onProgress);
    if (controller !== undefined) (controller as VideoRenderController)._markDone();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (
      signal?.aborted === true ||
      controller?.state === 'aborted' ||
      message.includes('VideoPipeline.renderCompose: Cancelled')
    ) {
      throw new CancelledError({ message: 'compose aborted', cause: err });
    }
    throw err;
  } finally {
    if (signal !== undefined && onAbort !== undefined) {
      signal.removeEventListener('abort', onAbort);
    }
  }
}

async function runRender(spec: VideoSpec, options: RenderOptions | undefined): Promise<void> {
  validateRenderSpec(spec, options);

  const native = getNativeVideoPipeline();
  const token = nextRenderToken();
  const nativeSpec = toNativeSpec(spec);

  const controller = options?.controller;
  if (controller !== undefined) {
    const durationMode = spec.duration?.mode ?? 'fixed';
    (controller as VideoRenderController)._bind({
      durationMode,
      finishRender: () => native.finishRender(token),
      cancelRender: () => native.cancelRender(token),
    });
  }

  const signal = options?.signal;
  let onAbort: (() => void) | undefined;
  if (signal !== undefined) {
    if (signal.aborted) {
      native.cancelRender(token);
      throw new CancelledError({ message: 'render aborted before it started' });
    }
    onAbort = () => {
      native.cancelRender(token);
    };
    signal.addEventListener('abort', onAbort);
  }

  try {
    await native.render(nativeSpec, token, options?.onProgress);
    if (controller !== undefined) (controller as VideoRenderController)._markDone();
  } catch (err) {
    // Any of three paths surface a Cancelled rejection from native:
    //  - AbortSignal fired → JS called native.cancelRender, native throws.
    //  - controller.abort() called → same cancelRender path.
    //  - Race: abort() after render kicked off but before native registered.
    // Detect via local state + the native error message prefix; the latter
    // catches the "native aborted on its own" edge case where cancelRender
    // flipped the stop token but the signal listener ran on a later tick.
    const message = err instanceof Error ? err.message : String(err);
    if (
      signal?.aborted === true ||
      controller?.state === 'aborted' ||
      message.includes('VideoPipeline.render: Cancelled')
    ) {
      throw new CancelledError({ message: 'render aborted', cause: err });
    }
    throw err;
  } finally {
    if (signal !== undefined && onAbort !== undefined) {
      signal.removeEventListener('abort', onAbort);
    }
  }
}

function pickRenderOptions(opts: RenderOptions): RenderOptions {
  const out: RenderOptions = {};
  if (opts.signal !== undefined) out.signal = opts.signal;
  if (opts.controller !== undefined) out.controller = opts.controller;
  if (opts.onProgress !== undefined) out.onProgress = opts.onProgress;
  if (opts.priority !== undefined) out.priority = opts.priority;
  return out;
}

export const Video = {
  /** Probe a video and return its container/codec/dimension metadata. */
  info(uri: string): Promise<VideoInfo> {
    return getNativeVideoPipeline().info(uri);
  },

  /** Extract a single JPEG frame at `atSec` and write it to `outPath`. */
  thumbnail(uri: string, options: ThumbnailOptions): Promise<string> {
    requireNonNeg('thumbnail.atSec', options.atSec);
    return getNativeVideoPipeline().thumbnail(uri, options);
  },

  /** Cached encoder capability snapshot (codecs, max dims, HDR, …). */
  capabilities(): Promise<EncoderCaps> {
    return getNativeVideoPipeline().capabilities();
  },

  /** Remux trim — never re-encodes when `transform` is rotation-only. */
  trim(uri: string, options: TrimOptions): Promise<void> {
    requireNonNeg('trim.startSec', options.startSec);
    requirePositive('trim.durationSec', options.durationSec);
    return getNativeVideoPipeline().trim(
      uri,
      options.outPath,
      options.startSec,
      options.durationSec,
      options.transform,
      nextRenderToken(),
    );
  },

  /** Rotation-flag remux when the container supports it; transcode fallback otherwise. */
  flip(uri: string, options: FlipOptions): Promise<void> {
    return getNativeVideoPipeline().flip(uri, options.outPath, options.axis, nextRenderToken());
  },

  /** Auto-routed: metadata-only stamp uses remux; watermark falls into transcode. */
  stamp(uri: string, options: StampOptions): Promise<void> {
    if (options.watermark === undefined && options.metadata === undefined) {
      fail('stamp: at least one of `watermark` or `metadata` must be provided');
    }
    if (options.watermark?.kind === 'worklet') {
      fail(
        'stamp: watermark must be Overlay.Image or Overlay.Text — worklet overlays go through Video.compose',
      );
    }
    const watermark =
      options.watermark !== undefined ? (options.watermark as NativeOverlay) : undefined;
    return getNativeVideoPipeline().stamp(
      uri,
      options.outPath,
      watermark,
      options.metadata,
      nextRenderToken(),
    );
  },

  /** Single source of truth for trim / transcode / compose — auto-routed natively. */
  render(spec: VideoSpec, options?: RenderOptions): Promise<void> {
    return runRender(spec, options);
  },

  /**
   * Sugar for the worklet `compose` path: the `drawFrame` you pass crosses
   * the Nitro boundary as a callback and is invoked by the native pump per
   * frame with a live `FrameTarget` HybridObject. `drawFrame` must NOT also
   * appear as a worklet overlay on the spec (would double-dispatch).
   */
  compose(spec: VideoSpec, options: ComposeOptions): Promise<void> {
    if (hasWorkletOverlay(spec)) {
      fail(
        'compose: spec.overlays must not contain a worklet overlay — pass it as drawFrame instead',
      );
    }
    if (typeof options.drawFrame !== 'function') {
      fail('compose: drawFrame is required and must be a function');
    }
    return runCompose(spec, options.drawFrame, pickRenderOptions(options));
  },

  /**
   * Null-input compose: no source clips, the entire frame stream is produced
   * by `drawFrame`. `output.width`, `output.height`, `output.fps` and
   * `duration` are all required (see §9 routing rules).
   */
  synthesize(options: SynthesizeOptions): Promise<void> {
    if (typeof options.drawFrame !== 'function') {
      fail('synthesize: drawFrame is required and must be a function');
    }
    const spec: VideoSpec = {
      output: options.output,
      duration: options.duration,
      ...(options.audio !== undefined ? { audio: options.audio } : {}),
      ...(options.metadata !== undefined ? { metadata: options.metadata } : {}),
    };
    return runCompose(spec, options.drawFrame, pickRenderOptions(options));
  },
} as const;
