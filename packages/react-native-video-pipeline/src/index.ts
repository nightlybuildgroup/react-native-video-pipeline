export * from './bootstrap-pattern';
export * from './controller';
export * from './drawWithRGBA';
export * from './errors';
// Re-export the shared Nitro types that don't need a public facade.
// Types with discriminants (DurationSpec, AudioSpec, Overlay) and runtime
// invariants (Size, SynthesizeOutputSpec, StampOptions) are exported from
// `./types`, `./overlay`, and `./video` with literal-narrowed / refined
// public facades instead.
export type {
  Anchor,
  AnchorPoint,
  AnchorPreset,
  Clip,
  ClipTransform,
  CropRect,
  EncoderCaps,
  FlipAxis,
  FontWeight,
  FrameDrawer,
  FrameDrawerContext,
  FrameSource,
  FrameTarget,
  MetadataSpec,
  PixelFormat,
  Progress,
  RenderControllerState,
  RenderOptions,
  RenderPriority,
  Rotation,
  TextAlign,
  TextShadow,
  TextStyle,
  ThumbnailOptions,
  VideoCodec,
  VideoContainer,
  VideoInfo,
  VideoPipelineErrorCode,
  VideoPipelineErrorShape,
} from './nitro/VideoPipeline.nitro';
export * from './overlay';
export * from './types';
export * from './video';
