///
/// AHardwareBufferBridge.kt — `Java_HardwareBuffer → AHardwareBuffer*` shim.
///
/// `android.hardware.HardwareBuffer` is the Java wrapper around an NDK
/// `AHardwareBuffer*`. Skia's `Image.MakeImageFromNativeBuffer(addr: bigint)`
/// expects the raw `AHardwareBuffer*` pointer, not the Java handle. The NDK
/// helper `AHardwareBuffer_fromHardwareBuffer(env, jobj)` extracts that
/// pointer; we expose it to Kotlin via a tiny JNI shim that ships in the same
/// `NitroVideoPipeline` shared lib (see `cpp-hardware-buffer.cpp`).
///
/// API 26+ only — older devices would trip the `@RequiresApi`. Callers (the
/// compose pump) must gate on `Build.VERSION.SDK_INT >= 26`. The returned
/// `Long` is a non-owning pointer; lifetime is owned by the Java
/// `HardwareBuffer` (close it on the consumer side after Skia is done).
///

package com.margelo.nitro.videopipeline

import android.hardware.HardwareBuffer
import android.os.Build
import androidx.annotation.RequiresApi

@RequiresApi(Build.VERSION_CODES.O)
internal object AHardwareBufferBridge {
  init {
    // Make sure libNitroVideoPipeline is loaded — it carries the JNI shim
    // for `nativePtr` alongside Nitro's autolinking glue. `initializeNative`
    // is idempotent so calling it twice is harmless.
    NitroVideoPipelineOnLoad.initializeNative()
  }

  /// Returns the `AHardwareBuffer*` pointer (cast to `jlong`) so we can hand
  /// it to Skia via Nitro's `bigint`. `0L` for a null input.
  @JvmStatic
  external fun nativePtr(buffer: HardwareBuffer): Long
}
