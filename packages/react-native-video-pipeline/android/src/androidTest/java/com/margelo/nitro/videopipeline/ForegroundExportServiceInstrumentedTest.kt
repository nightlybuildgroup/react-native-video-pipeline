///
/// ForegroundExportServiceInstrumentedTest.kt
///
/// On-device verification of T047 (US8): the render journal's
/// kill-then-cleanup contract and the foreground-service declaration/wiring.
///

package com.margelo.nitro.videopipeline

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ForegroundExportServiceInstrumentedTest {

  private val ctx: Context
    get() = InstrumentationRegistry.getInstrumentation().targetContext

  @Before fun clearJournal() = RenderJournal.resetForTesting(ctx)

  @After fun cleanup() = RenderJournal.resetForTesting(ctx)

  // --- Journal: the "killed process → next launch cleans up" contract -----

  @Test
  fun drainZombies_deletesPartialOutputAndClearsJournal() {
    val partial = File(ctx.cacheDir, "rnvp-zombie-${System.nanoTime()}.mp4")
    partial.writeBytes(ByteArray(1024)) // stand-in for a partial export
    assertTrue(partial.exists())

    RenderJournal.markActive(ctx, "vp_zombie", partial.absolutePath)
    assertEquals(partial.absolutePath, RenderJournal.activeEntriesSnapshot(ctx)["vp_zombie"])

    val drained = RenderJournal.drainZombies(ctx)

    assertTrue("token reported as drained", drained.contains("vp_zombie"))
    assertFalse("partial output deleted", partial.exists())
    assertTrue("journal emptied", RenderJournal.activeEntriesSnapshot(ctx).isEmpty())
  }

  @Test
  fun clearToken_removesEntryButKeepsCompletedOutput() {
    val output = File(ctx.cacheDir, "rnvp-done-${System.nanoTime()}.mp4")
    output.writeBytes(ByteArray(1024)) // a successfully finished export
    RenderJournal.markActive(ctx, "vp_done", output.absolutePath)

    // Clean completion clears the journal entry without touching the file.
    RenderJournal.clearToken(ctx, "vp_done")

    assertTrue("journal entry cleared", RenderJournal.activeEntriesSnapshot(ctx).isEmpty())
    assertTrue("finished output left intact", output.exists())
    // A subsequent drain has nothing to do (no zombie left behind).
    assertTrue(RenderJournal.drainZombies(ctx).isEmpty())
  }

  @Test
  fun markActive_emptyTokenIsIgnored() {
    RenderJournal.markActive(ctx, "", "/tmp/whatever.mp4")
    assertTrue(RenderJournal.activeEntriesSnapshot(ctx).isEmpty())
  }

  // --- Foreground service: declaration + wiring ---------------------------

  @Test
  fun service_isDeclaredAsMediaProcessingForegroundService() {
    val info = ctx.packageManager.getServiceInfo(
      ComponentName(ctx, ForegroundExportService::class.java), 0,
    )
    assertFalse("service must not be exported", info.exported)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      assertNotEquals(
        "mediaProcessing foreground-service type must be declared",
        0,
        info.foregroundServiceType and ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING,
      )
    }
  }

  @Test
  fun service_refCountStartsThenStopsForeground() {
    // 0 -> 1: foreground service should come up.
    ForegroundExportService.renderStarted(ctx)
    val started = pollForService(present = true, foreground = true, timeoutMs = 5000)
    // Background-start policy can refuse a service started without a visible
    // activity (instrumentation has none). If it came up, assert it's a real
    // foreground service; either way the wiring must not crash.
    if (started) {
      // 1 -> 2 -> 1: still alive after a single finish (ref-counted).
      ForegroundExportService.renderStarted(ctx)
      ForegroundExportService.renderFinished(ctx)
      assertTrue("still running while a render remains", pollForService(present = true, foreground = false, timeoutMs = 2000))
      // 1 -> 0: last finish stops it.
      ForegroundExportService.renderFinished(ctx)
      assertFalse("stopped after last render", pollForService(present = true, foreground = false, timeoutMs = 5000))
    } else {
      // Roll the (already rolled-back) state forward cleanly.
      ForegroundExportService.renderFinished(ctx)
    }
  }

  private fun pollForService(present: Boolean, foreground: Boolean, timeoutMs: Long): Boolean {
    val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val deadline = System.nanoTime() + timeoutMs * 1_000_000
    while (System.nanoTime() < deadline) {
      @Suppress("DEPRECATION")
      val running = am.getRunningServices(Int.MAX_VALUE)
      val svc = running.firstOrNull {
        it.service.className == ForegroundExportService::class.java.name
      }
      val matches = if (present) {
        svc != null && (!foreground || svc.foreground)
      } else {
        svc == null
      }
      if (matches) return true
      Thread.sleep(100)
    }
    return false
  }
}
