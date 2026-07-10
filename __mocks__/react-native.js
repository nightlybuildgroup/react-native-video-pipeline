// Minimal `react-native` mock for the Jest JS-wrapper suites. The real module
// pulls in native-only code that throws under Node, so `src/` only ever touches
// the tiny surface the wrapper needs. Today that is `Platform.OS` (the compose
// `output.colorRange: 'hdr'` gate is platform-aware). Tests flip the platform
// through `__setPlatformOSForTesting` in `src/platform.ts`; this default keeps
// non-platform-aware suites deterministic.
module.exports = {
  Platform: { OS: 'ios' },
};
