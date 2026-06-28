///
/// Mp4MetadataInjector.kt
///
/// Post-encode MP4 udta/meta/keys+ilst patcher. Android's `MediaMuxer`
/// has no public API for arbitrary user-data items — it can write
/// `setLocation` and `setOrientationHint` and that's it. To round-trip
/// `MetadataSpec.custom` entries the way iOS's AVAssetWriter does, we
/// re-open the file after the muxer finishes and inject the metadata
/// atoms ourselves.
///
/// We write to the same `moov.udta.meta.keys+ilst` structure iOS emits,
/// with `mdta`-keyspace keys and UTF-8 value items, so the resulting
/// MP4 is byte-compatible with what the iOS demuxer reads back today
/// (and what `mediainfo`, `ffprobe`, `exiftool` recognise).
///
/// Scope of the first cut:
///   - Single-file in-place patch.
///   - Assumes `moov` is the last top-level box (MediaMuxer's default;
///     non-fast-start). If `moov` is followed by `mdat` we'd need to
///     fix `stco`/`co64` chunk offsets to absorb the `moov` size change;
///     not implemented — we throw rather than silently corrupt.
///   - Replaces any pre-existing `udta/meta/keys+ilst` tree wholesale.
///     Other `udta` children (e.g. `setLocation`'s `loci` box) are
///     preserved.
///   - A rewrite that *shrinks* the moov (re-stamping with a smaller
///     payload) is padded back up with a `free` box rather than moving
///     `mdat` — see `padMoovToNoShrink`.
///   - 4-byte (32-bit) box sizes only. 64-bit `largesize` is detected
///     on read but rewritten as 32-bit — fine for files under 4 GiB.
///

package com.margelo.nitro.videopipeline

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object Mp4MetadataInjector {

  /// Canonical `mdta` keys this library uses to persist the non-location
  /// scalar `MetadataSpec` fields on Android. `MediaMuxer` can only express
  /// `location` (`setLocation`), so everything else rides in the
  /// `moov.udta.meta` mdta store — the same store iOS's `AVAssetWriter`
  /// writes for `custom`. They round-trip through [read] + `ProbeRunner`:
  /// `KEY_DESCRIPTION`/`KEY_CREATION_DATE` map back into the dedicated
  /// `VideoInfo` fields; `KEY_SOFTWARE` surfaces under `custom["software"]`,
  /// matching how AVFoundation normalises `AVMetadataCommonKeySoftware`.
  ///
  /// The keys are bare (not reverse-DNS) so an iOS reader sees `software`
  /// in `custom` exactly as it would for an iOS-authored file. A caller
  /// `custom` entry colliding with one of these is overwritten by the
  /// explicit `MetadataSpec` field (see [itemsFor]); reverse-DNS custom
  /// keys never collide in practice.
  const val KEY_SOFTWARE = "software"
  const val KEY_DESCRIPTION = "description"
  const val KEY_CREATION_DATE = "creationDate"

  /// Flatten a `MetadataSpec` into the `mdta` key/value items [inject]
  /// persists: caller `custom` entries verbatim, plus the standard scalar
  /// fields under their canonical keys. `location` is intentionally excluded
  /// — it's written via `MediaMuxer.setLocation` as a real `©xyz` atom the
  /// probe reads natively. `creationDate` is serialised ISO-8601 (the shape
  /// `ProbeRunner.parseCreationDate` already accepts).
  fun itemsFor(metadata: MetadataSpec): Map<String, String> {
    val items = LinkedHashMap<String, String>()
    metadata.custom?.forEach { (k, v) -> if (k.isNotEmpty() && v.isNotEmpty()) items[k] = v }
    metadata.software?.takeIf { it.isNotEmpty() }?.let { items[KEY_SOFTWARE] = it }
    metadata.description?.takeIf { it.isNotEmpty() }?.let { items[KEY_DESCRIPTION] = it }
    metadata.creationDate?.let { items[KEY_CREATION_DATE] = it.toString() }
    return items
  }

  /// Persist a full `MetadataSpec`'s non-location fields. No-op when there's
  /// nothing to write. Safe to call after `MediaMuxer.setLocation` has already
  /// handled `location`.
  fun injectSpec(outputPath: String, metadata: MetadataSpec) {
    val items = itemsFor(metadata)
    if (items.isNotEmpty()) inject(outputPath, items)
  }

  /// Inject `custom` as `mdta`-keyspace items into `outputPath`'s moov box.
  /// Existing `udta` siblings other than `meta` are preserved; an existing
  /// `meta` is replaced. No-op when `custom` is empty.
  ///
  /// MediaMuxer's typical layout is `ftyp · moov · free · mdat` — `mdat`
  /// is *not* last, but `free` is a `moov`-adjacent padding box we can
  /// shrink to absorb the moov size increase, leaving `mdat` exactly where
  /// it was so the chunk offsets in `stco`/`co64` stay valid. If there's
  /// no `free` box (or not enough room), we'd need to relocate `mdat` and
  /// fix offsets — that's a future enhancement; for now we throw.
  fun inject(outputPath: String, custom: Map<String, String>) {
    if (custom.isEmpty()) return
    val file = File(outputPath)
    require(file.exists()) { "Mp4MetadataInjector: file not found at $outputPath" }

    android.util.Log.d(
      "Mp4MetadataInjector",
      "inject: outputPath=$outputPath items=${custom.size}",
    )

    RandomAccessFile(file, "rw").use { raf ->
      val totalLen = raf.length()

      // 1. Walk top-level boxes; find moov + the box immediately after.
      val topLevel = readTopLevelBoxes(raf, totalLen)
      android.util.Log.d(
        "Mp4MetadataInjector",
        "boxes: ${topLevel.joinToString(",") { "${it.type}@${it.headerStart}+${it.totalSize}" }}",
      )
      val moovIdx = topLevel.indexOfFirst { it.type == "moov" }
      require(moovIdx >= 0) { "Mp4MetadataInjector: no moov box in $outputPath" }
      val moov = topLevel[moovIdx]

      // 2. Read + patch moov.
      raf.seek(moov.headerStart)
      val moovBytes = ByteArray(moov.totalSize.toInt())
      raf.readFully(moovBytes)
      // A rewritten moov can be *smaller* than the original (e.g. re-stamping
      // with shorter/fewer metadata values). Shrinking the container would mean
      // pulling mdat backwards; instead pad the moov back up with a `free` box
      // so it never shrinks below its original size. After this `delta >= 0`
      // always, and the grow branches below (extend-eof / free-shrink /
      // offset-fixup) cover every remaining case.
      val patchedMoov = padMoovToNoShrink(patchMoov(moovBytes, custom), moov.totalSize.toInt())
      val delta = patchedMoov.size - moov.totalSize.toInt()

      android.util.Log.d(
        "Mp4MetadataInjector",
        "delta=$delta moovIdx=$moovIdx topLevelCount=${topLevel.size}",
      )

      if (delta == 0) {
        // Same size; just overwrite in place.
        android.util.Log.d("Mp4MetadataInjector", "path=in-place")
        raf.seek(moov.headerStart)
        raf.write(patchedMoov)
        return@use
      }

      val followingBox = topLevel.getOrNull(moovIdx + 1)
      val moovIsLast = moovIdx == topLevel.size - 1

      when {
        // Unreachable: padMoovToNoShrink guarantees delta >= 0. Kept as a
        // defensive guard so a future regression fails loudly instead of
        // corrupting chunk offsets.
        delta < 0 -> error(
          "Mp4MetadataInjector: patched moov still smaller than original after " +
            "padding (delta=$delta) — internal invariant violated.",
        )

        // moov is the last box: extending the file is fine, no shift.
        moovIsLast -> {
          android.util.Log.d("Mp4MetadataInjector", "path=extend-eof")
          raf.setLength(moov.headerStart + patchedMoov.size)
          raf.seek(moov.headerStart)
          raf.write(patchedMoov)
        }

        // moov is followed by a free/skip box big enough to absorb delta.
        followingBox != null &&
          (followingBox.type == "free" || followingBox.type == "skip") &&
          followingBox.totalSize >= 8 + delta -> {
          val newFreeSize = followingBox.totalSize.toInt() - delta
          android.util.Log.d(
            "Mp4MetadataInjector",
            "path=free-shrink free=${followingBox.totalSize} -> $newFreeSize",
          )
          raf.seek(moov.headerStart)
          raf.write(patchedMoov)
          // After our patched moov ends, write the new free-box header.
          // The body (zeros, '0' padding, whatever) shifts forward but
          // is by definition ignored content — readers just skip it.
          raf.seek((moov.headerStart + patchedMoov.size).toLong())
          raf.write(intToBE(newFreeSize))
          raf.write(followingBox.type.toByteArray(Charsets.ISO_8859_1))
        }

        // Fallback: free box absent or too small to absorb delta. Shift
        // everything after moov forward by delta bytes, then patch every
        // stco/co64 chunk offset inside moov by +delta so the chunk
        // pointers track the moved mdat. Same trick AtomicParsley uses
        // when its fast-path free-shrink can't fit the new metadata, and
        // what AVAssetWriter does on the fast-start re-arrange pass.
        else -> {
          android.util.Log.d(
            "Mp4MetadataInjector",
            "path=offset-fixup delta=$delta following=${followingBox?.type}+${followingBox?.totalSize}",
          )
          patchChunkOffsetsInPlace(patchedMoov, delta)
          shiftFileForward(raf, moov.headerStart + moov.totalSize, delta)
          raf.seek(moov.headerStart)
          raf.write(patchedMoov)
        }
      }
    }
  }

  /// Read all `mdta`-keyspace items from the file's `moov.udta.meta`
  /// box, plus any classic QuickTime user-data atoms (`©inf`, `©cpy`,
  /// `©too`, etc.) sitting directly inside `udta`. Returns an empty map
  /// when no such items are present (e.g. file written by a muxer that
  /// only set legacy fields).
  ///
  /// Mirrors the iOS side of the read path: items appear under their
  /// caller-authored key for `mdta/<key>` entries, and under their
  /// 4-character atom name (with the leading `©`) for legacy `udta`
  /// entries.
  fun read(filePath: String): Map<String, String> {
    val file = File(filePath)
    if (!file.exists()) return emptyMap()
    return RandomAccessFile(file, "r").use { raf ->
      val totalLen = raf.length()
      val topLevel = readTopLevelBoxes(raf, totalLen)
      val moov = topLevel.firstOrNull { it.type == "moov" } ?: return@use emptyMap()
      raf.seek(moov.headerStart)
      val moovBytes = ByteArray(moov.totalSize.toInt())
      raf.readFully(moovBytes)
      readMoovMetadata(moovBytes)
    }
  }

  private fun readMoovMetadata(moovBytes: ByteArray): Map<String, String> {
    val out = LinkedHashMap<String, String>()
    val children = moovBytes.copyOfRange(8, moovBytes.size)
    var i = 0
    while (i < children.size) {
      if (i + 8 > children.size) break
      val sz = ByteBuffer.wrap(children, i, 4).order(ByteOrder.BIG_ENDIAN).int
      val ty = String(children, i + 4, 4, Charsets.ISO_8859_1)
      if (sz <= 0 || i + sz > children.size) break
      if (ty == "udta") {
        readUdta(children, i + 8, i + sz, out)
      }
      i += sz
    }
    return out
  }

  private fun readUdta(
    bytes: ByteArray,
    start: Int,
    end: Int,
    out: MutableMap<String, String>,
  ) {
    var i = start
    while (i < end) {
      if (i + 8 > end) break
      val sz = ByteBuffer.wrap(bytes, i, 4).order(ByteOrder.BIG_ENDIAN).int
      val ty = String(bytes, i + 4, 4, Charsets.ISO_8859_1)
      if (sz <= 0 || i + sz > end) break
      when {
        ty == "meta" -> readMeta(bytes, i + 12 /* skip header + version+flags */, i + sz, out)
        ty.startsWith("©") -> {
          // Classic QuickTime ©xyz user-data atom: payload is a 16-bit
          // length, 16-bit language code, then UTF-8 text. Surface under
          // the atom name verbatim.
          val payloadStart = i + 8
          val payloadLen = sz - 8
          if (payloadLen >= 4) {
            val textLen = ByteBuffer.wrap(bytes, payloadStart, 2).order(ByteOrder.BIG_ENDIAN).short.toInt() and 0xFFFF
            val textOff = payloadStart + 4
            val safeLen = minOf(textLen, sz - 12).coerceAtLeast(0)
            if (safeLen > 0) {
              val value = String(bytes, textOff, safeLen, Charsets.UTF_8)
              if (out[ty] == null) out[ty] = value
            }
          }
        }
      }
      i += sz
    }
  }

  /// `meta` is a full box; caller passes the offset *after* its
  /// version+flags so we land on the first child box.
  private fun readMeta(
    bytes: ByteArray,
    start: Int,
    end: Int,
    out: MutableMap<String, String>,
  ) {
    val keys = mutableListOf<String>()
    var ilstStart = -1
    var ilstEnd = -1
    var i = start
    while (i < end) {
      if (i + 8 > end) break
      val sz = ByteBuffer.wrap(bytes, i, 4).order(ByteOrder.BIG_ENDIAN).int
      val ty = String(bytes, i + 4, 4, Charsets.ISO_8859_1)
      if (sz <= 0 || i + sz > end) break
      if (ty == "keys") {
        // [version+flags:4][entry_count:4][key boxes...]
        var j = i + 12 // skip header (8) + version+flags (4)
        val entryCount = ByteBuffer.wrap(bytes, i + 8, 4).order(ByteOrder.BIG_ENDIAN).int
        repeat(entryCount) {
          if (j + 8 > end) return@repeat
          val keyBoxSize = ByteBuffer.wrap(bytes, j, 4).order(ByteOrder.BIG_ENDIAN).int
          if (keyBoxSize < 8 || j + keyBoxSize > end) return@repeat
          val keyValue = String(bytes, j + 8, keyBoxSize - 8, Charsets.UTF_8)
          keys.add(keyValue)
          j += keyBoxSize
        }
      } else if (ty == "ilst") {
        // ilst is a plain Box (not FullBox); items begin right after the
        // 8-byte header.
        ilstStart = i + 8
        ilstEnd = i + sz
      }
      i += sz
    }
    if (keys.isEmpty() || ilstStart < 0) return
    // Walk ilst items: type field is the 1-based key index.
    var k = ilstStart
    while (k < ilstEnd) {
      if (k + 8 > ilstEnd) break
      val itemSize = ByteBuffer.wrap(bytes, k, 4).order(ByteOrder.BIG_ENDIAN).int
      val keyIndex = ByteBuffer.wrap(bytes, k + 4, 4).order(ByteOrder.BIG_ENDIAN).int
      if (itemSize < 8 || k + itemSize > ilstEnd) break
      // First child should be the data box.
      val dataStart = k + 8
      if (dataStart + 16 <= k + itemSize) {
        val dataSize = ByteBuffer.wrap(bytes, dataStart, 4).order(ByteOrder.BIG_ENDIAN).int
        val dataType = String(bytes, dataStart + 4, 4, Charsets.ISO_8859_1)
        if (dataType == "data" && dataSize >= 16 && dataStart + dataSize <= k + itemSize) {
          val payloadOff = dataStart + 16
          val payloadLen = dataSize - 16
          if (payloadLen > 0 && keyIndex in 1..keys.size) {
            val value = String(bytes, payloadOff, payloadLen, Charsets.UTF_8)
            val key = keys[keyIndex - 1]
            if (out[key] == null) out[key] = value
          }
        }
      }
      k += itemSize
    }
  }

  // -------------------------------------------------------------------
  // Box-walking primitives.
  // -------------------------------------------------------------------

  private data class BoxRef(
    val headerStart: Long,
    val payloadStart: Long,
    val totalSize: Long,
    val type: String,
  )

  /// Return all top-level boxes in the file, with their byte ranges.
  private fun readTopLevelBoxes(raf: RandomAccessFile, totalLen: Long): List<BoxRef> {
    val out = mutableListOf<BoxRef>()
    var cursor = 0L
    while (cursor < totalLen) {
      raf.seek(cursor)
      val header = ByteArray(8)
      raf.readFully(header)
      val (size, type) = parseBoxHeader(header, raf, cursor)
      val payloadOffset = if (size.first == BoxSizeKind.LARGE) 16 else 8
      out.add(
        BoxRef(
          headerStart = cursor,
          payloadStart = cursor + payloadOffset,
          totalSize = size.second,
          type = type,
        ),
      )
      cursor += size.second
    }
    return out
  }

  private enum class BoxSizeKind { NORMAL, LARGE }

  private fun parseBoxHeader(
    header: ByteArray,
    raf: RandomAccessFile,
    headerStart: Long,
  ): Pair<Pair<BoxSizeKind, Long>, String> {
    val size32 = ByteBuffer.wrap(header, 0, 4).order(ByteOrder.BIG_ENDIAN).int.toLong() and 0xFFFFFFFFL
    val type = String(header, 4, 4, Charsets.ISO_8859_1)
    val size: Pair<BoxSizeKind, Long> = when {
      size32 == 1L -> {
        // 64-bit size in next 8 bytes.
        val ext = ByteArray(8)
        raf.seek(headerStart + 8)
        raf.readFully(ext)
        val s = ByteBuffer.wrap(ext).order(ByteOrder.BIG_ENDIAN).long
        BoxSizeKind.LARGE to s
      }
      size32 == 0L -> {
        // "until end of file" — only valid for the last box.
        BoxSizeKind.NORMAL to (raf.length() - headerStart)
      }
      else -> BoxSizeKind.NORMAL to size32
    }
    return size to type
  }

  // -------------------------------------------------------------------
  // moov patcher.
  // -------------------------------------------------------------------

  /// Take an entire moov box (header + payload) and return a new moov box
  /// with custom items merged into its udta/meta/keys+ilst structure.
  private fun patchMoov(moovBytes: ByteArray, custom: Map<String, String>): ByteArray {
    // moov is itself a box: [size:4][type:4='moov'][children…]. We strip
    // the header, work on the children, then re-wrap.
    require(moovBytes.size >= 8) { "Mp4MetadataInjector: moov bytes too small" }
    require(String(moovBytes, 4, 4, Charsets.ISO_8859_1) == "moov") {
      "Mp4MetadataInjector: bytes do not start with a moov box"
    }
    val moovChildren = moovBytes.copyOfRange(8, moovBytes.size)

    // Walk moov children. Capture any existing udta (preserve its
    // non-meta children like loci); drop any moov-level meta box —
    // MediaMuxer emits a `meta` directly inside moov rather than nested
    // inside udta, and readers (mediainfo, ffprobe) get confused when
    // both moov.meta and moov.udta.meta are present. We consolidate
    // everything into our udta.meta so there's exactly one canonical
    // metadata bag in the file.
    val newChildren = StringBuilder() // dummy — we use ByteArrayOutputStream
    val out = java.io.ByteArrayOutputStream()
    var existingUdta: ByteArray? = null
    var i = 0
    while (i < moovChildren.size) {
      require(i + 8 <= moovChildren.size) {
        "Mp4MetadataInjector: truncated moov child header at offset $i"
      }
      val childSize = ByteBuffer.wrap(moovChildren, i, 4).order(ByteOrder.BIG_ENDIAN).int
      val childType = String(moovChildren, i + 4, 4, Charsets.ISO_8859_1)
      val childEnd = i + childSize
      require(childSize > 0 && childEnd <= moovChildren.size) {
        "Mp4MetadataInjector: invalid moov child size $childSize at offset $i"
      }
      when (childType) {
        "udta" -> existingUdta = moovChildren.copyOfRange(i, childEnd)
        "meta" -> { /* drop — our udta.meta is canonical */ }
        // Drop moov-level padding. `padMoovToNoShrink` re-adds exactly the
        // slack a given rewrite needs; carrying old free boxes through would
        // let them accumulate across repeated re-stamps.
        "free", "skip" -> { /* drop — regenerated as slack when needed */ }
        else -> out.write(moovChildren, i, childSize)
      }
      i = childEnd
    }

    // Build the patched udta and append.
    out.write(buildUdta(existingUdta, custom))

    // Re-wrap: [size:4][type:4='moov'][newChildren].
    val payload = out.toByteArray()
    return wrapBox("moov", payload)
    // Suppress unused-variable warning in some lint configs.
    @Suppress("UNUSED_EXPRESSION") newChildren
  }

  /// Ensure a freshly-patched moov is never smaller than the original by
  /// appending a `free` child box to absorb the shortfall. This keeps the
  /// container from having to shrink (which would require moving `mdat` and
  /// rewriting chunk offsets) and turns every rewrite into a no-shrink case the
  /// grow branches in [inject] already handle.
  ///
  /// The minimum box is 8 bytes (header only). When the shortfall is >= 8 the
  /// padded moov lands at exactly the original size (delta 0, in-place rewrite);
  /// a 1..7-byte shortfall can't be expressed as a free box that small, so we
  /// add the minimum 8-byte free box and overshoot by a few bytes (delta 1..7),
  /// which the standard grow path absorbs. No-op when the moov already grew.
  private fun padMoovToNoShrink(patchedMoov: ByteArray, originalSize: Int): ByteArray {
    val shortfall = originalSize - patchedMoov.size
    if (shortfall <= 0) return patchedMoov
    val freeBody = ByteArray((shortfall - 8).coerceAtLeast(0))
    val freeBox = wrapBox("free", freeBody) // size = max(8, shortfall)
    val out = java.io.ByteArrayOutputStream()
    out.write(patchedMoov, 8, patchedMoov.size - 8) // moov children
    out.write(freeBox)
    return wrapBox("moov", out.toByteArray())
  }

  /// Build a complete `udta` box with our custom items. If
  /// `existingUdta` is non-null, its non-`meta` children are preserved
  /// (e.g. `loci` from `MediaMuxer.setLocation`), and any pre-existing
  /// `meta` is dropped — we own that part.
  private fun buildUdta(existingUdta: ByteArray?, custom: Map<String, String>): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    if (existingUdta != null) {
      // Skip [size:4][type:4='udta'] header; iterate children.
      val payload = existingUdta.copyOfRange(8, existingUdta.size)
      var i = 0
      while (i < payload.size) {
        val childSize = ByteBuffer.wrap(payload, i, 4).order(ByteOrder.BIG_ENDIAN).int
        val childType = String(payload, i + 4, 4, Charsets.ISO_8859_1)
        if (childType == "meta") {
          // drop; we'll replace
        } else {
          out.write(payload, i, childSize)
        }
        i += childSize
      }
    }
    out.write(buildMeta(custom))
    return wrapBox("udta", out.toByteArray())
  }

  /// Build a `meta` full-box with `hdlr` ('mdta'), `keys`, `ilst`.
  private fun buildMeta(custom: Map<String, String>): ByteArray {
    val keys = custom.keys.toList()
    // 'meta' is a full box: 4 bytes of (version=0, flags=0) before children.
    val payload = java.io.ByteArrayOutputStream()
    payload.write(byteArrayOf(0, 0, 0, 0)) // version(0) + flags(0)
    payload.write(buildHdlr())
    payload.write(buildKeys(keys))
    payload.write(buildIlst(keys.size, custom.values.toList()))
    return wrapBox("meta", payload.toByteArray())
  }

  /// hdlr box for 'mdta' metadata handler. Same shape iOS emits.
  private fun buildHdlr(): ByteArray {
    val payload = java.io.ByteArrayOutputStream()
    payload.write(byteArrayOf(0, 0, 0, 0)) // version + flags
    payload.write(byteArrayOf(0, 0, 0, 0)) // pre_defined
    payload.write("mdta".toByteArray(Charsets.ISO_8859_1))
    payload.write(byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) // reserved
    payload.write(byteArrayOf(0)) // empty UTF-8 name + null terminator
    return wrapBox("hdlr", payload.toByteArray())
  }

  /// keys box: list of mdta keys.
  private fun buildKeys(keys: List<String>): ByteArray {
    val payload = java.io.ByteArrayOutputStream()
    payload.write(byteArrayOf(0, 0, 0, 0)) // version + flags
    payload.write(intToBE(keys.size)) // entry_count
    for (key in keys) {
      val keyBytes = key.toByteArray(Charsets.UTF_8)
      val keyBoxSize = 8 + keyBytes.size // size(4) + namespace(4) + key
      payload.write(intToBE(keyBoxSize))
      payload.write("mdta".toByteArray(Charsets.ISO_8859_1)) // key_namespace
      payload.write(keyBytes)
    }
    return wrapBox("keys", payload.toByteArray())
  }

  /// ilst box: list of items, one per key. Each item's type is the
  /// 1-based index of the key it refers to (4-byte big-endian).
  /// Per ISO/IEC 14496-12, `ilst` is a plain Box (not a FullBox) — no
  /// leading version+flags before the item entries.
  private fun buildIlst(numKeys: Int, values: List<String>): ByteArray {
    require(numKeys == values.size)
    val payload = java.io.ByteArrayOutputStream()
    for (i in 0 until numKeys) {
      val valueBytes = values[i].toByteArray(Charsets.UTF_8)
      // 'data' box: [size:4][type:4='data'][version+flags:4][reserved:4][payload]
      val dataBox = java.io.ByteArrayOutputStream()
      dataBox.write(intToBE(16 + valueBytes.size)) // total data box size
      dataBox.write("data".toByteArray(Charsets.ISO_8859_1))
      dataBox.write(intToBE(1))      // type_indicator=1 (UTF-8 string)
      dataBox.write(intToBE(0))      // locale=0
      dataBox.write(valueBytes)
      // item box: [size:4][type:4=BE(i+1)][data box]
      val item = java.io.ByteArrayOutputStream()
      item.write(intToBE(8 + dataBox.size())) // item total size
      item.write(intToBE(i + 1))               // item type = key index
      item.write(dataBox.toByteArray())
      payload.write(item.toByteArray())
    }
    return wrapBox("ilst", payload.toByteArray())
  }

  // -------------------------------------------------------------------
  // Offset-fixup fallback (used when free-box absorption isn't possible).
  // -------------------------------------------------------------------

  /// Walk the patched moov bytes for every `trak.mdia.minf.stbl.{stco,co64}`
  /// and add `delta` to each chunk-offset entry. Modifies the byte array
  /// in place. Throws on malformed input.
  private fun patchChunkOffsetsInPlace(moovBytes: ByteArray, delta: Int) {
    walkBoxesIn(moovBytes, 8, moovBytes.size) { type, start, end ->
      if (type == "trak") walkTrak(moovBytes, start, end, delta)
    }
  }

  private fun walkTrak(b: ByteArray, start: Int, end: Int, delta: Int) {
    walkBoxesIn(b, start, end) { type, s, e ->
      if (type == "mdia") walkBoxesIn(b, s, e) { t2, s2, e2 ->
        if (t2 == "minf") walkBoxesIn(b, s2, e2) { t3, s3, e3 ->
          if (t3 == "stbl") walkBoxesIn(b, s3, e3) { t4, s4, e4 ->
            when (t4) {
              "stco" -> patchStco(b, s4, e4, delta.toLong())
              "co64" -> patchCo64(b, s4, e4, delta.toLong())
            }
          }
        }
      }
    }
  }

  /// stco is a FullBox: [v+f:4][entry_count:4][entries: uint32 each].
  /// `start` points past the 8-byte header.
  private fun patchStco(b: ByteArray, start: Int, end: Int, delta: Long) {
    val entryCount = ByteBuffer.wrap(b, start + 4, 4).order(ByteOrder.BIG_ENDIAN).int
    var off = start + 8 // skip v+f and entry_count
    for (i in 0 until entryCount) {
      if (off + 4 > end) error("stco: entry $i past end")
      val current = ByteBuffer.wrap(b, off, 4).order(ByteOrder.BIG_ENDIAN).int.toLong() and 0xFFFFFFFFL
      val updated = current + delta
      require(updated in 0L..0xFFFFFFFFL) {
        "stco: entry $i overflow 32-bit ($current + $delta = $updated). " +
          "File needs co64 — not handled yet."
      }
      ByteBuffer.wrap(b, off, 4).order(ByteOrder.BIG_ENDIAN).putInt(updated.toInt())
      off += 4
    }
  }

  /// co64: same shape but uint64 entries.
  private fun patchCo64(b: ByteArray, start: Int, end: Int, delta: Long) {
    val entryCount = ByteBuffer.wrap(b, start + 4, 4).order(ByteOrder.BIG_ENDIAN).int
    var off = start + 8
    for (i in 0 until entryCount) {
      if (off + 8 > end) error("co64: entry $i past end")
      val current = ByteBuffer.wrap(b, off, 8).order(ByteOrder.BIG_ENDIAN).long
      ByteBuffer.wrap(b, off, 8).order(ByteOrder.BIG_ENDIAN).putLong(current + delta)
      off += 8
    }
  }

  /// Iterate child boxes of a parent whose payload spans [start, end).
  /// `consume(type, payloadStart, payloadEnd)` — payloadStart points just
  /// past the box's 8-byte header.
  private inline fun walkBoxesIn(
    b: ByteArray,
    start: Int,
    end: Int,
    consume: (String, Int, Int) -> Unit,
  ) {
    var i = start
    while (i + 8 <= end) {
      val sz = ByteBuffer.wrap(b, i, 4).order(ByteOrder.BIG_ENDIAN).int
      val ty = String(b, i + 4, 4, Charsets.ISO_8859_1)
      if (sz < 8 || i + sz > end) break
      consume(ty, i + 8, i + sz)
      i += sz
    }
  }

  /// Shift `[from, file_end)` forward by `delta` bytes (grow file). Uses
  /// a backwards copy so source/dest can overlap. Buffer size is bounded
  /// so we don't pull a multi-hundred-MB mdat into memory at once.
  private fun shiftFileForward(raf: RandomAccessFile, from: Long, delta: Int) {
    require(delta > 0) { "shiftFileForward expects delta>0, got $delta" }
    val originalLen = raf.length()
    val toMove = originalLen - from
    if (toMove <= 0L) {
      // Nothing past the moov; just extend.
      raf.setLength(from + delta)
      return
    }
    raf.setLength(originalLen + delta)

    val bufSize = 256 * 1024 // 256 KiB; balances syscalls vs RAM.
    val buf = ByteArray(bufSize)
    var remaining = toMove
    var srcEnd = from + toMove           // exclusive
    var dstEnd = from + toMove + delta   // exclusive (after the shift)
    while (remaining > 0) {
      val chunk = if (remaining > bufSize) bufSize.toLong() else remaining
      val srcStart = srcEnd - chunk
      val dstStart = dstEnd - chunk
      raf.seek(srcStart)
      raf.readFully(buf, 0, chunk.toInt())
      raf.seek(dstStart)
      raf.write(buf, 0, chunk.toInt())
      srcEnd = srcStart
      dstEnd = dstStart
      remaining -= chunk
    }
  }

  // -------------------------------------------------------------------
  // Helpers.
  // -------------------------------------------------------------------

  private fun wrapBox(type: String, payload: ByteArray): ByteArray {
    require(type.length == 4) { "Box type must be 4 chars, got '$type'" }
    val totalSize = 8 + payload.size
    val out = ByteArray(totalSize)
    val sizeBytes = intToBE(totalSize)
    System.arraycopy(sizeBytes, 0, out, 0, 4)
    val typeBytes = type.toByteArray(Charsets.ISO_8859_1)
    System.arraycopy(typeBytes, 0, out, 4, 4)
    System.arraycopy(payload, 0, out, 8, payload.size)
    return out
  }

  private fun intToBE(v: Int): ByteArray {
    return ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(v).array()
  }
}
