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

NSString* _Nullable RNVPOutputPathRejectionReason(NSString* pathOrUri) {
  NSString* path = RNVPOutputFilesystemPath(pathOrUri ?: @"");
  if (path.length == 0) {
    return @"output.path is empty";
  }
  NSFileManager* fm = [NSFileManager defaultManager];
  // output.path must name a file, not an existing directory: the contract is a
  // file path, and the render's pre-write cleanup does `removeItemAtPath:` on an
  // existing target — which would recursively delete a directory (including a
  // volume root like "/"). Reject it here instead of destroying data.
  BOOL targetIsDir = NO;
  if ([fm fileExistsAtPath:path isDirectory:&targetIsDir] && targetIsDir) {
    return [NSString
        stringWithFormat:@"output.path is a directory, not a file: %@", path];
  }
  // The parent must be an existing directory — AVFoundation/the muxer create
  // the file itself but will not create intermediate directories, and a
  // missing parent is the classic source of the opaque "Cannot create file".
  NSString* parent = path.stringByDeletingLastPathComponent;
  if (parent.length == 0) parent = @"/";
  BOOL isDir = NO;
  if (![fm fileExistsAtPath:parent isDirectory:&isDir] || !isDir) {
    return [NSString
        stringWithFormat:@"output.path parent directory does not exist: %@",
                         parent];
  }
  return nil;
}
