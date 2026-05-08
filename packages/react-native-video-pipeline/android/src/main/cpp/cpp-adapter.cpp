///
/// cpp-adapter.cpp
///
/// JNI_OnLoad entrypoint for the NitroVideoPipeline shared library. Delegates
/// to the nitrogen-generated `initialize(vm)` which (a) registers JHybrid
/// natives for every HybridObject spec in this module and (b) registers the
/// JS-visible HybridObject constructor that default-constructs the Kotlin
/// `HybridVideoPipeline` class.
///

#include <jni.h>
#include "NitroVideoPipelineOnLoad.hpp"

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /* reserved */) {
  return margelo::nitro::videopipeline::initialize(vm);
}
