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
      _drawFrame: (target: unknown, frameIndex: number, timeSec: number) => boolean,
      onProgress?: (p: Progress) => void,
    ): Promise<void> {
      return new Promise<void>((resolve, reject) => {
        renderCalls.push({ spec, token, onProgress, resolve, reject });
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
  clips: [{ uri: 'in.mp4', sourceStart: 0, sourceDuration: 1, outputStart: 0 }],
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

  it('forwards flip', async () => {
    await Video.flip('in.mp4', { outPath: '/tmp/out.mp4', axis: 'horizontal' });
    expect(fake.flipCalls).toHaveLength(1);
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
        size: { w: 120 },
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
      watermark: Overlay.Image({ uri: 'logo.png', anchor: 'tl', size: { w: 0.2 } }),
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

  it("rejects audio.mode='replace' without replaceUri", async () => {
    await expect(
      Video.render({
        ...baseClipSpec,
        // Cast through `unknown` — the public discriminated `AudioSpec`
        // requires `replaceUri` on `'replace'` at compile time. The native
        // boundary is structurally laxer, so we still defend at runtime.
        audio: { mode: 'replace' } as unknown as RenderSpec['audio'],
      }),
    ).rejects.toBeInstanceOf(InvalidSpecError);
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
      overlays: [Overlay.Image({ uri: 'logo.png', anchor: 'tl', size: { w: 0.2 } })],
    });
    expect(fake.renderCalls).toHaveLength(1);
    const passed = fake.renderCalls[0]?.spec as { overlays?: Array<{ kind: string }> };
    expect(passed.overlays).toHaveLength(1);
    expect(passed.overlays?.[0]?.kind).toBe('image');
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
});
