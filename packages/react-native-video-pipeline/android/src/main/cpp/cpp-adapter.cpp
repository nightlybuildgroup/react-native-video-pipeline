///
/// cpp-adapter.cpp
///
/// JNI_OnLoad entrypoint for the NitroVideoPipeline shared library. Wraps the
/// nitrogen-generated `registerAllNatives()` in `facebook::jni::initialize`,
/// which (a) registers JHybrid natives for every HybridObject spec in this
/// module and (b) registers the JS-visible HybridObject constructor that
/// default-constructs the Kotlin `HybridVideoPipeline` class.
///
/// Nitro deprecated the older one-shot `initialize(vm)` helper in favor of this
/// explicit form (see NitroVideoPipelineOnLoad.hpp) — and `-Werror` promotes
/// the deprecation to a hard failure, so we call the supported API directly.
///

#include <jni.h>
#include <fbjni/fbjni.h>
#include "NitroVideoPipelineOnLoad.hpp"

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /* reserved */) {
  return facebook::jni::initialize(vm, [] {
    margelo::nitro::videopipeline::registerAllNatives();
  });
}
