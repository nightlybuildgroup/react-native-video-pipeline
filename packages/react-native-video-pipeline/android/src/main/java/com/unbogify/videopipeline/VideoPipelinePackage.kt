package com.unbogify.videopipeline

import com.facebook.react.TurboReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.margelo.nitro.videopipeline.NitroVideoPipelineOnLoad

/**
 * Bookkeeping ReactPackage for `react-native-video-pipeline`. The library
 * itself exposes no TurboModule — everything flows through Nitro's
 * HybridObjectRegistry. This ReactPackage exists only to:
 *
 *  1. Let `@react-native-community/cli` autolink this library (the CLI
 *     scans Android source for a `ReactPackage` and skips the dependency
 *     otherwise).
 *  2. Trigger `System.loadLibrary("NitroVideoPipeline")` on app start so
 *     `JNI_OnLoad` fires and registers the Kotlin `HybridVideoPipeline`
 *     constructor in the Nitro HybridObjectRegistry.
 */
class VideoPipelinePackage : TurboReactPackage() {
  init {
    NitroVideoPipelineOnLoad.initializeNative()
  }

  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? = null

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider =
    ReactModuleInfoProvider { emptyMap<String, ReactModuleInfo>() }
}
