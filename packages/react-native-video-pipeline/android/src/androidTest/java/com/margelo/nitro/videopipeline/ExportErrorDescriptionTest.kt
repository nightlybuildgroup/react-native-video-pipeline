///
/// ExportErrorDescriptionTest.kt
///
/// Coverage for `TransformerRunner.describeExportException` /
/// `hintForExportErrorCode` (issue #89 — the Android parity for iOS #85 /
/// `RNVPDescribeError`). Media3 export failures must surface the greppable
/// structured signal — the symbolic `errorCodeName`, the raw `errorCode`, and
/// the `cause` chain — inline in the thrown message, not just the human string
/// (which was previously dropped whenever `ExportException.message` was
/// non-null, i.e. the common case).
///
/// `ExportException` is pure Java, but the test lives in androidTest so it
/// compiles in the offline Kotlin loop alongside the rest of the module's
/// instrumented suite (`compileDebugAndroidTestKotlin`); it needs no emulator
/// state beyond a JVM. `describeExportException` is `internal`, visible to the
/// module's own test source set.
///

package com.margelo.nitro.videopipeline

import androidx.media3.transformer.ExportException
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.FileNotFoundException

@RunWith(AndroidJUnit4::class)
class ExportErrorDescriptionTest {

  /// `createForAssetLoader(cause, errorCode)` is the public factory that lets
  /// us pin an arbitrary `errorCode` + `cause`, standing in for whatever
  /// Media3 raises internally.
  private fun exportException(cause: Throwable, errorCode: Int): ExportException =
    ExportException.createForAssetLoader(cause, errorCode)

  @Test
  fun includesErrorCodeNameAndRawCode() {
    val e = exportException(
      FileNotFoundException("/bad/dir/out.mp4"),
      ExportException.ERROR_CODE_IO_FILE_NOT_FOUND,
    )
    val desc = TransformerRunner.describeExportException(e)
    assertTrue("must name the symbolic code: $desc", desc.contains("ERROR_CODE_IO_FILE_NOT_FOUND"))
    assertTrue(
      "must include the raw errorCode int: $desc",
      desc.contains("[${ExportException.ERROR_CODE_IO_FILE_NOT_FOUND}]"),
    )
  }

  @Test
  fun surfacesCauseChain() {
    val root = IllegalStateException("codec died")
    val mid = RuntimeException("wrapper", root)
    val desc = TransformerRunner.describeExportException(
      exportException(mid, ExportException.ERROR_CODE_ENCODING_FAILED),
    )
    assertTrue("must include the cause: $desc", desc.contains("cause: "))
    assertTrue("must include the wrapper: $desc", desc.contains("wrapper"))
    assertTrue("must walk into the root cause: $desc", desc.contains("codec died"))
    assertTrue(
      "must chain causes with 'caused by': $desc",
      desc.contains("caused by"),
    )
  }

  /// Regression for the exact #89 bug: when `ExportException.message` is
  /// non-null (the common case), the structured `errorCode` must STILL be
  /// appended — previously it was included only when the message was null.
  @Test
  fun appendsCodeEvenWhenMessagePresent() {
    val e = exportException(
      RuntimeException("boom"),
      ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
    )
    assertTrue("sanity: Media3 supplies a message", !e.message.isNullOrEmpty())
    val desc = TransformerRunner.describeExportException(e)
    assertTrue("human message preserved: $desc", desc.contains(e.message!!))
    assertTrue("code still appended: $desc", desc.contains("ERROR_CODE_ENCODER_INIT_FAILED"))
  }

  @Test
  fun ioErrorCodesGetAWritablePathHint() {
    assertTrue(
      hint(ExportException.ERROR_CODE_IO_FILE_NOT_FOUND).contains("parent directory"),
    )
    assertTrue(
      hint(ExportException.ERROR_CODE_IO_NO_PERMISSION).contains("writable filesystem path"),
    )
  }

  @Test
  fun encoderErrorCodesGetAFormatHint() {
    assertTrue(
      hint(ExportException.ERROR_CODE_ENCODER_INIT_FAILED).contains("device encoder"),
    )
    assertTrue(
      hint(ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED).contains("output format"),
    )
  }

  @Test
  fun unmappedCodeHasNoHint() {
    assertNull(TransformerRunner.hintForExportErrorCode(ExportException.ERROR_CODE_MUXING_FAILED))
    val desc = TransformerRunner.describeExportException(
      exportException(RuntimeException("x"), ExportException.ERROR_CODE_MUXING_FAILED),
    )
    assertTrue("no hint segment when unmapped: $desc", !desc.contains("; hint: "))
  }

  private fun hint(code: Int): String =
    requireNotNull(TransformerRunner.hintForExportErrorCode(code)) {
      "expected a hint for code $code"
    }
}
