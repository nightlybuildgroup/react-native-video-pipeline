///
/// OverlayTextRasterizer.kt
///
/// Android analogue of iOS OverlayRenderer.mm's `rasterizeTextOverlay`
/// (CATextLayer path). Pre-rasterizes a `TextOverlay` into an ARGB_8888
/// `Bitmap` using bare `android.graphics` + `android.text` — no Media3
/// TextOverlay, no Skia. The bitmap is then composited through the exact same
/// alpha-blended RGBA quad path as image overlays (see `Transcoder.ComposeGL`),
/// so text and image watermarks share identical anchor / timeRange / opacity
/// semantics on Android.
///
/// The bitmap is rendered at the text's natural measured size plus symmetric
/// shadow padding, so `Transcoder` treats it like a no-explicit-size image
/// overlay (natural-size fallback) and the anchor math stays a plain centered
/// rect — matching the iOS rasterizer's padX/padY convention.
///

package com.margelo.nitro.videopipeline

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.roundToInt

internal object OverlayTextRasterizer {

  fun rasterize(overlay: TextOverlay): Bitmap {
    val style = overlay.style
    val fontSize = if (style.fontSize > 0.0) style.fontSize else 16.0
    val color = parseColor(style.color)
      ?: throw Transcoder.InvalidSpecException(
        "text overlay color is malformed: ${style.color}"
      )

    val typefaceStyle =
      if (style.weight == FontWeight.BOLD) Typeface.BOLD else Typeface.NORMAL
    val family = style.fontFamily
    val typeface = if (family.isNullOrEmpty()) {
      Typeface.create(Typeface.DEFAULT, typefaceStyle)
    } else {
      Typeface.create(family, typefaceStyle)
    }

    val paint = TextPaint(TextPaint.ANTI_ALIAS_FLAG).apply {
      this.textSize = fontSize.toFloat()
      this.color = color
      this.typeface = typeface
    }

    val shadow = style.shadow
    if (shadow != null) {
      val shadowColor = parseColor(shadow.color)
        ?: throw Transcoder.InvalidSpecException(
          "text overlay shadow color is malformed: ${shadow.color}"
        )
      // android requires a non-zero blur radius for setShadowLayer to draw;
      // clamp to a tiny epsilon so dx/dy-only (hard) shadows still render.
      val radius = if (shadow.blur > 0.0) shadow.blur.toFloat() else 0.01f
      paint.setShadowLayer(
        radius, shadow.dx.toFloat(), shadow.dy.toFloat(), shadowColor,
      )
    }

    val alignment = when (style.align) {
      TextAlign.CENTER -> Layout.Alignment.ALIGN_CENTER
      TextAlign.RIGHT -> Layout.Alignment.ALIGN_OPPOSITE
      else -> Layout.Alignment.ALIGN_NORMAL
    }

    val text = overlay.text
    // getDesiredWidth handles embedded '\n' — returns the widest line.
    val lineWidth = ceil(Layout.getDesiredWidth(text, paint)).toInt().coerceAtLeast(1)
    val layout = StaticLayout.Builder
      .obtain(text, 0, text.length, paint, lineWidth)
      .setAlignment(alignment)
      .setIncludePad(true)
      .build()

    val textW = lineWidth
    val textH = layout.height.coerceAtLeast(1)

    // Symmetric padding so a large blur / offset doesn't clip at the bitmap
    // edge. Mirrors iOS rasterizeTextOverlay's padX/padY; the +1 base guards
    // antialiased glyph edges.
    val padX = if (shadow != null) ceil(abs(shadow.dx) + shadow.blur).toInt() + 1 else 1
    val padY = if (shadow != null) ceil(abs(shadow.dy) + shadow.blur).toInt() + 1 else 1

    val bitmap = Bitmap.createBitmap(
      textW + 2 * padX, textH + 2 * padY, Bitmap.Config.ARGB_8888,
    )
    val canvas = Canvas(bitmap)
    canvas.save()
    canvas.translate(padX.toFloat(), padY.toFloat())
    layout.draw(canvas)
    canvas.restore()
    return bitmap
  }

  /// Parses `#rgb` / `#rgba` / `#rrggbb` / `#rrggbbaa` (alpha LAST) and
  /// `rgb()` / `rgba()` into an Android ARGB int. Returns null on malformed
  /// input. Matches iOS OverlayRenderer.mm's parseColorString semantics
  /// (alpha-last hex, 0..255 rgb channels, 0..1 alpha) — Android's
  /// `Color.parseColor` uses alpha-FIRST (`#aarrggbb`) and rejects the 3/4-digit
  /// and `rgba()` forms, so we cannot delegate to it.
  fun parseColor(input: String): Int? {
    val s = input.trim().lowercase()
    if (s.isEmpty()) return null

    if (s.startsWith("#")) {
      val body = s.substring(1)
      val n = body.length
      if (n != 3 && n != 4 && n != 6 && n != 8) return null
      val d = IntArray(n)
      for (i in 0 until n) {
        val v = hexDigit(body[i])
        if (v < 0) return null
        d[i] = v
      }
      var r: Int
      var g: Int
      var b: Int
      var a = 255
      if (n == 3 || n == 4) {
        r = d[0] * 16 + d[0]
        g = d[1] * 16 + d[1]
        b = d[2] * 16 + d[2]
        if (n == 4) a = d[3] * 16 + d[3]
      } else {
        r = d[0] * 16 + d[1]
        g = d[2] * 16 + d[3]
        b = d[4] * 16 + d[5]
        if (n == 8) a = d[6] * 16 + d[7]
      }
      return argb(a, r, g, b)
    }

    if (s.startsWith("rgb")) {
      val open = s.indexOf('(')
      val close = s.indexOf(')')
      if (open < 0 || close < 0 || close <= open + 1) return null
      val parts = s.substring(open + 1, close).split(",")
      if (parts.size != 3 && parts.size != 4) return null
      val vals = DoubleArray(4)
      vals[3] = 1.0
      for (i in parts.indices) {
        val raw = parts[i].trim()
        if (raw.isEmpty()) return null
        vals[i] = raw.toDoubleOrNull() ?: return null
      }
      // r/g/b in 0..255 → clamp to 0..1 → 0..255; alpha already in 0..1.
      val r = (clampUnit(vals[0] / 255.0) * 255.0).roundToInt()
      val g = (clampUnit(vals[1] / 255.0) * 255.0).roundToInt()
      val b = (clampUnit(vals[2] / 255.0) * 255.0).roundToInt()
      val a = (clampUnit(vals[3]) * 255.0).roundToInt()
      return argb(a, r, g, b)
    }

    return null
  }

  private fun hexDigit(c: Char): Int = when (c) {
    in '0'..'9' -> c - '0'
    in 'a'..'f' -> c - 'a' + 10
    else -> -1
  }

  private fun clampUnit(v: Double): Double =
    if (v.isNaN()) 0.0 else v.coerceIn(0.0, 1.0)

  private fun argb(a: Int, r: Int, g: Int, b: Int): Int =
    ((a and 0xFF) shl 24) or
      ((r and 0xFF) shl 16) or
      ((g and 0xFF) shl 8) or
      (b and 0xFF)
}
