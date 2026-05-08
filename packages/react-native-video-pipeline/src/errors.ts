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
    this.name = 'VideoPipelineError';
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
