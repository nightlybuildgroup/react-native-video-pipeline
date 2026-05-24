import { CancelledError, InvalidSpecError, normalizeNativeError } from './errors';
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
  Overlay as NativeOverlay,
  VideoSpec as NativeVideoSpec,
  ThumbnailOptions,
  VideoInfo,
} from './nitro/VideoPipeline.nitro';
import { type Overlay, toNativeOverlaySize } from './overlay';
import type {
  AudioSpec,
  ClipInput,
  ComposeSpec,
  DurationSpec,
  NonEmptyArray,
  OutputSpec,
  RenderOptions,
  RenderSpec,
  SynthesizeOutputSpec,
} from './types';

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
 * Shared validator for any URI we hand to the native pipeline as either an
 * input file (clip sources, audio replacement) or an output target. Accepts
 * a non-empty plain filesystem path or a `file://` URI; rejects every other
 * scheme up front so platform-specific behavior (Android `content://`,
 * iOS Photos asset identifiers, http(s), data:, …) can never silently reach
 * the native URL parsers. If/when the library grows first-class support for
 * those, it will appear as an explicit `Source` discriminated union rather
 * than an implicit scheme passed through `uri: string`.
 */
function validateFileUri(name: string, uri: string): void {
  if (uri.length === 0 || uri.trim() === '') {
    fail(`${name} must be a non-empty filesystem path`);
  }
  // Match a leading `scheme:` (RFC 3986 syntax). file:// is allowed; anything
  // else with a scheme is rejected. Plain absolute filesystem paths fall
  // through (the slash in `/tmp/...` is not a scheme delimiter).
  if (/^[a-z][a-z0-9+.-]*:/i.test(uri) && !uri.startsWith('file://')) {
    fail(`${name} must be a filesystem path or a file:// URI — got an unsupported scheme`, { uri });
  }
}

const validateOutputPath = (name: string, path: string): void =>
  validateFileUri(`${name}: outPath`, path);

function validateOutputForSynthesis(output: OutputSpec): void {
  if (output.width === undefined)
    fail('synthesize: output.width is required when there are no clips');
  if (output.height === undefined)
    fail('synthesize: output.height is required when there are no clips');
  if (output.fps === undefined) fail('synthesize: output.fps is required when there are no clips');
}

/**
 * Convert concat-style `ClipInput[]` into the Nitro boundary `Clip[]`
 * shape (cumulative `outputStart`, default `sourceStart = 0`). Returns a
 * `Clip[]` synchronously when every input supplies `durationSec`;
 * otherwise returns a `Promise<Clip[]>` that probes the missing
 * durations via `Video.info`. The sync path is preserved so callers that
 * already know their slice durations don't pay a microtask penalty (and
 * the existing test pattern that checks `native.render` was invoked
 * before awaiting the return promise keeps working).
 */
function normalizeClips(
  inputs: NonEmptyArray<ClipInput>,
): NonEmptyArray<Clip> | Promise<NonEmptyArray<Clip>> {
  // Validate URIs eagerly so `native.info` is never called with a bad scheme.
  for (const c of inputs) validateFileUri('clip.uri', c.uri);
  const needsProbe = inputs.some((c) => c.durationSec === undefined);
  if (!needsProbe) {
    return finalizeClips(
      inputs.map((c) => ({ input: c, sourceDuration: c.durationSec as number })),
    );
  }
  const native = getNativeVideoPipeline();
  return Promise.all(
    inputs.map(async (c) => {
      if (c.durationSec !== undefined) return { input: c, sourceDuration: c.durationSec };
      const info = await native.info(c.uri);
      const sourceStart = c.startSec ?? 0;
      const remaining = info.durationSec - sourceStart;
      if (!(remaining > 0)) {
        fail(
          `clip: probed source duration ${info.durationSec}s is <= startSec ${sourceStart}s — provide an explicit durationSec`,
          { uri: c.uri, sourceStart, sourceDurationSec: info.durationSec },
        );
      }
      return { input: c, sourceDuration: remaining };
    }),
  ).then(finalizeClips);
}

function finalizeClips(
  resolved: ReadonlyArray<{ input: ClipInput; sourceDuration: number }>,
): NonEmptyArray<Clip> {
  const out: Clip[] = [];
  let outputStart = 0;
  for (const { input, sourceDuration } of resolved) {
    const sourceStart = input.startSec ?? 0;
    validateFileUri('clip.uri', input.uri);
    requireNonNeg('clip.startSec', sourceStart);
    requirePositive('clip.durationSec', sourceDuration);
    out.push({
      uri: input.uri,
      sourceStart,
      sourceDuration,
      outputStart,
      ...(input.transform !== undefined ? { transform: input.transform } : {}),
    });
    outputStart += sourceDuration;
  }
  // `inputs` came in as `NonEmptyArray<ClipInput>`, so `out` has length >= 1.
  return out as NonEmptyArray<Clip>;
}

/**
 * Convert a public `Overlay` (image overlays carry the `OverlaySize`
 * `width`/`height` shape) into the Nitro `Overlay` (image overlays carry
 * the `{ w, h }` boundary shape). Text overlays pass through unchanged.
 * Also validates image-overlay URIs as file paths / `file://`.
 */
function toNativeOverlay(o: Overlay): NativeOverlay {
  if (o.kind === 'text') return o;
  validateFileUri('overlay.uri', o.uri);
  return {
    kind: 'image',
    uri: o.uri,
    anchor: o.anchor,
    size: toNativeOverlaySize(o.size),
    ...(o.opacity !== undefined ? { opacity: o.opacity } : {}),
    ...(o.timeRange !== undefined ? { timeRange: o.timeRange } : {}),
  };
}

function buildNativeSpecFromClipped(
  spec: RenderSpec | ComposeSpec,
  clips: NonEmptyArray<Clip>,
): NativeVideoSpec {
  return {
    output: spec.output,
    clips,
    ...(spec.overlays !== undefined ? { overlays: spec.overlays.map(toNativeOverlay) } : {}),
    ...(spec.audio !== undefined ? { audio: spec.audio } : {}),
    ...(spec.metadata !== undefined ? { metadata: spec.metadata } : {}),
  };
}

function validateAudio(audio: NativeVideoSpec['audio']): void {
  if (audio?.mode === 'replace') {
    if (audio.replaceUri === undefined || audio.replaceUri === '') {
      fail("audio.mode='replace' requires a non-empty replaceUri");
    }
    validateFileUri('audio.replaceUri', audio.replaceUri);
  }
}

/**
 * Internal validation for the loose Nitro `VideoSpec`. The public
 * `RenderSpec` / `ComposeSpec` facades already encode "clips is non-empty"
 * at the type level — this function only fires when:
 *
 *  - `Video.synthesize` constructs a clip-less spec internally (and supplies
 *    its own `duration`), so we still verify the synth-output invariants.
 *  - Audio is `'replace'` and `replaceUri` is empty at runtime despite the
 *    discriminated-union type.
 *  - An open-ended duration was set without a way to stop it.
 */
function validateNativeSpec(spec: NativeVideoSpec, options: RenderOptions | undefined): void {
  validateOutputPath('render', spec.output.path);

  const synth = spec.clips === undefined || spec.clips.length === 0;
  if (synth) {
    if (spec.duration === undefined) {
      fail('render: synthesized specs require a duration');
    }
    validateOutputForSynthesis(spec.output);
  } else if (spec.duration !== undefined) {
    fail('render: duration is only valid when clips is empty or omitted');
  }

  // Nitro's named-union `DurationMode` doesn't narrow the struct, so the
  // structural `in` check is what gates which field we read.
  const dur = spec.duration;
  if (dur?.mode === 'fixed' && 'seconds' in dur) {
    requirePositive('duration.seconds', dur.seconds);
  }
  if (dur?.mode === 'open') {
    if ('maxSeconds' in dur && dur.maxSeconds !== undefined) {
      requirePositive('duration.maxSeconds', dur.maxSeconds);
    }
    if (options?.signal === undefined && options?.controller === undefined) {
      fail(
        'render: open-ended duration requires either an AbortSignal or a VideoRenderController so the render can be stopped',
      );
    }
  }

  validateAudio(spec.audio);
}

/**
 * Find the source clip producing the frame at `timeSec` on a concat
 * timeline. Returns the largest-indexed clip whose `outputStart <=
 * timeSec` (which also handles the trailing-edge `timeSec ==
 * totalDuration` case by pinning to the last clip). Returns `undefined`
 * when there are no clips — the synthesize path.
 */
function activeClipFor(
  clips: readonly Clip[],
  timeSec: number,
): { index: number; clip: Clip } | undefined {
  if (clips.length === 0) return undefined;
  let idx = 0;
  for (let i = 0; i < clips.length; i++) {
    const c = clips[i];
    if (c !== undefined && c.outputStart <= timeSec) idx = i;
    else break;
  }
  const clip = clips[idx];
  if (clip === undefined) return undefined;
  return { index: idx, clip };
}

async function runCompose(
  spec: NativeVideoSpec,
  drawFrame: FrameDrawer,
  options: RenderOptions | undefined,
): Promise<void> {
  validateNativeSpec(spec, options);

  const native = getNativeVideoPipeline();
  const token = nextRenderToken();

  const controller = options?.controller;
  if (controller !== undefined) {
    const durationMode = spec.duration?.mode ?? 'fixed';
    controller._bind({
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
  // Snapshot the clip timeline once per render so per-frame lookups don't
  // re-read the spec. Empty on the synthesize path (no source clips).
  const clipTimeline = spec.clips ?? [];
  const fps = spec.output.fps;
  const wrapped = (
    target: FrameTarget,
    source: FrameSource | undefined,
    frameIndex: number,
    timeSec: number,
  ): boolean => {
    const activeClip = activeClipFor(clipTimeline, timeSec);
    const ctx: FrameDrawerContext = {
      target,
      ...(source !== undefined ? { source } : {}),
      frameIndex,
      timeSec,
      elapsedMs: Date.now() - renderStartMs,
      width: target.width,
      height: target.height,
      ...(fps !== undefined ? { fps } : {}),
      ...(activeClip !== undefined
        ? {
            clipIndex: activeClip.index,
            sourceUri: activeClip.clip.uri,
            sourceTimeSec: activeClip.clip.sourceStart + (timeSec - activeClip.clip.outputStart),
          }
        : {}),
      finish: () => {
        if (controller !== undefined) {
          controller.finish();
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
    if (controller !== undefined) controller._markDone();
  } catch (err) {
    if (signal?.aborted === true || controller?.state === 'aborted') {
      throw new CancelledError({ message: 'compose aborted', cause: err });
    }
    throw normalizeNativeError(err);
  } finally {
    if (signal !== undefined && onAbort !== undefined) {
      signal.removeEventListener('abort', onAbort);
    }
  }
}

async function runRender(spec: NativeVideoSpec, options: RenderOptions | undefined): Promise<void> {
  validateNativeSpec(spec, options);

  const native = getNativeVideoPipeline();
  const token = nextRenderToken();

  const controller = options?.controller;
  if (controller !== undefined) {
    const durationMode = spec.duration?.mode ?? 'fixed';
    controller._bind({
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
    if (controller !== undefined) controller._markDone();
  } catch (err) {
    // Two paths surface a Cancelled rejection here:
    //  - AbortSignal fired → JS called native.cancelRender, native throws.
    //  - controller.abort() called → same cancelRender path.
    // The race where native aborts on its own (cancelRender flipped the stop
    // token but the signal listener ran on a later tick) is handled inside
    // `normalizeNativeError`, which maps "VideoPipeline.<method>: Cancelled"
    // messages to CancelledError too.
    if (signal?.aborted === true || controller?.state === 'aborted') {
      throw new CancelledError({ message: 'render aborted', cause: err });
    }
    throw normalizeNativeError(err);
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
    controller._bind({
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
    if (controller !== undefined) controller._markDone();
  } catch (err) {
    if (signal?.aborted === true || controller?.state === 'aborted') {
      throw new CancelledError({ message: 'operation aborted', cause: err });
    }
    throw normalizeNativeError(err);
  } finally {
    if (signal !== undefined && onAbort !== undefined) {
      signal.removeEventListener('abort', onAbort);
    }
  }
}

export const Video = {
  /** Probe a video and return its container/codec/dimension metadata. */
  info(uri: string): Promise<VideoInfo> {
    validateFileUri('info.uri', uri);
    return getNativeVideoPipeline()
      .info(uri)
      .catch((err) => {
        throw normalizeNativeError(err);
      });
  },

  /** Extract a single JPEG frame at `atSec` and write it to `outPath`. */
  thumbnail(uri: string, options: ThumbnailOptions): Promise<string> {
    validateFileUri('thumbnail.uri', uri);
    requireNonNeg('thumbnail.atSec', options.atSec);
    validateOutputPath('thumbnail', options.outPath);
    return getNativeVideoPipeline()
      .thumbnail(uri, options)
      .catch((err) => {
        throw normalizeNativeError(err);
      });
  },

  /** Cached encoder capability snapshot (codecs, max dims, HDR, …). */
  capabilities(): Promise<EncoderCaps> {
    return getNativeVideoPipeline()
      .capabilities()
      .catch((err) => {
        throw normalizeNativeError(err);
      });
  },

  /** Remux trim — never re-encodes when `transform` is rotation-only. */
  trim(uri: string, options: TrimOptions): Promise<void> {
    validateFileUri('trim.uri', uri);
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
        options.onProgress,
      ),
    );
  },

  /** Rotation-flag remux when the container supports it; transcode fallback otherwise. */
  flip(uri: string, options: FlipOptions): Promise<void> {
    validateFileUri('flip.uri', uri);
    validateOutputPath('flip', options.outPath);
    return withCancellation(options, (token) =>
      getNativeVideoPipeline().flip(uri, options.outPath, options.axis, token, options.onProgress),
    );
  },

  /** Auto-routed: metadata-only stamp uses remux; watermark falls into transcode. */
  stamp(uri: string, options: StampOptions): Promise<void> {
    if (options.watermark === undefined && options.metadata === undefined) {
      fail('stamp: at least one of `watermark` or `metadata` must be provided');
    }
    validateFileUri('stamp.uri', uri);
    validateOutputPath('stamp', options.outPath);
    const watermark =
      options.watermark !== undefined ? toNativeOverlay(options.watermark) : undefined;
    return withCancellation(options, (token) =>
      getNativeVideoPipeline().stamp(
        uri,
        options.outPath,
        watermark,
        options.metadata,
        token,
        options.onProgress,
      ),
    );
  },

  /** Single source of truth for native remux / transcode — auto-routed natively. */
  render(spec: RenderSpec, options?: RenderOptions): Promise<void> {
    const clips = normalizeClips(spec.clips);
    if (clips instanceof Promise) {
      return clips.then((c) => runRender(buildNativeSpecFromClipped(spec, c), options));
    }
    return runRender(buildNativeSpecFromClipped(spec, clips), options);
  },

  /**
   * Sugar for the worklet `compose` path: the `drawFrame` you pass crosses
   * the Nitro boundary as a callback and is invoked by the native pump per
   * frame with a live `FrameTarget` HybridObject.
   */
  compose(spec: ComposeSpec, options: ComposeOptions): Promise<void> {
    if (typeof options.drawFrame !== 'function') {
      fail('compose: drawFrame is required and must be a function');
    }
    const composeOpts = pickRenderOptions(options);
    const clips = normalizeClips(spec.clips);
    if (clips instanceof Promise) {
      return clips.then((c) =>
        runCompose(buildNativeSpecFromClipped(spec, c), options.drawFrame, composeOpts),
      );
    }
    return runCompose(buildNativeSpecFromClipped(spec, clips), options.drawFrame, composeOpts);
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
    const spec: NativeVideoSpec = {
      output: options.output,
      duration: options.duration,
      ...(options.audio !== undefined ? { audio: options.audio } : {}),
      ...(options.metadata !== undefined ? { metadata: options.metadata } : {}),
    };
    return runCompose(spec, options.drawFrame, pickRenderOptions(options));
  },
} as const;
