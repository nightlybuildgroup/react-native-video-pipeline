///
/// RenderTokenRegistry.hpp
///
/// Process-wide map from the opaque `renderToken` string (minted by
/// `src/video.ts::nextRenderToken`) to the `StopToken` the in-flight render
/// is listening on. `cancelRender` / `finishRender` at the Nitro boundary
/// look up the token here and flip the corresponding flag; the producing
/// thread sees the change on its next poll and exits cleanly.
///
/// A single process may run multiple renders concurrently (§10 — active
/// render handles), so the lookup is keyed by token rather than a global
/// singleton stop. Stale tokens (render already completed) are silently
/// ignored — matches the `VideoRenderController` idempotent-terminal-state
/// contract.
///

#pragma once

#include <memory>
#include <string>

namespace margelo::nitro::videopipeline {

class StopToken;

class RenderTokenRegistry {
public:
  /// Registers a fresh `StopToken` for `token` and returns it. The caller
  /// must `unregister` (or rely on RAII via `Scope`) before the token is
  /// released so the map doesn't grow unbounded.
  static std::shared_ptr<StopToken> registerToken(const std::string& token);
  static void unregisterToken(const std::string& token);
  /// Returns `nullptr` when the token is unknown.
  static std::shared_ptr<StopToken> lookup(const std::string& token);

  /// RAII helper — registers on construction, unregisters on destruction.
  /// Intended for use by the adapter layer (e.g. `HybridVideoPipeline::render`)
  /// so a thrown exception cannot leak the entry.
  class Scope {
  public:
    explicit Scope(std::string token);
    ~Scope();
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;

    const std::shared_ptr<StopToken>& stop() const noexcept { return _stop; }
    const std::string& token() const noexcept { return _token; }

  private:
    std::string _token;
    std::shared_ptr<StopToken> _stop;
  };
};

} // namespace margelo::nitro::videopipeline
