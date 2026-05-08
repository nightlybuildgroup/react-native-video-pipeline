import { type ControllerBindings, VideoRenderController } from '../src/controller';

function makeBindings(
  durationMode: ControllerBindings['durationMode'],
): ControllerBindings & { calls: { finish: number; cancel: number } } {
  const calls = { finish: 0, cancel: 0 };
  return {
    durationMode,
    finishRender: () => {
      calls.finish += 1;
    },
    cancelRender: () => {
      calls.cancel += 1;
    },
    calls,
  };
}

describe('VideoRenderController', () => {
  it('starts in running state', () => {
    const c = new VideoRenderController();
    expect(c.state).toBe('running');
  });

  it('abort() transitions to aborted (unbound)', () => {
    const c = new VideoRenderController();
    c.abort();
    expect(c.state).toBe('aborted');
  });

  it('abort() is idempotent', () => {
    const c = new VideoRenderController();
    const b = makeBindings('open');
    c._bind(b);
    c.abort();
    c.abort();
    c.abort();
    expect(c.state).toBe('aborted');
    expect(b.calls.cancel).toBe(1);
  });

  it('finish() is idempotent on open-ended renders', () => {
    const c = new VideoRenderController();
    const b = makeBindings('open');
    c._bind(b);
    c.finish();
    c.finish();
    c.finish();
    expect(c.state).toBe('finishing');
    expect(b.calls.finish).toBe(1);
  });

  it('finish() is a no-op on fixed-duration renders (§14 Q policy)', () => {
    const c = new VideoRenderController();
    const b = makeBindings('fixed');
    c._bind(b);
    c.finish();
    c.finish();
    expect(c.state).toBe('running');
    expect(b.calls.finish).toBe(0);
  });

  it('finish() on open-ended transitions to finishing and calls native', () => {
    const c = new VideoRenderController();
    const b = makeBindings('open');
    c._bind(b);
    c.finish();
    expect(c.state).toBe('finishing');
    expect(b.calls.finish).toBe(1);
    expect(b.calls.cancel).toBe(0);
  });

  it('_markDone transitions running → done', () => {
    const c = new VideoRenderController();
    const b = makeBindings('fixed');
    c._bind(b);
    c._markDone();
    expect(c.state).toBe('done');
  });

  it('_markDone transitions finishing → done', () => {
    const c = new VideoRenderController();
    const b = makeBindings('open');
    c._bind(b);
    c.finish();
    expect(c.state).toBe('finishing');
    c._markDone();
    expect(c.state).toBe('done');
  });

  it('_markDone does NOT resurrect an aborted controller', () => {
    const c = new VideoRenderController();
    const b = makeBindings('open');
    c._bind(b);
    c.abort();
    c._markDone();
    expect(c.state).toBe('aborted');
  });

  it('finish() after abort() is ignored', () => {
    const c = new VideoRenderController();
    const b = makeBindings('open');
    c._bind(b);
    c.abort();
    c.finish();
    expect(c.state).toBe('aborted');
    expect(b.calls.finish).toBe(0);
  });

  it('abort() after finish() wins (finishing → aborted)', () => {
    const c = new VideoRenderController();
    const b = makeBindings('open');
    c._bind(b);
    c.finish();
    c.abort();
    expect(c.state).toBe('aborted');
    expect(b.calls.cancel).toBe(1);
  });

  it('abort() before bind is relayed to native on bind', () => {
    const c = new VideoRenderController();
    c.abort();
    const b = makeBindings('open');
    c._bind(b);
    expect(b.calls.cancel).toBe(1);
    expect(b.calls.finish).toBe(0);
    expect(c.state).toBe('aborted');
  });

  it('finish() before bind is relayed to native on bind (open)', () => {
    const c = new VideoRenderController();
    c.finish();
    expect(c.state).toBe('running');
    const b = makeBindings('open');
    c._bind(b);
    expect(c.state).toBe('finishing');
    expect(b.calls.finish).toBe(1);
  });

  it('finish() before bind stays a no-op on fixed-duration binding', () => {
    const c = new VideoRenderController();
    c.finish();
    const b = makeBindings('fixed');
    c._bind(b);
    expect(c.state).toBe('running');
    expect(b.calls.finish).toBe(0);
  });

  it('rebinding a controller throws (1:1 controller ↔ render)', () => {
    const c = new VideoRenderController();
    c._bind(makeBindings('open'));
    expect(() => c._bind(makeBindings('open'))).toThrow(/already bound/);
  });
});
