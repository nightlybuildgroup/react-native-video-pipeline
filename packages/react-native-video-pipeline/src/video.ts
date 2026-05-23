import type { VideoRenderController } from './controller';
import { CancelledError, InvalidSpecError } from './errors';
import { getNativeVideoPipeline } from './native';
import type {
  Clip,
  ClipTransform,
  EncoderCaps,
  FlipAxis,
  FrameDrawer,
  FrameDrawerContext,
  FrameSource,
  FrameTarget,
  MetadataSpec,
  RenderOptions,
  ThumbnailOptions,
  VideoInfo,
} from './nitro/VideoPipeline.nitro';
import type { Overlay } from './overlay';
import type { AudioSpec, DurationSpec, OutputSpec, SynthesizeOutputSpec } from './types';

/**
 * Public render spec. Uses literal-discriminant facades from `./types` and
 * `./overlay` so consumer narrowing (`if (audio.mode === 'replace') …`)
 * works. The shape is a structural subtype of the Nitro `VideoSpec`, so
 * passing one across the Nitro boundary needs no runtime conversion.
 */
export interface VideoSpec {
  output: OutputSpec;
  clips?: Clip[];
  overlays?: Overlay[];
  audio?: AudioSpec;
  metadata?: MetadataSpec;
  duration?: DurationSpec;
}

export interface TrimOptions extends RenderOptions {
  startSec: number;
  durationSec: number;
  outPath: string;
  transform?: ClipTransform;
}

export interface FlipOptions extends RenderOptions {
  outPath: string;
  axis: FlipAxis;
}

/** At least one of `watermark` or `metadata` is required. */
export type StampOptions = { outPath: string } & RenderOptions &
  (
    | { watermark: Overlay; metadata?: MetadataSpec }
    | { watermark?: Overlay; metadata: MetadataSpec }
  );

export interface ComposeOptions extends RenderOptions {
  drawFrame: FrameDrawer;
}

export interface SynthesizeOptions extends RenderOptions {
  output: SynthesizeOutputSpec;
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

/**
 * Output paths must be a non-empty filesystem path or a `file://` URI. Other
 * URI schemes (http://, https://, content://, data:, …) would silently
 * confuse the native URL parsers — reject them at the JS boundary instead.
 */
function validateOutputPath(name: string, path: string): void {
  if (path.length === 0 || path.trim() === '') {
    fail(`${name}: outPath must be a non-empty filesystem path`);
  }
  // Match a leading `scheme:` (RFC 3986 syntax). file:// is allowed; anything
  // else with a scheme is rejected. Plain absolute filesystem paths fall
  // through (the slash in `/tmp/...` is not a scheme delimiter).
  if (/^[a-z][a-z0-9+.-]*:/i.test(path) && !path.startsWith('file://')) {
    fail(
      `${name}: outPath must be a filesystem path or a file:// URI — got an unsupported scheme`,
      { path },
    );
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

function validateRenderSpec(
  spec: VideoSpec,
  options: RenderOptions | undefined,
  { allowSynthesized = false }: { allowSynthesized?: boolean } = {},
): void {
  validateOutputPath('render', spec.output.path);
  const synth = isSynthesized(spec);

  if (synth) {
    if (!allowSynthesized) {
      fail(
        'render: synthesized specs (no clips) must go through Video.synthesize — Video.render only handles remux/transcode of source clips',
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

async function runCompose(
  spec: VideoSpec,
  drawFrame: FrameDrawer,
  options: RenderOptions | undefined,
): Promise<void> {
  validateRenderSpec(spec, options, { allowSynthesized: true });

  const native = getNativeVideoPipeline();
  const token = nextRenderToken();

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
    await native.renderCompose(spec, token, wrapped, options?.onProgress);
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
    await native.render(spec, token, options?.onProgress);
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

/**
 * Wraps a native call (trim/flip/stamp) with the same cancellation plumbing
 * `runRender` uses: signal listener calls `cancelRender(token)`, controller
 * binds to the token for `abort()`. These are fixed-duration ops, so
 * `controller.finish()` is a no-op (matches `Video.render`'s contract).
 * `onProgress` is accepted but not yet routed to native for these methods.
 */
async function withCancellation(
  options: RenderOptions | undefined,
  invoke: (token: string) => Promise<void>,
): Promise<void> {
  const native = getNativeVideoPipeline();
  const token = nextRenderToken();
  const controller = options?.controller;
  if (controller !== undefined) {
    (controller as VideoRenderController)._bind({
      durationMode: 'fixed',
      finishRender: () => native.finishRender(token),
      cancelRender: () => native.cancelRender(token),
    });
  }

  const signal = options?.signal;
  let onAbort: (() => void) | undefined;
  if (signal !== undefined) {
    if (signal.aborted) {
      native.cancelRender(token);
      throw new CancelledError({ message: 'operation aborted before it started' });
    }
    onAbort = () => {
      native.cancelRender(token);
    };
    signal.addEventListener('abort', onAbort);
  }

  try {
    await invoke(token);
    if (controller !== undefined) (controller as VideoRenderController)._markDone();
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (
      signal?.aborted === true ||
      controller?.state === 'aborted' ||
      message.includes('VideoPipeline.render: Cancelled')
    ) {
      throw new CancelledError({ message: 'operation aborted', cause: err });
    }
    throw err;
  } finally {
    if (signal !== undefined && onAbort !== undefined) {
      signal.removeEventListener('abort', onAbort);
    }
  }
}

export const Video = {
  /** Probe a video and return its container/codec/dimension metadata. */
  info(uri: string): Promise<VideoInfo> {
    return getNativeVideoPipeline().info(uri);
  },

  /** Extract a single JPEG frame at `atSec` and write it to `outPath`. */
  thumbnail(uri: string, options: ThumbnailOptions): Promise<string> {
    requireNonNeg('thumbnail.atSec', options.atSec);
    validateOutputPath('thumbnail', options.outPath);
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
    validateOutputPath('trim', options.outPath);
    return withCancellation(options, (token) =>
      getNativeVideoPipeline().trim(
        uri,
        options.outPath,
        options.startSec,
        options.durationSec,
        options.transform,
        token,
      ),
    );
  },

  /** Rotation-flag remux when the container supports it; transcode fallback otherwise. */
  flip(uri: string, options: FlipOptions): Promise<void> {
    validateOutputPath('flip', options.outPath);
    return withCancellation(options, (token) =>
      getNativeVideoPipeline().flip(uri, options.outPath, options.axis, token),
    );
  },

  /** Auto-routed: metadata-only stamp uses remux; watermark falls into transcode. */
  stamp(uri: string, options: StampOptions): Promise<void> {
    if (options.watermark === undefined && options.metadata === undefined) {
      fail('stamp: at least one of `watermark` or `metadata` must be provided');
    }
    validateOutputPath('stamp', options.outPath);
    return withCancellation(options, (token) =>
      getNativeVideoPipeline().stamp(
        uri,
        options.outPath,
        options.watermark,
        options.metadata,
        token,
      ),
    );
  },

  /** Single source of truth for trim / transcode / compose — auto-routed natively. */
  render(spec: VideoSpec, options?: RenderOptions): Promise<void> {
    return runRender(spec, options);
  },

  /**
   * Sugar for the worklet `compose` path: the `drawFrame` you pass crosses
   * the Nitro boundary as a callback and is invoked by the native pump per
   * frame with a live `FrameTarget` HybridObject.
   */
  compose(spec: VideoSpec, options: ComposeOptions): Promise<void> {
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
