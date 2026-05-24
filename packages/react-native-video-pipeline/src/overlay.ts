import type {
  AnchorPoint,
  AnchorPreset,
  ImageOverlay as NativeImageOverlay,
  ImageOverlaySize as NativeImageOverlaySize,
  TextOverlay as NativeTextOverlay,
  TextStyle,
} from './nitro/VideoPipeline.nitro';
import type { OverlaySize, TimeRange } from './types';

export type ImageOverlay = Omit<NativeImageOverlay, 'kind' | 'size'> & {
  kind: 'image';
  size: NativeImageOverlaySize;
};
export type TextOverlay = Omit<NativeTextOverlay, 'kind'> & { kind: 'text' };

export type Overlay = ImageOverlay | TextOverlay;

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
    size: normalizeOverlaySize(input.size),
    ...(input.opacity !== undefined ? { opacity: input.opacity } : {}),
    ...(input.timeRange !== undefined ? { timeRange: input.timeRange } : {}),
  };
}

function normalizeOverlaySize(size: OverlaySize): NativeImageOverlaySize {
  return {
    ...(size.width !== undefined ? { w: { unit: size.width.unit, value: size.width.value } } : {}),
    ...(size.height !== undefined
      ? { h: { unit: size.height.unit, value: size.height.value } }
      : {}),
  };
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
