///
/// ProgressEmitter.hpp
///
/// Coalescing wrapper around the Nitro `onProgress` callback. Render loops
/// produce a frame-by-frame tick; most of those ticks are uninteresting to
/// the consumer and will only slow the render down if every single one
/// crosses JSI. This helper implements the `≥10 Hz, coalesced on the native
/// side` contract from prd.md §14 US7.
///
/// Usage from a runner:
///
///   ProgressEmitter emitter(callback, nbFramesOpt);
///   emitter.start();                 // capture wall-clock t0
///   for (int i = 0; i < N; ++i) {
///     // ... produce/append frame i ...
///     emitter.report(i + 1);         // post-frame: framesCompleted = i+1
///   }
///   emitter.finalize(N);             // force the last tick through
///
/// The emitter:
///   - Always fires the first and last ticks unconditionally so consumers see
///     a 0 → done progression without waiting on the coalescing window.
///   - In between, it emits at most one callback per `minIntervalMs`
///     (default 100 ms ≈ 10 Hz). The cap keeps a 60 fps encoder from firing
///     60 callbacks per second; the floor keeps UI progress bars live.
///   - Computes `elapsedMs` from `std::chrono::steady_clock` (monotonic) so
///     a wall-clock adjustment mid-render can't produce negative deltas.
///   - Computes `estimatedRemainingMs` only when `nbFrames` is known AND at
///     least one frame has been produced. For open-ended renders the helper
///     keeps `estimatedRemainingMs` as `std::nullopt` until the consumer
///     calls `updateNbFrames(...)` (e.g. `controller.finish()` locks in the
///     final count) and then emits a final definite ETA.
///
/// Thread-safety: a single `ProgressEmitter` is owned by one runner loop and
/// is not shared across threads. The Nitro callback itself is marshaled to
/// the JS thread by the `AsyncJSCallback` wrapper that `JSIConverter` for
/// `std::function<void(...)>` installs when the callback crosses the Nitro
/// boundary (see `react-native-nitro-modules/cpp/jsi/JSIConverter+Function
/// .hpp`), so this helper can invoke it from any worker thread safely.
///

#pragma once

#include <chrono>
#include <cstdint>
#include <functional>
#include <optional>

namespace margelo::nitro::videopipeline {

class ProgressEmitter {
public:
  /// Signature matches the flattened Nitro `Progress` struct — kept
  /// platform-agnostic so this header does not depend on the nitrogen
  /// generated headers. The caller (`VideoPipeline.mm`) wraps the Nitro
  /// `std::function<void(const Progress&)>` in a lambda that packs the
  /// four scalars into `Progress{}`.
  using Callback = std::function<void(double framesCompleted,
                                      std::optional<double> nbFrames,
                                      double elapsedMs,
                                      std::optional<double> estimatedRemainingMs)>;

  /// `minIntervalMs = 100` ≈ 10 Hz, matching the prd.md §14 US7 contract.
  /// The constant is a parameter rather than a hard-coded literal so XCTests
  /// can drop it to 0 and assert the per-frame contract independently of
  /// wall-clock timing.
  ProgressEmitter(Callback callback, std::optional<double> nbFrames,
                  double minIntervalMs = 100.0);

  /// Capture t0 and fire the initial `framesCompleted = 0` tick. Idempotent —
  /// callers can invoke it before every run without worrying about the
  /// runner's reuse semantics.
  void start();

  /// Lock in (or revise) the total frame count. Used by the open-ended
  /// synthesize path when `controller.finish()` transitions to `finishing`
  /// and the runner finally knows how many frames it will emit; also used
  /// by fixed-duration callers that build an emitter lazily.
  void updateNbFrames(std::optional<double> nbFrames);

  /// Post-frame tick. `framesCompleted` is the count of frames that have
  /// finished encoding (1-based after the first frame). The first call is
  /// emitted unconditionally; subsequent calls are coalesced so at most one
  /// tick fires per `minIntervalMs` window.
  void report(double framesCompleted);

  /// Final tick. Called from the runner once the encoder has finished
  /// writing so the consumer sees a `framesCompleted == nbFrames` callback
  /// even when the penultimate tick was coalesced away. Safe to call when
  /// no frames have been produced — in that case the emitter forwards the
  /// last-reported count unchanged.
  void finalize(double framesCompleted);

  /// Returns the number of times the underlying callback has been invoked.
  /// XCTests use this to tripwire against missing-tick regressions.
  std::uint64_t invocationCount() const noexcept { return _invocations; }

private:
  bool hasCallback() const noexcept { return static_cast<bool>(_callback); }
  double elapsedMs() const;
  std::optional<double> computeEta(double framesCompleted,
                                   double elapsedMs) const;
  void emit(double framesCompleted);

  Callback _callback;
  std::optional<double> _nbFrames;
  double _minIntervalMs;
  std::chrono::steady_clock::time_point _t0{};
  std::chrono::steady_clock::time_point _lastEmit{};
  bool _started = false;
  bool _emittedAny = false;
  double _lastFramesCompleted = 0.0;
  std::uint64_t _invocations = 0;
};

} // namespace margelo::nitro::videopipeline
