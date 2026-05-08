///
/// StopToken.hpp
///
/// Thread-safe signal used by open-ended synthesize / compose renders
/// (prd.md §8 `VideoRenderController`, §14 US12). Two distinct terminal
/// states:
///
///   - `requestFinish()` — stop after the current frame, finalize the output.
///     Mirrors `controller.finish()` from JS and `ctx.finish()` from the
///     worklet. The render promise resolves normally.
///   - `requestAbort()` — stop immediately, discard the output file. Mirrors
///     `controller.abort()` and the `AbortSignal` path. The render promise
///     rejects with `Cancelled`.
///
/// `abort` wins over `finish` once requested. Both transitions are one-way
/// and idempotent, matching `VideoRenderController`'s state machine.
///
/// Reads/writes use `std::atomic<bool>` so a background render loop can poll
/// the flags without a mutex on every frame.
///

#pragma once

#include <atomic>

namespace margelo::nitro::videopipeline {

class StopToken {
public:
  StopToken() = default;
  StopToken(const StopToken&) = delete;
  StopToken& operator=(const StopToken&) = delete;

  /// Ask the producing loop to stop after the current frame and finalize.
  void requestFinish() noexcept { _finish.store(true, std::memory_order_release); }

  /// Ask the producing loop to stop immediately and discard the output.
  void requestAbort() noexcept { _abort.store(true, std::memory_order_release); }

  bool finishRequested() const noexcept {
    return _finish.load(std::memory_order_acquire);
  }

  bool abortRequested() const noexcept {
    return _abort.load(std::memory_order_acquire);
  }

private:
  std::atomic<bool> _finish{false};
  std::atomic<bool> _abort{false};
};

} // namespace margelo::nitro::videopipeline
