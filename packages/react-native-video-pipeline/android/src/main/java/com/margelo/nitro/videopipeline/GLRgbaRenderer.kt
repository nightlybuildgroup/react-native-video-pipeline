///
/// GLRgbaRenderer.kt
///
/// Tiny GLES2 helper that uploads a RGBA8888 pixel buffer to a 2D texture
/// and draws it to the currently-bound EGL surface as a fullscreen quad.
/// Used by the compose pump to push per-frame Skia output into the
/// `MediaCodec` encoder's input surface — the equivalent on Android of
/// `appendPixelBuffer` on iOS.
///
/// Lives outside `VideoEncoder` because it's purely GL state and useful in
/// isolation; `VideoEncoder` constructs and owns one of these for the
/// duration of an encode session.
///
/// Pixel layout invariant: the input buffer is RGBA8888 with row-major,
/// top-down Y (matching what Skia's `readPixels(... ColorType.RGBA_8888)`
/// produces). MediaCodec's input surface uses the OpenGL convention of
/// bottom-up Y. The vertex shader flips the V coordinate so the encoded
/// frame matches the Skia draw orientation byte-for-byte.
///

package com.margelo.nitro.videopipeline

import android.opengl.GLES20
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

internal class GLRgbaRenderer(private val width: Int, private val height: Int) {
  private var program = 0
  private var positionHandle = 0
  private var texCoordHandle = 0
  private var samplerHandle = 0
  private var textureId = 0
  private val vertexBuffer: FloatBuffer = run {
    // Two triangles covering the whole quad. Position is in NDC; texture
    // coords flip V so a top-down RGBA byte buffer (Skia readPixels output)
    // maps to the upright orientation expected by the MediaCodec input
    // surface. Verified empirically: without this flip the user-drawn
    // top-left rect ends up at the bottom-left of the encoded video.
    //
    //   pos.x, pos.y, u, v
    val data = floatArrayOf(
      -1f, -1f, 0f, 1f,
      1f, -1f, 1f, 1f,
      -1f, 1f, 0f, 0f,
      1f, 1f, 1f, 0f,
    )
    ByteBuffer
      .allocateDirect(data.size * 4)
      .order(ByteOrder.nativeOrder())
      .asFloatBuffer()
      .apply {
        put(data)
        position(0)
      }
  }

  fun init() {
    val vs = compileShader(GLES20.GL_VERTEX_SHADER, VERT_SRC)
    val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAG_SRC)
    program = GLES20.glCreateProgram()
    require(program != 0) { "glCreateProgram returned 0" }
    GLES20.glAttachShader(program, vs)
    GLES20.glAttachShader(program, fs)
    GLES20.glLinkProgram(program)
    val linked = IntArray(1)
    GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
    if (linked[0] != GLES20.GL_TRUE) {
      val log = GLES20.glGetProgramInfoLog(program)
      GLES20.glDeleteProgram(program)
      error("glLinkProgram failed: $log")
    }
    GLES20.glDeleteShader(vs)
    GLES20.glDeleteShader(fs)

    positionHandle = GLES20.glGetAttribLocation(program, "aPosition")
    texCoordHandle = GLES20.glGetAttribLocation(program, "aTexCoord")
    samplerHandle = GLES20.glGetUniformLocation(program, "uTex")

    val tex = IntArray(1)
    GLES20.glGenTextures(1, tex, 0)
    textureId = tex[0]
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
    GLES20.glTexParameteri(
      GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
    )
    GLES20.glTexParameteri(
      GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
    )
    GLES20.glTexParameteri(
      GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
    )
    GLES20.glTexParameteri(
      GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
    )
    // Allocate storage once. Per-frame we'll use glTexSubImage2D — saves a
    // re-allocation when the buffer is written to repeatedly.
    GLES20.glTexImage2D(
      GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0,
      GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
    )
    GLES20.glViewport(0, 0, width, height)
  }

  fun draw(rgbaBytes: ByteBuffer) {
    require(rgbaBytes.remaining() >= width * height * 4) {
      "GLRgbaRenderer.draw: buffer remaining=${rgbaBytes.remaining()} " +
        "< expected ${width * height * 4}"
    }
    GLES20.glUseProgram(program)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
    GLES20.glTexSubImage2D(
      GLES20.GL_TEXTURE_2D, 0, 0, 0, width, height,
      GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, rgbaBytes,
    )
    GLES20.glUniform1i(samplerHandle, 0)

    vertexBuffer.position(0)
    GLES20.glEnableVertexAttribArray(positionHandle)
    GLES20.glVertexAttribPointer(
      positionHandle, 2, GLES20.GL_FLOAT, false, 4 * 4, vertexBuffer,
    )
    vertexBuffer.position(2)
    GLES20.glEnableVertexAttribArray(texCoordHandle)
    GLES20.glVertexAttribPointer(
      texCoordHandle, 2, GLES20.GL_FLOAT, false, 4 * 4, vertexBuffer,
    )
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    GLES20.glDisableVertexAttribArray(positionHandle)
    GLES20.glDisableVertexAttribArray(texCoordHandle)
  }

  fun release() {
    if (textureId != 0) {
      GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
      textureId = 0
    }
    if (program != 0) {
      GLES20.glDeleteProgram(program)
      program = 0
    }
  }

  private fun compileShader(type: Int, source: String): Int {
    val id = GLES20.glCreateShader(type)
    require(id != 0) { "glCreateShader($type) returned 0" }
    GLES20.glShaderSource(id, source)
    GLES20.glCompileShader(id)
    val compiled = IntArray(1)
    GLES20.glGetShaderiv(id, GLES20.GL_COMPILE_STATUS, compiled, 0)
    if (compiled[0] != GLES20.GL_TRUE) {
      val log = GLES20.glGetShaderInfoLog(id)
      GLES20.glDeleteShader(id)
      error("glCompileShader failed: $log")
    }
    return id
  }

  companion object {
    private const val VERT_SRC = """
      attribute vec4 aPosition;
      attribute vec2 aTexCoord;
      varying vec2 vTexCoord;
      void main() {
        gl_Position = aPosition;
        vTexCoord = aTexCoord;
      }
    """

    private const val FRAG_SRC = """
      precision mediump float;
      varying vec2 vTexCoord;
      uniform sampler2D uTex;
      void main() {
        gl_FragColor = texture2D(uTex, vTexCoord);
      }
    """
  }
}
