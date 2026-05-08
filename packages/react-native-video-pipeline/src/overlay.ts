import type {
  AnchorPoint,
  AnchorPreset,
  FrameDrawer,
  ImageOverlay,
  Size,
  TextOverlay,
  TextStyle,
  TimeRange,
  WorkletOverlay,
} from './nitro/VideoPipeline.nitro';

export type ImageOverlayValue = Omit<ImageOverlay, 'kind'> & { kind: 'image' };
export type TextOverlayValue = Omit<TextOverlay, 'kind'> & { kind: 'text' };
export type WorkletOverlayValue = Omit<WorkletOverlay, 'kind'> & { kind: 'worklet' };

export type OverlayValue = ImageOverlayValue | TextOverlayValue | WorkletOverlayValue;

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
  size: Size;
  opacity?: number;
  timeRange?: TimeRange;
}

export interface TextOverlayInput {
  text: string;
  style: TextStyle;
  anchor: AnchorPreset | AnchorPoint;
  timeRange?: TimeRange;
}

export interface WorkletOverlayInput {
  draw: FrameDrawer;
  timeRange?: TimeRange;
}

function image(input: ImageOverlayInput): ImageOverlayValue {
  return {
    kind: 'image',
    uri: input.uri,
    anchor: resolveAnchor(input.anchor),
    size: input.size,
    ...(input.opacity !== undefined ? { opacity: input.opacity } : {}),
    ...(input.timeRange !== undefined ? { timeRange: input.timeRange } : {}),
  };
}

function text(input: TextOverlayInput): TextOverlayValue {
  return {
    kind: 'text',
    text: input.text,
    style: input.style,
    anchor: resolveAnchor(input.anchor),
    ...(input.timeRange !== undefined ? { timeRange: input.timeRange } : {}),
  };
}

function worklet(input: WorkletOverlayInput): WorkletOverlayValue {
  return {
    kind: 'worklet',
    draw: input.draw,
    ...(input.timeRange !== undefined ? { timeRange: input.timeRange } : {}),
  };
}

export const Overlay = {
  Image: image,
  Text: text,
  Worklet: worklet,
} as const;
