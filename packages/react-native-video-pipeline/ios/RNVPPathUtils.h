#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Resolve a user-supplied location string — either a bare filesystem path
/// (`/var/.../out.mp4`) or a `file://` URI (`file:///var/.../out.mp4`) — into a
/// file `NSURL`. `file://` URIs are parsed with `URLWithString:` (preserving
/// percent-encoding); anything else is treated as a POSIX path via
/// `fileURLWithPath:`. Always returns a non-nil URL.
NSURL* RNVPURLFromUri(NSString* uri);

/// Normalize a user-supplied output location to a bare POSIX path suitable for
/// the muxer (`openVideoOnlyAtPath:`), `NSFileManager`, and `fileURLWithPath:`
/// — all of which expect a filesystem path, not a URL. Feeding them a `file://`
/// URI yields a nonsense path the export can't create (the cryptic
/// -17913/-12115 "Cannot create file" of issue #74). Accepts both a bare path
/// and a `file://` URI and returns the bare path either way, so every entry
/// point can take both forms uniformly (matching how source `uri`/`outPath`
/// already route through `RNVPURLFromUri`).
NSString* RNVPOutputFilesystemPath(NSString* pathOrUri);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
