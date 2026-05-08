///
/// RenderTokenRegistry.cpp — see RenderTokenRegistry.hpp for the contract.
///

#include "RenderTokenRegistry.hpp"

#include "StopToken.hpp"

#include <mutex>
#include <unordered_map>

namespace margelo::nitro::videopipeline {

namespace {

// Plain mutex rather than shared_mutex: the map is consulted at most a handful
// of times per render (register + unregister + a couple of cancel/finish
// calls), not per frame, so contention is negligible.
std::mutex& mapMutex() {
  static std::mutex m;
  return m;
}

std::unordered_map<std::string, std::shared_ptr<StopToken>>& tokenMap() {
  static std::unordered_map<std::string, std::shared_ptr<StopToken>> m;
  return m;
}

} // namespace

std::shared_ptr<StopToken> RenderTokenRegistry::registerToken(const std::string& token) {
  auto stop = std::make_shared<StopToken>();
  std::lock_guard<std::mutex> lock(mapMutex());
  tokenMap()[token] = stop;
  return stop;
}

void RenderTokenRegistry::unregisterToken(const std::string& token) {
  std::lock_guard<std::mutex> lock(mapMutex());
  tokenMap().erase(token);
}

std::shared_ptr<StopToken> RenderTokenRegistry::lookup(const std::string& token) {
  std::lock_guard<std::mutex> lock(mapMutex());
  const auto it = tokenMap().find(token);
  if (it == tokenMap().end()) return nullptr;
  return it->second;
}

RenderTokenRegistry::Scope::Scope(std::string token) : _token(std::move(token)) {
  _stop = RenderTokenRegistry::registerToken(_token);
}

RenderTokenRegistry::Scope::~Scope() {
  RenderTokenRegistry::unregisterToken(_token);
}

} // namespace margelo::nitro::videopipeline
