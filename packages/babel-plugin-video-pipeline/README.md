# babel-plugin-video-pipeline

Build-time enforcement of the `'worklet';` directive for [`react-native-video-pipeline`](https://www.npmjs.com/package/react-native-video-pipeline)'s worklet render paths.

`Video.compose` and `Video.synthesize` take a `drawFrame` callback that runs across the worklet boundary. If you pass a **function literal** that forgets the `'worklet';` directive, this plugin **fails the bundle** with a precise code frame — instead of letting a broken drawer ship and fail at runtime. There is intentionally no runtime "first-frame-throws" fallback; the check is entirely at build time.

## Install

```sh
yarn add --dev babel-plugin-video-pipeline
```

### Peer dependency

- `@babel/core` (>= 7.20)

## Setup

Add it to your `babel.config.js`:

```js
module.exports = {
  presets: ['module:@react-native/babel-preset'],
  plugins: ['babel-plugin-video-pipeline'],
};
```

## What it checks

For each call to `Video.compose(spec, options)` and `Video.synthesize(options)`, it inspects the `drawFrame` property of the options object:

- **Function literal without `'worklet';`** → build error.
- **Arrow with an expression body** (`() => expr`, nowhere to put a directive) → build error.
- **Function/method with `'worklet';` as the first statement** → passes.
- **A named identifier or member expression** (e.g. `drawFrame: myDrawer`) → skipped; marking the worklet is then the caller's responsibility at its definition site.

### Example

```ts
const output = { path: `${dir}/synth.mp4`, width: 1080, height: 1920, fps: 30 };
const duration = { mode: 'fixed', seconds: 1 } as const;

// ❌ Build error: missing 'worklet';
await Video.synthesize({
  output,
  duration,
  drawFrame: (ctx) => {
    ctx.target.writeBytes(new ArrayBuffer(ctx.width * ctx.height * 4));
  },
});

// ✅ Passes
await Video.synthesize({
  output,
  duration,
  drawFrame: (ctx) => {
    'worklet';
    ctx.target.writeBytes(new ArrayBuffer(ctx.width * ctx.height * 4));
  },
});
```

## License

MIT
