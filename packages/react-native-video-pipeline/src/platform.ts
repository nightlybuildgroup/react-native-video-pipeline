import { Platform } from 'react-native';

/**
 * The one place the JS wrapper reads the host platform. Isolated behind a
 * single function (plus a test override) so `react-native` — which throws under
 * plain Node — is imported from exactly one module the Jest harness can mock,
 * mirroring the `__setNativeVideoPipelineForTesting` seam in `native.ts`.
 *
 * Used by the compose `output.colorRange: 'hdr'` gate: HDR-preserving compose
 * is implemented on iOS (worklet-generated / `Video.synthesize`) but not yet on
 * Android (#93), so the reject is platform-specific.
 */
let osOverride: string | undefined;

export function currentPlatformOS(): string {
  return osOverride ?? Platform.OS;
}

/**
 * Force `currentPlatformOS()` to a value (or clear the override with
 * `undefined`). Test-only — lets a Jest suite exercise both the iOS and Android
 * branches of a platform-aware gate without a real React Native runtime.
 *
 * @internal
 */
export function __setPlatformOSForTesting(os: string | undefined): void {
  osOverride = os;
}
