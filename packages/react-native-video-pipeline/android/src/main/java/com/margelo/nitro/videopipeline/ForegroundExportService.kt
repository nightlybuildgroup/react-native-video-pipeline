///
/// ForegroundExportService.kt
///
/// Keeps the app process alive at foreground-service priority while at least
/// one video export is running, so a long render survives arbitrary
/// backgrounding (US8). Android's analogue of iOS's UIApplication background
/// task — except a foreground service has no time budget, so unlike iOS there
/// is no expiration → abort cascade; the export simply keeps running.
///
/// The service does NOT run the render — exports stay on the
/// `Promise.parallel` worker pool. The service only holds process priority
/// and shows the mandatory ongoing notification. A process-wide ref-count of
/// active renders drives start (0 → 1) and stop (1 → 0); see
/// `RenderForegroundGuard` for the lifecycle wiring.
///
/// `onStartCommand` returns START_NOT_STICKY on purpose: if the OS kills the
/// process we do NOT want the service auto-restarted into an empty process —
/// we want it gone so the next *user* launch runs `RenderJournal.drainZombies`
/// and reports the interrupted renders as cancelled.
///

package com.margelo.nitro.videopipeline

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger

class ForegroundExportService : Service() {

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    // Must call startForeground promptly (within ~5s of startForegroundService)
    // or the platform throws. We build + post immediately.
    runCatching { startForeground(NOTIFICATION_ID, buildNotification(this)) }
      .onFailure { Log.w(TAG, "startForeground failed: ${it.message}") }
    return START_NOT_STICKY
  }

  companion object {
    private const val TAG = "RNVP.ExportService"
    private const val CHANNEL_ID = "rnvp_export"
    private const val NOTIFICATION_ID = 0x524E5650 // "RNVP"

    private val activeCount = AtomicInteger(0)

    /// Ref-count up; start + foreground the service on the 0 → 1 edge.
    fun renderStarted(ctx: Context) {
      if (activeCount.getAndIncrement() == 0) {
        val intent = Intent(ctx, ForegroundExportService::class.java)
        runCatching {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ctx.startForegroundService(intent)
          } else {
            ctx.startService(intent)
          }
        }.onFailure {
          // start can be refused (e.g. background-start limits); the render
          // still runs, it just isn't protected from backgrounding. Roll the
          // count back so a later render retries the start.
          Log.w(TAG, "could not start export service: ${it.message}")
          activeCount.decrementAndGet()
        }
      }
    }

    /// Ref-count down; stop the service on the 1 → 0 edge.
    fun renderFinished(ctx: Context) {
      if (activeCount.decrementAndGet() <= 0) {
        activeCount.set(0)
        runCatching { ctx.stopService(Intent(ctx, ForegroundExportService::class.java)) }
      }
    }

    private fun buildNotification(ctx: Context): Notification {
      ensureChannel(ctx)
      val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        Notification.Builder(ctx, CHANNEL_ID)
      } else {
        @Suppress("DEPRECATION")
        Notification.Builder(ctx)
      }
      return builder
        .setContentTitle("Exporting video…")
        .setContentText("Video export in progress")
        .setSmallIcon(android.R.drawable.stat_sys_upload)
        .setOngoing(true)
        .build()
    }

    private fun ensureChannel(ctx: Context) {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
      val mgr = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      if (mgr.getNotificationChannel(CHANNEL_ID) != null) return
      val channel = NotificationChannel(
        CHANNEL_ID,
        "Video export",
        NotificationManager.IMPORTANCE_LOW,
      ).apply {
        description = "Keeps video exports running while the app is in the background."
        setShowBadge(false)
      }
      mgr.createNotificationChannel(channel)
    }
  }
}
