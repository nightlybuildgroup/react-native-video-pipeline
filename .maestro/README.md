# Maestro E2E flows

[Maestro](https://maestro.mobile.dev/) end-to-end flows that drive the
`bare-example` app. Each flow taps a button by `testID`, waits for the result,
and asserts on the rendered result text.

## T048 smoke flows (synthesize + trim + stamp)

The canonical T048 flows drive the self-contained `run-remux-smoke` button,
which synthesizes a 160×120/30fps source, trims it, concatenates it, and stamps
metadata onto it — exercising the synthesize, trim, and stamp render paths in
one tap with no pre-pushed fixtures:

- `e2e-trim-synth-stamp-android.yaml` — `appId: com.bareexample`
- `e2e-trim-synth-stamp-ios.yaml` — `appId: org.reactjs.native.example.bareexample`

Run them via the package scripts:

```sh
yarn test:e2e:android
yarn test:e2e:ios
```

Other flows in this directory (`synthesize-probe*`, `stamp-watermark-android`,
`frame-number-overlay`, `perf-*`, `bootstrap-fixtures-probe`) are
single-purpose smokes from earlier tasks.

## Preconditions

1. **The app is built + installed** on the target device/simulator
   (`yarn workspace bare-example run android` / `run ios`, or a gradle
   `installDebug` / Xcode build).
2. **Metro is serving JS**, reachable from the app (`yarn workspace bare-example start`).
3. **The library's `lib/` is current** — the app bundles built JS, so run
   `yarn workspace react-native-video-pipeline build` after editing `src/`
   (see [`CONTRIBUTING.md`](../CONTRIBUTING.md#running-the-example-apps)).

## Known limitation — Maestro vs. very new Android

Maestro 2.0.3's Android driver does not attach to an **API 36 / Android 16**
emulator (its on-device gRPC server never comes up — `Connection refused …:7001`).
Run `test:e2e:android` against an API ≤ 35 emulator, or upgrade Maestro once it
supports API 36. The flow itself is correct: the `run-remux-smoke` path
(synthesize → trim → concat → stamp) completes green when driven directly
(verified via `adb shell input` on API 36).

## Out of scope here

- **Playwright** is _not_ configured in this repo. It is deferred to the
  docs-site work in v0.5; do not add a Playwright dependency here.
