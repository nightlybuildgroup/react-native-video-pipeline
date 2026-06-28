/**
 * Unit tests for the experimental off-thread compose dispatcher (#34).
 *
 * These exercise the JS orchestration — boxing, context dispatch, unbox, and
 * the reconstructed FrameDrawerContext — with a faithful in-process mock of
 * `react-native-worklets-core`. The actual cross-thread worklet execution
 * (pixel-correctness on the context thread) is a runtime concern verified
 * separately on a simulator/device; it cannot run in Jest (no JSI runtime).
 */

// Faithful mock: a context's run-async just invokes the worklet synchronously
// (in-process) and resolves its result; createRunOnJS returns the fn verbatim.
const createRunAsync = jest.fn(
  (fn: (...a: unknown[]) => unknown) =>
    (...args: unknown[]): Promise<unknown> =>
      Promise.resolve(fn(...args)),
);
jest.mock('react-native-worklets-core', () => ({
  Worklets: {
    createContext: jest.fn(() => ({ createRunAsync })),
    createRunOnJS: jest.fn((fn: unknown) => fn),
  },
}));

import { createWorkletDispatcher } from '../src/worklet-compose';

type FakeTarget = { width: number; height: number; tag: string };

beforeEach(() => {
  createRunAsync.mockClear();
});

describe('createWorkletDispatcher (#34 off-thread compose)', () => {
  it('boxes the frame objects and invokes drawFrame with an unboxed, reconstructed ctx', async () => {
    const seen: Record<string, unknown>[] = [];
    const drawFrame = (ctx: Record<string, unknown>) => {
      seen.push(ctx);
    };
    const dispatch = createWorkletDispatcher(drawFrame as never, () => {});
    expect(dispatch).toBeDefined();

    const target = { width: 160, height: 120, tag: 't' } as FakeTarget;
    const source = { width: 160, height: 120, tag: 's' } as FakeTarget;
    await dispatch?.(target as never, source as never, {
      frameIndex: 7,
      timeSec: 1.5,
      elapsedMs: 42,
      fps: 30,
      clip: { clipIndex: 1, sourceUri: 'b.mp4', sourceTimeSec: 0.5 },
      clipId: 'body',
    });

    expect(seen).toHaveLength(1);
    const ctx = seen[0] as Record<string, unknown>;
    // The worklet unboxed back to the *same* target/source instances.
    expect(ctx.target).toBe(target);
    expect(ctx.source).toBe(source);
    // width/height are read off the unboxed target inside the worklet.
    expect(ctx.width).toBe(160);
    expect(ctx.height).toBe(120);
    expect(ctx.frameIndex).toBe(7);
    expect(ctx.timeSec).toBe(1.5);
    expect(ctx.elapsedMs).toBe(42);
    expect(ctx.fps).toBe(30);
    expect(ctx.clipIndex).toBe(1);
    expect(ctx.sourceUri).toBe('b.mp4');
    expect(ctx.sourceTimeSec).toBe(0.5);
    expect(ctx.clipId).toBe('body');
    expect(typeof ctx.finish).toBe('function');
  });

  it('omits source on the synthesize path (no FrameSource)', async () => {
    let ctx: Record<string, unknown> | undefined;
    const dispatch = createWorkletDispatcher(
      ((c: Record<string, unknown>) => {
        ctx = c;
      }) as never,
      () => {},
    );
    const target = { width: 64, height: 64, tag: 't' } as FakeTarget;
    await dispatch?.(target as never, undefined, {
      frameIndex: 0,
      timeSec: 0,
      elapsedMs: 0,
    });
    expect(ctx).toBeDefined();
    expect(ctx).not.toHaveProperty('source');
    expect(ctx).not.toHaveProperty('clipIndex');
    expect(ctx).not.toHaveProperty('fps');
  });

  it('bridges ctx.finish back to onFinish on the JS thread', async () => {
    const onFinish = jest.fn();
    const dispatch = createWorkletDispatcher(
      ((c: Record<string, unknown>) => {
        (c.finish as () => void)();
      }) as never,
      onFinish,
    );
    await dispatch?.({ width: 1, height: 1 } as never, undefined, {
      frameIndex: 0,
      timeSec: 0,
      elapsedMs: 0,
    });
    expect(onFinish).toHaveBeenCalledTimes(1);
  });
});
