import type { VideoPipelineErrorCode } from './nitro/VideoPipeline.nitro';

export interface VideoPipelineErrorOptions {
  message?: string;
  details?: Record<string, unknown>;
  cause?: unknown;
}

export abstract class VideoPipelineError extends Error {
  abstract readonly code: VideoPipelineErrorCode;
  readonly details?: Record<string, unknown>;

  constructor(options?: VideoPipelineErrorOptions) {
    super(options?.message, options?.cause !== undefined ? { cause: options.cause } : undefined);
    // `new.target` is the concrete subclass being constructed, so logs show
    // `CancelledError`, `InvalidSpecError`, etc. — the discriminant in `code`
    // is still the supported programmatic discriminant.
    this.name = new.target.name;
    if (options?.details !== undefined) {
      this.details = options.details;
    }
  }
}

export class UnsupportedCodecError extends VideoPipelineError {
  readonly code = 'UnsupportedCodec';
}

export class DeviceCapabilityExceededError extends VideoPipelineError {
  readonly code = 'DeviceCapabilityExceeded';
}

export class SourceCorruptedError extends VideoPipelineError {
  readonly code = 'SourceCorrupted';
}

export class CancelledError extends VideoPipelineError {
  readonly code = 'Cancelled';
}

export class IOError extends VideoPipelineError {
  readonly code = 'IOError';
}

export class EncoderFailureError extends VideoPipelineError {
  readonly code = 'EncoderFailure';
}

export class InvalidSpecError extends VideoPipelineError {
  readonly code = 'InvalidSpec';
}

export function assertNever(x: never): never {
  throw new Error(`Unreachable: unexpected value ${String(x)}`);
}

export function errorForCode(
  code: VideoPipelineErrorCode,
  options?: VideoPipelineErrorOptions,
): VideoPipelineError {
  switch (code) {
    case 'UnsupportedCodec':
      return new UnsupportedCodecError(options);
    case 'DeviceCapabilityExceeded':
      return new DeviceCapabilityExceededError(options);
    case 'SourceCorrupted':
      return new SourceCorruptedError(options);
    case 'Cancelled':
      return new CancelledError(options);
    case 'IOError':
      return new IOError(options);
    case 'EncoderFailure':
      return new EncoderFailureError(options);
    case 'InvalidSpec':
      return new InvalidSpecError(options);
    default:
      return assertNever(code);
  }
}

/**
 * Pattern matched against native rejection messages. Native throws
 * `std::runtime_error`s shaped like:
 *
 *   "VideoPipeline.<method>: <Code>"           (Cancelled, InvalidSpec — ...)
 *   "VideoPipeline.<method>(...) failed: ..."   (generic encoder/IO failure)
 *
 * The first form encodes the discriminant directly; the second is a
 * catch-all that maps to `EncoderFailure` so callers always see a typed
 * `VideoPipelineError`. Library-thrown `VideoPipelineError`s are returned
 * unchanged.
 */
export function normalizeNativeError(err: unknown): unknown {
  if (err instanceof VideoPipelineError) return err;
  const message = err instanceof Error ? err.message : String(err);
  const codeMatch = message.match(
    /^VideoPipeline\.[a-zA-Z]+:?\s+(Cancelled|InvalidSpec|UnsupportedCodec|DeviceCapabilityExceeded|SourceCorrupted|IOError|EncoderFailure)\b/,
  );
  if (codeMatch !== null && codeMatch[1] !== undefined) {
    return errorForCode(codeMatch[1] as VideoPipelineErrorCode, { message, cause: err });
  }
  // "VideoPipeline.<method>[ something] failed: ..." → generic encoder failure.
  if (/^VideoPipeline\.[a-zA-Z]+( [a-zA-Z]+)? failed:/.test(message)) {
    return new EncoderFailureError({ message, cause: err });
  }
  return err;
}
