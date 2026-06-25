///
/// RenderForegroundGuard.kt
///
/// Lifecycle wrapper for one render dispatch — Android analogue of iOS
/// `RNVPBackgroundTaskGuard` (ios/BackgroundTaskGuard.{h,mm}). `begin`:
///   1. drains zombies from a prior launch (once per process),
///   2. journals the render so a process-kill leaves a cleanup record,
///   3. (when `keepAlive`) ref-counts up the foreground service so the
///      export survives backgrounding.
/// `end` (call from every completion branch — success/error/abort):
///   1. clears the journal entry,
///   2. (when `keepAlive`) ref-counts the foreground service down.
///
/// Long encode/mux paths pass `keepAlive = true`; fast passthrough remux
/// paths (trim, metadata-only stamp) pass `false` — they finish in
/// milliseconds, so a foreground-service notification would only flicker, but
/// they are still journaled so a mid-op kill cleans up the partial file.
///
/// Unlike iOS, there is no `stopToken` here: a foreground service has no time
/// budget to expire, so nothing needs to cascade to abort.
///

package com.margelo.nitro.videopipeline

import android.content.Context
import com.margelo.nitro.NitroModules
import java.util.concurrent.atomic.AtomicLong

internal class RenderForegroundGuard private constructor(
  private val context: Context?,
  private val journalToken: String,
  private val keepAlive: Boolean,
) {
  private var ended = false

  /// Idempotent. Safe to call from every completion branch.
  fun end() {
    if (ended) return
    ended = true
    val ctx = context ?: return
    RenderJournal.clearToken(ctx, journalToken)
    if (keepAlive) ForegroundExportService.renderFinished(ctx)
  }

  companion object {
    private val internalCounter = AtomicLong(0)

    /// `token` is the caller's renderToken; empty (cancellation opted out)
    /// gets a synthesized internal token so cleanup still works. `outputPath`
    /// is journaled so the next-launch drain can delete a partial file.
    fun begin(token: String, outputPath: String?, keepAlive: Boolean): RenderForegroundGuard {
      val ctx = appContext()
      val journalToken = if (token.isNotEmpty()) {
        token
      } else {
        "__rnvp_internal_${internalCounter.incrementAndGet()}"
      }
      if (ctx != null) {
        RenderJournal.drainZombiesOnce(ctx)
        RenderJournal.markActive(ctx, journalToken, outputPath)
        if (keepAlive) ForegroundExportService.renderStarted(ctx)
      }
      return RenderForegroundGuard(ctx, journalToken, keepAlive)
    }

    private fun appContext(): Context? =
      NitroModules.applicationContext?.applicationContext
  }
}
