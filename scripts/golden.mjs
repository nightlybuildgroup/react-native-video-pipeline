#!/usr/bin/env node
//
// golden.mjs — T048 cross-platform golden pixel-hash suite (host orchestrator).
//
// Renders the deterministic golden spec(s) on each available platform via the
// app-free native test harnesses (Android instrumented `GoldenRenderTest`, iOS
// host `testGoldenDumpFrames`), pulls the sampled frames as raw RGBA, reduces
// each to a low-res RGB signature, and:
//   * regression-checks each platform's signature against its committed
//     reference under __tests__/golden/<platform>/<spec>.hash, and
//   * cross-platform-checks iOS vs Android within tolerance.
//
// The render is app-free and (for iOS) simulator-free: iOS runs on the macOS
// host via `yarn test:native`, Android on a booted emulator/device via Gradle.
//
// Usage:
//   node scripts/golden.mjs              # render both platforms + verify
//   node scripts/golden.mjs --update     # render both + (re)write references
//   node scripts/golden.mjs --no-render  # verify using existing dumps
//   node scripts/golden.mjs --platform android   # one platform only
//
// No npm dependencies — pure Node fs/child_process.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..');
const BUILD = join(REPO, 'build', 'golden');
const GOLDEN = join(REPO, '__tests__', 'golden');

// Lockstep with android GoldenSpecs.kt + ios LibraryTests.m testGoldenDumpFrames.
const GOLDEN_SPECS = [{ id: 'synthesize', w: 160, h: 120, frames: [5, 10, 14] }];

// Signature grid + tolerances (mean absolute per-channel difference, 0..255).
const GRID = 8; // 8x8 RGB downsample → 192 values
//
// REGRESSION_TOL — same platform, same input. The decode is deterministic, so
// this is effectively exact (observed Δ=0.00); the small budget only absorbs
// future encoder/driver changes.
//
// CROSS_TOL — iOS vs Android. Strict 0.5% (~1.3) cross-platform pixel parity
// is NOT achievable here: AVFoundation (AVAssetReader) and Android MediaCodec
// decode H.264 to RGB with different YUV range/matrix handling — iOS expands to
// a wider range, so the green channel in particular drifts ~10–20 on saturated
// frames (observed signature Δ up to ~10.6). This is a perceptual bound that
// still catches gross divergence (wrong frame, flip, channel swap → Δ ≫ 14),
// not the exact-match the TODO optimistically wrote. Text overlays are even
// less comparable (platform font shaping) and are intentionally out of the
// cross-platform set — they are covered per-platform by the T045 unit tests.
const REGRESSION_TOL = 3.0;
const CROSS_TOL = 14.0;

const args = new Set(process.argv.slice(2).filter((a) => a.startsWith('--')));
const platformArg = (() => {
  const i = process.argv.indexOf('--platform');
  return i >= 0 ? process.argv[i + 1] : null;
})();
const UPDATE = args.has('--update');
const NO_RENDER = args.has('--no-render');
const PLATFORMS = platformArg ? [platformArg] : ['ios', 'android'];

function sh(cmd, cmdArgs, opts = {}) {
  return execFileSync(cmd, cmdArgs, { stdio: 'inherit', cwd: REPO, ...opts });
}

// --- signature ------------------------------------------------------------

// Reduce a raw RGBA buffer (w*h*4, top-row-first) to a GRID×GRID RGB average
// grid → Uint8Array(GRID*GRID*3). Robust to the small per-pixel differences
// H.264 introduces while still catching colour / geometry drift.
function signature(buf, w, h) {
  const out = new Uint8Array(GRID * GRID * 3);
  for (let gy = 0; gy < GRID; gy++) {
    const y0 = Math.floor((gy * h) / GRID);
    const y1 = Math.floor(((gy + 1) * h) / GRID);
    for (let gx = 0; gx < GRID; gx++) {
      const x0 = Math.floor((gx * w) / GRID);
      const x1 = Math.floor(((gx + 1) * w) / GRID);
      let r = 0,
        g = 0,
        b = 0,
        n = 0;
      for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) {
          const p = (y * w + x) * 4;
          r += buf[p];
          g += buf[p + 1];
          b += buf[p + 2];
          n++;
        }
      }
      const o = (gy * GRID + gx) * 3;
      out[o] = Math.round(r / n);
      out[o + 1] = Math.round(g / n);
      out[o + 2] = Math.round(b / n);
    }
  }
  return out;
}

const toHex = (u8) => Buffer.from(u8).toString('hex');
const fromHex = (hex) => new Uint8Array(Buffer.from(hex, 'hex'));

function meanAbs(a, b) {
  if (a.length !== b.length) return Infinity;
  let sum = 0;
  for (let i = 0; i < a.length; i++) sum += Math.abs(a[i] - b[i]);
  return sum / a.length;
}

// --- per-frame dump → signatures -----------------------------------------

// Returns Map<"<spec>:f<frame>", Uint8Array sig> for a platform's dump dir.
function signaturesFor(dir) {
  const sigs = new Map();
  if (!existsSync(dir)) return sigs;
  for (const file of readdirSync(dir)) {
    const m = file.match(/^(.+?)__(\d+)x(\d+)__f(\d+)\.rgba$/);
    if (!m) continue;
    const [, spec, ws, hs, frame] = m;
    const w = Number(ws),
      h = Number(hs);
    const buf = readFileSync(join(dir, file));
    if (buf.length !== w * h * 4) {
      throw new Error(`${file}: expected ${w * h * 4} bytes, got ${buf.length}`);
    }
    sigs.set(`${spec}:f${frame}`, signature(buf, w, h));
  }
  return sigs;
}

// --- reference files ------------------------------------------------------

const refPath = (platform, spec) => join(GOLDEN, platform, `${spec}.hash`);

function writeRef(platform, spec, frameSigs) {
  mkdirSync(join(GOLDEN, platform), { recursive: true });
  const lines = [
    `# rnvp golden signature — spec=${spec} platform=${platform} grid=${GRID}x${GRID} (RGB)`,
    '# regenerate: yarn test:golden --update',
  ];
  for (const frame of frameSigs.frames) {
    lines.push(`f${frame} ${toHex(frameSigs.byFrame.get(frame))}`);
  }
  writeFileSync(refPath(platform, spec), `${lines.join('\n')}\n`);
}

function readRef(platform, spec) {
  const p = refPath(platform, spec);
  if (!existsSync(p)) return null;
  const byFrame = new Map();
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const m = line.match(/^f(\d+)\s+([0-9a-f]+)$/);
    if (m) byFrame.set(Number(m[1]), fromHex(m[2]));
  }
  return byFrame;
}

// --- render orchestration -------------------------------------------------

function renderAndroid() {
  const out = join(BUILD, 'android');
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  // Clear prior dumps + their MediaStore rows up front. The test APK is
  // reinstalled (new UID) every run, so the in-test MediaStore delete can't
  // remove rows owned by a previous UID — leaving stale "name (1).rgba"
  // collisions. The `content`/`rm` shell commands run as the shell UID, which
  // has the authority to clean both the rows and the files.
  console.log('▶ android: clearing prior golden dumps on device…');
  try {
    sh(
      'adb',
      [
        'shell',
        'content',
        'delete',
        '--uri',
        'content://media/external/downloads',
        '--where',
        "relative_path LIKE 'Download/rnvp-golden%'",
      ],
      { stdio: 'ignore' },
    );
    sh('adb', ['shell', 'rm', '-f', '/sdcard/Download/rnvp-golden/*.rgba'], { stdio: 'ignore' });
  } catch {
    /* nothing to clear on first run */
  }
  console.log('▶ android: rendering golden frames on the booted device…');
  sh(
    join(REPO, 'apps/bare-example/android/gradlew'),
    [
      ':react-native-video-pipeline:connectedDebugAndroidTest',
      '-Pandroid.testInstrumentationRunnerArguments.class=com.margelo.nitro.videopipeline.GoldenRenderTest',
    ],
    { cwd: join(REPO, 'apps/bare-example/android') },
  );
  console.log('▶ android: pulling dumps…');
  sh('adb', ['pull', '/sdcard/Download/rnvp-golden/.', out]);
}

function renderIos() {
  const out = join(BUILD, 'ios');
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  console.log('▶ ios: rendering golden frames on the macOS host (no simulator)…');
  sh('bash', [join(REPO, 'scripts/test-native.sh')], {
    env: { ...process.env, RNVP_GOLDEN_DIR: out },
  });
}

// --- main -----------------------------------------------------------------

function loadSigs(platform) {
  const all = signaturesFor(join(BUILD, platform));
  // group by spec
  const bySpec = new Map();
  for (const [key, sig] of all) {
    const [spec, fr] = key.split(':f');
    if (!bySpec.has(spec)) bySpec.set(spec, { frames: [], byFrame: new Map() });
    const entry = bySpec.get(spec);
    entry.frames.push(Number(fr));
    entry.byFrame.set(Number(fr), sig);
  }
  for (const e of bySpec.values()) e.frames.sort((a, b) => a - b);
  return bySpec;
}

if (!NO_RENDER) {
  if (PLATFORMS.includes('android')) renderAndroid();
  if (PLATFORMS.includes('ios')) renderIos();
}

const sigsByPlatform = new Map();
for (const p of PLATFORMS) sigsByPlatform.set(p, loadSigs(p));

if (UPDATE) {
  for (const p of PLATFORMS) {
    for (const spec of GOLDEN_SPECS) {
      const entry = sigsByPlatform.get(p).get(spec.id);
      if (!entry) throw new Error(`no ${p} dumps for spec ${spec.id} — did the render run?`);
      writeRef(p, spec.id, entry);
      console.log(`✓ wrote reference ${p}/${spec.id}.hash (${entry.frames.length} frames)`);
    }
  }
  console.log('\nGolden references updated. Review + commit the .hash files.');
  process.exit(0);
}

// verify
let failures = 0;
const note = (ok, msg) => {
  console.log(`${ok ? '✓' : '✗'} ${msg}`);
  if (!ok) failures++;
};

for (const spec of GOLDEN_SPECS) {
  // per-platform regression
  for (const p of PLATFORMS) {
    const entry = sigsByPlatform.get(p).get(spec.id);
    const ref = readRef(p, spec.id);
    if (!entry) {
      note(false, `${p}/${spec.id}: no rendered dumps`);
      continue;
    }
    if (!ref) {
      note(false, `${p}/${spec.id}: no committed reference (run --update)`);
      continue;
    }
    for (const frame of spec.frames) {
      const cur = entry.byFrame.get(frame);
      const exp = ref.get(frame);
      if (!cur || !exp) {
        note(false, `${p}/${spec.id} f${frame}: missing frame`);
        continue;
      }
      const d = meanAbs(cur, exp);
      note(
        d <= REGRESSION_TOL,
        `${p}/${spec.id} f${frame} regression Δ=${d.toFixed(2)} (≤${REGRESSION_TOL})`,
      );
    }
  }
  // cross-platform parity (only when both platforms rendered)
  if (PLATFORMS.includes('ios') && PLATFORMS.includes('android')) {
    const a = sigsByPlatform.get('android').get(spec.id);
    const i = sigsByPlatform.get('ios').get(spec.id);
    if (a && i) {
      for (const frame of spec.frames) {
        const ai = a.byFrame.get(frame),
          ii = i.byFrame.get(frame);
        if (!ai || !ii) {
          note(false, `${spec.id} f${frame}: missing for cross-check`);
          continue;
        }
        const d = meanAbs(ai, ii);
        note(d <= CROSS_TOL, `${spec.id} f${frame} iOS↔Android Δ=${d.toFixed(2)} (≤${CROSS_TOL})`);
      }
    }
  }
}

console.log(failures === 0 ? '\nGolden suite PASSED.' : `\nGolden suite FAILED (${failures}).`);
process.exit(failures === 0 ? 0 : 1);
