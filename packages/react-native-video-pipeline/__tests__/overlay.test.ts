import { Overlay } from '../src/overlay';

const pxW = (value: number) => ({ width: { unit: 'px' as const, value } });
const pxH = (value: number) => ({ height: { unit: 'px' as const, value } });

describe('Overlay.Image', () => {
  it('builds an image overlay with narrowed kind and normalized tagged size', () => {
    const o = Overlay.Image({
      uri: 'file:///tmp/wm.png',
      anchor: { x: 0.25, y: 0.75 },
      size: pxW(100),
    });
    expect(o.kind).toBe('image');
    expect(o.uri).toBe('file:///tmp/wm.png');
    expect(o.anchor).toEqual({ x: 0.25, y: 0.75 });
    // Builder converts public { width: Dim } into the Nitro { w: Dim } shape.
    expect(o.size).toEqual({ w: { unit: 'px', value: 100 } });
    expect('opacity' in o).toBe(false);
    expect('timeRange' in o).toBe(false);
  });

  it('passes ratio-tagged dimensions through to the Nitro shape', () => {
    const o = Overlay.Image({
      uri: 'x',
      anchor: 'tl',
      size: { width: { unit: 'ratio', value: 0.15 } },
    });
    expect(o.size).toEqual({ w: { unit: 'ratio', value: 0.15 } });
  });

  it('expands AnchorPreset shorthand', () => {
    expect(Overlay.Image({ uri: 'x', anchor: 'tl', size: pxW(10) }).anchor).toEqual({
      x: 0,
      y: 0,
    });
    expect(Overlay.Image({ uri: 'x', anchor: 'tr', size: pxW(10) }).anchor).toEqual({
      x: 1,
      y: 0,
    });
    expect(Overlay.Image({ uri: 'x', anchor: 'bl', size: pxW(10) }).anchor).toEqual({
      x: 0,
      y: 1,
    });
    expect(Overlay.Image({ uri: 'x', anchor: 'br', size: pxW(10) }).anchor).toEqual({
      x: 1,
      y: 1,
    });
    expect(Overlay.Image({ uri: 'x', anchor: 'center', size: pxW(10) }).anchor).toEqual({
      x: 0.5,
      y: 0.5,
    });
  });

  it('carries optional opacity/timeRange when provided', () => {
    const o = Overlay.Image({
      uri: 'x',
      anchor: 'center',
      size: pxH(50),
      opacity: 0.5,
      timeRange: { startSec: 1, endSec: 2 },
    });
    expect(o.opacity).toBe(0.5);
    expect(o.timeRange).toEqual({ startSec: 1, endSec: 2 });
  });
});

describe('Overlay.Text', () => {
  it('builds a text overlay with narrowed kind', () => {
    const o = Overlay.Text({
      text: 'hello',
      style: { fontSize: 24, color: '#fff' },
      anchor: 'br',
    });
    expect(o.kind).toBe('text');
    expect(o.text).toBe('hello');
    expect(o.style).toEqual({ fontSize: 24, color: '#fff' });
    expect(o.anchor).toEqual({ x: 1, y: 1 });
    expect('timeRange' in o).toBe(false);
  });
});

describe('discriminant round-trips through JSON', () => {
  it('image kind survives JSON round-trip', () => {
    const o = Overlay.Image({ uri: 'x', anchor: 'tl', size: pxW(1) });
    const round = JSON.parse(JSON.stringify(o)) as Overlay;
    expect(round.kind).toBe('image');
  });

  it('text kind survives JSON round-trip', () => {
    const o = Overlay.Text({
      text: 'hi',
      style: { fontSize: 12, color: '#000' },
      anchor: 'center',
    });
    const round = JSON.parse(JSON.stringify(o)) as Overlay;
    expect(round.kind).toBe('text');
  });

  it('switching on kind is exhaustive', () => {
    const describe = (o: Overlay): string => {
      switch (o.kind) {
        case 'image':
          return `image:${o.uri}`;
        case 'text':
          return `text:${o.text}`;
      }
    };
    expect(describe(Overlay.Image({ uri: 'u', anchor: 'tl', size: pxW(1) }))).toBe('image:u');
    expect(
      describe(
        Overlay.Text({
          text: 't',
          style: { fontSize: 10, color: '#000' },
          anchor: 'tl',
        }),
      ),
    ).toBe('text:t');
  });
});
