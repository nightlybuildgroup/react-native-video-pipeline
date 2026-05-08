///
/// ComposeRunner.cpp — see ComposeRunner.hpp for the contract.
///

#include "ComposeRunner.hpp"

#include "ProgressEmitter.hpp"
#include "StopToken.hpp"

#include <cmath>
#include <vector>

namespace margelo::nitro::videopipeline {

namespace {

bool validateFixed(const ComposeRunner::FixedSpec& spec, std::string& error) {
  if (spec.width <= 0 || spec.height <= 0) {
    error = "ComposeRunner: width and height must be positive";
    return false;
  }
  if (!(spec.fps > 0.0)) {
    error = "ComposeRunner: fps must be > 0";
    return false;
  }
  if (!(spec.seconds > 0.0)) {
    error = "ComposeRunner: seconds must be > 0";
    return false;
  }
  return true;
}

bool validateOpen(const ComposeRunner::OpenSpec& spec, std::string& error) {
  if (spec.width <= 0 || spec.height <= 0) {
    error = "ComposeRunner: width and height must be positive";
    return false;
  }
  if (!(spec.fps > 0.0)) {
    error = "ComposeRunner: fps must be > 0";
    return false;
  }
  return true;
}

} // namespace

int ComposeRunner::frameCountFor(double fps, double seconds) {
  if (!(fps > 0.0) || !(seconds > 0.0)) return 0;
  const double raw = fps * seconds;
  // US11: "produces a playable video file with exactly round(seconds * fps) frames".
  return static_cast<int>(std::lround(raw));
}

bool ComposeRunner::runFixed(const FixedSpec& spec, const FrameSourceFn& source,
                             const FrameSink& sink, std::string& error,
                             ProgressEmitter* progress, const StopToken* stop,
                             bool* aborted) {
  if (aborted != nullptr) *aborted = false;

  if (!validateFixed(spec, error)) return false;
  if (!source) {
    error = "ComposeRunner: FrameSource is required";
    return false;
  }
  if (!sink.open || !sink.appendFrame || !sink.close) {
    error = "ComposeRunner: FrameSink must provide open/appendFrame/close";
    return false;
  }

  // If the caller already flagged abort, don't touch the file system.
  if (stop != nullptr && stop->abortRequested()) {
    if (aborted != nullptr) *aborted = true;
    return true;
  }

  if (!sink.open(spec.width, spec.height, spec.fps, error)) {
    std::string ignored;
    sink.close(ignored); // best-effort
    return false;
  }

  const int frameCount = frameCountFor(spec.fps, spec.seconds);
  const std::size_t rowBytes = static_cast<std::size_t>(spec.width) * 4;
  std::vector<uint8_t> buffer(rowBytes * static_cast<std::size_t>(spec.height));

  if (progress != nullptr) {
    progress->updateNbFrames(static_cast<double>(frameCount));
    progress->start();
  }

  bool ok = true;
  bool wasAborted = false;
  for (int i = 0; i < frameCount && ok; ++i) {
    if (stop != nullptr && stop->abortRequested()) {
      wasAborted = true;
      break;
    }
    if (!source(i, buffer.data(), rowBytes, error)) {
      ok = false;
      break;
    }
    // PTS is deterministic and independent of wall clock — see CLAUDE.md.
    const double pts = static_cast<double>(i) / spec.fps;
    if (!sink.appendFrame(buffer.data(), rowBytes, pts, error)) {
      // If a stop signal arrived while the sink was blocked inside this
      // append (e.g. encoder back-pressure), promote the failure into the
      // abort path rather than surfacing it as a sink error.
      if (stop != nullptr && stop->abortRequested()) {
        wasAborted = true;
        break;
      }
      ok = false;
      break;
    }
    if (progress != nullptr) {
      progress->report(static_cast<double>(i + 1));
    }
  }

  if (wasAborted) {
    // Skip sink.close — caller discards the partial file. Matches the
    // runOpen abort contract.
    if (aborted != nullptr) *aborted = true;
    return true;
  }

  std::string closeError;
  const bool closedOk = sink.close(closeError);
  if (!ok) return false;
  if (!closedOk) {
    error = closeError;
    return false;
  }
  if (progress != nullptr) {
    progress->finalize(static_cast<double>(frameCount));
  }
  return true;
}

bool ComposeRunner::runOpen(const OpenSpec& spec, const FrameSourceOpenFn& source,
                            const FrameSink& sink, const StopToken& stop,
                            OpenResult& result, std::string& error,
                            ProgressEmitter* progress) {
  result = {};

  if (!validateOpen(spec, error)) return false;
  if (!source) {
    error = "ComposeRunner: FrameSource is required";
    return false;
  }
  if (!sink.open || !sink.appendFrame || !sink.close) {
    error = "ComposeRunner: FrameSink must provide open/appendFrame/close";
    return false;
  }

  // If the caller requested abort before we even opened the sink, honour it
  // and don't touch the file system at all.
  if (stop.abortRequested()) {
    result.aborted = true;
    return true;
  }

  if (!sink.open(spec.width, spec.height, spec.fps, error)) {
    // Open failures leave no partial file worth preserving; mirror runFixed's
    // best-effort close. We don't set `aborted` — this is a producer error,
    // not a user-requested abort.
    std::string ignored;
    sink.close(ignored);
    return false;
  }

  const std::size_t rowBytes = static_cast<std::size_t>(spec.width) * 4;
  std::vector<uint8_t> buffer(rowBytes * static_cast<std::size_t>(spec.height));
  const bool hasCap = spec.maxSeconds > 0.0;

  // Open-ended renders start with nbFrames unknown — the emitter was built
  // with `std::nullopt` at the caller. A later `updateNbFrames` locks it in
  // if the runner knows the total (e.g. finish requested on the current
  // frame) but without that hook consumers stay on an open-ended bar.
  if (progress != nullptr) {
    progress->start();
  }

  int i = 0;
  bool sourceFinished = false;
  while (true) {
    // Check abort/finish BEFORE producing the next frame. `finish` means
    // "stop after the current frame" — since we haven't produced this one
    // yet, exiting here is equivalent.
    if (stop.abortRequested()) {
      result.framesWritten = i;
      result.aborted = true;
      // Deliberately skip sink.close — caller discards the partial file.
      return true;
    }
    if (stop.finishRequested()) {
      break;
    }
    if (hasCap) {
      const double nextPts = static_cast<double>(i) / spec.fps;
      if (nextPts >= spec.maxSeconds) {
        result.hitMaxSeconds = true;
        break;
      }
    }

    bool shouldFinish = false;
    if (!source(i, buffer.data(), rowBytes, shouldFinish, error)) {
      // Producer failure — close best-effort, surface error.
      result.framesWritten = i;
      std::string ignored;
      sink.close(ignored);
      return false;
    }
    const double pts = static_cast<double>(i) / spec.fps;
    if (!sink.appendFrame(buffer.data(), rowBytes, pts, error)) {
      // If a stop signal arrived while the sink was blocked inside this
      // append (e.g. encoder back-pressure), the sink is expected to return
      // false rather than keep waiting. Promote that into the normal
      // finish/abort path instead of surfacing it as a producer error —
      // the frames produced so far are still valid.
      if (stop.abortRequested()) {
        result.framesWritten = i;
        result.aborted = true;
        return true;
      }
      if (stop.finishRequested()) {
        break;
      }
      result.framesWritten = i;
      std::string ignored;
      sink.close(ignored);
      return false;
    }
    ++i;
    if (progress != nullptr) {
      progress->report(static_cast<double>(i));
    }

    if (shouldFinish) {
      sourceFinished = true;
      break;
    }
  }

  // Re-poll abort just before close: the caller may have flipped it while the
  // final frame was being appended. If so, still treat the run as aborted.
  if (stop.abortRequested() && !sourceFinished) {
    result.framesWritten = i;
    result.aborted = true;
    return true;
  }

  result.framesWritten = i;
  std::string closeError;
  if (!sink.close(closeError)) {
    error = closeError;
    return false;
  }
  if (progress != nullptr) {
    // Lock in the final count so the last tick carries a definite ETA=0
    // and consumers can detect "done" from the callback alone.
    progress->updateNbFrames(static_cast<double>(i));
    progress->finalize(static_cast<double>(i));
  }
  return true;
}

} // namespace margelo::nitro::videopipeline
