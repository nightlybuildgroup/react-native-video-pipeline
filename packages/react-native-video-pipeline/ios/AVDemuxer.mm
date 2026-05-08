///
/// AVDemuxer.mm — see AVDemuxer.h for the contract.
///

#import "AVDemuxer.h"

#import <AVFoundation/AVFoundation.h>

NSErrorDomain const RNVPAVDemuxerErrorDomain = @"RNVPAVDemuxerErrorDomain";

namespace {

NSError *makeError(RNVPAVDemuxerErrorCode code, NSString *message) {
  return [NSError errorWithDomain:RNVPAVDemuxerErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSString *fourCCString(FourCharCode code) {
  // FourCharCode is big-endian on disk regardless of host endianness.
  unsigned char chars[5] = {
      (unsigned char)((code >> 24) & 0xFF),
      (unsigned char)((code >> 16) & 0xFF),
      (unsigned char)((code >> 8) & 0xFF),
      (unsigned char)(code & 0xFF),
      0,
  };
  return [[NSString alloc] initWithBytes:chars
                                  length:4
                                encoding:NSASCIIStringEncoding];
}

NSString *canonicalCodec(FourCharCode code) {
  switch (code) {
    case kCMVideoCodecType_H264:    // 'avc1'
      return @"h264";
    case kCMVideoCodecType_HEVC:    // 'hvc1'
    case 'hev1':
      return @"hevc";
    default:
      return fourCCString(code);
  }
}

NSInteger rotationFromTransform(CGAffineTransform t) {
  // Standard AVFoundation pattern: angle of (a, b) basis vector in degrees,
  // normalised to [0, 360), snapped to the four quadrant rotations the spec
  // exposes. AVMuxer-authored files use the identity transform → 0°.
  CGFloat angleRad = atan2(t.b, t.a);
  CGFloat angleDeg = angleRad * 180.0 / M_PI;
  long snapped = lround(angleDeg / 90.0) * 90;
  long normalised = ((snapped % 360) + 360) % 360;
  return (NSInteger)normalised;
}

BOOL isHDRTransferFunction(NSString *_Nullable transfer) {
  if (transfer == nil) return NO;
  // Both HLG and PQ live under the SMPTE/ITU HDR transfer characteristic
  // identifiers. SDR transfers (BT.709, sRGB, gamma 2.2) never set isHDR.
  if ([transfer isEqualToString:
                    (__bridge NSString *)
                        kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG]) {
    return YES;
  }
  if ([transfer isEqualToString:
                    (__bridge NSString *)
                        kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ]) {
    return YES;
  }
  return NO;
}

NSString *_Nullable trimColorPrimariesPrefix(NSString *_Nullable raw) {
  // The CMFormatDescription extension values are short canonical strings like
  // @"ITU_R_709_2" or @"ITU_R_2020". Returned verbatim — the library exposes
  // these as opaque labels; T026 maps to the high-level VideoInfo schema.
  return raw;
}

NSString *_Nullable containerFromURL(NSURL *url) {
  NSString *ext = url.pathExtension.lowercaseString;
  if (ext.length == 0) return nil;
  return ext;
}

NSDate *_Nullable coerceToDate(id _Nullable value) {
  if (value == nil) return nil;
  if ([value isKindOfClass:[NSDate class]]) return (NSDate *)value;
  if (![value isKindOfClass:[NSString class]]) return nil;
  // AVFoundation's common-metadata creation-date items are almost always
  // already NSDate on read, but QuickTime user-data authored dates arrive as
  // ISO 8601 strings. Try both formats that show up in the wild without
  // pulling in a full date-parsing dependency.
  static NSISO8601DateFormatter *iso = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    iso = [[NSISO8601DateFormatter alloc] init];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                        NSISO8601DateFormatWithFractionalSeconds;
  });
  NSDate *date = [iso dateFromString:(NSString *)value];
  if (date != nil) return date;
  iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
  date = [iso dateFromString:(NSString *)value];
  return date;
}

// ISO 6709 is what AVFoundation writes for AVMetadataCommonKeyLocation — e.g.
// @"+37.7749-122.4194/" or @"+37.7749-122.4194+010.000/". Two sign+number
// tokens at the start encode latitude and longitude in decimal degrees; an
// optional third sign+number token is altitude in metres. Returns NO on a
// malformed input rather than surfacing garbage coordinates. @p outHasAlt
// is set to YES iff a parseable third token is present; lat/lon are always
// written when the function returns YES.
BOOL parseISO6709(NSString *_Nullable raw, double *outLat, double *outLon,
                  BOOL *outHasAlt, double *outAlt) {
  *outHasAlt = NO;
  if (raw.length == 0) return NO;
  const char *s = raw.UTF8String;
  if (s == NULL) return NO;
  double values[2] = {0.0, 0.0};
  for (int i = 0; i < 2; ++i) {
    if (*s != '+' && *s != '-') return NO;
    char *end = NULL;
    double v = strtod(s, &end);
    if (end == s) return NO;
    values[i] = v;
    s = end;
  }
  *outLat = values[0];
  *outLon = values[1];
  if (*s == '+' || *s == '-') {
    char *end = NULL;
    double alt = strtod(s, &end);
    if (end != s) {
      *outHasAlt = YES;
      *outAlt = alt;
    }
  }
  return YES;
}

} // namespace

@implementation RNVPAVDemuxer {
  AVURLAsset *_asset;
  AVAssetReader *_reader;
  AVAssetReaderTrackOutput *_videoOutput;
  BOOL _opened;
  BOOL _closed;

  NSString *_codec;
  NSString *_container;
  NSInteger _bitRate;
  NSInteger _width;
  NSInteger _height;
  double _fps;
  double _durationSec;
  NSInteger _rotation;
  BOOL _isHDR;
  BOOL _hasAudio;
  NSString *_colorPrimaries;
  NSDate *_creationDate;
  NSString *_contentDescription;
  BOOL _hasLocation;
  double _locationLatitude;
  double _locationLongitude;
  BOOL _hasLocationAltitude;
  double _locationAltitude;
  NSDictionary<NSString *, NSString *> *_customMetadata;
}

- (BOOL)openAtURL:(NSURL *)url
            error:(NSError *_Nullable __autoreleasing *)error {
  if (_opened) {
    if (error) {
      *error = makeError(RNVPAVDemuxerErrorCodeInvalidState,
                         @"AVDemuxer has already been opened.");
    }
    return NO;
  }

  if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
    if (error) {
      *error = makeError(
          RNVPAVDemuxerErrorCodeNotFound,
          [NSString stringWithFormat:@"No file at %@", url.path]);
    }
    return NO;
  }

  AVURLAsset *asset = [AVURLAsset assetWithURL:url];

  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  if (videoTracks.count == 0) {
    if (error) {
      *error = makeError(RNVPAVDemuxerErrorCodeNoVideoTrack,
                         @"Source has no video track.");
    }
    return NO;
  }
  AVAssetTrack *videoTrack = videoTracks.firstObject;

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  if (reader == nil) {
    if (error) {
      *error = readerError
                   ?: makeError(RNVPAVDemuxerErrorCodeReaderFailed,
                                @"AVAssetReader init failed.");
    }
    return NO;
  }

  // outputSettings:nil → compressed passthrough samples. Required for the
  // remux path (T027) which writes the bytes through unchanged. Counts as
  // valid sample retrieval for T025's "round-trip samples" verification.
  AVAssetReaderTrackOutput *output =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack
                                       outputSettings:nil];
  if (![reader canAddOutput:output]) {
    if (error) {
      *error = makeError(RNVPAVDemuxerErrorCodeReaderFailed,
                         @"AVAssetReader rejected the video output.");
    }
    return NO;
  }
  [reader addOutput:output];

  if (![reader startReading]) {
    if (error) {
      *error = reader.error
                   ?: makeError(RNVPAVDemuxerErrorCodeReaderFailed,
                                @"AVAssetReader.startReading failed.");
    }
    return NO;
  }

  CMFormatDescriptionRef formatDescription = NULL;
  NSArray *formatDescriptions = videoTrack.formatDescriptions;
  if (formatDescriptions.count > 0) {
    formatDescription =
        (__bridge CMFormatDescriptionRef)formatDescriptions.firstObject;
  }

  FourCharCode subtype =
      formatDescription != NULL
          ? CMFormatDescriptionGetMediaSubType(formatDescription)
          : 0;
  _codec = subtype != 0 ? canonicalCodec(subtype) : nil;

  CGSize natural = videoTrack.naturalSize;
  _width = (NSInteger)llround(natural.width);
  _height = (NSInteger)llround(natural.height);
  _fps = (double)videoTrack.nominalFrameRate;
  _bitRate = (NSInteger)llround((double)videoTrack.estimatedDataRate);
  _durationSec = CMTimeGetSeconds(asset.duration);
  _rotation = rotationFromTransform(videoTrack.preferredTransform);
  _hasAudio = [asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
  _container = containerFromURL(url);

  NSString *transfer = nil;
  NSString *primaries = nil;
  if (formatDescription != NULL) {
    CFDictionaryRef extensions =
        CMFormatDescriptionGetExtensions(formatDescription);
    if (extensions != NULL) {
      transfer = (__bridge NSString *)CFDictionaryGetValue(
          extensions, kCMFormatDescriptionExtension_TransferFunction);
      primaries = (__bridge NSString *)CFDictionaryGetValue(
          extensions, kCMFormatDescriptionExtension_ColorPrimaries);
    }
  }
  _isHDR = isHDRTransferFunction(transfer);
  _colorPrimaries = trimColorPrimariesPrefix(primaries);

  // Common-metadata pass: populates creationDate, location, and the
  // everything-else `customMetadata` bag. AVFoundation normalises any
  // per-format metadata (QuickTime user-data, mp4 ©-prefixed atoms, etc.)
  // into the commonMetadata array under `AVMetadataCommonKey*` identifiers,
  // so one loop covers every source format we care about.
  NSArray<AVMetadataItem *> *commonItems = asset.commonMetadata;
  NSMutableDictionary<NSString *, NSString *> *custom =
      [NSMutableDictionary dictionary];
  for (AVMetadataItem *item in commonItems) {
    NSString *key = item.commonKey;
    if (key.length == 0) continue;
    if ([key isEqualToString:AVMetadataCommonKeyCreationDate]) {
      NSDate *date = coerceToDate(item.value);
      if (date != nil) _creationDate = date;
      continue;
    }
    if ([key isEqualToString:AVMetadataCommonKeyDescription]) {
      NSString *value = item.stringValue;
      if (value.length > 0) _contentDescription = [value copy];
      continue;
    }
    if ([key isEqualToString:AVMetadataCommonKeyLocation]) {
      NSString *raw = item.stringValue;
      double lat = 0, lon = 0, alt = 0;
      BOOL hasAlt = NO;
      if (parseISO6709(raw, &lat, &lon, &hasAlt, &alt)) {
        _hasLocation = YES;
        _locationLatitude = lat;
        _locationLongitude = lon;
        if (hasAlt) {
          _hasLocationAltitude = YES;
          _locationAltitude = alt;
        }
      }
      continue;
    }
    NSString *value = item.stringValue;
    if (value.length > 0) custom[key] = value;
  }

  // Second pass: pull every `mdta/<key>` item out of the full metadata
  // array — these are the caller-authored entries written via
  // `MetadataSpec.custom`. AVFoundation does NOT normalise these into
  // commonMetadata, so the first loop above misses them. Key is the part
  // after `mdta/` (typically a reverse-DNS string like
  // "com.acme.shotanalysis"). Verbatim — no prefix manipulation, the
  // caller owns the key namespace.
  // Two scans of asset.metadata:
  //   * `mdta/<key>` items — the modern Apple-style key/value store, used
  //     by `MetadataSpec.custom` writes since this library's introduction.
  //   * `udta/©inf` (and other classic QuickTime user-data atoms) — the
  //     pre-Apple-style location, still emitted by phones / cameras /
  //     screen-recording tools today (mediainfo's "Title, more info" line
  //     comes from `©inf`). We surface these under their atom four-char
  //     codes prefixed with "©" — read-only, legacy compat. Writers in
  //     this library only emit `mdta/`, never `udta/`. Consumers that
  //     want the data forward should re-author it under their own
  //     reverse-DNS key.
  for (AVMetadataItem *item in asset.metadata) {
    NSString *identifier = item.identifier;
    if ([identifier hasPrefix:@"mdta/"]) {
      NSString *key = [identifier substringFromIndex:5];  // strip "mdta/"
      if (key.length == 0) continue;
      NSString *value = item.stringValue;
      if (value.length == 0) continue;
      // Only set if this key wasn't already populated by the common-
      // metadata pass (e.g. an mdta `title` shouldn't overwrite the
      // common `title`).
      if (custom[key] == nil) custom[key] = value;
      continue;
    }
    if ([identifier hasPrefix:@"udta/"]) {
      // identifier shape is "udta/<4cc>"; classic atoms include
      // ©inf (info), ©cpy (copyright), ©too (encoder), ©day (date).
      NSString *atom = [identifier substringFromIndex:5];  // strip "udta/"
      if (atom.length == 0) continue;
      NSString *value = item.stringValue;
      if (value.length == 0) continue;
      if (custom[atom] == nil) custom[atom] = value;
      continue;
    }
  }

  _customMetadata = custom.count > 0 ? [custom copy] : nil;

  _asset = asset;
  _reader = reader;
  _videoOutput = output;
  _opened = YES;
  _closed = NO;
  return YES;
}

- (CMSampleBufferRef _Nullable)copyNextVideoSampleBuffer:
    (NSError *_Nullable __autoreleasing *)error {
  if (!_opened || _closed) {
    if (error) {
      *error = makeError(RNVPAVDemuxerErrorCodeInvalidState,
                         @"AVDemuxer.copyNextVideoSampleBuffer: not open.");
    }
    return NULL;
  }
  CMSampleBufferRef sample = [_videoOutput copyNextSampleBuffer];
  if (sample == NULL) {
    // EOS or failure. Distinguish via reader.status — Completed/Reading mean
    // clean EOS; anything else surfaces as a typed error so callers can tell
    // apart "no more samples" from "decode pipeline crashed mid-read".
    if (error) *error = nil;
    AVAssetReaderStatus status = _reader.status;
    if (status == AVAssetReaderStatusFailed ||
        status == AVAssetReaderStatusUnknown) {
      if (error) {
        *error = _reader.error
                     ?: makeError(RNVPAVDemuxerErrorCodeReaderFailed,
                                  @"AVAssetReader entered the Failed state.");
      }
    }
    return NULL;
  }
  return sample;
}

- (BOOL)closeWithError:(NSError *_Nullable __autoreleasing *)error {
  if (!_opened || _closed) {
    if (error) {
      *error = makeError(RNVPAVDemuxerErrorCodeInvalidState,
                         @"AVDemuxer.close: not open or already closed.");
    }
    return NO;
  }
  // cancelReading is safe even if the reader has already drained; it's also
  // the only way to release file handles deterministically before the
  // reader's autorelease.
  [_reader cancelReading];
  _reader = nil;
  _videoOutput = nil;
  _asset = nil;
  _closed = YES;
  return YES;
}

- (NSString *)codec { return _codec; }
- (NSString *)container { return _container; }
- (NSInteger)bitRate { return _bitRate; }
- (NSInteger)width { return _width; }
- (NSInteger)height { return _height; }
- (double)fps { return _fps; }
- (double)durationSec { return _durationSec; }
- (NSInteger)rotation { return _rotation; }
- (BOOL)isHDR { return _isHDR; }
- (BOOL)hasAudio { return _hasAudio; }
- (NSString *)colorPrimaries { return _colorPrimaries; }
- (NSDate *)creationDate { return _creationDate; }
- (BOOL)hasLocation { return _hasLocation; }
- (double)locationLatitude { return _locationLatitude; }
- (double)locationLongitude { return _locationLongitude; }
- (BOOL)hasLocationAltitude { return _hasLocationAltitude; }
- (double)locationAltitude { return _locationAltitude; }
- (NSString *)contentDescription { return _contentDescription; }
- (NSDictionary<NSString *, NSString *> *)customMetadata {
  return _customMetadata;
}

@end
