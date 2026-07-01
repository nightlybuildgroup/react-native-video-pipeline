#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Build a diagnosable, single-line description of an `NSError` for the message
/// thrown across the JS boundary. AVFoundation/MediaToolbox export failures
/// otherwise surface only their generic `localizedDescription` (e.g. the same
/// "Cannot create file" string regardless of root cause), hiding the real
/// signal — the domain/code and, crucially, the `NSUnderlyingError` chain that
/// carries the internal CoreMedia/Fig codes (e.g. -17913 / -12115) that only
/// appear in os_log. This surfaces all of it inline (issue #85):
///
///   Cannot create file (AVFoundationErrorDomain -11820; underlying
///   NSOSStatusErrorDomain -17913; hint: MediaToolbox could not create the
///   output file — verify the parent directory exists and output.path is a
///   filesystem path, not a file:// URI)
///
/// The undocumented internal codes are gold for searching/triaging even when
/// Apple ships no header for them, so they are always included. Returns
/// `"(nil)"` for a nil error. Never returns nil.
NSString* RNVPDescribeError(NSError* _Nullable error);

/// A human hint for a small set of known-but-undocumented MediaToolbox/Fig
/// codes seen on the export path (issue #85), or nil if the code isn't mapped.
/// Exposed for testing; `RNVPDescribeError` folds it into its output.
NSString* _Nullable RNVPHintForErrorCode(NSInteger code);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
