package com.margelo.nitro.videopipeline

import android.net.Uri

/**
 * Normalize a user-supplied output location to a bare filesystem path.
 *
 * MediaMuxer, Media3 Transformer, [VideoEncoder], `java.io.File(...)`, and the
 * [RenderJournal] / [RenderForegroundGuard] zombie-cleanup all expect a real
 * filesystem path — not a URL. `output.path` (and the convenience `outPath`)
 * may legitimately arrive as either a bare path or a `file://` URI (e.g.
 * expo-file-system's `File.uri`), exactly like the source `uri`/`outPath`.
 * Feeding a `file://` URI straight into `File(...)` yields a path literally
 * containing `file:` that the muxer can't create — the Android analogue of the
 * iOS -12115/-17913 "Cannot create file" (issues #74 / #78). This strips the
 * scheme for `file://` URIs and leaves bare paths untouched, so every entry
 * point accepts both forms uniformly. Mirrors iOS's `RNVPOutputFilesystemPath`.
 *
 * `Uri.getPath()` returns the **decoded** path component, so percent-encoded
 * segments (e.g. expo's `%20` for spaces) come back as real characters —
 * unlike a naive `removePrefix("file://")`, which would leave `%20` in the
 * path and write to the wrong file.
 */
internal fun outputFilesystemPath(pathOrUri: String): String {
  if (!pathOrUri.startsWith("file://")) return pathOrUri
  return Uri.parse(pathOrUri).path ?: pathOrUri
}
