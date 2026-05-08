# CMakeLists.txt — react-native-video-pipeline Android native library.
#
# Declares the `NitroVideoPipeline` shared library and pulls in the
# nitrogen-generated spec + JHybrid glue. Android doesn't currently compile any
# hand-written C++ from `cpp/` at T040 (those are iOS-only adapters at this
# stage). T041+ will add Media3-supporting C++ files to `target_sources` as each
# task lands.

project(NitroVideoPipeline)
cmake_minimum_required(VERSION 3.9.0)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_VERBOSE_MAKEFILE ON)

# Create the shared library target first — the nitrogen autolinking cmake
# expects it to already exist when it calls `target_sources(NitroVideoPipeline ...)`.
add_library(NitroVideoPipeline SHARED
  src/main/cpp/cpp-adapter.cpp
  src/main/cpp/cpp-hardware-buffer.cpp
)

# AHardwareBuffer_fromHardwareBuffer lives in libandroid.so on API 26+;
# __android_log_print lives in liblog.so.
find_library(ANDROID_LIB android)
find_library(LOG_LIB log)
target_link_libraries(NitroVideoPipeline ${ANDROID_LIB} ${LOG_LIB})

# Pull in all nitrogen-generated C++ bridges (shared + android-specific) plus
# the OnLoad + autolinking glue. This also adds the required prefab-linked
# libraries (fbjni, JSI, React Native prefab, Nitro).
include(${CMAKE_SOURCE_DIR}/../nitrogen/generated/android/NitroVideoPipeline+autolinking.cmake)
