///
/// VideoPipelineAutolinking.mm
///
/// Hand-written iOS Nitro autolinker. Registers the C++ `HybridVideoPipeline`
/// under the JS name "VideoPipeline" so `NitroModules.createHybridObject(...)`
/// can construct it. Replaces the nitrogen-generated iOS autolinker that used
/// to live under nitrogen/generated/ios/ — we switched `nitro.json` to a
/// kotlin-only autolinking entry in T040 so Android routes to the Kotlin
/// `HybridVideoPipeline` class, and the iOS side has to register its cpp
/// equivalent manually.
///

#import <Foundation/Foundation.h>
#import <NitroModules/HybridObjectRegistry.hpp>

#import "HybridVideoPipeline.hpp"

#import <type_traits>

@interface VideoPipelineAutolinking : NSObject
@end

@implementation VideoPipelineAutolinking

+ (void) load {
  using namespace margelo::nitro;
  using namespace margelo::nitro::videopipeline;

  HybridObjectRegistry::registerHybridObjectConstructor(
    "VideoPipeline",
    []() -> std::shared_ptr<HybridObject> {
      static_assert(std::is_default_constructible_v<HybridVideoPipeline>,
                    "The HybridObject \"HybridVideoPipeline\" must be default-constructible to be autolinked.");
      return std::make_shared<HybridVideoPipeline>();
    }
  );
}

@end
