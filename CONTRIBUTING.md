# Contributing

Thanks for your interest in `react-native-video-pipeline`. This doc covers local dev setup and the commit/PR conventions. Project invariants (yarn-only, no Skia in library, no FFmpeg, strict type-safety, Nitro single source of truth) live in [`CLAUDE.md`](./CLAUDE.md) / [`AGENTS.md`](./AGENTS.md); the full spec is in `docs/architecture.md`.

---

## Prerequisites

- **Node.js** 20+ (LTS).
- **Yarn 4** via [Corepack](https://nodejs.org/api/corepack.html) — do not install Yarn globally. From the repo root:
  ```sh
  corepack enable
  corepack prepare yarn@4.13.0 --activate   # matches the `packageManager` field in root package.json
  ```
- **Xcode** 15+ with Command Line Tools, for the iOS example app and XCTest native suites.
- **Android Studio** (or standalone SDK + NDK) with API 34 platform + a x86_64 / arm64 emulator image, for Android builds and JUnit suites.
- **CocoaPods** 1.15+ (installed via `gem install cocoapods` or `brew install cocoapods`).

This repo uses the Yarn Berry **node-modules** linker (not PnP), because CocoaPods, Gradle, and the Nitro native toolchains expect a real `node_modules/` tree.

---

## First-time setup

```sh
git clone <repo-url>
cd react-native-video-pipeline
yarn install           # resolves every workspace; writes yarn.lock updates if your local Yarn diverges
yarn typecheck         # all workspaces, strict, must pass
yarn lint              # Biome (primary) + ESLint (RN-only rules)
```

Never run `npm install` or `pnpm install` — both will produce an incorrect lockfile and break CI.

---

## Daily workflow

```sh
yarn lint              # fix lint issues
yarn format            # Biome formatter; should leave a clean tree
yarn typecheck         # strict TS across every workspace
yarn test              # Jest, across workspaces (once T050 lands)
yarn nitrogen          # regenerate native bindings from the Nitro spec (once T008 lands)
```

- **Nitro spec.** `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` is the **single source of truth** for every cross-boundary type. Change types there and run `yarn nitrogen` to regenerate. Never hand-edit files under `nitrogen/`.
- **Derived artifacts** (`nitrogen/`, `packages/react-native-video-pipeline/plugin/build/`) are gitignored. The Expo plugin's `plugin/build/` is shipped to npm via the package's `files` allowlist + a `prepack` script — it never goes through git.

### Running the example apps

```sh
# iOS (from repo root)
yarn workspace bare-example run ios

# Android
yarn workspace bare-example run android
```

The bare example is the fastest path to exercise a native change end-to-end. The Expo example exists to verify the bundled config plugin.

---

## Branching

- **`main`** — protected. PRs merge into it; direct commits are not allowed.
- **`v0.1`** — the v0.1 MVP integration branch used by the agent task loop. Human contributors generally branch their own topic branches off `main` and open PRs against `main`.

Never force-push to `main`. Never commit to `main` directly.

---

## Commit style

One logical change per commit. Keep the subject under ~72 characters. Use the [Conventional Commits](https://www.conventionalcommits.org/) vocabulary:

- `feat:` — new user-visible capability.
- `fix:` — bug fix.
- `refactor:` — internal change, no behavior delta.
- `perf:` — performance change.
- `test:` — adds or adjusts tests only.
- `docs:` — documentation-only.
- `chore:` — tooling, CI, lockfile bumps, etc.
- `build:` — build system / native toolchain changes.

For agent-driven task commits, prefix the subject with the task ID — e.g. `feat(T012): implement Video.* public API surface`. Every task commit should reference what the task's `verification` criteria were and how they were met (the progress entry in `activity.md` carries the details; the commit message can be short).

---

## Pull requests

- PRs target `main`. Reference the PRD section(s) the change implements or the issue it closes.
- CI (once `T005` lands) will run `yarn lint`, `yarn typecheck`, `yarn test`, the iOS simulator build + Jest integration suite, the Android emulator build + Jest integration suite, and the golden-file pixel-hash suite. All jobs must be green.
- If your change touches the Nitro spec, confirm `yarn nitrogen` produces a clean diff *outside* your PR (the generated files stay gitignored).

---

## Reporting issues

Open a GitHub issue with: RN version, platform + OS version, package version, a minimal repro, and (if relevant) the output of `Video.capabilities()`. For crashes, include full native logs (`xcrun simctl spawn booted log stream` on iOS, `adb logcat` on Android).

---

## Code of conduct

Be kind, be precise, be patient. If you'd like to discuss a design change before writing code, open a discussion or draft PR first — we'd rather align early than review a large diff that misses a constraint in `CLAUDE.md`.
