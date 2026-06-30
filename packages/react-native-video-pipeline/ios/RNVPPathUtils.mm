#import "RNVPPathUtils.h"

// Standalone (Nitro-free) path helpers, kept in their own translation unit so
// the host XCTest harness (`yarn test:native`, which cannot compile
// VideoPipeline.mm's Nitro-generated dependencies) can exercise them directly.
// VideoPipeline.mm delegates its `urlFromUri` / `outputFilesystemPath` here so
// there is a single source of truth.

NSURL* RNVPURLFromUri(NSString* uri) {
  NSString* nsUri = uri ?: @"";
  if ([nsUri hasPrefix:@"file://"]) {
    NSURL* parsed = [NSURL URLWithString:nsUri];
    if (parsed != nil) return parsed;
  }
  return [NSURL fileURLWithPath:nsUri];
}

NSString* RNVPOutputFilesystemPath(NSString* pathOrUri) {
  NSString* input = pathOrUri ?: @"";
  NSURL* url = RNVPURLFromUri(input);
  NSString* fsPath = url.path;
  return fsPath ?: input;
}
