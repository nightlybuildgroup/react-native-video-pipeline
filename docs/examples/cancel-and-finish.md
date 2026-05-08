# Cancel or gracefully finish a render

Two distinct mechanisms — pick the one that matches the semantics you want:

- **`AbortSignal`** — discard the output. The render promise rejects with `CancelledError`. Works on every render path.
- **`VideoRenderController`** — graceful end-of-stream for open-ended renders. `finish()` finalizes the output (promise resolves); `abort()` discards it (promise rejects). On fixed-duration renders, `finish()` is a no-op.

Both can be combined; either firing stops the render.

## AbortSignal — discard output

```ts
import { Video, CancelledError, drawWithRGBA } from 'react-native-video-pipeline';

const ac = new AbortController();

const promise = Video.synthesize({
  output: { path: `${dir}/x.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'fixed', seconds: 10 },
  signal: ac.signal,
  drawFrame: myDrawer,
});

// later:
ac.abort();

try {
  await promise;
} catch (err) {
  if (err instanceof CancelledError) {
    // file at outPath is incomplete and should be considered garbage
  } else {
    throw err;
  }
}
```

## VideoRenderController — finalize output

Use this when you want to **keep** what's been rendered so far. Only meaningful for `duration: { mode: 'open' }`.

```ts
import { Video, VideoRenderController } from 'react-native-video-pipeline';

const controller = new VideoRenderController();

const promise = Video.synthesize({
  output: { path: `${dir}/x.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'open' },
  controller,
  drawFrame: myDrawer,
});

// later:
controller.finish(); // stop after current frame, finalize file
await promise;       // resolves normally
```

`controller.state` reads as `'running' | 'finishing' | 'aborted' | 'done'`. Both `finish()` and `abort()` are idempotent.

## Worklet-side `ctx.finish()`

The same graceful stop, triggered from inside the worklet — useful when the stop condition depends on rendered content (e.g., "stop after the bouncing-ball animation completes").

```ts
drawFrame: drawWithRGBA((pixels, ctx) => {
  'worklet';
  if (ctx.timeSec >= 5) {
    ctx.finish();
    return;
  }
  // ... fill pixels ...
}),
```

`ctx.finish()` is a no-op without an attached `controller` and on fixed-duration renders.

## Combining signal + controller

Pass both — useful when external code (`signal`) needs to abort, while internal code (`controller`) wants the option to gracefully finish.

```ts
const ac = new AbortController();
const controller = new VideoRenderController();

const promise = Video.synthesize({
  output: { path: `${dir}/x.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'open' },
  signal: ac.signal,
  controller,
  drawFrame: myDrawer,
});

// either:
controller.finish(); // promise resolves, file kept
// or:
ac.abort();          // promise rejects, file discarded
```

If both fire, the **first** one wins. `abort` after `finish` is registered transitions the controller to `'aborted'` and the file is discarded.

## Progress

`onProgress` runs on the JS thread. `nbFrames` is `undefined` for open-ended renders until `finish()` is called.

```ts
await Video.synthesize({
  output: { path: `${dir}/x.mp4`, width: 320, height: 240, fps: 30 },
  duration: { mode: 'fixed', seconds: 5 },
  onProgress: (p) => {
    // p.framesCompleted, p.nbFrames, p.elapsedMs, p.estimatedRemainingMs
  },
  drawFrame: myDrawer,
});
```

## See also

- [`synthesize.md`](./synthesize.md) — open-ended renders are usually synthesize
- [`../api.md#videorendercontroller`](../api.md#videorendercontroller) — full state-transition table
