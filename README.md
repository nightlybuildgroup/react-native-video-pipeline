# react-native-video-pipeline

Offline video editing for React Native (iOS + Android) built on Nitro Modules.

> **Status:** pre-alpha (v0.1 scaffolding). This is a monorepo root; the consumable library lives at [`packages/react-native-video-pipeline/`](./packages/react-native-video-pipeline/).

## Packages

| Package | Purpose |
| --- | --- |
| `packages/react-native-video-pipeline` | Main library + Expo config plugin (offline trim / flip / stamp / compose / synthesize / probe). |
| `packages/babel-plugin-video-pipeline` | Build-time enforcement of `'worklet';` directives on `drawFrame` callbacks. |
| `apps/bare-example` | Bare React Native consumer app used for local verification. |
| `apps/expo-example` | Expo-managed consumer app used for local verification. |

## Invariants

- **yarn only** (Yarn 4 Berry, `nodeLinker: node-modules`). Never `npm` or `pnpm`.
- **Both iOS and Android** are first-class — no platform stubs.
- **Zero Skia in the library itself** — consumers bring `@shopify/react-native-skia` for the compose worklet path.
- **No FFmpeg**, ever — AVFoundation + Media3 Transformer only.
- **Offline only** — no realtime pacing, no network calls.
- **Type safety:** strict TS, no `any` in the public API, exhaustive discriminated unions.
- The Nitro spec at `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` is the single source of truth for cross-boundary types.
- Derived artifacts (`nitrogen/`, `plugin/build/`) are gitignored and regenerated.
- Tests bootstrap their own fixtures via `Video.synthesize` — no binary video files in git.

## License

[MIT](./LICENSE).
