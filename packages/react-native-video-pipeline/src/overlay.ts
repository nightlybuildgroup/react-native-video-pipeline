import type {
  AnchorPoint,
  AnchorPreset,
  ImageOverlay as NativeImageOverlay,
  ImageOverlaySize as NativeImageOverlaySize,
  TextOverlay as NativeTextOverlay,
  TextStyle,
} from './nitro/VideoPipeline.nitro';
import type { OverlaySize, TimeRange } from './types';

/**
 * Public image overlay. Carries the same `OverlaySize` shape (`width` /
 * `height`) on output that the `Overlay.Image` builder accepts on input —
 * callers can read, transform, or serialize the returned object using the
 * same vocabulary they constructed it with. The wrapper in `./video.ts`
 * converts to the Nitro boundary shape (`{ w, h }`) before crossing.
 */
export type ImageOverlay = Omit<NativeImageOverlay, 'kind' | 'size'> & {
  kind: 'image';
  size: OverlaySize;
};
export type TextOverlay = Omit<NativeTextOverlay, 'kind'> & { kind: 'text' };

export type Overlay = ImageOverlay | TextOverlay;

/** Internal: convert the public `OverlaySize` (`width`/`height`) into the
 *  Nitro boundary shape (`{ w, h }`). Used by `./video.ts` when building the
 *  native spec. Exported so the wrapper can share one definition. */
export function toNativeOverlaySize(size: OverlaySize): NativeImageOverlaySize {
  return {
    ...(size.width !== undefined ? { w: { unit: size.width.unit, value: size.width.value } } : {}),
    ...(size.height !== undefined
      ? { h: { unit: size.height.unit, value: size.height.value } }
      : {}),
  };
}

const ANCHOR_PRESETS: Record<AnchorPreset, AnchorPoint> = {
  tl: { x: 0, y: 0 },
  tr: { x: 1, y: 0 },
  bl: { x: 0, y: 1 },
  br: { x: 1, y: 1 },
  center: { x: 0.5, y: 0.5 },
};

function resolveAnchor(anchor: AnchorPreset | AnchorPoint): AnchorPoint {
  if (typeof anchor === 'string') {
    return ANCHOR_PRESETS[anchor];
  }
  return { x: anchor.x, y: anchor.y };
}

export interface ImageOverlayInput {
  uri: string;
  anchor: AnchorPreset | AnchorPoint;
  size: OverlaySize;
  opacity?: number;
  timeRange?: TimeRange;
}

export interface TextOverlayInput {
  text: string;
  style: TextStyle;
  anchor: AnchorPreset | AnchorPoint;
  timeRange?: TimeRange;
}

function image(input: ImageOverlayInput): ImageOverlay {
  return {
    kind: 'image',
    uri: input.uri,
    anchor: resolveAnchor(input.anchor),
    size: copyOverlaySize(input.size),
    ...(input.opacity !== undefined ? { opacity: input.opacity } : {}),
    ...(input.timeRange !== undefined ? { timeRange: input.timeRange } : {}),
  };
}

/** Shallow-copy so the returned object doesn't alias caller-mutable input. */
function copyOverlaySize(size: OverlaySize): OverlaySize {
  if (size.width !== undefined && size.height !== undefined) {
    return { width: { ...size.width }, height: { ...size.height } };
  }
  if (size.width !== undefined) {
    return { width: { ...size.width } };
  }
  return { height: { ...(size.height as { unit: 'px' | 'ratio'; value: number }) } };
}

function text(input: TextOverlayInput): TextOverlay {
  return {
    kind: 'text',
    text: input.text,
    style: input.style,
    anchor: resolveAnchor(input.anchor),
    ...(input.timeRange !== undefined ? { timeRange: input.timeRange } : {}),
  };
}

export const Overlay = {
  Image: image,
  Text: text,
} as const;
