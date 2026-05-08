///
/// RenderTokenRegistry.kt
///
/// Process-wide map of in-flight renderTokens to their backing
/// VideoPipelineStopToken. Mirrors the C++ RenderTokenRegistry
/// (cpp/compose/RenderTokenRegistry.hpp) that iOS uses: JS-side calls to
/// `cancelRender(token)` / `finishRender(token)` look up the matching
/// stop token and flip its flags, which the background render loop polls.
///
/// An empty renderToken means "caller opted out of cancellation" — we hand
/// back a fresh stop token but never register it, so lookups always miss.
///

package com.margelo.nitro.videopipeline

import java.util.concurrent.ConcurrentHashMap

internal object RenderTokenRegistry {
  private val map = ConcurrentHashMap<String, VideoPipelineStopToken>()

  fun registerToken(token: String): VideoPipelineStopToken {
    val stop = VideoPipelineStopToken()
    if (token.isNotEmpty()) {
      map[token] = stop
    }
    return stop
  }

  fun unregisterToken(token: String) {
    if (token.isNotEmpty()) {
      map.remove(token)
    }
  }

  fun lookup(token: String): VideoPipelineStopToken? {
    if (token.isEmpty()) return null
    return map[token]
  }
}
