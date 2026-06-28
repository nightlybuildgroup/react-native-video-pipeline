# Synthesize — generate a clip from scratch

`Video.synthesize` is null-input compose. There are no source clips; every output frame comes from your `drawFrame` worklet. `output.width`, `output.height`, `output.fps`, and `duration` are all required.

`ctx.source` is always `undefined` on this path.

## Fixed-duration synthesize

```ts
import { Video, drawWithRGBA } from 'react-native-video-pipeline';

await Video.synthesize({
  output: { path: `${dir}/synth.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'fixed', seconds: 2 },
  drawFrame: drawWithRGBA((pixels, ctx) => {
    'worklet';
    const phase = (ctx.frameIndex * 4) & 0xff;
    for (let i = 0; i < pixels.length; i += 4) {
      pixels[i]     = phase;
      pixels[i + 1] = 128;
      pixels[i + 2] = 255;
      pixels[i + 3] = 255;
    }
  }),
});
```

Output PTS is deterministic: `timeSec === frameIndex / fps`. The render is offline — wall-clock and output time are unrelated.

## Open-ended synthesize with a controller

When you don't know the duration up front (e.g., recording a Reanimated animation until the user hits stop), use `duration: { mode: 'open' }` and stop with a `VideoRenderController`. The `controller.finish()` finalizes the output cleanly; `controller.abort()` discards it.

```ts
import { Video, VideoRenderController, drawWithRGBA } from 'react-native-video-pipeline';

const controller = new VideoRenderController();

const promise = Video.synthesize({
  output: { path: `${dir}/synth-open.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'open' },
  controller,
  drawFrame: drawWithRGBA((pixels, ctx) => {
    'worklet';
    if (ctx.timeSec >= 5) {
      ctx.finish(); // worklet-side graceful stop
      return;
    }
    // ... fill pixels ...
  }),
});

// or stop from JS:
setTimeout(() => controller.finish(), 5000);

await promise; // resolves normally on finish, rejects with CancelledError on abort
```

You can also stop with an `AbortSignal` — but `signal.abort()` discards the output. Use the controller's `finish()` to keep it.

See [`cancel-and-finish.md`](./cancel-and-finish.md) for the full cancellation matrix.

## Audio on a synthesized render

A synthesized render is **video-only** — there is no source soundtrack. `audio.mode` `'passthrough'` and `'mute'` are both accepted and produce the same video-only output. `'replace'` is **rejected** with `InvalidSpecError`: a synthesized render has no source timeline to mux a soundtrack onto.

To put a backing track under synthesized frames, render the video first, then add the audio in a second pass over a clip:

```ts
await Video.synthesize({
  output: { path: `${dir}/synth.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'fixed', seconds: 4 },
  drawFrame: myDrawer,
});
await Video.render({
  clips: [{ uri: `${dir}/synth.mp4` }],
  output: { path: `${dir}/synth-audio.mp4` },
  audio: { mode: 'replace', replaceUri: backingTrackUri },
});
```

## With metadata

```ts
await Video.synthesize({
  output: { path: `${dir}/synth-meta.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'fixed', seconds: 2 },
  metadata: {
    software: 'MyApp 1.4',
    creationDate: new Date(),
    custom: { generator: 'demo-1' },
  },
  drawFrame: myDrawer,
});
```

## See also

- [`compose.md`](./compose.md) — compose over a source clip
- [`compose-skia.md`](./compose-skia.md) — Skia path
- [`cancel-and-finish.md`](./cancel-and-finish.md) — controller vs. AbortSignal
- [`../api.md#videosynthesize`](../api.md#videosynthesize) — full type reference
