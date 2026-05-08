///
/// ProgressEmitter.cpp — see ProgressEmitter.hpp for the contract.
///

#include "ProgressEmitter.hpp"

#include <chrono>

namespace margelo::nitro::videopipeline {

ProgressEmitter::ProgressEmitter(Callback callback,
                                 std::optional<double> nbFrames,
                                 double minIntervalMs)
    : _callback(std::move(callback)),
      _nbFrames(nbFrames),
      _minIntervalMs(minIntervalMs) {}

void ProgressEmitter::start() {
  _t0 = std::chrono::steady_clock::now();
  _lastEmit = _t0;
  _started = true;
  _emittedAny = false;
  _lastFramesCompleted = 0.0;
  // Seed the consumer with a framesCompleted=0 tick so progress bars move
  // off the initial state immediately instead of waiting for the first
  // encoded frame (which, on a cold transcode, can be several hundred ms).
  emit(0.0);
}

void ProgressEmitter::updateNbFrames(std::optional<double> nbFrames) {
  _nbFrames = nbFrames;
}

void ProgressEmitter::report(double framesCompleted) {
  if (!_started) return;
  _lastFramesCompleted = framesCompleted;
  // First produced-frame tick always fires — callers need to see a
  // framesCompleted>0 callback even if the encode finished in <minInterval.
  if (!_emittedAny) {
    emit(framesCompleted);
    return;
  }
  const auto now = std::chrono::steady_clock::now();
  const double sinceLastMs =
      std::chrono::duration<double, std::milli>(now - _lastEmit).count();
  if (sinceLastMs + 1e-6 < _minIntervalMs) {
    return; // coalesced — try again next frame.
  }
  emit(framesCompleted);
}

void ProgressEmitter::finalize(double framesCompleted) {
  if (!_started) return;
  // Always force the final tick through — even if the encoder finished in
  // <minInterval after the last real emit, the consumer expects a
  // `framesCompleted == nbFrames` callback on completion.
  emit(framesCompleted);
}

double ProgressEmitter::elapsedMs() const {
  const auto now = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(now - _t0).count();
}

std::optional<double> ProgressEmitter::computeEta(double framesCompleted,
                                                  double elapsedMs) const {
  // Open-ended renders (or any render where the total count hasn't been
  // locked in yet) have no meaningful ETA until the runner calls
  // `updateNbFrames`.
  if (!_nbFrames.has_value()) return std::nullopt;
  const double total = *_nbFrames;
  if (!(total > 0.0)) return std::nullopt;
  if (!(framesCompleted > 0.0)) return std::nullopt;
  if (framesCompleted >= total) return 0.0;
  // Linear extrapolation from the average so-far frame cost. Cheap; good
  // enough for a UI progress bar. A smarter EWMA could replace this if a
  // consumer files a concrete jank complaint.
  const double perFrameMs = elapsedMs / framesCompleted;
  const double remaining = (total - framesCompleted) * perFrameMs;
  return remaining;
}

void ProgressEmitter::emit(double framesCompleted) {
  if (!hasCallback()) {
    _lastEmit = std::chrono::steady_clock::now();
    _emittedAny = true;
    return;
  }
  const double elapsed = elapsedMs();
  const std::optional<double> eta = computeEta(framesCompleted, elapsed);
  _callback(framesCompleted, _nbFrames, elapsed, eta);
  _lastEmit = std::chrono::steady_clock::now();
  _emittedAny = true;
  ++_invocations;
}

} // namespace margelo::nitro::videopipeline
