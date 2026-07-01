#import "RNVPExportError.h"

// Standalone (Nitro-free) error-description helpers, kept in their own
// translation unit so the host XCTest harness (`yarn test:native`, which cannot
// compile VideoPipeline.mm's Nitro-generated dependencies) can exercise them
// directly. The AVFoundation/muxer error-throw sites in VideoPipeline.mm and
// ExportSession.mm delegate here so the diagnosable formatting has a single
// source of truth (issue #85).

NSString* _Nullable RNVPHintForErrorCode(NSInteger code) {
  switch (code) {
    // FigFile / Remaker: the two internal MediaToolbox codes seen behind the
    // generic AVFoundation "Cannot create file" when the output can't be
    // written — the #74/#85 failure mode (a file:// URI or a missing parent
    // directory handed to the muxer/export as if it were a filesystem path).
    case -17913:  // <<<< FigFile >>>>   signalled err=-17913
    case -12115:  // <<<< Remaker >>>>   signalled err=-12115
      return @"MediaToolbox could not create the output file — verify the "
             @"parent directory exists and output.path is a filesystem path, "
             @"not a file:// URI";
    default:
      return nil;
  }
}

// Append "<domain> <code>" for `error`, then recurse into its NSUnderlyingError
// (guarded against pathological cycles), collecting the first known-code hint
// found anywhere in the chain.
static void RNVPAppendErrorChain(NSError* error, NSMutableString* out,
                                 NSString* _Nullable* outHint, int depth) {
  if (error == nil || depth > 8) return;
  [out appendFormat:@"%@ %ld", error.domain, (long)error.code];
  if (*outHint == nil) {
    *outHint = RNVPHintForErrorCode(error.code);
  }
  NSError* underlying = error.userInfo[NSUnderlyingErrorKey];
  if (underlying != nil) {
    [out appendString:@"; underlying "];
    RNVPAppendErrorChain(underlying, out, outHint, depth + 1);
  }
}

NSString* RNVPDescribeError(NSError* _Nullable error) {
  if (error == nil) return @"(nil)";

  NSString* desc = error.localizedDescription;
  if (desc.length == 0) desc = @"(no description)";

  NSMutableString* chain = [NSMutableString string];
  NSString* hint = nil;
  RNVPAppendErrorChain(error, chain, &hint, 0);

  NSMutableString* detail = [chain mutableCopy];
  if (hint != nil) {
    [detail appendFormat:@"; hint: %@", hint];
  }
  return [NSString stringWithFormat:@"%@ (%@)", desc, detail];
}
