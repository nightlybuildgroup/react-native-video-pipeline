/**
 * bare-example — smoke test harness for react-native-video-pipeline.
 *
 * Two buttons:
 *   - "Call Video.capabilities()" — kept from T017; on Android (T040 skeleton
 *     state) it still surfaces a typed "not implemented yet" error so the
 *     bridge wiring is observable.
 *   - "Run Video.synthesize()" — T041 smoke. Synthesizes a 160×120/30fps/1s
 *     fixed render into the app's cache dir, reports the output file size.
 *     Exercises the full Kotlin SynthesizeRunner → MediaCodec+EGL+MediaMuxer
 *     pipeline on Android; on iOS it goes through RNVPSynthesizeRunner.
 */

// T054b — Skia is imported at module top so a missing / broken install crashes
// the app on start (loud failure) rather than silently mocking out. Canvas is
// rendered below so the native-side SkiaViewManager also has to be linked, not
// just the JS module. Invariant #3 is preserved: the main `react-native-video-
// pipeline` package is still Skia-free; bare-example depends on Skia directly
// (consumers opt into Skia the same way).
import { Canvas, matchFont, Rect, Skia } from '@shopify/react-native-skia';
import type React from 'react';
import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  NativeModules,
  Platform,
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';

import { bootstrapPatternRGBA, drawWithRGBA, Overlay, Video } from 'react-native-video-pipeline';
import { drawWithSkia } from 'react-native-video-pipeline-skia';

const SKIA_LOAD_SIGNATURE =
  typeof Skia.Surface.MakeOffscreen === 'function'
    ? `Skia.Surface.MakeOffscreen: function`
    : `Skia.Surface.MakeOffscreen: ${typeof Skia.Surface.MakeOffscreen}`;

// Resolve a platform-writable scratch dir without pulling in react-native-fs.
// React Native exposes these via the RNCExternalStorageDirectory-style modules
// in the standard CLI template — but we only need something writable, so fall
// back to a known-writable app-local path when the constant isn't present.
function resolveTempDir(): string {
  if (Platform.OS === 'ios') {
    const c = (NativeModules.RNCFileSystem?.Constants ?? NativeModules.BlobModule) as
      | { CacheDir?: string; TemporaryDirectoryPath?: string }
      | undefined;
    return c?.CacheDir ?? c?.TemporaryDirectoryPath ?? '/tmp';
  }
  // Android: every app has /data/data/<pkg>/cache writable by the app process.
  return '/data/data/com.bareexample/cache';
}

type Result =
  | { kind: 'idle' }
  | { kind: 'loading' }
  | { kind: 'ok'; value: string }
  | { kind: 'error'; name: string; message: string };

function App(): React.JSX.Element {
  const [result, setResult] = useState<Result>({ kind: 'idle' });
  const [skiaBoot, setSkiaBoot] = useState<string>('pending');
  // Per-stage markers for the perf flow. Maestro waits on each testID
  // (`perf-stage-${name}`) — RN Text exposes content via accessibilityText
  // which Maestro's `visible:` matcher does NOT query, so per-stage testIDs
  // are the only reliable way to drive the staged flow.
  const [perfStages, setPerfStages] = useState<{ name: string; line: string }[]>([]);
  const [perfProgress, setPerfProgress] = useState<string>('');

  // T054b verification — prove Skia actually executes in Hermes, not just
  // resolves as a module. MakeOffscreen(1,1) is the cheapest real call that
  // exercises the native GPU context + SkSurface allocation. If this returns
  // null the Skia install is broken at runtime even though the import and
  // types resolved. Logged so the smoke-flow stdout scraper can assert on it.
  useEffect(() => {
    try {
      const surface = Skia.Surface.MakeOffscreen(1, 1);
      if (surface == null) {
        const msg = 'Skia boot: MakeOffscreen(1,1) returned null';
        console.warn(msg);
        setSkiaBoot(msg);
        return;
      }
      surface.dispose?.();
      const msg = `Skia boot: OK (${SKIA_LOAD_SIGNATURE})`;
      console.log(msg);
      setSkiaBoot(msg);
    } catch (err) {
      const e = err as Error;
      const msg = `Skia boot: threw ${e.name}: ${e.message}`;
      console.error(msg);
      setSkiaBoot(msg);
    }
  }, []);

  const run = async () => {
    setResult({ kind: 'loading' });
    try {
      const caps = await Video.capabilities();
      setResult({ kind: 'ok', value: JSON.stringify(caps, null, 2) });
    } catch (err) {
      const e = err as Error;
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  const runSynthesize = async () => {
    setResult({ kind: 'loading' });
    try {
      const outPath = `${resolveTempDir()}/rnvp-synth-smoke.mp4`;
      const t0 = Date.now();
      // T054d — exercises the real JS → Nitro → renderCompose → HybridFrameTarget
      // → CVPixelBuffer → AVAssetWriter path end-to-end. drawWithRGBA wraps the
      // ctx.target.writeBytes boilerplate; the per-pixel body is the canonical
      // BOOTSTRAP_PATTERN (rotating-triangle gradient) so a future XCTest / smoke
      // probe can decode a known frame's center pixel and compare against
      // expectedCenterRGBA.
      await Video.synthesize({
        output: { path: outPath, width: 160, height: 120, fps: 30 },
        duration: { mode: 'fixed', seconds: 1.0 },
        drawFrame: drawWithRGBA((pixels, ctx) => {
          'worklet';
          const { width, height, frameIndex } = ctx;
          for (let y = 0; y < height; y++) {
            for (let x = 0; x < width; x++) {
              const rgba = bootstrapPatternRGBA(frameIndex, x, y, width, height);
              const i = (y * width + x) * 4;
              pixels[i] = rgba.r;
              pixels[i + 1] = rgba.g;
              pixels[i + 2] = rgba.b;
              pixels[i + 3] = rgba.a;
            }
          }
        }),
      });
      const elapsed = Date.now() - t0;
      setResult({
        kind: 'ok',
        value: `platform=${Platform.OS}\npath=${outPath}\nelapsed=${elapsed}ms\npattern=BOOTSTRAP_PATTERN via drawWithRGBA`,
      });
    } catch (err) {
      const e = err as Error;
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  const runSynthesizeSkia = async () => {
    setResult({ kind: 'loading' });
    try {
      const outPath = `${resolveTempDir()}/rnvp-synth-skia.mp4`;
      const t0 = Date.now();
      // T054d (Skia path) — exercises drawWithSkia end-to-end through the
      // real worklet / compose pipeline. Proves Skia runs in Hermes during
      // a synthesize (not just as a mocked unit test) and that the helper's
      // CPU readback / GPU blit plumbing lands bytes in the MP4.
      await Video.synthesize({
        output: { path: outPath, width: 160, height: 120, fps: 30 },
        duration: { mode: 'fixed', seconds: 1.0 },
        drawFrame: drawWithSkia((canvas, ctx) => {
          'worklet';
          // Teal background + yellow square sliding with frame index so the
          // output is visibly animated and non-trivial. Asymmetric (x-only
          // motion) so a flip/rotation regression would shift probe values.
          canvas.drawColor(Skia.Color('#0ea5e9'));
          const paint = Skia.Paint();
          paint.setColor(Skia.Color('#fbbf24'));
          const travel = ctx.width - 32;
          const x = travel > 0 ? (ctx.frameIndex * 4) % travel : 0;
          canvas.drawRect(Skia.XYWHRect(x, 40, 32, 32), paint);
        }),
      });
      const elapsed = Date.now() - t0;
      setResult({
        kind: 'ok',
        value: `platform=${Platform.OS}\npath=${outPath}\nelapsed=${elapsed}ms\npattern=Skia teal+yellow via drawWithSkia`,
      });
    } catch (err) {
      const e = err as Error;
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  // T024 — generate the four declared bootstrap fixtures via the real
  // Video.synthesize + drawWithRGBA + bootstrapPatternRGBA pipeline. Proxy
  // resolutions (160×120) so the Maestro run completes in seconds rather
  // than minutes — the canonical full-resolution matrix (1080p/4K/720p from
  // __tests__/bootstrap/generators.ts) lands with the T048 golden-file
  // harness where CI has the budget for multi-gigabyte H.264 encodes.
  const runBootstrapFixtures = async () => {
    setResult({ kind: 'loading' });
    try {
      const tmp = resolveTempDir();
      type ProxyFixture = {
        readonly kind: 'animated' | 'gradient' | 'rotated' | 'hdrFlag';
        readonly fps: number;
        readonly seconds: number;
      };
      const fixtures: ProxyFixture[] = [
        { kind: 'animated', fps: 30, seconds: 1 },
        { kind: 'gradient', fps: 60, seconds: 0.5 },
        { kind: 'rotated', fps: 30, seconds: 0.5 },
        { kind: 'hdrFlag', fps: 30, seconds: 0.5 },
      ];
      const lines: string[] = [`platform=${Platform.OS}`];
      for (const f of fixtures) {
        const outPath = `${tmp}/rnvp-bootstrap-${f.kind}.mp4`;
        const t0 = Date.now();
        await Video.synthesize({
          output: { path: outPath, width: 160, height: 120, fps: f.fps },
          duration: { mode: 'fixed', seconds: f.seconds },
          drawFrame: drawWithRGBA((pixels, ctx) => {
            'worklet';
            const { width, height, frameIndex } = ctx;
            for (let y = 0; y < height; y++) {
              for (let x = 0; x < width; x++) {
                const rgba = bootstrapPatternRGBA(frameIndex, x, y, width, height);
                const i = (y * width + x) * 4;
                pixels[i] = rgba.r;
                pixels[i + 1] = rgba.g;
                pixels[i + 2] = rgba.b;
                pixels[i + 3] = rgba.a;
              }
            }
          }),
        });
        lines.push(`${f.kind}=${Date.now() - t0}ms ${outPath}`);
      }
      lines.push('pattern=BOOTSTRAP_PATTERN via drawWithRGBA (T024)');
      setResult({ kind: 'ok', value: lines.join('\n') });
    } catch (err) {
      const e = err as Error;
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  // T044 — Android transcode + watermark smoke. Bypasses Video.synthesize
  // (which on Android currently rejects with "renderCompose not implemented
  // — T041c") by using a pre-pushed source MP4 + watermark PNG that the
  // test runner stages via `adb push` before invocation. iOS simulator can
  // also run this if the same paths are populated; the flow is platform-
  // agnostic because Video.stamp itself is.
  const runStampWatermarkSmoke = async () => {
    setResult({ kind: 'loading' });
    try {
      const tmp = resolveTempDir();
      const src = `${tmp}/red-test.mp4`;
      const watermark = `${tmp}/yellow.png`;
      const outPath = `${tmp}/red-stamped.mp4`;
      const t0 = Date.now();
      await Video.stamp(`file://${src}`, {
        outPath,
        watermark: Overlay.Image({
          uri: `file://${watermark}`,
          anchor: 'center',
          size: { width: { unit: 'px', value: 40 }, height: { unit: 'px', value: 40 } },
        }),
        metadata: { software: 'rnvp-stamp-smoke' },
      });
      const elapsed = Date.now() - t0;
      setResult({
        kind: 'ok',
        value: `platform=${Platform.OS}\nsrc=${src}\nout=${outPath}\nelapsed=${elapsed}ms\npattern=stamp+ImageOverlay (T044)`,
      });
    } catch (err) {
      const e = err as Error;
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  // Tiered perf test — each stage updates the result-ok UI as it completes,
  // so a Maestro driver can wait on intermediate markers and fail fast when
  // any stage stalls. Stages get progressively heavier:
  //   1. probe  : Video.info(IMG_6643)              — should be ~tens of ms
  //   2. tiny   : 160x120 / 30fps / 0.1s (3 frames) — proves pipeline path
  //   3. medium : 360x640 / 30fps / 0.5s (15)       — exercises real shape
  //   4. native : full source w/h/fps for 0.5s      — perf measurement
  // Each stage is wrapped in try/catch so a failure surfaces in the result
  // UI without taking down the whole flow. iOS simulator only — file://
  // URLs to /Users/... paths work because the simulator runs on the host.
  const runPerfTestSkia = async () => {
    console.log('[perf] runPerfTestSkia entered');
    setResult({ kind: 'loading' });
    setPerfStages([]);
    const lines: string[] = [`platform=${Platform.OS}`];
    const stages: { name: string; line: string }[] = [];
    const flush = () => {
      setResult({ kind: 'ok', value: lines.join('\n') });
      setPerfStages([...stages]);
    };
    const recordStage = (name: string, line: string) => {
      console.log(`[perf] recordStage ${name}: ${line}`);
      stages.push({ name, line });
      flush();
    };

    const skiaDraw = drawWithSkia((canvas, ctx) => {
      'worklet';
      canvas.drawColor(Skia.Color('#1e293b'));
      const radius = 40 + (ctx.frameIndex % 30) * 2;
      const fillPaint = Skia.Paint();
      fillPaint.setColor(Skia.Color('#fbbf24'));
      canvas.drawCircle(ctx.width / 2, ctx.height / 2, radius, fillPaint);
      const dotPaint = Skia.Paint();
      dotPaint.setColor(Skia.Color('#ffffff'));
      const dotR = Math.max(4, Math.floor(ctx.width / 80));
      const dotPad = Math.max(2, Math.floor(dotR / 2));
      const dotsPerRow = Math.max(6, Math.floor(ctx.width / (dotR * 2 + dotPad) / 2));
      for (let i = 0; i < ctx.frameIndex; i++) {
        const col = i % dotsPerRow;
        const row = Math.floor(i / dotsPerRow);
        const x = 8 + col * (dotR * 2 + dotPad);
        const y = 8 + row * (dotR * 2 + dotPad);
        canvas.drawCircle(x, y, dotR, dotPaint);
      }
    });

    const sourceUri = 'file:///Users/biallas/proj/react-native-video-pipeline/IMG_6643.MP4';
    const tmp = resolveTempDir();

    try {
      // ---- Stage 1: probe ----
      console.log('[perf] probe: about to call Video.info', sourceUri);
      const t0 = Date.now();
      const info = await Video.info(sourceUri);
      console.log('[perf] probe: Video.info returned in', Date.now() - t0, 'ms');
      const probeLine = `probe=${Date.now() - t0}ms ${Math.round(info.width)}x${Math.round(info.height)}@${info.fps}fps for ${info.durationSec.toFixed(2)}s codec=${info.codec}`;
      lines.push(probeLine);
      lines.push(`  rotation=${info.rotation}° container=${info.container}`);
      recordStage('probe', probeLine);

      // Helper that runs one synth stage with a tight wall-clock budget.
      const stage = async (
        name: string,
        width: number,
        height: number,
        fps: number,
        seconds: number,
      ): Promise<void> => {
        const nb = Math.round(fps * seconds);
        console.log(
          `[perf] stage ${name} starting ${width}x${height}@${fps} for ${seconds}s (${nb} frames)`,
        );
        const t = Date.now();
        let lastProgressUpdate = 0;
        await Video.synthesize({
          output: { path: `${tmp}/rnvp-perf-${name}.mp4`, width, height, fps },
          duration: { mode: 'fixed', seconds },
          drawFrame: skiaDraw,
          onProgress: (p) => {
            // Throttle UI updates to ≤5Hz so the render isn't dragged down
            // by React state churn at high frame rates.
            const now = Date.now();
            if (now - lastProgressUpdate < 200) return;
            lastProgressUpdate = now;
            const elapsed = now - t;
            setPerfProgress(
              `${name}: ${p.framesCompleted}/${p.nbFrames ?? '?'} @ ${elapsed}ms (${
                p.framesCompleted > 0 ? (elapsed / p.framesCompleted).toFixed(1) : '?'
              }ms/f)`,
            );
          },
        });
        const ms = Date.now() - t;
        const perFrame = nb > 0 ? (ms / nb).toFixed(1) : '?';
        const line = `${name}=${ms}ms (${width}x${height} ${nb}f ${perFrame}ms/f)`;
        lines.push(line);
        setPerfProgress('');
        recordStage(name, line);
      };

      // ---- Stage 2: tiny — proves pipeline path ----
      await stage('tiny', 160, 120, 30, 0.1);

      // ---- Stage 3: medium — real consumer shape ----
      await stage('medium', 360, 640, 30, 0.5);

      // ---- Stage 4: native shape, capped to 0.5s (~120f) so a stall
      //              fails fast. ----
      const nw = Math.round(info.width);
      const nh = Math.round(info.height);
      await stage('native', nw, nh, info.fps, 0.5);

      // ---- Stage 5: full duration native — only attempted after 0.5s
      //              passes, so we have a per-frame baseline. ----
      await stage('full', nw, nh, info.fps, info.durationSec);

      lines.push('done');
      recordStage('done', 'done');
    } catch (err) {
      const e = err as Error;
      console.log('[perf] caught error:', e.name ?? 'Error', '-', e.message ?? String(err));
      lines.push(`ERROR ${e.name ?? 'Error'}: ${e.message ?? String(err)}`);
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: lines.join('\n'),
      });
    }
  };

  // Compose-on-clip demo: take IMG_6643.MP4, draw the frame number on each
  // frame via Skia, write to disk. Exercises the renderCompose source-clip
  // branch — the native pump decodes source frames into BGRA pixel buffers
  // and hands each one to JS as `ctx.source`; drawWithSkia paints the source
  // image first and then we overlay text on top.
  const runFrameNumberOverlay = async () => {
    console.log('[fno] runFrameNumberOverlay entered');
    setResult({ kind: 'loading' });
    try {
      const sourceUri =
        Platform.OS === 'ios'
          ? 'file:///Users/biallas/proj/react-native-video-pipeline/IMG_6643.MP4'
          : 'file:///data/data/com.bareexample/files/IMG_6643.MP4';
      const outPath = `${resolveTempDir()}/rnvp-framenum.mp4`;
      const t0 = Date.now();
      console.log('[fno] calling Video.compose source=', sourceUri, 'out=', outPath);
      await Video.compose(
        {
          output: { path: outPath },
          // No `durationSec` → library probes and uses the rest of the source.
          clips: [{ uri: sourceUri, startSec: 0 }],
          metadata: {
            software: 'bare-example/rnvp v0.1',
            custom: {
              'com.acme.shotanalysis':
                '{"shot":{"dexterity":"leftHanded"},"author":"bare-example"}',
              'com.acme.processedAt': new Date().toISOString(),
            },
          },
        },
        {
          drawFrame: drawWithSkia((canvas, ctx) => {
            'worklet';
            // Red bar in top-left as orientation marker, plus the frame
            // number. Marker lands first so even if matchFont returns
            // something unrenderable the marker still proves the user
            // draw ran.
            const markerPaint = Skia.Paint();
            markerPaint.setColor(Skia.Color('#ef4444'));
            canvas.drawRect(Skia.XYWHRect(0, 0, ctx.width / 3, ctx.height / 12), markerPaint);

            const text = `Frame ${ctx.frameIndex}`;
            const fontSize = Math.max(48, ctx.width / 16);
            // Always pass an explicit fontFamily — matchFont's default on
            // Android returns a font whose typeface is null and drawText
            // silently no-ops. "sans-serif" resolves to Roboto on Android
            // and falls back to a default sans on iOS.
            const font = matchFont({ fontFamily: 'sans-serif', fontSize });
            const stroke = Skia.Paint();
            stroke.setColor(Skia.Color('#000000'));
            stroke.setStyle(1);
            stroke.setStrokeWidth(6);
            const fill = Skia.Paint();
            fill.setColor(Skia.Color('#fbbf24'));
            const x = Math.max(24, ctx.width / 24);
            const y = Math.max(96, ctx.height / 12);
            canvas.drawText(text, x, y, stroke, font);
            canvas.drawText(text, x, y, fill, font);
          }),
        },
      );
      const elapsed = Date.now() - t0;
      console.log('[fno] elapsed=', elapsed, 'ms');
      setResult({
        kind: 'ok',
        value: `platform=${Platform.OS}\npath=${outPath}\nelapsed=${elapsed}ms`,
      });
    } catch (err) {
      const e = err as Error;
      console.log('[fno] caught', e.name ?? 'Error', '-', e.message ?? String(err));
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  const runRemuxSmoke = async () => {
    setResult({ kind: 'loading' });
    try {
      const tmp = resolveTempDir();
      const srcPath = `${tmp}/rnvp-remux-src.mp4`;
      const trimPath = `${tmp}/rnvp-remux-trim.mp4`;
      const concatPath = `${tmp}/rnvp-remux-concat.mp4`;
      const stampPath = `${tmp}/rnvp-remux-stamp.mp4`;
      const drawFrame = (() => {
        'worklet';
      }) as (ctx: unknown) => void;

      const t0 = Date.now();
      await Video.synthesize({
        output: { path: srcPath, width: 160, height: 120, fps: 30 },
        duration: { mode: 'fixed', seconds: 2.0 },
        drawFrame,
      });
      const tSynth = Date.now() - t0;

      const t1 = Date.now();
      // Keyframe-aligned trim (start at 0.0). The iOS T027 test uses the
      // same pattern because AVAssetWriter / MediaCodec both place the only
      // keyframe at PTS 0 for short fixtures; non-keyframe trim precision
      // on Android requires Media3 Transformer edit lists (follow-up).
      await Video.trim(`file://${srcPath}`, {
        startSec: 0.0,
        durationSec: 1.0,
        outPath: trimPath,
      });
      const tTrim = Date.now() - t1;

      const t2 = Date.now();
      await Video.render(
        {
          output: { path: concatPath },
          clips: [
            { uri: `file://${srcPath}`, startSec: 0, durationSec: 2.0 },
            { uri: `file://${srcPath}`, startSec: 0, durationSec: 2.0 },
          ],
        },
        {},
      );
      const tConcat = Date.now() - t2;

      const t3 = Date.now();
      await Video.stamp(`file://${srcPath}`, {
        outPath: stampPath,
        metadata: { location: { latitude: 48.8584, longitude: 2.2945 } },
      });
      const tStamp = Date.now() - t3;

      setResult({
        kind: 'ok',
        value: [
          `platform=${Platform.OS}`,
          `synth=${tSynth}ms ${srcPath}`,
          `trim=${tTrim}ms ${trimPath}`,
          `concat=${tConcat}ms ${concatPath}`,
          `stamp=${tStamp}ms ${stampPath}`,
        ].join('\n'),
      });
    } catch (err) {
      const e = err as Error;
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  // High-fps end-to-end smoke: a longer 240fps clip must run through every
  // re-encoding render path. Synthesizes 5s @ 240fps (1200 frames), then trims
  // (remux passthrough) and re-encodes (resize transcode) the full timeline.
  // Exercises the #32 encode paths (no wall-clock deadline) at high frame
  // count through RN → Nitro → native. Measured ~0.2ms/frame; 1200 frames
  // synthesize in ~260ms, so the whole chain is well under a second of native
  // work (logged for visibility).
  const runHighFpsSmoke = async () => {
    setResult({ kind: 'loading' });
    try {
      const tmp = resolveTempDir();
      const srcPath = `${tmp}/rnvp-hifps-src.mp4`;
      const trimPath = `${tmp}/rnvp-hifps-trim.mp4`;
      const reencPath = `${tmp}/rnvp-hifps-reenc.mp4`;
      const drawFrame = (() => {
        'worklet';
      }) as (ctx: unknown) => void;

      const t0 = Date.now();
      await Video.synthesize({
        output: { path: srcPath, width: 160, height: 120, fps: 240 },
        duration: { mode: 'fixed', seconds: 5.0 },
        drawFrame,
      });
      const tSynth = Date.now() - t0;

      const t1 = Date.now();
      await Video.trim(`file://${srcPath}`, {
        startSec: 0.0,
        durationSec: 5.0,
        outPath: trimPath,
      });
      const tTrim = Date.now() - t1;

      const t2 = Date.now();
      await Video.render(
        {
          output: { path: reencPath, width: 80, height: 60, fps: 240 },
          clips: [{ uri: `file://${srcPath}`, startSec: 0, durationSec: 5.0 }],
        },
        {},
      );
      const tReenc = Date.now() - t2;

      const value = [
        `platform=${Platform.OS}`,
        `hifps-synth=${tSynth}ms ${srcPath}`,
        `hifps-trim=${tTrim}ms ${trimPath}`,
        `hifps-reenc=${tReenc}ms ${reencPath}`,
      ].join('\n');
      console.log(value);
      setResult({ kind: 'ok', value });
    } catch (err) {
      const e = err as Error;
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  const runProbeSmoke = async () => {
    setResult({ kind: 'loading' });
    try {
      const tmp = resolveTempDir();
      const srcPath = `${tmp}/rnvp-probe-src.mp4`;
      const thumbPath = `${tmp}/rnvp-probe-thumb.jpg`;
      const drawFrame = (() => {
        'worklet';
      }) as (ctx: unknown) => void;

      await Video.synthesize({
        output: { path: srcPath, width: 160, height: 120, fps: 30 },
        duration: { mode: 'fixed', seconds: 1.0 },
        drawFrame,
      });

      const t0 = Date.now();
      const info = await Video.info(`file://${srcPath}`);
      const tInfo = Date.now() - t0;

      const t1 = Date.now();
      const returnedThumbPath = await Video.thumbnail(`file://${srcPath}`, {
        atSec: 0.5,
        outPath: thumbPath,
        resizeTo: { w: 80, h: 60 },
      });
      const tThumb = Date.now() - t1;

      const t2 = Date.now();
      const caps = await Video.capabilities();
      const tCaps = Date.now() - t2;

      setResult({
        kind: 'ok',
        value: [
          `platform=${Platform.OS}`,
          `info=${tInfo}ms ${JSON.stringify(info)}`,
          `thumb=${tThumb}ms ${returnedThumbPath}`,
          `caps=${tCaps}ms ${JSON.stringify(caps)}`,
        ].join('\n'),
      });
    } catch (err) {
      const e = err as Error;
      setResult({
        kind: 'error',
        name: e.name ?? 'Error',
        message: e.message ?? String(err),
      });
    }
  };

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar barStyle="dark-content" backgroundColor={colors.bg} />
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>react-native-video-pipeline</Text>
        <Text style={styles.subtitle}>
          Tap the button to call Video.capabilities(). At this stage the native module is expected
          to throw a typed "not implemented" error.
        </Text>

        {/* T054b — Skia boot banner + live Canvas. If Skia didn't load the
            import crashes the app; if it loaded but the native view isn't
            linked the Canvas mounts as an empty box. Both are clearly
            observable from a smoke run. */}
        <View testID="skia-boot" style={styles.skiaBox}>
          <Text style={styles.skiaLabel} testID="skia-boot-status">
            {skiaBoot}
          </Text>
          <View style={styles.skiaCanvasWrapper}>
            <Canvas style={styles.skiaCanvas} testID="skia-canvas">
              <Rect x={8} y={8} width={48} height={48} color="#1e40af" />
              <Rect x={24} y={24} width={32} height={32} color="#dc2626" />
            </Canvas>
          </View>
        </View>

        <TouchableOpacity
          accessibilityRole="button"
          testID="call-capabilities"
          style={styles.button}
          onPress={run}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Call Video.capabilities()</Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-synthesize"
          style={styles.button}
          onPress={runSynthesize}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Run Video.synthesize() (1s fixed)</Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-synthesize-skia"
          style={styles.button}
          onPress={runSynthesizeSkia}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Run Video.synthesize() via drawWithSkia</Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-bootstrap-fixtures"
          style={styles.button}
          onPress={runBootstrapFixtures}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Run bootstrap fixtures (T024)</Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-stamp-watermark"
          style={styles.button}
          onPress={runStampWatermarkSmoke}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Run stamp + watermark (T044)</Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-perf-skia"
          style={styles.button}
          onPress={runPerfTestSkia}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Run perf test (info + Skia)</Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-frame-number-overlay"
          style={styles.button}
          onPress={runFrameNumberOverlay}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Stamp frame # on IMG_6643 (Skia compose-on-clip)</Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-highfps-smoke"
          style={styles.button}
          onPress={runHighFpsSmoke}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>
            Run high-fps smoke (synth + trim + transcode @ 240fps × 5s)
          </Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-remux-smoke"
          style={styles.button}
          onPress={runRemuxSmoke}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Run remux smoke (synth + trim + concat + stamp)</Text>
        </TouchableOpacity>

        <TouchableOpacity
          accessibilityRole="button"
          testID="run-probe-smoke"
          style={styles.button}
          onPress={runProbeSmoke}
          disabled={result.kind === 'loading'}
        >
          <Text style={styles.buttonLabel}>Run probe smoke (info + thumbnail + caps)</Text>
        </TouchableOpacity>

        <View style={styles.resultBox} testID="result-box">
          {result.kind === 'idle' && <Text style={styles.idle}>No call yet.</Text>}
          {result.kind === 'loading' && <ActivityIndicator />}
          {perfProgress !== '' && (
            <Text testID="perf-progress" style={styles.ok}>
              {perfProgress}
            </Text>
          )}
          {result.kind === 'ok' && (
            <>
              <Text style={styles.okLabel}>Capabilities:</Text>
              <Text style={styles.ok} testID="result-ok">
                {result.value}
              </Text>
              {/* Per-stage markers for the perf test — each stage gets its
                  own testID so Maestro can wait on `perf-stage-<name>`. RN
                  Text content lands in `accessibilityText` (not `text`)
                  which Maestro's `visible:` regex doesn't match, so we
                  rely on testID-based assertions. */}
              {perfStages.map((s) => (
                <Text
                  key={s.name}
                  testID={`perf-stage-${s.name}`}
                  style={styles.ok}
                  accessibilityLabel={s.line}
                >
                  {s.line}
                </Text>
              ))}
            </>
          )}
          {result.kind === 'error' && (
            <>
              <Text style={styles.errLabel}>{result.name}</Text>
              <Text style={styles.err} testID="result-error">
                {result.message}
              </Text>
            </>
          )}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const colors = {
  bg: '#ffffff',
  text: '#111111',
  muted: '#444444',
  faint: '#6b7280',
  border: '#e5e7eb',
  primary: '#1e40af',
  primaryText: '#ffffff',
  ok: '#065f46',
  err: '#991b1b',
} as const;

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.bg },
  content: { padding: 24, gap: 16 },
  title: { fontSize: 22, fontWeight: '700', color: colors.text },
  subtitle: { fontSize: 14, color: colors.muted, lineHeight: 20 },
  button: {
    backgroundColor: colors.primary,
    paddingVertical: 14,
    paddingHorizontal: 20,
    borderRadius: 10,
    alignItems: 'center',
  },
  buttonLabel: { color: colors.primaryText, fontSize: 16, fontWeight: '600' },
  resultBox: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 10,
    padding: 16,
    minHeight: 120,
  },
  skiaBox: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 10,
    padding: 12,
    gap: 8,
  },
  skiaLabel: { fontFamily: 'Menlo', fontSize: 11, color: colors.muted },
  skiaCanvasWrapper: {
    alignItems: 'center',
    justifyContent: 'center',
    height: 64,
  },
  skiaCanvas: { width: 64, height: 64 },
  idle: { color: colors.faint },
  okLabel: { fontWeight: '600', marginBottom: 6, color: colors.ok },
  ok: { fontFamily: 'Menlo', fontSize: 12, color: colors.ok },
  errLabel: { fontWeight: '700', marginBottom: 6, color: colors.err },
  err: { fontFamily: 'Menlo', fontSize: 13, color: colors.err },
});

export default App;
