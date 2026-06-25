///
/// RenderJournal.kt
///
/// Android analogue of iOS `RNVPBackgroundTaskJournal`
/// (ios/BackgroundTaskGuard.{h,mm}). A persistent map of in-flight renders
/// (`renderToken` → output file path) backed by SharedPreferences, so it
/// survives process death and is readable on the next launch.
///
/// US8 "killed process → next launch reports Cancelled" contract: on the
/// first render-adjacent call after launch, `drainZombiesOnce` deletes the
/// partial output of any render that was still journaled (i.e. the previous
/// process died mid-export) and clears the entry. A consumer who persisted a
/// `renderToken` across launches then observes the output file missing — the
/// render is observably incomplete. There is no JS-reachable promise to
/// reject; the JS runtime that owned it died with the process. Same contract,
/// same mechanism as iOS.
///
/// Writes use `commit()` (synchronous) rather than `apply()`: the whole point
/// is durability across an imminent kill, so the entry must hit disk before
/// the long render proceeds.
///

package com.margelo.nitro.videopipeline

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

internal object RenderJournal {
  private const val TAG = "RNVP.RenderJournal"

  /// Matches the iOS NSUserDefaults key namespace so the two platforms read
  /// as one design (`com.unbogify.rnvp.activeRenders`).
  private const val PREFS = "com.unbogify.rnvp.activeRenders"

  private val lock = Any()
  private val drained = AtomicBoolean(false)

  private fun prefs(ctx: Context) =
    ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  /// Record a render as in-flight. `outputPath` (if any) is stored so the
  /// next-launch drain can delete the partial file. Overwrites any existing
  /// entry for `token`. Empty token → no-op (caller opted out).
  fun markActive(ctx: Context, token: String, outputPath: String?) {
    if (token.isEmpty()) return
    synchronized(lock) {
      prefs(ctx).edit().putString(token, outputPath ?: "").commit()
    }
  }

  /// Clear the entry for `token` on clean completion (success/error/abort).
  fun clearToken(ctx: Context, token: String) {
    if (token.isEmpty()) return
    synchronized(lock) {
      prefs(ctx).edit().remove(token).commit()
    }
  }

  /// Snapshot of the active-renders map (token → outputPath or ""). Mainly
  /// for tests; production code is otherwise write-only here.
  fun activeEntriesSnapshot(ctx: Context): Map<String, String> =
    synchronized(lock) {
      prefs(ctx).all.entries.associate { (k, v) -> k to (v as? String ?: "") }
    }

  /// Delete partial outputs of every journaled render and clear the journal.
  /// Returns the drained tokens. Safe on every launch — empty journal is a
  /// no-op. Best-effort file deletion: a failure still clears the entry so
  /// the drain stays idempotent.
  fun drainZombies(ctx: Context): List<String> = synchronized(lock) {
    val p = prefs(ctx)
    val entries = p.all
    if (entries.isEmpty()) return emptyList()
    val tokens = entries.keys.toList()
    for ((_, value) in entries) {
      val path = value as? String
      if (!path.isNullOrEmpty()) {
        runCatching {
          val f = File(path)
          if (f.exists()) f.delete()
        }
      }
    }
    p.edit().clear().commit()
    tokens
  }

  /// Drain zombies exactly once per process. Called on the first
  /// render-adjacent path after launch (mirrors iOS `drainZombiesOnce`).
  fun drainZombiesOnce(ctx: Context) {
    if (!drained.compareAndSet(false, true)) return
    val tokens = drainZombies(ctx)
    if (tokens.isNotEmpty()) {
      Log.i(TAG, "drained ${tokens.size} zombie render(s) from a prior launch: $tokens")
    }
  }

  /// Clears every entry without touching output files. Test-only.
  fun resetForTesting(ctx: Context) {
    synchronized(lock) { prefs(ctx).edit().clear().commit() }
    drained.set(false)
  }
}
