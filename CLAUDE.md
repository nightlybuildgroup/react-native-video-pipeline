# CLAUDE.md

Project conventions live in `prd.md` (gitignored, local-only planning doc) until task **T006** expands this file with the real content.

For now, the invariants any agent working on this repo must respect:

- **yarn only** (Yarn 4 Berry, `nodeLinker: node-modules`). Never `npm` or `pnpm`.
- **Both iOS and Android are in scope** — no "platform is a stub" shortcuts.
- **Zero Skia in the library itself** — consumers bring `@shopify/react-native-skia` only for the compose worklet path.
- **No FFmpeg**, ever.
- **Offline only** — no realtime pacing, no network calls.
- **Type safety is non-negotiable**: strict tsconfig, no `any` in public API, exhaustive discriminated unions, no `@ts-ignore` in `src/`.
- **Nitro spec** at `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` is the single source of truth for cross-boundary types.
- **Derived artifacts** (`nitrogen/`, `plugin/build/`) are gitignored and regenerated.
- **Tests bootstrap their own fixtures** via `Video.synthesize` — don't commit binary video files.
