import { VideoRenderController } from '../src/controller';
import { CancelledError, InvalidSpecError } from '../src/errors';
import { __setNativeVideoPipelineForTesting } from '../src/native';
import type {
  EncoderCaps,
  Progress,
  VideoInfo,
  VideoPipeline,
} from '../src/nitro/VideoPipeline.nitro';
import { Overlay } from '../src/overlay';
import type { RenderSpec } from '../src/types';
import { Video } from '../src/video';

interface RenderCall {
  spec: unknown;
  token: string;
  onProgress: ((p: Progress) => void) | undefined;
  /** Wrapped drawFrame passed by the JS layer to native.renderCompose (compose path only). */
  drawFrame?: (
    target: { width: number; height: number },
    source: undefined,
    frameIndex: number,
    timeSec: number,
  ) => boolean;
  resolve: () => void;
  reject: (e: unknown) => void;
}

interface FakeNative {
  module: VideoPipeline;
  renderCalls: RenderCall[];
  cancelled: string[];
  finished: string[];
  trimCalls: unknown[];
  flipCalls: unknown[];
  stampCalls: unknown[];
  thumbnailCalls: unknown[];
  infoCalls: string[];
  capabilitiesCalls: number;
}

function makeFakeNative(): FakeNative {
  const fake: Omit<FakeNative, 'module'> = {
    renderCalls: [],
    cancelled: [],
    finished: [],
    trimCalls: [],
    flipCalls: [],
    stampCalls: [],
    thumbnailCalls: [],
    infoCalls: [],
    capabilitiesCalls: 0,
  };
  const {
    renderCalls,
    cancelled,
    finished,
    trimCalls,
    flipCalls,
    stampCalls,
    thumbnailCalls,
    infoCalls,
  } = fake;

  const module = {
    info(uri: string): Promise<VideoInfo> {
      infoCalls.push(uri);
      return Promise.resolve({
        uri,
        durationSec: 1,
        width: 16,
        height: 9,
        codedWidth: 16,
        codedHeight: 9,
        fps: 30,
        bitRate: 1000,
        fileSizeBytes: 0,
        codec: 'h264',
        container: 'mp4',
        hasAudio: false,
        isHDR: false,
        rotation: 0,
      });
    },
    thumbnail(uri: string, options: unknown): Promise<string> {
      thumbnailCalls.push({ uri, options });
      return Promise.resolve('out.jpg');
    },
    capabilities(): Promise<EncoderCaps> {
      fake.capabilitiesCalls += 1;
      return Promise.resolve({
        codecs: ['h264'],
        maxWidth: 1920,
        maxHeight: 1080,
        maxFps: 60,
        maxBitrate: 10_000_000,
        hdr: false,
      });
    },
    render(spec: unknown, token: string, onProgress?: (p: Progress) => void): Promise<void> {
      return new Promise<void>((resolve, reject) => {
        renderCalls.push({ spec, token, onProgress, resolve, reject });
      });
    },
    renderCompose(
      spec: unknown,
      token: string,
      drawFrame: (
        target: { width: number; height: number },
        source: undefined,
        frameIndex: number,
        timeSec: number,
      ) => boolean,
      onProgress?: (p: Progress) => void,
    ): Promise<void> {
      return new Promise<void>((resolve, reject) => {
        renderCalls.push({ spec, token, onProgress, drawFrame, resolve, reject });
      });
    },
    cancelRender(token: string): void {
      cancelled.push(token);
      // Reject any pending render with this token, mimicking native behaviour.
      for (const c of renderCalls) {
        if (c.token === token) c.reject(new CancelledError({ message: 'cancelled by signal' }));
      }
    },
    finishRender(token: string): void {
      finished.push(token);
    },
    trim(...args: unknown[]): Promise<void> {
      trimCalls.push(args);
      return Promise.resolve();
    },
    flip(...args: unknown[]): Promise<void> {
      flipCalls.push(args);
      return Promise.resolve();
    },
    stamp(...args: unknown[]): Promise<void> {
      stampCalls.push(args);
      return Promise.resolve();
    },
  };

  return Object.assign(fake, { module: module as unknown as VideoPipeline });
}

let fake: FakeNative;

beforeEach(() => {
  fake = makeFakeNative();
  __setNativeVideoPipelineForTesting(fake.module);
});

afterEach(() => {
  __setNativeVideoPipelineForTesting(undefined);
});

const baseClipSpec: RenderSpec = {
  output: { path: '/tmp/out.mp4' },
  clips: [{ uri: 'in.mp4', startSec: 0, durationSec: 1 }],
};

describe('Video.info / thumbnail / capabilities', () => {
  it('forwards info to the native module', async () => {
    const result = await Video.info('in.mp4');
    expect(fake.infoCalls).toEqual(['in.mp4']);
    expect(result.uri).toBe('in.mp4');
  });

  it('forwards thumbnail', async () => {
    await Video.thumbnail('in.mp4', { atSec: 0.5, outPath: '/tmp/thumb.jpg' });
    expect(fake.thumbnailCalls).toHaveLength(1);
  });

  it('rejects negative atSec on thumbnail', () => {
    expect(() => Video.thumbnail('in.mp4', { atSec: -1, outPath: '/tmp/thumb.jpg' })).toThrow(
      InvalidSpecError,
    );
  });

  it('forwards capabilities', async () => {
    await Video.capabilities();
    expect(fake.capabilitiesCalls).toBe(1);
  });
});

describe('Video.trim / flip / stamp', () => {
  it('forwards trim with positive durations', async () => {
    await Video.trim('in.mp4', { startSec: 0, durationSec: 2, outPath: '/tmp/out.mp4' });
    expect(fake.trimCalls).toHaveLength(1);
  });

  it('rejects negative startSec on trim', () => {
    expect(() =>
      Video.trim('in.mp4', { startSec: -1, durationSec: 1, outPath: '/tmp/out.mp4' }),
    ).toThrow(InvalidSpecError);
  });

  it('rejects zero durationSec on trim', () => {
    expect(() =>
      Video.trim('in.mp4', { startSec: 0, durationSec: 0, outPath: '/tmp/out.mp4' }),
    ).toThrow(InvalidSpecError);
  });

  it('forwards flip with the requested axis', async () => {
    await Video.flip('in.mp4', { outPath: '/tmp/out.mp4', axis: 'horizontal' });
    await Video.flip('in.mp4', { outPath: '/tmp/out-v.mp4', axis: 'vertical' });
    expect(fake.flipCalls).toHaveLength(2);
    const [, , horizontalAxis] = fake.flipCalls[0] as unknown[];
    const [, , verticalAxis] = fake.flipCalls[1] as unknown[];
    expect(horizontalAxis).toBe('horizontal');
    expect(verticalAxis).toBe('vertical');
  });

  it('forwards stamp with metadata only', async () => {
    await Video.stamp('in.mp4', { outPath: '/tmp/out.mp4', metadata: { software: 'rnvp' } });
    expect(fake.stampCalls).toHaveLength(1);
    const [, , watermarkArg] = fake.stampCalls[0] as unknown[];
    expect(watermarkArg).toBeUndefined();
  });

  it('forwards stamp with an image watermark + metadata', async () => {
    await Video.stamp('in.mp4', {
      outPath: '/tmp/out.mp4',
      watermark: Overlay.Image({
        uri: 'file:///logo.png',
        anchor: 'br',
        size: { width: { unit: 'px', value: 120 } },
      }),
      metadata: { location: { latitude: 52.5, longitude: 13.4 }, software: 'MyApp 1.0' },
    });
    expect(fake.stampCalls).toHaveLength(1);
    const [, , watermarkArg, metadataArg] = fake.stampCalls[0] as unknown[];
    expect((watermarkArg as { kind: string }).kind).toBe('image');
    expect((metadataArg as { software: string }).software).toBe('MyApp 1.0');
  });

  it('rejects stamp with neither watermark nor metadata', () => {
    expect(() =>
      // @ts-expect-error — StampOptions requires at least one of watermark/metadata at compile time; this exercises the runtime guard for consumers who bypass types.
      Video.stamp('in.mp4', { outPath: '/tmp/out.mp4' }),
    ).toThrow(InvalidSpecError);
  });

  it('a pre-aborted signal on trim short-circuits with CancelledError', async () => {
    const ctl = new AbortController();
    ctl.abort();
    await expect(
      Video.trim('in.mp4', {
        startSec: 0,
        durationSec: 1,
        outPath: '/tmp/out.mp4',
        signal: ctl.signal,
      }),
    ).rejects.toBeInstanceOf(CancelledError);
    expect(fake.cancelled).toHaveLength(1);
    expect(fake.trimCalls).toHaveLength(0);
  });

  it('a pre-aborted signal on flip short-circuits with CancelledError', async () => {
    const ctl = new AbortController();
    ctl.abort();
    await expect(
      Video.flip('in.mp4', { outPath: '/tmp/out.mp4', axis: 'horizontal', signal: ctl.signal }),
    ).rejects.toBeInstanceOf(CancelledError);
    expect(fake.cancelled).toHaveLength(1);
    expect(fake.flipCalls).toHaveLength(0);
  });

  it('a pre-aborted signal on stamp short-circuits with CancelledError', async () => {
    const ctl = new AbortController();
    ctl.abort();
    await expect(
      Video.stamp('in.mp4', {
        outPath: '/tmp/out.mp4',
        metadata: { software: 'rnvp' },
        signal: ctl.signal,
      }),
    ).rejects.toBeInstanceOf(CancelledError);
    expect(fake.cancelled).toHaveLength(1);
    expect(fake.stampCalls).toHaveLength(0);
  });

  it('rejects empty outPath on trim', () => {
    expect(() => Video.trim('in.mp4', { startSec: 0, durationSec: 1, outPath: '' })).toThrow(
      InvalidSpecError,
    );
  });

  it('rejects http:// scheme on flip outPath', () => {
    expect(() =>
      Video.flip('in.mp4', { outPath: 'http://example.com/out.mp4', axis: 'horizontal' }),
    ).toThrow(InvalidSpecError);
  });

  it('accepts file:// URI on stamp outPath', async () => {
    await Video.stamp('in.mp4', {
      outPath: 'file:///tmp/out.mp4',
      metadata: { software: 'rnvp' },
    });
    expect(fake.stampCalls).toHaveLength(1);
  });

  it('forwards onProgress to native stamp', async () => {
    const onProgress = jest.fn();
    await Video.stamp('in.mp4', {
      outPath: '/tmp/out.mp4',
      watermark: Overlay.Image({
        uri: 'logo.png',
        anchor: 'tl',
        size: { width: { unit: 'ratio', value: 0.2 } },
      }),
      onProgress,
    });
    expect(fake.stampCalls).toHaveLength(1);
    // stamp's native signature is (uri, outPath, watermark, metadata, token, onProgress)
    const args = fake.stampCalls[0] as unknown[];
    expect(args[5]).toBe(onProgress);
  });

  it('binds a VideoRenderController to a trim and reports done after success', async () => {
    const controller = new VideoRenderController();
    await Video.trim('in.mp4', {
      startSec: 0,
      durationSec: 1,
      outPath: '/tmp/out.mp4',
      controller,
    });
    expect(fake.trimCalls).toHaveLength(1);
    expect(controller.state).toBe('done');
  });
});

describe('Video.render — validation', () => {
  // Synthesized specs and `duration` on clip-backed renders are rejected
  // at compile time by the `RenderSpec` facade (clips: NonEmptyArray<Clip>,
  // no `duration` field) — the corresponding runtime guards still exist in
  // `validateNativeSpec` for the `Video.synthesize` internal path but are
  // unreachable from the public `Video.render` surface.

  it("accepts audio.mode='replace' with a valid replaceUri", async () => {
    const promise = Video.render({
      ...baseClipSpec,
      audio: { mode: 'replace', replaceUri: 'file:///tmp/track.m4a' },
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as {
      audio?: { mode: string; replaceUri?: string };
    };
    expect(passed.audio).toEqual({
      mode: 'replace',
      replaceUri: 'file:///tmp/track.m4a',
    });
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it("rejects audio.mode='replace' with an empty replaceUri", async () => {
    await expect(
      Video.render({
        ...baseClipSpec,
        audio: { mode: 'replace', replaceUri: '' },
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });

  it("rejects audio.mode='replace' with a non-file replaceUri", async () => {
    await expect(
      Video.render({
        ...baseClipSpec,
        audio: { mode: 'replace', replaceUri: 'https://example.com/track.m4a' },
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });

  it("rejects audio.mode='replace' on a synthesized render (no source clips)", async () => {
    await expect(
      Video.synthesize({
        output: { path: '/tmp/out.mp4', width: 16, height: 16, fps: 30 },
        duration: { mode: 'fixed', seconds: 1 },
        drawFrame: () => undefined,
        audio: { mode: 'replace', replaceUri: 'file:///tmp/track.m4a' },
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });

  it("accepts audio.mode='mute' (drops the audio track natively)", async () => {
    // Wired into both engines (iOS: omit/skip the audio track; Android:
    // EditedMediaItem.setRemoveAudio). The spec is forwarded to native.
    const promise = Video.render({
      ...baseClipSpec,
      audio: { mode: 'mute' },
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as { audio?: { mode: string } };
    expect(passed.audio).toEqual({ mode: 'mute' });
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it("accepts audio.mode='passthrough' (keeps the source audio)", async () => {
    const promise = Video.render({
      ...baseClipSpec,
      audio: { mode: 'passthrough' },
    });
    expect(fake.renderCalls).toHaveLength(1);
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it('forwards a clip-based render to native and resolves', async () => {
    const promise = Video.render(baseClipSpec);
    expect(fake.renderCalls).toHaveLength(1);
    expect(fake.renderCalls[0]?.token).toMatch(/^vp_/);
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it('forwards native overlays unchanged to native', async () => {
    const promise = Video.render({
      ...baseClipSpec,
      overlays: [
        Overlay.Image({
          uri: 'logo.png',
          anchor: 'tl',
          size: { width: { unit: 'ratio', value: 0.2 } },
        }),
      ],
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as { overlays?: Array<{ kind: string }> };
    expect(passed.overlays).toHaveLength(1);
    expect(passed.overlays?.[0]?.kind).toBe('image');
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it('normalizes ClipInput concat shape into Nitro Clip with cumulative outputStart', async () => {
    const promise = Video.render({
      output: { path: '/tmp/out.mp4' },
      clips: [
        { uri: 'a.mp4', startSec: 2, durationSec: 3 },
        { uri: 'b.mp4', durationSec: 4 },
      ],
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as {
      clips: Array<{
        uri: string;
        sourceStart: number;
        sourceDuration: number;
        outputStart: number;
      }>;
    };
    expect(passed.clips).toEqual([
      { uri: 'a.mp4', sourceStart: 2, sourceDuration: 3, outputStart: 0 },
      { uri: 'b.mp4', sourceStart: 0, sourceDuration: 4, outputStart: 3 },
    ]);
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it('accepts an explicit outputStartSec that matches the concat position', async () => {
    const promise = Video.render({
      output: { path: '/tmp/out.mp4' },
      clips: [
        { uri: 'a.mp4', startSec: 0, durationSec: 3, outputStartSec: 0 },
        { uri: 'b.mp4', startSec: 0, durationSec: 4, outputStartSec: 3 },
      ],
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as { clips: Array<{ outputStart: number }> };
    // outputStartSec is a validation-only field; the boundary shape is unchanged.
    expect(passed.clips.map((c) => c.outputStart)).toEqual([0, 3]);
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it('accepts an outputStartSec gap (beyond the concat position) and forwards it', () => {
    const promise = Video.render({
      output: { path: '/tmp/out.mp4' },
      clips: [
        { uri: 'a.mp4', startSec: 0, durationSec: 3 },
        { uri: 'b.mp4', startSec: 0, durationSec: 4, outputStartSec: 5 },
      ],
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as { clips: Array<{ outputStart: number }> };
    // The gap is preserved: clip B starts at 5 (a 2s gap after clip A ends at 3).
    expect(passed.clips.map((c) => c.outputStart)).toEqual([0, 5]);
    fake.renderCalls[0]?.resolve();
    return promise;
  });

  it('rejects an outputStartSec overlap (before the concat position)', () => {
    expect(() =>
      Video.render({
        output: { path: '/tmp/out.mp4' },
        clips: [
          { uri: 'a.mp4', startSec: 0, durationSec: 3 },
          { uri: 'b.mp4', startSec: 0, durationSec: 4, outputStartSec: 1 },
        ],
      }),
    ).toThrow(InvalidSpecError);
  });

  it('rejects a duplicate clip id', () => {
    expect(() =>
      Video.render({
        output: { path: '/tmp/out.mp4' },
        clips: [
          { uri: 'a.mp4', startSec: 0, durationSec: 1, id: 'intro' },
          { uri: 'b.mp4', startSec: 0, durationSec: 1, id: 'intro' },
        ],
      }),
    ).toThrow(InvalidSpecError);
  });

  it('rejects a non-zero track', () => {
    expect(() =>
      Video.render({
        output: { path: '/tmp/out.mp4' },
        clips: [{ uri: 'a.mp4', startSec: 0, durationSec: 1, track: 1 }],
      }),
    ).toThrow(InvalidSpecError);
  });

  it('accepts track 0 and unique ids', async () => {
    const promise = Video.render({
      output: { path: '/tmp/out.mp4' },
      clips: [
        { uri: 'a.mp4', startSec: 0, durationSec: 1, id: 'intro', track: 0 },
        { uri: 'b.mp4', startSec: 0, durationSec: 1, id: 'body' },
      ],
    });
    expect(fake.renderCalls).toHaveLength(1);
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it('forwards a per-clip transform into the native Clip array on a multi-clip render (#16)', async () => {
    // Per-clip transforms on a multi-clip spec are a #16 capability: the native
    // side routes the spec to the transcode-each-then-concat path when any clip
    // carries a transform. This locks the JS contract that path depends on — the
    // transform reaches the boundary per clip, untouched, and only on its clip.
    const promise = Video.render({
      output: { path: '/tmp/out.mp4' },
      clips: [
        { uri: 'a.mp4', startSec: 0, durationSec: 3, transform: { rotate: 90, flipH: true } },
        { uri: 'b.mp4', startSec: 0, durationSec: 4 },
      ],
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as {
      clips: Array<{ uri: string; transform?: { rotate?: number; flipH?: boolean } }>;
    };
    expect(passed.clips[0]?.transform).toEqual({ rotate: 90, flipH: true });
    // A clip with no transform stays untransformed — the field is omitted, not
    // defaulted, so the native router can keep that clip on the passthrough path.
    expect(passed.clips[1]).not.toHaveProperty('transform');
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it('probes missing durationSec via Video.info and uses the remaining source duration', async () => {
    const promise = Video.render({
      output: { path: '/tmp/out.mp4' },
      clips: [{ uri: 'probe.mp4', startSec: 0.5 }],
    });
    // Sync check on renderCalls is intentionally skipped — probing introduces
    // microtasks (info() → Promise.all → .then(normalize) → runRender) before
    // native.render fires. Yield a few ticks so the chain settles.
    for (let i = 0; i < 5; i++) await Promise.resolve();
    expect(fake.infoCalls).toContain('probe.mp4');
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as {
      clips: Array<{ sourceStart: number; sourceDuration: number; outputStart: number }>;
    };
    // The fake's info() returns durationSec: 1; startSec is 0.5 → remaining 0.5.
    expect(passed.clips[0]).toEqual({
      uri: 'probe.mp4',
      sourceStart: 0.5,
      sourceDuration: 0.5,
      outputStart: 0,
    });
    fake.renderCalls[0]?.resolve();
    await promise;
  });
});

describe('Video.render — cancellation and progress', () => {
  it('passes onProgress through to native', async () => {
    const onProgress = jest.fn();
    const promise = Video.render(baseClipSpec, { onProgress });
    expect(fake.renderCalls[0]?.onProgress).toBe(onProgress);
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  it('aborting an AbortSignal calls cancelRender on the native module', async () => {
    const ctl = new AbortController();
    const promise = Video.render(baseClipSpec, { signal: ctl.signal });
    const token = fake.renderCalls[0]?.token;
    ctl.abort();
    await expect(promise).rejects.toBeInstanceOf(CancelledError);
    expect(fake.cancelled).toContain(token);
  });

  it('a pre-aborted signal short-circuits without invoking native render', async () => {
    const ctl = new AbortController();
    ctl.abort();
    await expect(Video.render(baseClipSpec, { signal: ctl.signal })).rejects.toBeInstanceOf(
      CancelledError,
    );
    // Native render is never called; cancelRender is called once for the issued token.
    expect(fake.renderCalls).toHaveLength(0);
    expect(fake.cancelled).toHaveLength(1);
  });

  it('controller.abort() cancels the native render', async () => {
    const drawFrame = () => undefined;
    const controller = new VideoRenderController();
    const promise = Video.synthesize({
      output: { path: '/tmp/out.mp4', width: 16, height: 9, fps: 30 },
      duration: { mode: 'open' },
      drawFrame,
      controller,
    });
    const token = fake.renderCalls[0]?.token;
    controller.abort();
    await expect(promise).rejects.toBeInstanceOf(CancelledError);
    expect(fake.cancelled).toContain(token);
    expect(controller.state).toBe('aborted');
  });

  it('controller.finish() on open-ended renders calls finishRender', async () => {
    const drawFrame = () => undefined;
    const controller = new VideoRenderController();
    const promise = Video.synthesize({
      output: { path: '/tmp/out.mp4', width: 16, height: 9, fps: 30 },
      duration: { mode: 'open' },
      drawFrame,
      controller,
    });
    const token = fake.renderCalls[0]?.token;
    controller.finish();
    expect(fake.finished).toContain(token);
    fake.renderCalls[0]?.resolve();
    await promise;
    expect(controller.state).toBe('done');
  });
});

describe('Video.compose', () => {
  it('forwards drawFrame to native renderCompose', async () => {
    const drawFrame = () => undefined;
    const promise = Video.compose(baseClipSpec, { drawFrame });
    expect(fake.renderCalls).toHaveLength(1);
    fake.renderCalls[0]?.resolve();
    await promise;
  });
});

describe('Video.synthesize', () => {
  it('builds a valid synthesize spec and forwards', async () => {
    const drawFrame = () => undefined;
    const promise = Video.synthesize({
      output: { path: '/tmp/out.mp4', width: 16, height: 9, fps: 30 },
      duration: { mode: 'fixed', seconds: 1 },
      drawFrame,
    });
    expect(fake.renderCalls).toHaveLength(1);
    fake.renderCalls[0]?.resolve();
    await promise;
  });

  // SynthesizeOutputSpec now requires width/height/fps at compile time; the
  // runtime guard below exists for consumers who bypass types.
  it('rejects synthesize without output.width', async () => {
    const drawFrame = () => undefined;
    await expect(
      Video.synthesize({
        // @ts-expect-error — width required at compile time
        output: { path: '/tmp/out.mp4', height: 9, fps: 30 },
        duration: { mode: 'fixed', seconds: 1 },
        drawFrame,
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });

  it('rejects synthesize without output.height', async () => {
    const drawFrame = () => undefined;
    await expect(
      Video.synthesize({
        // @ts-expect-error — height required at compile time
        output: { path: '/tmp/out.mp4', width: 16, fps: 30 },
        duration: { mode: 'fixed', seconds: 1 },
        drawFrame,
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });

  it('rejects synthesize without output.fps', async () => {
    const drawFrame = () => undefined;
    await expect(
      Video.synthesize({
        // @ts-expect-error — fps required at compile time
        output: { path: '/tmp/out.mp4', width: 16, height: 9 },
        duration: { mode: 'fixed', seconds: 1 },
        drawFrame,
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });

  it('rejects open-ended synthesize without signal or controller', async () => {
    const drawFrame = () => undefined;
    await expect(
      Video.synthesize({
        output: { path: '/tmp/out.mp4', width: 16, height: 9, fps: 30 },
        duration: { mode: 'open' },
        drawFrame,
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });

  it('rejects synthesize with non-positive fixed duration.seconds', async () => {
    const drawFrame = () => undefined;
    await expect(
      Video.synthesize({
        output: { path: '/tmp/out.mp4', width: 16, height: 9, fps: 30 },
        duration: { mode: 'fixed', seconds: 0 },
        drawFrame,
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
    await expect(
      Video.synthesize({
        output: { path: '/tmp/out.mp4', width: 16, height: 9, fps: 30 },
        duration: { mode: 'fixed', seconds: -1 },
        drawFrame,
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });

  it('rejects synthesize with non-positive open duration.maxSeconds', async () => {
    const drawFrame = () => undefined;
    const ctl = new AbortController();
    await expect(
      Video.synthesize({
        output: { path: '/tmp/out.mp4', width: 16, height: 9, fps: 30 },
        duration: { mode: 'open', maxSeconds: -1 },
        drawFrame,
        signal: ctl.signal,
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
  });
});

describe('Source URI validation', () => {
  // Sync validations throw at the call site, matching the existing pattern
  // used for requireNonNeg / validateOutputPath. The audio.replaceUri check
  // goes through the async validateNativeSpec path so that one rejects.

  it('rejects content:// on Video.info', () => {
    expect(() => Video.info('content://media/external/video/1')).toThrow(InvalidSpecError);
  });

  it('rejects http:// on Video.trim source uri', () => {
    expect(() =>
      Video.trim('https://example.com/clip.mp4', {
        startSec: 0,
        durationSec: 1,
        outPath: '/tmp/out.mp4',
      }),
    ).toThrow(InvalidSpecError);
  });

  it('rejects empty uri on Video.flip', () => {
    expect(() => Video.flip('', { outPath: '/tmp/out.mp4', axis: 'horizontal' })).toThrow(
      InvalidSpecError,
    );
  });

  it('rejects content:// on a clip input', () => {
    expect(() =>
      Video.render({
        output: { path: '/tmp/out.mp4' },
        clips: [{ uri: 'content://x', startSec: 0, durationSec: 1 }],
      }),
    ).toThrow(InvalidSpecError);
  });

  // NOTE: granular audio.replaceUri validation (non-empty, file URI) is removed
  // while replace is unimplemented — replace is rejected outright (see the
  // "not implemented" tests above). Restore that coverage with #29.

  it('rejects non-file overlay uri on Video.render', () => {
    expect(() =>
      Video.render({
        ...baseClipSpec,
        overlays: [
          Overlay.Image({
            uri: 'http://example.com/logo.png',
            anchor: 'tl',
            size: { width: { unit: 'ratio', value: 0.2 } },
          }),
        ],
      }),
    ).toThrow(InvalidSpecError);
  });

  it('accepts file:// uris on clips', async () => {
    const promise = Video.render({
      ...baseClipSpec,
      clips: [{ uri: 'file:///tmp/in.mp4', startSec: 0, durationSec: 1 }],
    });
    expect(fake.renderCalls).toHaveLength(1);
    fake.renderCalls[0]?.resolve();
    await promise;
  });
});

describe('Overlay size shape — boundary conversion (review #4)', () => {
  it('converts public { width, height } to Nitro { w, h } at the boundary', async () => {
    const promise = Video.render({
      ...baseClipSpec,
      overlays: [
        Overlay.Image({
          uri: 'file:///logo.png',
          anchor: 'tl',
          size: { width: { unit: 'ratio', value: 0.2 }, height: { unit: 'px', value: 64 } },
        }),
      ],
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as {
      overlays?: Array<{ kind: string; size?: { w?: unknown; h?: unknown } }>;
    };
    const size = passed.overlays?.[0]?.size;
    expect(size).toEqual({
      w: { unit: 'ratio', value: 0.2 },
      h: { unit: 'px', value: 64 },
    });
    fake.renderCalls[0]?.resolve();
    await promise;
  });
});

describe('FrameDrawerContext enrichment (review #7)', () => {
  it('exposes fps + clipIndex/sourceUri/sourceTimeSec on the compose path', async () => {
    const seen: Array<{
      timeSec: number;
      fps?: number;
      clipIndex?: number;
      sourceUri?: string;
      sourceTimeSec?: number;
    }> = [];
    const drawFrame = (ctx: {
      timeSec: number;
      fps?: number;
      clipIndex?: number;
      sourceUri?: string;
      sourceTimeSec?: number;
    }) => {
      seen.push({
        timeSec: ctx.timeSec,
        fps: ctx.fps,
        clipIndex: ctx.clipIndex,
        sourceUri: ctx.sourceUri,
        sourceTimeSec: ctx.sourceTimeSec,
      });
    };
    const promise = Video.compose(
      {
        output: { path: '/tmp/out.mp4', fps: 30 },
        clips: [
          { uri: 'a.mp4', startSec: 2, durationSec: 3 },
          { uri: 'b.mp4', startSec: 0, durationSec: 4 },
        ],
      },
      { drawFrame },
    );
    const call = fake.renderCalls[0];
    expect(call?.drawFrame).toBeDefined();
    const target = { width: 16, height: 9 };
    // First clip: timeSec=0 → clipIndex 0, sourceTimeSec = 2.
    call?.drawFrame?.(target, undefined, 0, 0);
    // Mid first clip: timeSec=1.5 → still clip 0, sourceTimeSec = 3.5.
    call?.drawFrame?.(target, undefined, 45, 1.5);
    // Second clip boundary: timeSec=3 → clip 1, sourceTimeSec = 0.
    call?.drawFrame?.(target, undefined, 90, 3);
    // Within second clip: timeSec=5 → clip 1, sourceTimeSec = 2.
    call?.drawFrame?.(target, undefined, 150, 5);
    expect(seen).toEqual([
      { timeSec: 0, fps: 30, clipIndex: 0, sourceUri: 'a.mp4', sourceTimeSec: 2 },
      { timeSec: 1.5, fps: 30, clipIndex: 0, sourceUri: 'a.mp4', sourceTimeSec: 3.5 },
      { timeSec: 3, fps: 30, clipIndex: 1, sourceUri: 'b.mp4', sourceTimeSec: 0 },
      { timeSec: 5, fps: 30, clipIndex: 1, sourceUri: 'b.mp4', sourceTimeSec: 2 },
    ]);
    call?.resolve();
    await promise;
  });

  it('exposes clipId when the active clip carries an id (review #1)', async () => {
    const seen: Array<{ clipIndex?: number; clipId?: string }> = [];
    const drawFrame = (ctx: { clipIndex?: number; clipId?: string }) => {
      seen.push({ clipIndex: ctx.clipIndex, clipId: ctx.clipId });
    };
    const promise = Video.compose(
      {
        output: { path: '/tmp/out.mp4', fps: 30 },
        clips: [
          { uri: 'a.mp4', startSec: 0, durationSec: 3, id: 'intro' },
          // Second clip intentionally has no id → clipId undefined on its frames.
          { uri: 'b.mp4', startSec: 0, durationSec: 4 },
        ],
      },
      { drawFrame },
    );
    const call = fake.renderCalls[0];
    const target = { width: 16, height: 9 };
    call?.drawFrame?.(target, undefined, 0, 0); // clip 0 → 'intro'
    call?.drawFrame?.(target, undefined, 120, 4); // clip 1 → no id
    expect(seen).toEqual([
      { clipIndex: 0, clipId: 'intro' },
      { clipIndex: 1, clipId: undefined },
    ]);
    call?.resolve();
    await promise;
  });

  it('synthesize path exposes fps but omits clip context', async () => {
    const seen: Array<{
      fps?: number;
      clipIndex?: number;
      sourceUri?: string;
      sourceTimeSec?: number;
    }> = [];
    const drawFrame = (ctx: {
      fps?: number;
      clipIndex?: number;
      sourceUri?: string;
      sourceTimeSec?: number;
    }) => {
      seen.push({
        fps: ctx.fps,
        clipIndex: ctx.clipIndex,
        sourceUri: ctx.sourceUri,
        sourceTimeSec: ctx.sourceTimeSec,
      });
    };
    const promise = Video.synthesize({
      output: { path: '/tmp/out.mp4', width: 16, height: 9, fps: 24 },
      duration: { mode: 'fixed', seconds: 1 },
      drawFrame,
    });
    const call = fake.renderCalls[0];
    call?.drawFrame?.({ width: 16, height: 9 }, undefined, 0, 0);
    expect(seen).toEqual([{ fps: 24 }]);
    call?.resolve();
    await promise;
  });

  it('omits fps when compose output has no explicit fps', async () => {
    const seen: Array<{ fps?: number }> = [];
    const drawFrame = (ctx: { fps?: number }) => {
      seen.push({ fps: ctx.fps });
    };
    const promise = Video.compose(
      {
        output: { path: '/tmp/out.mp4' },
        clips: [{ uri: 'a.mp4', startSec: 0, durationSec: 1 }],
      },
      { drawFrame },
    );
    const call = fake.renderCalls[0];
    call?.drawFrame?.({ width: 16, height: 9 }, undefined, 0, 0);
    expect(seen).toEqual([{ fps: undefined }]);
    call?.resolve();
    await promise;
  });
});

describe('Native error normalization (review #6)', () => {
  it('maps a generic native "VideoPipeline.trim failed: ..." into EncoderFailureError', async () => {
    // Patch the fake trim to reject with a native-shaped error.
    const native = fake.module as unknown as {
      trim: (...a: unknown[]) => Promise<void>;
    };
    native.trim = () =>
      Promise.reject(new Error('VideoPipeline.trim failed: AVAssetWriter status 3'));
    const { EncoderFailureError } = await import('../src/errors');
    await expect(
      Video.trim('in.mp4', { startSec: 0, durationSec: 1, outPath: '/tmp/out.mp4' }),
    ).rejects.toBeInstanceOf(EncoderFailureError);
  });

  it('maps a native "VideoPipeline.render: InvalidSpec — ..." into InvalidSpecError', async () => {
    const promise = Video.render(baseClipSpec);
    fake.renderCalls[0]?.reject(new Error('VideoPipeline.render: InvalidSpec — bad clip'));
    await expect(promise).rejects.toBeInstanceOf(InvalidSpecError);
  });
});
