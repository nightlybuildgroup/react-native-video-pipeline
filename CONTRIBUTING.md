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
yarn lint              # Biome + ESLint
yarn format            # Biome formatter; should leave a clean tree
yarn typecheck         # strict TS across every workspace
yarn test              # Jest, across workspaces
yarn nitrogen          # regenerate native bindings from the Nitro spec
```

- **Nitro spec.** `packages/react-native-video-pipeline/src/nitro/VideoPipeline.nitro.ts` is the **single source of truth** for every cross-boundary type. Change types there and run `yarn nitrogen` to regenerate. Never hand-edit files under `nitrogen/`.
- **Derived artifacts** (`nitrogen/`, `packages/react-native-video-pipeline/plugin/build/`) are gitignored. The Expo plugin's `plugin/build/` is shipped to npm via the package's `files` allowlist + a `prepack` script — it never goes through git.

### Test suites

| Command | What it runs | Needs |
| --- | --- | --- |
| `yarn test` | Jest (JS unit + bootstrap canaries) | — |
| `yarn test:native` | iOS AVFoundation/CoreVideo XCTests, compiled against `-sdk macosx` and run on the host (~6s) — no simulator | macOS + Xcode |
| `yarn test:golden` | Cross-platform golden pixel-hash suite (see [`__tests__/golden/README.md`](./__tests__/golden/README.md)). App-free: renders on the Android emulator + iOS host, compares signatures. `--update` regenerates references. | booted Android emulator + macOS/Xcode |
| `yarn test:e2e:android` / `yarn test:e2e:ios` | Maestro smoke flow (synthesize + trim + stamp) against `bare-example` (see [`.maestro/README.md`](./.maestro/README.md)) | installed app + Metro + Maestro |
| `yarn smoke:ios` | lint + typecheck + `test` + `test:native`, then a `bare-example` simulator build | macOS + Xcode + simulator |
| Android instrumented | `./gradlew :react-native-video-pipeline:connectedDebugAndroidTest` (overlay/foreground-service/golden render + the Media3 composite paths). Run locally before landing Android changes; the matching CI workflow is manual-only — see [Continuous integration](#continuous-integration). | booted Android emulator |

### Running the example apps

```sh
# iOS (from repo root)
yarn workspace bare-example run ios

# Android
yarn workspace bare-example run android
```

The bare example is the fastest path to exercise a native change end-to-end. The Expo example exists to verify the bundled config plugin.

> **⚠️ The example app runs the library's _built_ JS, not `src/`.** `react-native-video-pipeline`'s `main` points at `lib/commonjs/`, so Metro bundles the **last `bob build` output**. After editing anything under `packages/react-native-video-pipeline/src/**`, rebuild before the app picks it up:
>
> ```sh
> yarn workspace react-native-video-pipeline build
> ```
>
> Symptom of a stale `lib/`: the app throws a runtime error from an API shape that no longer matches `src/` (e.g. `VideoPipeline.render(...): Value is undefined, expected a number`). Native (`cpp/**`, `ios/**`, `android/**`) changes are picked up by the normal app rebuild and don't need this step.

#### Android emulator disk space

RN debug builds are large and the default Pixel AVD ships a **6 GB** data partition, so repeated installs (plus the test-APK that `connectedAndroidTest` installs) fill it and `installDebug` fails with `Requested internal only, but not enough space`. Two levers:

- **Build one ABI.** The debug APK bundles all four ABIs (~183 MB of native libs); the emulator only needs one. On Apple Silicon: `./gradlew :app:installDebug -PreactNativeArchitectures=arm64-v8a` (or set `reactNativeArchitectures=arm64-v8a` in `apps/bare-example/android/gradle.properties`). This cuts the install from ~191 MB to ~60 MB.
- **Grow the partition.** Recreate the AVD with a larger data partition (e.g. `disk.dataPartition.size=16G` in `~/.android/avd/<name>.avd/config.ini`, or boot with `emulator -avd <name> -partition-size 16384`).

Housekeeping between runs: `adb uninstall <stale.pkg>` and `adb shell pm trim-caches 9G`.

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
- If your change touches the Nitro spec, confirm `yarn nitrogen` produces a clean diff *outside* your PR (the generated files stay gitignored).

---

## Continuous integration

CI lives under [`.github/workflows/`](./.github/workflows/). It is being built out incrementally; the planned full gate (`yarn lint`, `yarn typecheck`, `yarn test`, the iOS simulator build + Jest integration suite, and the golden-file pixel-hash suite) is tracked separately.

### `android-instrumented.yml`

Runs the Android **instrumented** suite (`connectedDebugAndroidTest`) on a GitHub-hosted emulator across an **API 36 + API 26** matrix. This is the only job that exercises the real Media3 encode/composite pipeline — hardware-encoder behaviour, coded-vs-displayed dimensions/rotation, `OverlayEffect` / `VideoCompositorSettings`, audio muxing — none of which the offline Kotlin compile or host JS/iOS suites can reach.

**This workflow is disabled in CI — it runs only on manual `workflow_dispatch`, not on pushes or PRs.** Booting a GitHub-hosted emulator per run is too slow/expensive to gate every push/PR for this project, so the instrumented suite is run **locally against a booted emulator** before landing Android changes ([#56](https://github.com/nightlybuildgroup/react-native-video-pipeline/issues/56), closed won't-do). The workflow is kept so it can be dispatched on demand (e.g. to reproduce an API-36-specific failure on a clean image) and so the hard-won setup notes below aren't lost. To re-enable automatic runs, add `push` / `pull_request` triggers back to the `on:` block.

Notes for anyone editing this workflow:

- **API 36 is load-bearing.** [#49](https://github.com/nightlybuildgroup/react-native-video-pipeline/issues/49) (single-dimension output stored as coded-landscape + rotation) only reproduced on API 36's hardware AVC encoder. Don't drop it from the matrix. The lower leg is **API 26**, not the library's `minSdk` of 24: the instrumented APK is assembled from `apps/bare-example/android`, which pins `minSdkVersion = 26` (the Skia AHardwareBuffer compose path needs `__ANDROID_API__ >= 26`), so a 24-image emulator can't install it.
- **Build one ABI.** `reactNativeArchitectures=x86_64` is forced via `ORG_GRADLE_PROJECT_reactNativeArchitectures` so the APK stays small *and* its native `.so` matches the x86_64 emulator image (see the disk-space note above).
- **Nitrogen runs before Gradle.** `nitrogen/` is gitignored; the Android build applies a generated autolinking `.gradle` file, so `yarn nitrogen` must run first.
- The native toolchain (`ndk;27.1.12297006`, `cmake;3.22.1`, `platforms;android-36`, `build-tools;36.0.0`) is pinned explicitly so the build doesn't depend on the runner image's preinstalled set.

---

## Reporting issues

Open a GitHub issue with: RN version, platform + OS version, package version, a minimal repro, and (if relevant) the output of `Video.capabilities()`. For crashes, include full native logs (`xcrun simctl spawn booted log stream` on iOS, `adb logcat` on Android).

---

## Code of conduct

Be kind, be precise, be patient. If you'd like to discuss a design change before writing code, open a discussion or draft PR first — we'd rather align early than review a large diff that misses a constraint in `CLAUDE.md`.
