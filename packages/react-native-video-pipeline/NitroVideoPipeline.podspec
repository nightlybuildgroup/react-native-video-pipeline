require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NitroVideoPipeline"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.description  = package["description"]
  s.homepage     = "https://github.com/nightlybuildgroup/react-native-video-pipeline"
  s.license      = package["license"]
  s.authors      = { "Sebastian Biallas" => "sb@biallas.net" }
  s.platforms    = { :ios => "13.0" }
  s.source       = { :git => "https://github.com/nightlybuildgroup/react-native-video-pipeline.git", :tag => "v#{s.version}" }

  # Hand-written adapter sources. The nitrogen-generated spec + bridges are
  # pulled in below via `add_nitrogen_files`.
  s.source_files = [
    "cpp/**/*.{h,hpp,c,cpp}",
    "ios/**/*.{h,hpp,c,cpp,m,mm,swift}",
  ]
  # `ios/__tests__/**` contains XCTest sources consumed by `yarn test:native`.
  # The Pod itself must NOT compile them — XCTest.framework isn't linked into
  # the library target and the pod glob above would otherwise try to build
  # LibraryTests.m as part of libNitroVideoPipeline.a.
  s.exclude_files = "ios/__tests__/**/*"

  # VideoToolbox is needed by Capabilities.mm (VTCompressionSession probe).
  # AVFoundation / CoreMedia / CoreVideo are pulled in transitively through
  # React-Core or the system umbrella on simulator + device builds, but
  # VideoToolbox is not — listing it here is the minimum that keeps the
  # bareexample link step resolving `_VTCompressionSessionCreate` on clean
  # checkouts.
  # CoreImage is needed by Transcoder.mm (CIContext + CIImage for the
  # decode→transform→encode pipeline). iOS apps usually pull it in through
  # UIKit transitively; listing it explicitly matches VideoToolbox below and
  # guarantees the link step resolves `_CIContextContextWithOptions` on a
  # clean checkout regardless of what the consumer app imports.
  # QuartzCore (CATextLayer) + CoreText (framesetter / font create) are needed
  # by OverlayRenderer.mm for T035 text overlay rasterization. Transitively
  # available on iOS via UIKit, listed explicitly for the same reason as
  # CoreImage above.
  # Metal is needed by MetalBlit.mm for T053b's GPU fast path (Skia-drawn
  # MTLTexture → IOSurface-backed CVPixelBuffer via MTLBlitCommandEncoder).
  s.frameworks = "VideoToolbox", "CoreImage", "QuartzCore", "CoreText", "Metal"

  # Expose hand-written cpp/ headers so NitroVideoPipelineAutolinking.mm can
  # resolve `#include "HybridVideoPipeline.hpp"`. iOS adapter .mm files use
  # subdir-qualified includes (e.g. `#include "compose/ComposeRunner.hpp"`)
  # so only `cpp/` itself needs to be on the search path.
  s.pod_target_xcconfig = {
    "HEADER_SEARCH_PATHS" => "\"$(PODS_TARGET_SRCROOT)/cpp\"",
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++20",
    "SWIFT_OBJC_INTEROP_MODE" => "objcxx",
    "DEFINES_MODULE" => "YES",
  }

  # Pull in the nitrogen-generated specs + Swift<->C++ bridges.
  # Adds spec.source_files + spec.dependency "NitroModules" + xcconfig tweaks.
  load File.join(__dir__, "nitrogen/generated/ios/NitroVideoPipeline+autolinking.rb")
  add_nitrogen_files(s)

  # Adds React-Core, Hermes, Fabric, New-Arch bits depending on RN version.
  install_modules_dependencies(s)
end
