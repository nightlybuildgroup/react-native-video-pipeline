import { NitroModules } from 'react-native-nitro-modules';

import type { VideoPipeline } from './nitro/VideoPipeline.nitro';

let cached: VideoPipeline | undefined;

/**
 * Returns the singleton Nitro `VideoPipeline` instance, creating it on first
 * use. Lazy so module-init time stays cheap and so a test can inject a fake
 * via `__setNativeVideoPipelineForTesting` before the first call.
 */
export function getNativeVideoPipeline(): VideoPipeline {
  if (cached === undefined) {
    cached = NitroModules.createHybridObject<VideoPipeline>('VideoPipeline');
  }
  return cached;
}

/**
 * Replace (or clear) the cached native module. Test-only escape hatch — the
 * Jest harness has no real Nitro runtime, so unit tests for the JS wrapper
 * must inject a fake before exercising any `Video.*` call.
 *
 * @internal
 */
export function __setNativeVideoPipelineForTesting(mod: VideoPipeline | undefined): void {
  cached = mod;
}
