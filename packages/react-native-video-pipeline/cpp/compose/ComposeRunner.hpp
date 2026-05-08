///
/// ComposeRunner.hpp
///
/// Drives the synthesize loop for the compose/null-input path (prd.md §9).
/// Platform-agnostic: the caller wires in
///
///   - a `FrameSource` that fills an RGBA8888 buffer for a given frame index
///     (this slot is the eventual worklet plug-in point — for v0.1 it's a
///     placeholder test-pattern generator on each platform), and
///   - a `FrameSink` that receives the RGBA bytes + a presentation timestamp
///     and forwards them to the platform encoder (AVMuxer on iOS, Media3 on
///     Android).
///
/// Two run modes:
///   - `runFixed` — deterministic `round(fps * seconds)` frames (US11).
///   - `runOpen`  — iterates until the `StopToken` is tripped by
///     `controller.finish()` / `controller.abort()` / `AbortSignal`, the
///     `FrameSource` signals `shouldFinish=true` (mirrors `ctx.finish()`
///     from the worklet, US12), or the optional `maxSeconds` safety cap is
///     reached. `sink.close` is only called on the finish/cap paths — abort
///     returns without closing so the caller can delete the partial file.
///
/// The runner is deliberately thin: it counts frames, computes deterministic
/// PTS as `frameIndex / fps`, and bubbles back the first error it sees from
/// either the source or the sink. No threading, no I/O — keeps the surface
/// testable without a real encoder. See prd.md §10 for the "frame pump" model.
///

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

namespace margelo::nitro::videopipeline {

class StopToken;
class ProgressEmitter;

class ComposeRunner {
public:
  struct FixedSpec {
    int width;
    int height;
    double fps;
    double seconds;
  };

  struct OpenSpec {
    int width;
    int height;
    double fps;
    /// Safety cap. Values <= 0 disable the cap; the loop then relies entirely
    /// on `StopToken` or the `FrameSource`'s `shouldFinish` to terminate.
    double maxSeconds;
  };

  /// Fills `dst` (row-major RGBA8888, `rowBytes` stride) for `frameIndex`.
  /// Return `false` + populate `error` to abort the run.
  using FrameSourceFn = std::function<bool(int frameIndex, uint8_t* dst,
                                           std::size_t rowBytes, std::string& error)>;

  /// Same contract as `FrameSourceFn` but with a `shouldFinish` out param —
  /// the real worklet bridge sets it when the worklet called `ctx.finish()`
  /// on the frame it just produced (US12). The runner still appends this
  /// frame before terminating the loop.
  using FrameSourceOpenFn =
      std::function<bool(int frameIndex, uint8_t* dst, std::size_t rowBytes,
                         bool& shouldFinish, std::string& error)>;

  struct FrameSink {
    /// Called once before the first frame. Implementations open the encoder here.
    std::function<bool(int width, int height, double fps, std::string& error)> open;
    /// Called for each produced frame in order.
    std::function<bool(const uint8_t* rgba, std::size_t rowBytes, double ptsSec,
                       std::string& error)>
        appendFrame;
    /// Called exactly once on the finish / max-seconds paths. NOT called on
    /// abort — the caller is expected to tear down / delete the partial file.
    std::function<bool(std::string& error)> close;
  };

  /// Result of an open-ended run. `aborted` distinguishes `controller.abort()`
  /// (→ caller should discard the output) from the finish / cap / source-finish
  /// paths (→ file finalised).
  struct OpenResult {
    int framesWritten = 0;
    bool aborted = false;
    /// True when the loop exited because it hit `maxSeconds` without any
    /// explicit stop. Purely informational — finalisation still happens.
    bool hitMaxSeconds = false;
  };

  /// Returns `round(fps * seconds)` as an int, clamped at 0. Public so the
  /// iOS adapter's XCTest can assert the frame-count contract independently.
  static int frameCountFor(double fps, double seconds);

  /// Synchronous, blocking. Runs the full fixed-duration loop on the caller's
  /// thread. On failure, returns `false` with `error` populated and
  /// `sink.close` has still been invoked (best-effort cleanup).
  /// When `progress` is non-null the runner starts it before the first frame,
  /// reports post-append for each encoded frame, and finalises it after
  /// `sink.close`. Coalescing is the emitter's responsibility.
  /// When `stop` is non-null the runner polls `abortRequested()` before each
  /// frame and surfaces abort by returning `true` with `*aborted = true` (if
  /// `aborted` is non-null); `sink.close` is NOT called on the abort path so
  /// the caller can delete the partial file. `finishRequested` is ignored on
  /// the fixed path — per VideoRenderController's policy, `finish()` is a
  /// no-op on fixed-duration renders; use `abort()` / AbortSignal instead.
  static bool runFixed(const FixedSpec& spec, const FrameSourceFn& source,
                       const FrameSink& sink, std::string& error,
                       ProgressEmitter* progress = nullptr,
                       const StopToken* stop = nullptr,
                       bool* aborted = nullptr);

  /// Synchronous, blocking open-ended loop. Polls `stop` after every frame
  /// (cheap atomic load) and between iterations. Returns `false` with
  /// `error` populated on source/sink failure. On `abort`, returns `true`
  /// with `result.aborted=true` and does NOT call `sink.close`.
  /// When `progress` is non-null the runner starts it before the first frame
  /// and reports post-append for each encoded frame. `nbFrames` stays as the
  /// caller configured it (typically `std::nullopt` for open-ended) — the
  /// caller is responsible for calling `updateNbFrames` once the total is
  /// known (e.g. via `controller.finish()` or the `maxSeconds` cap).
  static bool runOpen(const OpenSpec& spec, const FrameSourceOpenFn& source,
                      const FrameSink& sink, const StopToken& stop,
                      OpenResult& result, std::string& error,
                      ProgressEmitter* progress = nullptr);
};

} // namespace margelo::nitro::videopipeline
