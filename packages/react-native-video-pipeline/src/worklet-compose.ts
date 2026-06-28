/**
 * Experimental off-thread compose dispatch (#34).
 *
 * Runs the consumer's `'worklet'` `drawFrame` on a `react-native-worklets-core`
 * context instead of inline on the React JS thread. The frame's `FrameTarget`/
 * `FrameSource` are Nitro HybridObjects tied to the main runtime; they reach the
 * worklet runtime via Nitro's blessed **box/unbox** pattern
 * (`NitroModules.box(...)` → carry the `jsi::HostObject` across → `.unbox()`
 * inside the worklet). See https://nitro.margelo.com/docs/guides/worklets.
 *
 * The native pump already blocks per frame on the JS callback's returned
 * `Promise<bool>` (`promise->await().get()` in `VideoPipeline.mm`), so awaiting
 * the context run keeps the documented buffer-lifetime contract: the
 * `FrameTarget` is never invalidated before the worklet has finished writing.
 *
 * `react-native-worklets-core` is an OPTIONAL peer dep — this module loads it
 * lazily and returns `undefined` when it's absent, so the main library stays
 * worklets-free.
 */

import { NitroModules } from 'react-native-nitro-modules';
import type { FrameDrawer, FrameSource, FrameTarget } from './nitro/VideoPipeline.nitro';

/** Per-frame fields computed on the JS thread and forwarded into the worklet. */
export interface WorkletFrameMeta {
  frameIndex: number;
  timeSec: number;
  elapsedMs: number;
  fps?: number;
  clip?: { clipIndex: number; sourceUri: string; sourceTimeSec: number };
  clipId?: string;
}

export type WorkletDispatcher = (
  target: FrameTarget,
  source: FrameSource | undefined,
  meta: WorkletFrameMeta,
) => Promise<void>;

/** Minimal shape of the bits of `react-native-worklets-core` we use. */
interface BoxedLike<T> {
  unbox(): T;
}
interface WorkletContextLike {
  createRunAsync: <TArgs extends unknown[], TReturn>(
    fn: (...args: TArgs) => TReturn,
  ) => (...args: TArgs) => Promise<TReturn>;
}
interface WorkletsApiLike {
  createContext: (name: string) => WorkletContextLike;
  createRunOnJS: <TArgs extends unknown[], TReturn>(
    fn: (...args: TArgs) => TReturn,
  ) => (...args: TArgs) => void;
}

function loadWorklets(): WorkletsApiLike | undefined {
  try {
    // Optional peer dep — present only when the consumer installed it. A
    // dynamic require (not a static import) keeps the main library worklets-free
    // when it's absent.
    const req = require as (id: string) => { Worklets?: WorkletsApiLike };
    return req('react-native-worklets-core')?.Worklets;
  } catch {
    return undefined;
  }
}

/**
 * Build a per-frame dispatcher that runs `drawFrame` on a worklets-core context.
 * Returns `undefined` when `react-native-worklets-core` is not installed (the
 * caller then rejects the `offthread` render with a clear error).
 *
 * `onFinish` is invoked on the JS thread (via `createRunOnJS`) when the worklet
 * calls `ctx.finish()` — it bridges back to the `VideoRenderController`.
 */
export function createWorkletDispatcher(
  drawFrame: FrameDrawer,
  onFinish: () => void,
): WorkletDispatcher | undefined {
  const worklets = loadWorklets();
  if (worklets === undefined) return undefined;

  const context = worklets.createContext('rnvp-compose');
  const finishOnJS = worklets.createRunOnJS(onFinish);

  const run = context.createRunAsync(
    (
      boxedTarget: BoxedLike<FrameTarget>,
      boxedSource: BoxedLike<FrameSource> | null,
      meta: WorkletFrameMeta,
    ): boolean => {
      'worklet';
      const target = boxedTarget.unbox();
      const source = boxedSource != null ? boxedSource.unbox() : undefined;
      drawFrame({
        target,
        ...(source !== undefined ? { source } : {}),
        frameIndex: meta.frameIndex,
        timeSec: meta.timeSec,
        elapsedMs: meta.elapsedMs,
        width: target.width,
        height: target.height,
        ...(meta.fps !== undefined ? { fps: meta.fps } : {}),
        ...(meta.clip !== undefined ? meta.clip : {}),
        ...(meta.clipId !== undefined ? { clipId: meta.clipId } : {}),
        finish: finishOnJS,
      });
      return true;
    },
  );

  return async (target, source, meta) => {
    const boxedTarget = NitroModules.box(target) as unknown as BoxedLike<FrameTarget>;
    const boxedSource =
      source !== undefined ? (NitroModules.box(source) as unknown as BoxedLike<FrameSource>) : null;
    await run(boxedTarget, boxedSource, meta);
  };
}
