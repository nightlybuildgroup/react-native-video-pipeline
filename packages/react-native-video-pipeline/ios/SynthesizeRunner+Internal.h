///
/// SynthesizeRunner+Internal.h
///
/// Obj-C++ — only includable from `.mm` translation units. Exposes the
/// bridge between `RNVPStopToken` and the C++ `StopToken` so
/// `VideoPipeline.mm` can register a single shared_ptr with both the
/// `RenderTokenRegistry` and the runner's Obj-C surface without a
/// per-frame polling adapter.
///
/// The pure-Obj-C header (`SynthesizeRunner.h`) remains importable from
/// XCTest `.m` files; this sibling header stays C++-flavoured.
///

#import "SynthesizeRunner.h"

#include "compose/StopToken.hpp"

#include <memory>

NS_ASSUME_NONNULL_BEGIN

@interface RNVPStopToken (Internal)

/// Wraps an existing C++ `StopToken` so JS-side `cancelRender` / `finishRender`
/// (which look up the shared_ptr through `RenderTokenRegistry`) and the
/// runner's Obj-C poll path (`finishRequested` / `abortRequested`) mutate the
/// exact same atomic flags.
+ (instancetype)tokenFromSharedPtr:
    (std::shared_ptr<margelo::nitro::videopipeline::StopToken>)cpp;

/// Accessor for the runner's C++ loop so it can poll the token via the
/// `StopToken` interface without round-tripping through Obj-C selectors on
/// every frame.
- (const std::shared_ptr<margelo::nitro::videopipeline::StopToken> &)cpp;

@end

NS_ASSUME_NONNULL_END
