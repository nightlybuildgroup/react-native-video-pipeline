///
/// cpp-hardware-buffer.cpp
///
/// JNI helper that converts a Java `android.hardware.HardwareBuffer` to its
/// underlying `AHardwareBuffer*` pointer via the NDK's
/// `AHardwareBuffer_fromHardwareBuffer`. Returned as a `jlong` so the Kotlin
/// side can pass it across Nitro as a `bigint` (`HybridFrameSource.bufferAddr`)
/// straight into Skia's `MakeImageFromNativeBuffer`. Same pattern as
/// `react-native-skia`'s RNSkAndroidVideo bridge.
///
/// `AHardwareBuffer_fromHardwareBuffer` is API 26+; this lib's
/// minSdkVersion is 24. We resolve the symbol lazily via `dlsym` so the lib
/// loads on every supported device, and we fall back to a `nullptr` return
/// when the device is older than O. The Kotlin caller is gated by
/// `@RequiresApi(26)` so this code path is only invoked when the symbol is
/// guaranteed to be present.
///

#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/log.h>
#include <dlfcn.h>

namespace {

using FromHardwareBufferFn = AHardwareBuffer *(*)(JNIEnv *, jobject);

FromHardwareBufferFn ResolveFromHardwareBuffer() {
  static FromHardwareBufferFn cached = []() -> FromHardwareBufferFn {
    void *handle = dlopen("libandroid.so", RTLD_NOW);
    if (handle == nullptr) {
      __android_log_print(ANDROID_LOG_ERROR, "AHardwareBufferBridge",
                          "dlopen(libandroid.so) failed: %s", dlerror());
      return nullptr;
    }
    auto *symbol = reinterpret_cast<FromHardwareBufferFn>(
        dlsym(handle, "AHardwareBuffer_fromHardwareBuffer"));
    if (symbol == nullptr) {
      __android_log_print(ANDROID_LOG_ERROR, "AHardwareBufferBridge",
                          "dlsym(AHardwareBuffer_fromHardwareBuffer) failed: %s",
                          dlerror());
    }
    return symbol;
  }();
  return cached;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_margelo_nitro_videopipeline_AHardwareBufferBridge_nativePtr(
    JNIEnv *env, jclass /*clazz*/, jobject hardwareBuffer) {
  if (hardwareBuffer == nullptr) {
    __android_log_print(ANDROID_LOG_WARN, "AHardwareBufferBridge",
                        "nativePtr: jobject is null");
    return 0;
  }
  FromHardwareBufferFn fn = ResolveFromHardwareBuffer();
  if (fn == nullptr) {
    return 0;
  }
  AHardwareBuffer *buf = fn(env, hardwareBuffer);
  if (buf == nullptr) {
    __android_log_print(ANDROID_LOG_WARN, "AHardwareBufferBridge",
                        "AHardwareBuffer_fromHardwareBuffer returned null");
  }
  return reinterpret_cast<jlong>(buf);
}
