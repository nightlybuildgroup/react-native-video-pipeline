import { transformSync } from '@babel/core';
import plugin from '../src/index';

function transform(code: string): string | null {
  const result = transformSync(code, {
    filename: 'test-fixture.ts',
    babelrc: false,
    configFile: false,
    plugins: [plugin],
  });
  return result?.code ?? null;
}

function expectThrows(code: string, messageFragment: RegExp): void {
  expect(() => transform(code)).toThrow(messageFragment);
}

describe('babel-plugin-video-pipeline', () => {
  describe('positive cases (worklet directive present — no error)', () => {
    it('accepts Video.compose with an arrow containing a worklet directive', () => {
      const code = `
        Video.compose(spec, {
          drawFrame: (ctx) => {
            'worklet';
            ctx.canvas.drawImage(ctx.frame, 0, 0);
          },
        });
      `;
      expect(() => transform(code)).not.toThrow();
    });

    it('accepts Video.synthesize with a FunctionExpression containing a worklet directive', () => {
      const code = `
        Video.synthesize({
          output: { width: 720, height: 1280, fps: 30 },
          duration: { mode: 'fixed', durationSec: 5 },
          drawFrame: function (ctx) {
            'worklet';
            ctx.canvas.drawColor(0xffff0000);
          },
        });
      `;
      expect(() => transform(code)).not.toThrow();
    });

    it('accepts Video.compose with a method-shorthand containing a worklet directive', () => {
      const code = `
        Video.compose(spec, {
          drawFrame(ctx) {
            'worklet';
            ctx.canvas.drawColor(0xff00ff00);
          },
        });
      `;
      expect(() => transform(code)).not.toThrow();
    });
  });

  describe('negative cases (missing directive — throws)', () => {
    it('rejects Video.synthesize with an arrow missing the directive', () => {
      const code = `
        Video.synthesize({
          drawFrame: (ctx) => {
            ctx.canvas.drawColor(0xff000000);
          },
        });
      `;
      expectThrows(code, /Video\.synthesize.*'worklet'/s);
    });

    it('rejects Video.compose with a FunctionExpression missing the directive', () => {
      const code = `
        Video.compose(spec, {
          drawFrame: function (ctx) {
            ctx.canvas.drawImage(ctx.frame, 0, 0);
          },
        });
      `;
      expectThrows(code, /Video\.compose.*'worklet'/s);
    });

    it('rejects Video.compose with a method-shorthand missing the directive', () => {
      const code = `
        Video.compose(spec, {
          drawFrame(ctx) {
            ctx.canvas.drawColor(0);
          },
        });
      `;
      expectThrows(code, /Video\.compose.*'worklet'/s);
    });

    it('includes the file name in the error (via buildCodeFrameError)', () => {
      const code = `
        Video.synthesize({
          drawFrame: () => { ctx.canvas.drawColor(0); },
        });
      `;
      expectThrows(code, /test-fixture\.ts/);
    });

    it('includes the docs URL in the error message', () => {
      const code = `
        Video.synthesize({
          drawFrame: () => { /* no directive */ },
        });
      `;
      expectThrows(code, /github\.com\/unbogify\/react-native-video-pipeline#worklet-directives/);
    });
  });

  describe('edge cases', () => {
    it('rejects an expression-bodied arrow (no place for a directive)', () => {
      const code = `
        Video.synthesize({
          drawFrame: (ctx) => ctx.canvas.drawColor(0),
        });
      `;
      expectThrows(code, /Video\.synthesize/);
    });

    it('accepts an async arrow that has the directive', () => {
      const code = `
        Video.synthesize({
          drawFrame: async (ctx) => {
            'worklet';
            ctx.canvas.drawColor(0);
          },
        });
      `;
      expect(() => transform(code)).not.toThrow();
    });

    it('allows drawFrame passed as a named identifier (caller responsibility)', () => {
      const code = `
        const myDrawer = () => {};
        Video.synthesize({
          drawFrame: myDrawer,
        });
      `;
      expect(() => transform(code)).not.toThrow();
    });

    it('allows drawFrame passed as a member expression', () => {
      const code = `
        Video.synthesize({
          drawFrame: drawers.frame,
        });
      `;
      expect(() => transform(code)).not.toThrow();
    });

    it('ignores unrelated call sites', () => {
      const code = `
        SomeOther.api({
          drawFrame: () => {},
        });
      `;
      expect(() => transform(code)).not.toThrow();
    });

    it('ignores calls where the options argument is a spread of a variable', () => {
      const code = `
        const opts = { drawFrame: () => {} };
        Video.synthesize(opts);
      `;
      expect(() => transform(code)).not.toThrow();
    });

    it('does not complain when drawFrame is absent from the options object', () => {
      const code = `
        Video.compose(spec, { onProgress: () => {} });
      `;
      expect(() => transform(code)).not.toThrow();
    });

    it('handles the string-literal key form', () => {
      const code = `
        Video.synthesize({
          'drawFrame': (ctx) => {
            'worklet';
            ctx.canvas.drawColor(0);
          },
        });
      `;
      expect(() => transform(code)).not.toThrow();
    });
  });
});
