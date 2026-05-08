import {
  assertNever,
  CancelledError,
  DeviceCapabilityExceededError,
  EncoderFailureError,
  errorForCode,
  InvalidSpecError,
  IOError,
  SourceCorruptedError,
  UnsupportedCodecError,
  VideoPipelineError,
} from '../src/errors';
import type { VideoPipelineErrorCode } from '../src/nitro/VideoPipeline.nitro';

describe('VideoPipelineError subclasses', () => {
  const cases: [
    VideoPipelineErrorCode,
    new (options?: { message?: string }) => VideoPipelineError,
  ][] = [
    ['UnsupportedCodec', UnsupportedCodecError],
    ['DeviceCapabilityExceeded', DeviceCapabilityExceededError],
    ['SourceCorrupted', SourceCorruptedError],
    ['Cancelled', CancelledError],
    ['IOError', IOError],
    ['EncoderFailure', EncoderFailureError],
    ['InvalidSpec', InvalidSpecError],
  ];

  it.each(cases)('%s has literal code and instanceof chain', (code, Ctor) => {
    const err = new Ctor({ message: `test ${code}` });
    expect(err.code).toBe(code);
    expect(err).toBeInstanceOf(Ctor);
    expect(err).toBeInstanceOf(VideoPipelineError);
    expect(err).toBeInstanceOf(Error);
    expect(err.message).toBe(`test ${code}`);
    expect(err.name).toBe('VideoPipelineError');
  });

  it('preserves details', () => {
    const err = new IOError({ message: 'oh no', details: { path: '/tmp/x' } });
    expect(err.details).toEqual({ path: '/tmp/x' });
  });

  it('omits details when not provided (exactOptionalPropertyTypes)', () => {
    const err = new CancelledError();
    expect('details' in err).toBe(false);
  });
});

describe('errorForCode + assertNever exhaustiveness', () => {
  it('maps every code to its subclass', () => {
    const codes: VideoPipelineErrorCode[] = [
      'UnsupportedCodec',
      'DeviceCapabilityExceeded',
      'SourceCorrupted',
      'Cancelled',
      'IOError',
      'EncoderFailure',
      'InvalidSpec',
    ];
    for (const code of codes) {
      expect(errorForCode(code).code).toBe(code);
    }
  });

  it('assertNever throws at runtime if somehow reached', () => {
    expect(() => assertNever('bogus' as never)).toThrow(/Unreachable/);
  });

  it('compile-time exhaustiveness: switching on code without default is allowed', () => {
    const handle = (e: VideoPipelineError): string => {
      switch (e.code) {
        case 'UnsupportedCodec':
          return 'a';
        case 'DeviceCapabilityExceeded':
          return 'b';
        case 'SourceCorrupted':
          return 'c';
        case 'Cancelled':
          return 'd';
        case 'IOError':
          return 'e';
        case 'EncoderFailure':
          return 'f';
        case 'InvalidSpec':
          return 'g';
      }
    };
    expect(handle(new IOError())).toBe('e');
  });
});
