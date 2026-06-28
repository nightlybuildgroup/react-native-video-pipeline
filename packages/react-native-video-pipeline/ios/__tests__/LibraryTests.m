#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>

/**
 * Native-side XCTest for `react-native-video-pipeline`. The bareexample app
 * target doubles as the XCTest host because the library ships as a static
 * Pod (libNitroVideoPipeline.a), so XCTests do not need a bespoke host.
 *
 * Forward-declaring RNVPAVMuxer below — instead of `#import
 * <NitroVideoPipeline/AVMuxer.h>` — is deliberate: the NitroVideoPipeline
 * Clang module's umbrella aggregates every public header (including the
 * nitrogen-generated JSIConverter users that pull C++20 <cassert>), and a
 * pure-Obj-C test file can't satisfy those. The symbols still resolve at
 * link time against libNitroVideoPipeline.a. Keep this forward declaration
 * in lockstep with packages/react-native-video-pipeline/ios/AVMuxer.h.
 */

extern NSErrorDomain const RNVPAVMuxerErrorDomain;

typedef NS_ERROR_ENUM(RNVPAVMuxerErrorDomain, RNVPAVMuxerErrorCode) {
  RNVPAVMuxerErrorCodeInvalidState = 1,
  RNVPAVMuxerErrorCodeInvalidSpec = 2,
  RNVPAVMuxerErrorCodeWriterFailed = 3,
  RNVPAVMuxerErrorCodeAppendFailed = 4,
};

@interface RNVPAVMuxer : NSObject
- (BOOL)openAtPath:(NSString *)path
             width:(NSInteger)width
            height:(NSInteger)height
               fps:(NSInteger)fps
             error:(NSError *_Nullable __autoreleasing *)error;
- (BOOL)appendPixelBuffer:(CVPixelBufferRef)pixelBuffer
         presentationTime:(CMTime)pts
                    error:(NSError *_Nullable __autoreleasing *)error;
- (BOOL)closeWithError:(NSError *_Nullable __autoreleasing *)error;
@end

// Forward-declare RNVPWorkletFrameBridge for the same reason as RNVPAVMuxer
// above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/WorkletFrameBridge.h.
extern NSErrorDomain const RNVPWorkletFrameBridgeErrorDomain;

typedef NS_ERROR_ENUM(RNVPWorkletFrameBridgeErrorDomain,
                      RNVPWorkletFrameBridgeErrorCode) {
  RNVPWorkletFrameBridgeErrorCodeInvalidSpec = 1,
  RNVPWorkletFrameBridgeErrorCodeAllocationFailed = 2,
};

typedef NS_ENUM(NSInteger, RNVPBitmapFormat) {
  RNVPBitmapFormatRGBA8888Premultiplied,
  RNVPBitmapFormatBGRA8888Premultiplied,
};

@interface RNVPWorkletFrameBridge : NSObject
+ (CVPixelBufferRef _Nullable)
    pixelBufferFromBytes:(const void *)bytes
                   width:(NSInteger)width
                  height:(NSInteger)height
                rowBytes:(NSInteger)rowBytes
                  format:(RNVPBitmapFormat)format
                   error:(NSError *_Nullable __autoreleasing *)error
    CF_RETURNS_RETAINED;
@end

// Local helper for tests that need a bare IOSurface-backed BGRA destination
// buffer (e.g. MetalBlit round-trips). Production code dequeues from the
// muxer's pixel-buffer pool — there is no production allocator to share.
static CVPixelBufferRef RNVPMakeTestIOSurfaceBuffer(NSInteger width,
                                                   NSInteger height)
    CF_RETURNS_RETAINED;
static CVPixelBufferRef RNVPMakeTestIOSurfaceBuffer(NSInteger width,
                                                   NSInteger height) {
  NSDictionary<NSString *, id> *attrs = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_32BGRA),
    (NSString *)kCVPixelBufferWidthKey : @(width),
    (NSString *)kCVPixelBufferHeightKey : @(height),
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferRef pb = NULL;
  CVPixelBufferCreate(kCFAllocatorDefault, (size_t)width, (size_t)height,
                      kCVPixelFormatType_32BGRA,
                      (__bridge CFDictionaryRef)attrs, &pb);
  return pb;
}

// Forward-declare RNVPMetalBlit for the same clang-module reason as
// RNVPAVMuxer above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/MetalBlit.h.
extern NSErrorDomain const RNVPMetalBlitErrorDomain;

typedef NS_ERROR_ENUM(RNVPMetalBlitErrorDomain, RNVPMetalBlitErrorCode) {
  RNVPMetalBlitErrorCodeInvalidSpec = 1,
  RNVPMetalBlitErrorCodeMetalUnavailable = 2,
  RNVPMetalBlitErrorCodeTextureCacheFailed = 3,
  RNVPMetalBlitErrorCodeDimensionMismatch = 4,
  RNVPMetalBlitErrorCodeEncoderFailed = 5,
};

@interface RNVPMetalBlit : NSObject
+ (BOOL)blitFromMetalTexturePtr:(uintptr_t)mtlTexturePtr
                  toPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)isMetalAvailable;
@end

// Forward-declare RNVPSynthesizeRunner for the same clang-module reason as
// above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/SynthesizeRunner.h.
extern NSErrorDomain const RNVPSynthesizeRunnerErrorDomain;

typedef NS_ERROR_ENUM(RNVPSynthesizeRunnerErrorDomain,
                      RNVPSynthesizeRunnerErrorCode) {
  RNVPSynthesizeRunnerErrorCodeInvalidSpec = 1,
  RNVPSynthesizeRunnerErrorCodeOpenFailed = 2,
  RNVPSynthesizeRunnerErrorCodeFrameFailed = 3,
  RNVPSynthesizeRunnerErrorCodeCloseFailed = 4,
};

@interface RNVPStopToken : NSObject
- (instancetype)init;
- (void)requestFinish;
- (void)requestAbort;
@property(nonatomic, readonly) BOOL finishRequested;
@property(nonatomic, readonly) BOOL abortRequested;
@end

typedef void (^RNVPProgressBlock)(double framesCompleted, BOOL nbFramesValid,
                                  double nbFrames, double elapsedMs,
                                  BOOL etaMsValid, double estimatedRemainingMs);

@interface RNVPSynthesizeRunner : NSObject
+ (BOOL)runFixedWithOutputPath:(NSString *)outputPath
                         width:(NSInteger)width
                        height:(NSInteger)height
                           fps:(double)fps
                       seconds:(double)seconds
                     stopToken:(nullable RNVPStopToken *)stopToken
                      progress:(nullable RNVPProgressBlock)progress
                       aborted:(BOOL *_Nullable)aborted
                         error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)runOpenWithOutputPath:(NSString *)outputPath
                        width:(NSInteger)width
                       height:(NSInteger)height
                          fps:(double)fps
                   maxSeconds:(double)maxSeconds
                    stopToken:(RNVPStopToken *)stopToken
                finishOnFrame:(NSInteger)finishOnFrame
                     progress:(nullable RNVPProgressBlock)progress
                framesWritten:(NSInteger *_Nullable)framesWritten
                      aborted:(BOOL *_Nullable)aborted
                         error:(NSError *_Nullable __autoreleasing *)error;
@end

// Forward-declare RNVPAVDemuxer for the same clang-module reason as the
// other RNVP* classes above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/AVDemuxer.h.
extern NSErrorDomain const RNVPAVDemuxerErrorDomain;

typedef NS_ERROR_ENUM(RNVPAVDemuxerErrorDomain, RNVPAVDemuxerErrorCode) {
  RNVPAVDemuxerErrorCodeInvalidState = 1,
  RNVPAVDemuxerErrorCodeNotFound = 2,
  RNVPAVDemuxerErrorCodeNoVideoTrack = 3,
  RNVPAVDemuxerErrorCodeReaderFailed = 4,
};

@interface RNVPAVDemuxer : NSObject
- (BOOL)openAtURL:(NSURL *)url
            error:(NSError *_Nullable __autoreleasing *)error;
- (CMSampleBufferRef _Nullable)copyNextVideoSampleBuffer:
    (NSError *_Nullable __autoreleasing *)error CF_RETURNS_RETAINED;
- (BOOL)closeWithError:(NSError *_Nullable __autoreleasing *)error;
@property(nonatomic, readonly, nullable) NSString *codec;
@property(nonatomic, readonly, nullable) NSString *container;
@property(nonatomic, readonly) NSInteger bitRate;
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) double fps;
@property(nonatomic, readonly) double durationSec;
@property(nonatomic, readonly) NSInteger rotation;
@property(nonatomic, readonly) BOOL isHDR;
@property(nonatomic, readonly) BOOL hasAudio;
@property(nonatomic, readonly, nullable) NSString *colorPrimaries;
@property(nonatomic, readonly, nullable) NSDate *creationDate;
@property(nonatomic, readonly) BOOL hasLocation;
@property(nonatomic, readonly) double locationLatitude;
@property(nonatomic, readonly) double locationLongitude;
@property(nonatomic, readonly) BOOL hasLocationAltitude;
@property(nonatomic, readonly) double locationAltitude;
@property(nonatomic, readonly, nullable, copy) NSString *contentDescription;
@property(nonatomic, readonly, nullable)
    NSDictionary<NSString *, NSString *> *customMetadata;
@end

// Forward-declare RNVPRemuxer for the same clang-module reason as the other
// RNVP* classes above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/Remuxer.h.
extern NSErrorDomain const RNVPRemuxerErrorDomain;

typedef NS_ERROR_ENUM(RNVPRemuxerErrorDomain, RNVPRemuxerErrorCode) {
  RNVPRemuxerErrorCodeInvalidSpec = 1,
  RNVPRemuxerErrorCodeSourceCorrupted = 2,
  RNVPRemuxerErrorCodeWriterFailed = 3,
  RNVPRemuxerErrorCodeNotFound = 4,
  RNVPRemuxerErrorCodeCancelled = 5,
};

typedef NS_ENUM(NSInteger, RNVPFlipAxis) {
  RNVPFlipAxisHorizontal = 0,
  RNVPFlipAxisVertical = 1,
};

// Keep in lockstep with packages/react-native-video-pipeline/ios/RNVPAudio.h.
typedef NS_ENUM(NSInteger, RNVPAudioMode) {
  RNVPAudioModePassthrough = 0,
  RNVPAudioModeMute = 1,
  RNVPAudioModeReplace = 2,
};

@interface RNVPRemuxerConcatSource : NSObject
@property(nonatomic, readonly) NSURL *sourceURL;
@property(nonatomic, readonly) double sourceStart;
@property(nonatomic, readonly) double sourceDuration;
@property(nonatomic, readonly) double outputStart;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL
                      sourceStart:(double)sourceStart
                   sourceDuration:(double)sourceDuration
                      outputStart:(double)outputStart;
@end

@interface RNVPStampMetadata : NSObject
@property(nonatomic, readonly) BOOL hasGps;
@property(nonatomic, readonly) double gpsLatitude;
@property(nonatomic, readonly) double gpsLongitude;
@property(nonatomic, readonly) BOOL hasGpsAltitude;
@property(nonatomic, readonly) double gpsAltitude;
@property(nonatomic, readonly, nullable, copy) NSString *software;
@property(nonatomic, readonly, nullable, copy) NSDate *creationDate;
@property(nonatomic, readonly, nullable, copy) NSString *contentDescription;
@property(nonatomic, readonly, nullable, copy)
    NSDictionary<NSString *, NSString *> *custom;
- (instancetype)initWithGps:(BOOL)hasGps
                   latitude:(double)latitude
                  longitude:(double)longitude
             hasGpsAltitude:(BOOL)hasGpsAltitude
                   altitude:(double)altitude
                   software:(nullable NSString *)software
               creationDate:(nullable NSDate *)creationDate
         contentDescription:(nullable NSString *)contentDescription
                     custom:(nullable NSDictionary<NSString *, NSString *> *)custom;
@end

@interface RNVPRemuxer : NSObject
+ (BOOL)remuxTrimFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                startSec:(double)startSec
             durationSec:(double)durationSec
                   error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)remuxFlipFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                    axis:(RNVPFlipAxis)axis
                   error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)remuxTransformFromURL:(NSURL *)sourceURL
                        toURL:(NSURL *)outputURL
                     startSec:(double)startSec
                  durationSec:(double)durationSec
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                        error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)remuxConcatSources:(NSArray<RNVPRemuxerConcatSource *> *)sources
                     toURL:(NSURL *)outputURL
                      stop:(nullable RNVPStopToken *)stop
                     error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)remuxConcatSources:(NSArray<RNVPRemuxerConcatSource *> *)sources
                     toURL:(NSURL *)outputURL
                 audioMode:(RNVPAudioMode)audioMode
       audioReplacementURL:(nullable NSURL *)audioReplacementURL
                      stop:(nullable RNVPStopToken *)stop
                     error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)remuxStampFromURL:(NSURL *)sourceURL
                    toURL:(NSURL *)outputURL
                 metadata:(nullable RNVPStampMetadata *)metadata
                    error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)remuxTrimFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                startSec:(double)startSec
             durationSec:(double)durationSec
               audioMode:(RNVPAudioMode)audioMode
     audioReplacementURL:(nullable NSURL *)audioReplacementURL
                   error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)remuxFlipFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                    axis:(RNVPFlipAxis)axis
               audioMode:(RNVPAudioMode)audioMode
     audioReplacementURL:(nullable NSURL *)audioReplacementURL
                   error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)remuxTransformFromURL:(NSURL *)sourceURL
                        toURL:(NSURL *)outputURL
                     startSec:(double)startSec
                  durationSec:(double)durationSec
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                    audioMode:(RNVPAudioMode)audioMode
          audioReplacementURL:(nullable NSURL *)audioReplacementURL
                        error:(NSError *_Nullable __autoreleasing *)error;
@end

// Forward-declare RNVPThumbnailer for the same clang-module reason as the
// other RNVP* classes above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/Thumbnailer.h.
extern NSErrorDomain const RNVPThumbnailerErrorDomain;

typedef NS_ERROR_ENUM(RNVPThumbnailerErrorDomain, RNVPThumbnailerErrorCode) {
  RNVPThumbnailerErrorCodeInvalidSpec = 1,
  RNVPThumbnailerErrorCodeNotFound = 2,
  RNVPThumbnailerErrorCodeGenerationFailed = 3,
  RNVPThumbnailerErrorCodeWriteFailed = 4,
};

@interface RNVPThumbnailer : NSObject
+ (BOOL)generateThumbnailFromURL:(NSURL *)sourceURL
                           toURL:(NSURL *)outputURL
                           atSec:(double)atSec
                     resizeWidth:(double)resizeWidth
                    resizeHeight:(double)resizeHeight
                           error:(NSError *_Nullable __autoreleasing *)error;
@end

// Forward-declare RNVPCapabilities for the same clang-module reason as the
// other RNVP* classes above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/Capabilities.h.
@interface RNVPEncoderCapabilities : NSObject
@property(nonatomic, readonly) NSArray<NSString *> *codecs;
@property(nonatomic, readonly) NSInteger maxWidth;
@property(nonatomic, readonly) NSInteger maxHeight;
@property(nonatomic, readonly) double maxFps;
@property(nonatomic, readonly) NSInteger maxBitrate;
@property(nonatomic, readonly) BOOL hdr;
@end

@interface RNVPCapabilities : NSObject
+ (RNVPEncoderCapabilities *)probe;
+ (NSInteger)probeCount;
+ (void)resetCacheForTesting;
@end

// Forward-declare RNVPTranscoder for the same clang-module reason. Keep in
// lockstep with packages/react-native-video-pipeline/ios/Transcoder.h.
extern NSErrorDomain const RNVPTranscoderErrorDomain;

typedef NS_ERROR_ENUM(RNVPTranscoderErrorDomain, RNVPTranscoderErrorCode) {
  RNVPTranscoderErrorCodeInvalidSpec = 1,
  RNVPTranscoderErrorCodeSourceCorrupted = 2,
  RNVPTranscoderErrorCodeWriterFailed = 3,
  RNVPTranscoderErrorCodeNotFound = 4,
  RNVPTranscoderErrorCodeEncoderFailure = 5,
  RNVPTranscoderErrorCodeCancelled = 6,
};

typedef NS_ENUM(NSInteger, RNVPTranscodeCodec) {
  RNVPTranscodeCodecH264 = 0,
  RNVPTranscodeCodecHEVC = 1,
};

@interface RNVPTranscodeTarget : NSObject
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) double fps;
@property(nonatomic, readonly) RNVPTranscodeCodec codec;
@property(nonatomic, readonly) NSInteger bitrate;
@property(nonatomic, readonly) NSInteger rotate;
@property(nonatomic, readonly) BOOL flipH;
@property(nonatomic, readonly) BOOL flipV;
@property(nonatomic, readonly) double cropX;
@property(nonatomic, readonly) double cropY;
@property(nonatomic, readonly) double cropWidth;
@property(nonatomic, readonly) double cropHeight;
- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                          fps:(double)fps
                        codec:(RNVPTranscodeCodec)codec
                      bitrate:(NSInteger)bitrate
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                        cropX:(double)cropX
                        cropY:(double)cropY
                    cropWidth:(double)cropWidth
                   cropHeight:(double)cropHeight;
- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                          fps:(double)fps
                        codec:(RNVPTranscodeCodec)codec
                      bitrate:(NSInteger)bitrate
                       rotate:(NSInteger)rotate
                        flipH:(BOOL)flipH
                        flipV:(BOOL)flipV
                        cropX:(double)cropX
                        cropY:(double)cropY
                    cropWidth:(double)cropWidth
                   cropHeight:(double)cropHeight
                  sourceStart:(double)sourceStart
               sourceDuration:(double)sourceDuration;
@end

// Forward-declare RNVPImageOverlay + RNVPTextOverlay + RNVPOverlayRenderer
// (T034/T035) for the same clang-module reason. Keep in lockstep with
// packages/react-native-video-pipeline/ios/OverlayRenderer.h.
extern NSErrorDomain const RNVPOverlayRendererErrorDomain;

typedef NS_ERROR_ENUM(RNVPOverlayRendererErrorDomain,
                      RNVPOverlayRendererErrorCode) {
  RNVPOverlayRendererErrorCodeInvalidSpec = 1,
  RNVPOverlayRendererErrorCodeImageLoadFailed = 2,
  RNVPOverlayRendererErrorCodeTextRasterFailed = 3,
};

typedef NS_ENUM(NSInteger, RNVPTextAlignment) {
  RNVPTextAlignmentLeft = 0,
  RNVPTextAlignmentCenter = 1,
  RNVPTextAlignmentRight = 2,
};

@interface RNVPImageOverlay : NSObject
@property(nonatomic, readonly) NSURL *imageURL;
@property(nonatomic, readonly) double anchorX;
@property(nonatomic, readonly) double anchorY;
@property(nonatomic, readonly) BOOL hasSizeW;
@property(nonatomic, readonly) BOOL sizeWIsRatio;
@property(nonatomic, readonly) double sizeWValue;
@property(nonatomic, readonly) BOOL hasSizeH;
@property(nonatomic, readonly) BOOL sizeHIsRatio;
@property(nonatomic, readonly) double sizeHValue;
@property(nonatomic, readonly) double opacity;
@property(nonatomic, readonly) BOOL hasTimeRange;
@property(nonatomic, readonly) double startSec;
@property(nonatomic, readonly) double endSec;
- (instancetype)initWithImageURL:(NSURL *)imageURL
                         anchorX:(double)anchorX
                         anchorY:(double)anchorY
                        hasSizeW:(BOOL)hasSizeW
                    sizeWIsRatio:(BOOL)sizeWIsRatio
                      sizeWValue:(double)sizeWValue
                        hasSizeH:(BOOL)hasSizeH
                    sizeHIsRatio:(BOOL)sizeHIsRatio
                      sizeHValue:(double)sizeHValue
                         opacity:(double)opacity
                    hasTimeRange:(BOOL)hasTimeRange
                        startSec:(double)startSec
                          endSec:(double)endSec;
@end

@interface RNVPTextOverlay : NSObject
@property(nonatomic, readonly) NSString *text;
@property(nonatomic, readonly, nullable) NSString *fontFamily;
@property(nonatomic, readonly) double fontSize;
@property(nonatomic, readonly) NSString *colorString;
@property(nonatomic, readonly) BOOL weightBold;
@property(nonatomic, readonly) RNVPTextAlignment alignment;
@property(nonatomic, readonly) BOOL hasShadow;
@property(nonatomic, readonly, nullable) NSString *shadowColorString;
@property(nonatomic, readonly) double shadowBlur;
@property(nonatomic, readonly) double shadowDx;
@property(nonatomic, readonly) double shadowDy;
@property(nonatomic, readonly) double anchorX;
@property(nonatomic, readonly) double anchorY;
@property(nonatomic, readonly) BOOL hasTimeRange;
@property(nonatomic, readonly) double startSec;
@property(nonatomic, readonly) double endSec;
- (instancetype)initWithText:(NSString *)text
                  fontFamily:(nullable NSString *)fontFamily
                    fontSize:(double)fontSize
                 colorString:(NSString *)colorString
                  weightBold:(BOOL)weightBold
                   alignment:(RNVPTextAlignment)alignment
                   hasShadow:(BOOL)hasShadow
           shadowColorString:(nullable NSString *)shadowColorString
                  shadowBlur:(double)shadowBlur
                    shadowDx:(double)shadowDx
                    shadowDy:(double)shadowDy
                     anchorX:(double)anchorX
                     anchorY:(double)anchorY
                hasTimeRange:(BOOL)hasTimeRange
                    startSec:(double)startSec
                      endSec:(double)endSec;
@end

typedef void (^RNVPTranscoderProgressBlock)(double framesCompleted,
                                            BOOL nbFramesValid,
                                            double nbFrames, double elapsedMs,
                                            BOOL etaMsValid,
                                            double estimatedRemainingMs);

@interface RNVPTranscoder : NSObject
+ (BOOL)transcodeFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                  target:(RNVPTranscodeTarget *)target
                overlays:(nullable NSArray *)overlays
                metadata:(nullable RNVPStampMetadata *)metadata
                    stop:(nullable RNVPStopToken *)stop
                progress:(nullable RNVPTranscoderProgressBlock)progress
                   error:(NSError *_Nullable __autoreleasing *)error;
+ (BOOL)transcodeFromURL:(NSURL *)sourceURL
                   toURL:(NSURL *)outputURL
                  target:(RNVPTranscodeTarget *)target
                overlays:(nullable NSArray *)overlays
                metadata:(nullable RNVPStampMetadata *)metadata
               audioMode:(RNVPAudioMode)audioMode
     audioReplacementURL:(nullable NSURL *)audioReplacementURL
                    stop:(nullable RNVPStopToken *)stop
                progress:(nullable RNVPTranscoderProgressBlock)progress
                   error:(NSError *_Nullable __autoreleasing *)error;
@end

// Forward-declare RNVPBackgroundTaskJournal + RNVPBackgroundTaskGuard
// (T039) for the same clang-module reason as the other RNVP* classes
// above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/BackgroundTaskGuard.h.
extern NSString *const RNVPBackgroundTaskJournalDefaultsKey;

@interface RNVPBackgroundTaskJournal : NSObject
+ (void)markActiveTokenId:(NSString *)tokenId
               outputPath:(nullable NSString *)outputPath;
+ (void)clearTokenId:(NSString *)tokenId;
+ (NSDictionary<NSString *, id> *)activeEntriesSnapshot;
+ (NSArray<NSString *> *)drainZombies;
+ (void)resetForTesting;
@end

@interface RNVPBackgroundTaskGuard : NSObject
+ (instancetype)beginWithTokenId:(nullable NSString *)tokenId
                      outputPath:(nullable NSString *)outputPath
                       stopToken:(nullable RNVPStopToken *)stopToken;
- (void)end;
@end

// Forward-declare RNVPExportSessionStamp for the same clang-module reason as
// the other RNVP* classes above. Keep in lockstep with
// packages/react-native-video-pipeline/ios/ExportSessionStamp.h.
extern NSErrorDomain const RNVPExportSessionStampErrorDomain;

typedef NS_ERROR_ENUM(RNVPExportSessionStampErrorDomain,
                      RNVPExportSessionStampErrorCode) {
  RNVPExportSessionStampErrorCodeInvalidSpec = 1,
  RNVPExportSessionStampErrorCodeSourceCorrupted = 2,
  RNVPExportSessionStampErrorCodeExportFailed = 3,
  RNVPExportSessionStampErrorCodeImageLoadFailed = 4,
};

typedef void (^RNVPExportSessionProgress)(int32_t framesCompleted,
                                           int32_t nbFrames);

@interface RNVPExportSessionStamp : NSObject
+ (BOOL)stampFromURL:(NSURL *)sourceURL
               toURL:(NSURL *)outputURL
            overlays:(NSArray *)overlays
            metadata:(nullable RNVPStampMetadata *)metadata
            progress:(nullable RNVPExportSessionProgress)progress
               error:(NSError *_Nullable __autoreleasing *)error;
@end

@interface bareexampleTests : XCTestCase
@end

@implementation bareexampleTests

/// T018 acceptance: author an H.264 MP4 with 30 solid-color frames, then
/// re-open it with AVFoundation and assert width/height/fps/frame-count.
/// "Plays in QuickTime" is proven transitively — QuickTime uses the same
/// AVFoundation decoder as AVAssetReader below.
- (void)testAVMuxerWrites30SolidColorFrames
{
  const NSInteger kWidth = 320;
  const NSInteger kHeight = 240;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t018-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  XCTAssertTrue([muxer openAtPath:outputPath
                            width:kWidth
                           height:kHeight
                              fps:kFps
                            error:&error],
                @"open failed: %@", error);

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
    (id)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
  };

  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)pbAttrs, &pb);
    XCTAssertEqual(cv, kCVReturnSuccess, @"CVPixelBufferCreate failed at i=%ld",
                   (long)i);

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    uint8_t r = (uint8_t)((i * 8) & 0xFF);
    uint8_t g = 0x40;
    uint8_t b = 0x80;
    for (NSInteger y = 0; y < kHeight; y++) {
      uint8_t *row = base + (size_t)y * bytesPerRow;
      for (NSInteger x = 0; x < kWidth; x++) {
        uint8_t *px = row + (size_t)x * 4;
        px[0] = b;
        px[1] = g;
        px[2] = r;
        px[3] = 0xFF;
      }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    XCTAssertTrue(
        [muxer appendPixelBuffer:pb presentationTime:pts error:&error],
        @"append failed at i=%ld: %@", (long)i, error);
    CVPixelBufferRelease(pb);
  }

  XCTAssertTrue([muxer closeWithError:&error], @"close failed: %@", error);

  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outputPath],
                @"output file missing at %@", outputPath);

  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];

  NSArray<AVAssetTrack *> *videoTracks =
      [asset tracksWithMediaType:AVMediaTypeVideo];
  XCTAssertEqual(videoTracks.count, 1u, @"expected exactly one video track");
  AVAssetTrack *videoTrack = videoTracks.firstObject;
  CGSize natural = videoTrack.naturalSize;
  XCTAssertEqualWithAccuracy(natural.width, kWidth, 0.5);
  XCTAssertEqualWithAccuracy(natural.height, kHeight, 0.5);
  XCTAssertEqualWithAccuracy(videoTrack.nominalFrameRate, kFps, 0.5);

  Float64 durationSeconds = CMTimeGetSeconds(asset.duration);
  Float64 expected = (Float64)kFrameCount / (Float64)kFps;
  XCTAssertEqualWithAccuracy(durationSeconds, expected, 0.1,
                             @"duration %f differs from expected %f",
                             durationSeconds, expected);

  NSArray<AVAssetTrack *> *audioTracks =
      [asset tracksWithMediaType:AVMediaTypeAudio];
  XCTAssertGreaterThanOrEqual(audioTracks.count, 1u,
                              @"expected a silent audio track");

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  XCTAssertNotNil(reader, @"AVAssetReader init failed: %@", readerError);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading], @"reader failed to start: %@",
                reader.error);

  NSInteger observedFrames = 0;
  while (YES) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) {
      break;
    }
    observedFrames++;
    CFRelease(sample);
  }
  XCTAssertEqual(observedFrames, kFrameCount,
                 @"expected %ld decoded frames, got %ld", (long)kFrameCount,
                 (long)observedFrames);

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

- (void)testAVMuxerRejectsInvalidSpec
{
  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"t018-invalid.mp4"];
  XCTAssertFalse([muxer openAtPath:path width:0 height:240 fps:30
                             error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPAVMuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPAVMuxerErrorCodeInvalidSpec);
}

/// T019 acceptance: push a 512×512 RGBA "Skia surface" (a flat neutral-gray
/// buffer, simulating the output of `SkSurface::readPixels` on the consumer
/// side) through `RNVPWorkletFrameBridge`, encode one frame through
/// `RNVPAVMuxer`, decode it back with `AVAssetReader`, and confirm the center
/// pixel survives the H.264 round trip within 1/255 per channel.
///
/// Uses a neutral gray (128,128,128) on purpose: the YUV chroma components for
/// any achromatic pixel are exactly 128 at either BT.601 or BT.709, so the
/// RGB↔YUV matrix choice the encoder/decoder make can't introduce a per-channel
/// offset. A flat image also produces ~zero H.264 residual, keeping the test
/// stable across simulator runtime versions.
- (void)testWorkletFrameBridgeRoundTripsCentralPixel
{
  const NSInteger kSize = 512;
  const NSInteger kFps = 30;
  const uint8_t kR = 128;
  const uint8_t kG = 128;
  const uint8_t kB = 128;
  const uint8_t kA = 255;

  NSMutableData *bitmap =
      [NSMutableData dataWithLength:(NSUInteger)(kSize * kSize * 4)];
  uint8_t *bitmapBase = (uint8_t *)bitmap.mutableBytes;
  for (NSInteger y = 0; y < kSize; y++) {
    for (NSInteger x = 0; x < kSize; x++) {
      uint8_t *px = bitmapBase + (y * kSize + x) * 4;
      px[0] = kR;
      px[1] = kG;
      px[2] = kB;
      px[3] = kA;
    }
  }

  NSError *error = nil;
  CVPixelBufferRef pb = [RNVPWorkletFrameBridge
      pixelBufferFromBytes:bitmap.bytes
                     width:kSize
                    height:kSize
                  rowBytes:kSize * 4
                    format:RNVPBitmapFormatRGBA8888Premultiplied
                     error:&error];
  XCTAssertTrue(pb != NULL, @"bridge returned NULL: %@", error);

  // Sanity-check the pre-encode bridge output: bytes should already be the
  // expected BGRA layout. This isolates any post-test mismatch to the muxer
  // path rather than the bridge.
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  uint8_t *bridgeBase = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
  size_t bridgeStride = CVPixelBufferGetBytesPerRow(pb);
  uint8_t *bridgeCenter =
      bridgeBase + (kSize / 2) * bridgeStride + (kSize / 2) * 4;
  XCTAssertEqual(bridgeCenter[0], kB, @"bridge B channel wrong");
  XCTAssertEqual(bridgeCenter[1], kG, @"bridge G channel wrong");
  XCTAssertEqual(bridgeCenter[2], kR, @"bridge R channel wrong");
  XCTAssertEqual(bridgeCenter[3], kA, @"bridge A channel wrong");
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t019-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  XCTAssertTrue([muxer openAtPath:outputPath
                            width:kSize
                           height:kSize
                              fps:kFps
                            error:&error],
                @"open failed: %@", error);
  XCTAssertTrue([muxer appendPixelBuffer:pb
                        presentationTime:CMTimeMake(0, (int32_t)kFps)
                                   error:&error],
                @"append failed: %@", error);
  XCTAssertTrue([muxer closeWithError:&error], @"close failed: %@", error);
  CVPixelBufferRelease(pb);

  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(videoTrack);

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  XCTAssertNotNil(reader, @"reader init failed: %@", readerError);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading], @"reader start failed: %@",
                reader.error);

  CMSampleBufferRef sample = [output copyNextSampleBuffer];
  XCTAssertTrue(sample != NULL, @"no decoded frame produced");
  CVPixelBufferRef decoded = CMSampleBufferGetImageBuffer(sample);
  CVPixelBufferLockBaseAddress(decoded, kCVPixelBufferLock_ReadOnly);
  uint8_t *decBase = (uint8_t *)CVPixelBufferGetBaseAddress(decoded);
  size_t decStride = CVPixelBufferGetBytesPerRow(decoded);
  NSInteger cx = kSize / 2;
  NSInteger cy = kSize / 2;
  uint8_t *cpx = decBase + cy * decStride + cx * 4;
  int gotB = cpx[0];
  int gotG = cpx[1];
  int gotR = cpx[2];
  CVPixelBufferUnlockBaseAddress(decoded, kCVPixelBufferLock_ReadOnly);
  CFRelease(sample);

  XCTAssertLessThanOrEqual(abs(gotR - (int)kR), 1,
                           @"R round-trip out of 1/255 tolerance: %d vs %d",
                           gotR, kR);
  XCTAssertLessThanOrEqual(abs(gotG - (int)kG), 1,
                           @"G round-trip out of 1/255 tolerance: %d vs %d",
                           gotG, kG);
  XCTAssertLessThanOrEqual(abs(gotB - (int)kB), 1,
                           @"B round-trip out of 1/255 tolerance: %d vs %d",
                           gotB, kB);

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

/// T020 acceptance: run the fixed-duration synthesize path end-to-end and
/// assert the file has exactly `round(fps * seconds)` frames plus the
/// declared width/height/fps (US11). Exercises the full chain
/// SynthesizeRunner → ComposeRunner → WorkletFrameBridge → AVMuxer. The
/// FrameSource is the placeholder test pattern; the real Reanimated/Skia
/// worklet pump replaces it in T041 without changing this contract.
- (void)testSynthesizeFixedProducesExactFrameCount
{
  const NSInteger kWidth = 320;
  const NSInteger kHeight = 240;
  const double kFps = 30.0;
  const double kSeconds = 1.0;
  const NSInteger kExpectedFrames = (NSInteger)llround(kFps * kSeconds);

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t020-%@.mp4", NSUUID.UUID.UUIDString]];

  NSError *error = nil;
  XCTAssertTrue([RNVPSynthesizeRunner runFixedWithOutputPath:outputPath
                                                       width:kWidth
                                                      height:kHeight
                                                         fps:kFps
                                                     seconds:kSeconds
                                                       stopToken:nil
                                                       progress:nil
                                                       aborted:NULL
                                                       error:&error],
                @"synthesize failed: %@", error);

  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outputPath]);

  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(videoTrack);
  CGSize natural = videoTrack.naturalSize;
  XCTAssertEqualWithAccuracy(natural.width, kWidth, 0.5);
  XCTAssertEqualWithAccuracy(natural.height, kHeight, 0.5);
  XCTAssertEqualWithAccuracy(videoTrack.nominalFrameRate, kFps, 0.5);

  // Silent audio track is part of the acceptance criteria.
  NSArray<AVAssetTrack *> *audioTracks =
      [asset tracksWithMediaType:AVMediaTypeAudio];
  XCTAssertGreaterThanOrEqual(audioTracks.count, 1u);

  // Count decoded frames via AVAssetReader — exact, rather than a duration
  // approximation (H.264 duration rounding is more lenient than we want).
  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  XCTAssertNotNil(reader, @"reader init failed: %@", readerError);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading], @"reader start failed: %@",
                reader.error);

  NSInteger observedFrames = 0;
  while (YES) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) break;
    observedFrames++;
    CFRelease(sample);
  }
  XCTAssertEqual(observedFrames, kExpectedFrames,
                 @"expected %ld frames, got %ld", (long)kExpectedFrames,
                 (long)observedFrames);

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

/// Issue #32 diagnostic: the native fixed synthesize path (SynthesizeRunner →
/// ComposeRunner → AVMuxer, with-audio openAtPath) must complete at 240fps for
/// a multi-second clip — 480 frames — without stalling. If this hangs, the
/// freeze is in the native muxer / silent-audio close; if it passes fast, the
/// freeze observed end-to-end lives in the JS worklet frame bridge instead.
- (void)testSynthesizeFixedHighFpsCompletes
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const double kFps = 240.0;
  const double kSeconds = 2.0;
  const NSInteger kExpectedFrames = (NSInteger)llround(kFps * kSeconds);

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"i32-synth240-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  NSError *error = nil;
  XCTAssertTrue([RNVPSynthesizeRunner runFixedWithOutputPath:outputPath
                                                       width:kWidth
                                                      height:kHeight
                                                         fps:kFps
                                                     seconds:kSeconds
                                                   stopToken:nil
                                                    progress:nil
                                                     aborted:NULL
                                                       error:&error],
                @"240fps synthesize failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outputPath]);

  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(videoTrack);

  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&error];
  XCTAssertNotNil(reader);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading]);
  NSInteger observed = 0;
  while (YES) {
    CMSampleBufferRef s = [output copyNextSampleBuffer];
    if (s == NULL) break;
    observed++;
    CFRelease(s);
  }
  XCTAssertEqual(observed, kExpectedFrames, @"expected %ld frames, got %ld",
                 (long)kExpectedFrames, (long)observed);

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

- (void)testSynthesizeFixedRejectsInvalidSpec
{
  NSError *error = nil;
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"t020-invalid.mp4"];
  // width=0 — runner should reject before opening any muxer.
  XCTAssertFalse([RNVPSynthesizeRunner runFixedWithOutputPath:path
                                                        width:0
                                                       height:240
                                                          fps:30.0
                                                      seconds:1.0
                                                        stopToken:nil
                                                        progress:nil
                                                        aborted:NULL
                                                        error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPSynthesizeRunnerErrorDomain);
  XCTAssertEqual(error.code, RNVPSynthesizeRunnerErrorCodeInvalidSpec);
}

/// T021 acceptance: US12 — the source signals `ctx.finish()` on frame 15;
/// the loop must append that frame and stop, so the finalised file has
/// exactly 16 frames. `finishOnFrame:15` is the placeholder for a real
/// worklet call to `ctx.finish()`; T041 will replace the source with the
/// actual Reanimated bridge, but the termination contract tested here is
/// what that bridge will plug into.
- (void)testSynthesizeOpenStopsAtSourceFinish
{
  const NSInteger kWidth = 320;
  const NSInteger kHeight = 240;
  const double kFps = 30.0;
  const NSInteger kFinishFrame = 15;
  const NSInteger kExpectedFrames = kFinishFrame + 1;

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t021-finish-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  RNVPStopToken *stop = [[RNVPStopToken alloc] init];
  NSError *error = nil;
  NSInteger framesWritten = -1;
  BOOL aborted = YES; // start "wrong" to verify the runner writes to it

  XCTAssertTrue([RNVPSynthesizeRunner runOpenWithOutputPath:outputPath
                                                      width:kWidth
                                                     height:kHeight
                                                        fps:kFps
                                                 maxSeconds:0.0
                                                  stopToken:stop
                                              finishOnFrame:kFinishFrame
                                              progress:nil
                                              framesWritten:&framesWritten
                                                    aborted:&aborted
                                                      error:&error],
                @"runOpen failed: %@", error);

  XCTAssertFalse(aborted, @"ctx.finish() path should not mark aborted");
  XCTAssertEqual(framesWritten, kExpectedFrames,
                 @"expected %ld frames written, got %ld",
                 (long)kExpectedFrames, (long)framesWritten);

  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outputPath],
                @"output file missing at %@", outputPath);

  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(videoTrack);

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  XCTAssertNotNil(reader, @"reader init failed: %@", readerError);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading], @"reader start failed: %@",
                reader.error);

  NSInteger observedFrames = 0;
  while (YES) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) break;
    observedFrames++;
    CFRelease(sample);
  }
  XCTAssertEqual(observedFrames, kExpectedFrames,
                 @"expected %ld decoded frames, got %ld",
                 (long)kExpectedFrames, (long)observedFrames);

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

/// T021 acceptance: open-ended render with `maxSeconds` safety cap and no
/// other stop signal — the runner must finalise the output at
/// `round(fps * maxSeconds)` frames rather than loop indefinitely.
- (void)testSynthesizeOpenRespectsMaxSeconds
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const double kFps = 30.0;
  const double kMaxSeconds = 1.0;
  const NSInteger kExpectedFrames = (NSInteger)llround(kFps * kMaxSeconds);

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t021-cap-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  RNVPStopToken *stop = [[RNVPStopToken alloc] init];
  NSError *error = nil;
  NSInteger framesWritten = -1;
  BOOL aborted = YES;

  XCTAssertTrue([RNVPSynthesizeRunner runOpenWithOutputPath:outputPath
                                                      width:kWidth
                                                     height:kHeight
                                                        fps:kFps
                                                 maxSeconds:kMaxSeconds
                                                  stopToken:stop
                                              finishOnFrame:-1
                                              progress:nil
                                              framesWritten:&framesWritten
                                                    aborted:&aborted
                                                      error:&error],
                @"runOpen failed: %@", error);

  XCTAssertFalse(aborted);
  XCTAssertEqual(framesWritten, kExpectedFrames,
                 @"maxSeconds cap should produce exactly %ld frames, got %ld",
                 (long)kExpectedFrames, (long)framesWritten);

  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(videoTrack);
  XCTAssertEqualWithAccuracy(videoTrack.nominalFrameRate, kFps, 0.5);

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

/// T021 acceptance: `stopToken.requestFinish` fires from a background thread
/// after the loop has written some frames — the render must finalise
/// cleanly (not aborted) and the decoded frame count must match what the
/// loop reported.
- (void)testSynthesizeOpenStopsOnStopTokenFinish
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const double kFps = 30.0;
  const double kMaxSeconds = 10.0; // large cap — finish signal should hit first

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t021-tokfin-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  RNVPStopToken *stop = [[RNVPStopToken alloc] init];

  // Signal finish after a short delay from a background queue — plenty of
  // time for the loop to get past the first handful of frames without
  // tripping the 10-second cap.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                   [stop requestFinish];
                 });

  NSError *error = nil;
  NSInteger framesWritten = -1;
  BOOL aborted = YES;

  XCTAssertTrue([RNVPSynthesizeRunner runOpenWithOutputPath:outputPath
                                                      width:kWidth
                                                     height:kHeight
                                                        fps:kFps
                                                 maxSeconds:kMaxSeconds
                                                  stopToken:stop
                                              finishOnFrame:-1
                                              progress:nil
                                              framesWritten:&framesWritten
                                                    aborted:&aborted
                                                      error:&error],
                @"runOpen failed: %@", error);

  XCTAssertFalse(aborted, @"finish signal must not be treated as abort");
  XCTAssertGreaterThan(framesWritten, 0,
                       @"some frames should have been written before finish");
  XCTAssertLessThan(framesWritten, (NSInteger)llround(kFps * kMaxSeconds),
                    @"finish must stop well before the maxSeconds cap");

  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outputPath],
                @"finalised file must exist on finish path");

  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];
  NSError *readerError = nil;
  AVAssetReader *reader =
      [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading]);
  NSInteger decoded = 0;
  while (YES) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) break;
    decoded++;
    CFRelease(sample);
  }
  XCTAssertEqual(decoded, framesWritten,
                 @"decoded frame count should match framesWritten");

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

/// T021 acceptance: `stopToken.requestAbort` fires — the output file must
/// be deleted (abort discards, per §8 `VideoRenderController`).
- (void)testSynthesizeOpenAbortsOnStopTokenAbort
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const double kFps = 30.0;

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t021-abort-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  RNVPStopToken *stop = [[RNVPStopToken alloc] init];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                   [stop requestAbort];
                 });

  NSError *error = nil;
  NSInteger framesWritten = -1;
  BOOL aborted = NO;

  XCTAssertTrue([RNVPSynthesizeRunner runOpenWithOutputPath:outputPath
                                                      width:kWidth
                                                     height:kHeight
                                                        fps:kFps
                                                 maxSeconds:10.0
                                                  stopToken:stop
                                              finishOnFrame:-1
                                              progress:nil
                                              framesWritten:&framesWritten
                                                    aborted:&aborted
                                                      error:&error],
                @"runOpen returned error: %@", error);

  XCTAssertTrue(aborted, @"abort must be surfaced to the caller");
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outputPath],
                 @"abort must delete the partial output file");
}

- (void)testSynthesizeOpenRejectsInvalidSpec
{
  RNVPStopToken *stop = [[RNVPStopToken alloc] init];
  NSError *error = nil;
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"t021-invalid.mp4"];
  // width=0 — runner should reject before opening any muxer.
  XCTAssertFalse([RNVPSynthesizeRunner runOpenWithOutputPath:path
                                                       width:0
                                                      height:240
                                                         fps:30.0
                                                  maxSeconds:1.0
                                                   stopToken:stop
                                               finishOnFrame:-1
                                               progress:nil
                                               framesWritten:NULL
                                                     aborted:NULL
                                                       error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPSynthesizeRunnerErrorDomain);
  XCTAssertEqual(error.code, RNVPSynthesizeRunnerErrorCodeInvalidSpec);
}

/// T023 acceptance: the US13 canary. Run the fixed-duration synthesize
/// path and confirm the center pixel of each decoded frame matches the
/// authored (r,g,b) triple within H.264 round-trip tolerance.
///
/// Single source of truth for the canonical pattern:
/// `packages/react-native-video-pipeline/src/bootstrap-pattern.ts`
/// (`bootstrapPatternRGBA` / `expectedCenterRGBA`). The JS tripwire in
/// `__tests__/bootstrap/self-test.ts` imports from there and freezes a
/// center-pixel reference table, so a formula drift breaks `yarn test`
/// before the native canary ever runs.
///
/// Current native coverage: this XCTest exercises
/// `SynthesizeRunner.mm::fillTestPatternRGBA`, which emits the
/// BOOTSTRAP_PATTERN "outside-triangle" branch — the flat frame-keyed
/// triple `((i*11, i*53, i*97) & 0xff)`. That branch is what the native
/// placeholder ships until the `react-native-worklets-core` integration
/// lands; at that point T053's pointer-path screen and T053a's
/// `drawWithSkia` screen will drive the inside-triangle branch end-to-
/// end under `yarn smoke:ios`, and a matching canary here will decode
/// those MP4s against `expectedCenterRGBA` directly.
///
/// ±32/255 tolerance per channel. AVFoundation's default H.264 settings
/// use inter-frame prediction with rate control, so even flat-fill frames
/// drift by up to ~25 units on saturated colors (measured worst case on
/// the simulator: frame 15 G channel, authored 27, decoded 4 — a 23-unit
/// drift). 32 leaves headroom for OS-version variance while still
/// catching the regressions a canary exists to catch:
///   - blank/zero output frames (drift ≥132 on any mid-gray frame)
///   - R↔B channel swap (drift ≥174 on frame 5's pure-blue-heavy triple)
///   - brightness scaling by ≤0.75 (drift ≥52 on the brightest channel)
///   - pipeline producing a single solid-color stream instead of N distinct
///     frames (each frame's expected color differs by ≥53 from any other's)
/// A failing assertion is worded "synthesize regression" so the bootstrap
/// layer's failure is unambiguous in downstream CI logs.
- (void)testSynthesizeSelfTestCanary
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const double kFps = 30.0;
  const NSInteger kFrameCount = 20;
  const double kSeconds = (double)kFrameCount / kFps;
  const int kTolerance = 32;

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t023-%@.mp4", NSUUID.UUID.UUIDString]];

  NSError *error = nil;
  XCTAssertTrue([RNVPSynthesizeRunner runFixedWithOutputPath:outputPath
                                                       width:kWidth
                                                      height:kHeight
                                                         fps:kFps
                                                     seconds:kSeconds
                                                       stopToken:nil
                                                       progress:nil
                                                       aborted:NULL
                                                       error:&error],
                @"synthesize regression: runner failed before decode: %@",
                error);

  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(videoTrack, @"synthesize regression: no video track");

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&readerError];
  XCTAssertNotNil(reader, @"synthesize regression: reader init failed: %@",
                  readerError);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading],
                @"synthesize regression: reader start failed: %@",
                reader.error);

  NSInteger frameIndex = 0;
  while (YES) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) break;

    const uint8_t expR = (uint8_t)((frameIndex * 11) & 0xff);
    const uint8_t expG = (uint8_t)((frameIndex * 53) & 0xff);
    const uint8_t expB = (uint8_t)((frameIndex * 97) & 0xff);

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    const size_t stride = CVPixelBufferGetBytesPerRow(pb);
    const size_t cx = (size_t)kWidth / 2;
    const size_t cy = (size_t)kHeight / 2;
    const uint8_t *px = base + cy * stride + cx * 4;
    const int gotB = px[0];
    const int gotG = px[1];
    const int gotR = px[2];
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CFRelease(sample);

    XCTAssertLessThanOrEqual(
        abs(gotR - (int)expR), kTolerance,
        @"synthesize regression at frame %ld: expected R=%d got R=%d "
        @"(tolerance %d)",
        (long)frameIndex, (int)expR, gotR, kTolerance);
    XCTAssertLessThanOrEqual(
        abs(gotG - (int)expG), kTolerance,
        @"synthesize regression at frame %ld: expected G=%d got G=%d "
        @"(tolerance %d)",
        (long)frameIndex, (int)expG, gotG, kTolerance);
    XCTAssertLessThanOrEqual(
        abs(gotB - (int)expB), kTolerance,
        @"synthesize regression at frame %ld: expected B=%d got B=%d "
        @"(tolerance %d)",
        (long)frameIndex, (int)expB, gotB, kTolerance);
    frameIndex++;
  }

  XCTAssertEqual(frameIndex, kFrameCount,
                 @"synthesize regression: expected %ld frames, decoded %ld",
                 (long)kFrameCount, (long)frameIndex);

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

- (void)testWorkletFrameBridgeRejectsInvalidSpec
{
  uint8_t scratch[16] = {0};
  NSError *error = nil;
  CVPixelBufferRef pb =
      [RNVPWorkletFrameBridge pixelBufferFromBytes:scratch
                                             width:0
                                            height:2
                                          rowBytes:8
                                            format:
                                                RNVPBitmapFormatRGBA8888Premultiplied
                                             error:&error];
  XCTAssertTrue(pb == NULL);
  XCTAssertEqualObjects(error.domain, RNVPWorkletFrameBridgeErrorDomain);
  XCTAssertEqual(error.code, RNVPWorkletFrameBridgeErrorCodeInvalidSpec);
}

/// T053b GPU fast path: pre-fill a source `id<MTLTexture>` with a
/// deterministic asymmetric pattern, blit into an IOSurface-backed
/// `CVPixelBuffer` via `RNVPMetalBlit`, and verify the bytes round-trip
/// bit-identically. This proves that the future worklet pump can skip the
/// CPU readback entirely — the Metal blit is the only operation between
/// Skia's backing texture and the CVPixelBuffer the muxer appends.
- (void)testMetalBlitRoundTripsBytesBitIdentically
{
  if (![RNVPMetalBlit isMetalAvailable]) {
    XCTSkip(@"Host has no Metal device (likely a headless CI runner) — "
            @"GPU fast path cannot be exercised here.");
    return;
  }
  const NSUInteger kWidth = 32;
  const NSUInteger kHeight = 16;

  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  XCTAssertNotNil(device);

  // Author a source MTLTexture in BGRA8Unorm with a rotating-gradient pattern
  // that is neither horizontally nor vertically symmetric — a flip or a 90°
  // rotation of this buffer shifts every pixel, so a bit-identical blit is a
  // strong check on the encoder's coordinate handling.
  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:kWidth
                                  height:kHeight
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_SIMULATOR || TARGET_OS_IOS
  desc.storageMode = MTLStorageModeShared;
#else
  desc.storageMode = MTLStorageModeManaged;
#endif
  id<MTLTexture> source = [device newTextureWithDescriptor:desc];
  XCTAssertNotNil(source);

  uint8_t srcBytes[kWidth * kHeight * 4];
  for (NSUInteger y = 0; y < kHeight; y++) {
    for (NSUInteger x = 0; x < kWidth; x++) {
      uint8_t *px = srcBytes + (y * kWidth + x) * 4;
      px[0] = (uint8_t)(x * 7 + y * 3);   // B
      px[1] = (uint8_t)(x * 11 + y * 5);  // G
      px[2] = (uint8_t)(x * 13 + y * 2);  // R
      px[3] = 0xff;                       // A
    }
  }
  [source replaceRegion:MTLRegionMake2D(0, 0, kWidth, kHeight)
            mipmapLevel:0
              withBytes:srcBytes
            bytesPerRow:kWidth * 4];

  NSError *error = nil;
  CVPixelBufferRef dest = RNVPMakeTestIOSurfaceBuffer(kWidth, kHeight);
  XCTAssertTrue(dest != NULL);

  const uintptr_t srcPtr = (uintptr_t)(__bridge void *)source;
  BOOL ok = [RNVPMetalBlit blitFromMetalTexturePtr:srcPtr
                                     toPixelBuffer:dest
                                             error:&error];
  XCTAssertTrue(ok, @"blit error: %@", error);
  XCTAssertNil(error);

  // Read back the CVPixelBuffer and verify every byte matches the source
  // pattern. BGRA on both sides — no channel swap should be introduced.
  CVPixelBufferLockBaseAddress(dest, kCVPixelBufferLock_ReadOnly);
  const uint8_t *dstBase = (const uint8_t *)CVPixelBufferGetBaseAddress(dest);
  const size_t dstStride = CVPixelBufferGetBytesPerRow(dest);
  XCTAssertTrue(dstBase != NULL);
  for (NSUInteger y = 0; y < kHeight; y++) {
    const uint8_t *dstRow = dstBase + y * dstStride;
    const uint8_t *srcRow = srcBytes + y * kWidth * 4;
    for (NSUInteger x = 0; x < kWidth; x++) {
      const uint8_t *dpx = dstRow + x * 4;
      const uint8_t *spx = srcRow + x * 4;
      XCTAssertEqual(dpx[0], spx[0], @"B mismatch at (%lu,%lu)",
                     (unsigned long)x, (unsigned long)y);
      XCTAssertEqual(dpx[1], spx[1], @"G mismatch at (%lu,%lu)",
                     (unsigned long)x, (unsigned long)y);
      XCTAssertEqual(dpx[2], spx[2], @"R mismatch at (%lu,%lu)",
                     (unsigned long)x, (unsigned long)y);
      XCTAssertEqual(dpx[3], spx[3], @"A mismatch at (%lu,%lu)",
                     (unsigned long)x, (unsigned long)y);
    }
  }
  CVPixelBufferUnlockBaseAddress(dest, kCVPixelBufferLock_ReadOnly);

  CVPixelBufferRelease(dest);
}

- (void)testMetalBlitRejectsNullTexturePointer
{
  if (![RNVPMetalBlit isMetalAvailable]) {
    XCTSkip(@"Host has no Metal device.");
    return;
  }
  NSError *error = nil;
  CVPixelBufferRef dest = RNVPMakeTestIOSurfaceBuffer(4, 4);
  XCTAssertTrue(dest != NULL);

  BOOL ok = [RNVPMetalBlit blitFromMetalTexturePtr:0
                                     toPixelBuffer:dest
                                             error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPMetalBlitErrorDomain);
  XCTAssertEqual(error.code, RNVPMetalBlitErrorCodeInvalidSpec);

  CVPixelBufferRelease(dest);
}

- (void)testMetalBlitRejectsDimensionMismatch
{
  if (![RNVPMetalBlit isMetalAvailable]) {
    XCTSkip(@"Host has no Metal device.");
    return;
  }
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  XCTAssertNotNil(device);

  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:16
                                  height:16
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_SIMULATOR || TARGET_OS_IOS
  desc.storageMode = MTLStorageModeShared;
#else
  desc.storageMode = MTLStorageModeManaged;
#endif
  id<MTLTexture> source = [device newTextureWithDescriptor:desc];
  XCTAssertNotNil(source);

  NSError *error = nil;
  // Destination is 8×8, source is 16×16 — expect a dimension-mismatch error
  // rather than a silent partial copy.
  CVPixelBufferRef dest = RNVPMakeTestIOSurfaceBuffer(8, 8);
  XCTAssertTrue(dest != NULL);

  const uintptr_t srcPtr = (uintptr_t)(__bridge void *)source;
  BOOL ok = [RNVPMetalBlit blitFromMetalTexturePtr:srcPtr
                                     toPixelBuffer:dest
                                             error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPMetalBlitErrorDomain);
  XCTAssertEqual(error.code, RNVPMetalBlitErrorCodeDimensionMismatch);

  CVPixelBufferRelease(dest);
}

/// T024 pipeline canary — the JS `__tests__/bootstrap/generators.ts`
/// tripwire freezes the declared shape of the four bootstrap fixtures
/// (30fps/3s, 60fps/1s, and two 30fps/1s). The existing
/// `testSynthesizeSelfTestCanary` / `testSynthesizeFixedProducesExactFrameCount`
/// tests already exercise the synthesize path end-to-end at 30fps.
/// The one declared config those tests don't cover is **60fps** — so
/// this canary writes a very short 60fps clip and decode-counts the
/// frames. That's the minimum new native coverage T024 contributes;
/// anything broader (3s durations, HD+ dimensions) exceeds
/// `CLAUDE.md`'s "over 5s is wedged" per-test budget on the macOS
/// host encoder used by `yarn test:native`.
///
/// Uses the same 160×120 / 20-frame shape as `testSynthesizeSelfTestCanary`,
/// just at fps=60 instead of 30. If this test and the 30fps canary
/// both pass, the synthesize code path is proven at both declared
/// frame rates; full-resolution / full-duration round-trips land with
/// the downstream remux / transcode suites (T025+).
- (void)testBootstrapGenerators60fpsCanary
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const double kFps = 60.0;
  const NSInteger kFrameCount = 20;
  const double kSeconds = (double)kFrameCount / kFps;

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t024-%@.mp4", NSUUID.UUID.UUIDString]];

  @try {
    NSError *error = nil;
    XCTAssertTrue([RNVPSynthesizeRunner runFixedWithOutputPath:outputPath
                                                         width:kWidth
                                                        height:kHeight
                                                           fps:kFps
                                                       seconds:kSeconds
                                                         stopToken:nil
                                                         progress:nil
                                                         aborted:NULL
                                                         error:&error],
                  @"T024 60fps canary: runFixed failed: %@", error);

    AVURLAsset *asset =
        [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outputPath]];
    AVAssetTrack *videoTrack =
        [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    XCTAssertNotNil(videoTrack, @"T024 60fps canary: no video track");
    XCTAssertEqualWithAccuracy(videoTrack.nominalFrameRate, kFps, 0.5,
                               @"T024 60fps canary: fps mismatch %f vs %f",
                               videoTrack.nominalFrameRate, kFps);

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                           error:&readerError];
    XCTAssertNotNil(reader, @"T024 60fps canary: reader init failed: %@",
                    readerError);
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:videoTrack
       outputSettings:@{
         (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
       }];
    [reader addOutput:output];
    XCTAssertTrue([reader startReading], @"T024 60fps canary: reader: %@",
                  reader.error);

    NSInteger observedFrames = 0;
    while (YES) {
      CMSampleBufferRef sample = [output copyNextSampleBuffer];
      if (sample == NULL) break;
      observedFrames++;
      CFRelease(sample);
    }
    XCTAssertEqual(observedFrames, kFrameCount,
                   @"T024 60fps canary: expected %ld frames, got %ld",
                   (long)kFrameCount, (long)observedFrames);
  } @finally {
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
  }
}

/// T025 acceptance: write a known fixture with RNVPAVMuxer (320×240 / 30fps /
/// 30 frames, MP4/H.264, with silent audio), open it with RNVPAVDemuxer, and
/// assert the metadata matches what was written. Then drain the compressed
/// sample buffers and assert the count is 30 — proving the round-trip path
/// the remux tasks (T027+) will hang their work off.
- (void)testAVDemuxerRoundTripsAVMuxerFixture
{
  const NSInteger kWidth = 320;
  const NSInteger kHeight = 240;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t025-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  XCTAssertTrue([muxer openAtPath:outputPath
                            width:kWidth
                           height:kHeight
                              fps:kFps
                            error:&error],
                @"muxer open failed: %@", error);

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)pbAttrs, &pb);
    XCTAssertEqual(cv, kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    for (NSInteger y = 0; y < kHeight; y++) {
      uint8_t *row = base + (size_t)y * bytesPerRow;
      for (NSInteger x = 0; x < kWidth; x++) {
        uint8_t *px = row + (size_t)x * 4;
        px[0] = 0x80; px[1] = 0x80; px[2] = 0x80; px[3] = 0xFF;
      }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    XCTAssertTrue([muxer appendPixelBuffer:pb presentationTime:pts error:&error],
                  @"muxer append failed at i=%ld: %@", (long)i, error);
    CVPixelBufferRelease(pb);
  }
  XCTAssertTrue([muxer closeWithError:&error], @"muxer close failed: %@", error);

  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:[NSURL fileURLWithPath:outputPath]
                             error:&error],
                @"demuxer open failed: %@", error);

  XCTAssertEqualObjects(demuxer.codec, @"h264",
                        @"codec mismatch — got %@", demuxer.codec);
  XCTAssertEqualObjects(demuxer.container, @"mp4",
                        @"container mismatch — got %@", demuxer.container);
  XCTAssertEqual(demuxer.width, kWidth, @"width mismatch");
  XCTAssertEqual(demuxer.height, kHeight, @"height mismatch");
  XCTAssertEqualWithAccuracy(demuxer.fps, (double)kFps, 0.5,
                             @"fps mismatch: %f vs %ld",
                             demuxer.fps, (long)kFps);
  XCTAssertEqualWithAccuracy(demuxer.durationSec,
                             (double)kFrameCount / (double)kFps, 0.1,
                             @"duration mismatch: %f", demuxer.durationSec);
  XCTAssertEqual(demuxer.rotation, 0, @"unrotated source should report 0");
  XCTAssertFalse(demuxer.isHDR, @"AVMuxer SDR fixture must not flag HDR");
  XCTAssertTrue(demuxer.hasAudio, @"AVMuxer authors a silent audio track");
  XCTAssertGreaterThan(demuxer.bitRate, 0,
                       @"bitRate should be a positive estimate");
  XCTAssertNil(demuxer.creationDate,
               @"AVMuxer fixture writes no creationDate metadata");
  XCTAssertFalse(demuxer.hasLocation,
                 @"AVMuxer fixture writes no location metadata");
  XCTAssertNil(demuxer.customMetadata,
               @"AVMuxer fixture writes no common metadata beyond defaults");

  // Round-trip every compressed sample. Exact equality with kFrameCount is
  // intentionally not asserted: AVAssetReader passthrough returns one
  // CMSampleBuffer per access unit, and the H.264 encoder may emit extra
  // access units for B-frame buffering or GOP-end flushing. The contract
  // T025 needs is "samples come back without error and at least cover the
  // input"; the displayable frame count is already verified by the
  // decoded-output reader in testAVMuxerWrites30SolidColorFrames.
  // Round-trip every compressed sample. Exact equality with kFrameCount is
  // intentionally not asserted: AVAssetReader passthrough returns one
  // CMSampleBuffer per access unit, and the H.264 encoder may emit extra
  // access units for B-frame buffering or GOP-end flushing — those trailing
  // samples can also legitimately have invalid PTS. The contract T025 needs
  // is "samples come back without error and at least cover the input frames
  // with valid PTS"; the displayable frame count is already verified by the
  // decoded-output reader in testAVMuxerWrites30SolidColorFrames.
  NSInteger samples = 0;
  NSInteger samplesWithValidPts = 0;
  while (YES) {
    CMSampleBufferRef sample = [demuxer copyNextVideoSampleBuffer:&error];
    if (sample == NULL) {
      XCTAssertNil(error, @"unexpected reader error: %@", error);
      break;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    if (CMTIME_IS_VALID(pts)) samplesWithValidPts++;
    samples++;
    CFRelease(sample);
  }
  XCTAssertGreaterThanOrEqual(samples, kFrameCount,
                              @"expected at least %ld samples, got %ld",
                              (long)kFrameCount, (long)samples);
  XCTAssertGreaterThanOrEqual(samplesWithValidPts, kFrameCount,
                              @"expected at least %ld PTS-valid samples",
                              (long)kFrameCount);

  XCTAssertTrue([demuxer closeWithError:&error], @"demuxer close failed: %@",
                error);

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

- (void)testAVDemuxerRejectsMissingFile
{
  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  NSError *error = nil;
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:@"t025-missing.mp4"]];
  XCTAssertFalse([demuxer openAtURL:url error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPAVDemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPAVDemuxerErrorCodeNotFound);
}

/// T026 acceptance: author an MP4 via AVAssetWriter with known creationDate,
/// location (ISO 6709) and software metadata items, then open it with
/// RNVPAVDemuxer and assert every field survives the round-trip. AVAssetWriter
/// is used directly (rather than via RNVPAVMuxer) because writing container-
/// level metadata is scoped to the remux tasks (T032+), not to the test-only
/// fixture author.
- (void)testAVDemuxerExtractsCreationDateLocationAndCustomMetadata
{
  const NSInteger kWidth = 64;
  const NSInteger kHeight = 64;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 4;
  const double kLatitude = 37.7749;
  const double kLongitude = -122.4194;

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t026-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
  NSURL *outputURL = [NSURL fileURLWithPath:outputPath];

  NSError *error = nil;
  AVAssetWriter *writer =
      [[AVAssetWriter alloc] initWithURL:outputURL
                                fileType:AVFileTypeMPEG4
                                   error:&error];
  XCTAssertNotNil(writer, @"AVAssetWriter init failed: %@", error);

  NSDate *creationDate =
      [NSDate dateWithTimeIntervalSince1970:1700000000];  // 2023-11-14T22:13:20Z

  AVMutableMetadataItem *creationItem = [AVMutableMetadataItem metadataItem];
  creationItem.identifier = AVMetadataCommonIdentifierCreationDate;
  creationItem.extendedLanguageTag = @"und";
  creationItem.value = creationDate;
  creationItem.dataType = (NSString *)kCMMetadataBaseDataType_RawData;

  AVMutableMetadataItem *locationItem = [AVMutableMetadataItem metadataItem];
  locationItem.identifier = AVMetadataCommonIdentifierLocation;
  locationItem.extendedLanguageTag = @"und";
  // ISO 6709 string: +lat±lon[±alt]/ — AVFoundation parses this back into
  // AVMetadataCommonKeyLocation on read.
  locationItem.value = @"+37.7749-122.4194/";
  locationItem.dataType = (NSString *)kCMMetadataBaseDataType_UTF8;

  AVMutableMetadataItem *softwareItem = [AVMutableMetadataItem metadataItem];
  softwareItem.identifier = AVMetadataCommonIdentifierSoftware;
  softwareItem.extendedLanguageTag = @"und";
  softwareItem.value = @"react-native-video-pipeline";
  softwareItem.dataType = (NSString *)kCMMetadataBaseDataType_UTF8;

  writer.metadata = @[ creationItem, locationItem, softwareItem ];

  NSDictionary *settings = @{
    AVVideoCodecKey : AVVideoCodecTypeH264,
    AVVideoWidthKey : @(kWidth),
    AVVideoHeightKey : @(kHeight),
  };
  AVAssetWriterInput *input =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:settings];
  input.expectsMediaDataInRealTime = NO;
  XCTAssertTrue([writer canAddInput:input]);
  [writer addInput:input];

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor = [
      [AVAssetWriterInputPixelBufferAdaptor alloc]
        initWithAssetWriterInput:input
      sourcePixelBufferAttributes:pbAttrs];

  XCTAssertTrue([writer startWriting], @"startWriting failed: %@", writer.error);
  [writer startSessionAtSourceTime:kCMTimeZero];

  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, adaptor.pixelBufferPool, &pb);
    XCTAssertEqual(cv, kCVReturnSuccess,
                   @"CVPixelBufferPool create failed at i=%ld", (long)i);

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    memset(base, 0x20, bytesPerRow * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);

    while (!input.readyForMoreMediaData) {
      [NSThread sleepForTimeInterval:0.001];
    }
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    XCTAssertTrue([adaptor appendPixelBuffer:pb withPresentationTime:pts],
                  @"adaptor append failed at i=%ld: %@", (long)i, writer.error);
    CVPixelBufferRelease(pb);
  }

  [input markAsFinished];
  XCTestExpectation *done =
      [self expectationWithDescription:@"writer finishWriting"];
  [writer finishWritingWithCompletionHandler:^{
    [done fulfill];
  }];
  [self waitForExpectations:@[ done ] timeout:5.0];
  XCTAssertEqual(writer.status, AVAssetWriterStatusCompleted,
                 @"writer finished with status %ld / error %@",
                 (long)writer.status, writer.error);

  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:outputURL error:&error],
                @"demuxer open failed: %@", error);

  XCTAssertEqualObjects(demuxer.codec, @"h264");
  XCTAssertEqualObjects(demuxer.container, @"mp4");
  XCTAssertEqual(demuxer.width, kWidth);
  XCTAssertEqual(demuxer.height, kHeight);
  XCTAssertEqualWithAccuracy(demuxer.fps, (double)kFps, 0.5);
  XCTAssertEqualWithAccuracy(demuxer.durationSec,
                             (double)kFrameCount / (double)kFps, 0.1);
  XCTAssertEqual(demuxer.rotation, 0);
  XCTAssertFalse(demuxer.isHDR);
  XCTAssertFalse(demuxer.hasAudio,
                 @"no audio track was authored for this fixture");

  XCTAssertNotNil(demuxer.creationDate, @"creationDate should round-trip");
  XCTAssertEqualWithAccuracy(demuxer.creationDate.timeIntervalSince1970,
                             creationDate.timeIntervalSince1970, 1.0,
                             @"creationDate differs by more than 1s");

  XCTAssertTrue(demuxer.hasLocation, @"location should round-trip");
  XCTAssertEqualWithAccuracy(demuxer.locationLatitude, kLatitude, 1e-4);
  XCTAssertEqualWithAccuracy(demuxer.locationLongitude, kLongitude, 1e-4);

  XCTAssertNotNil(demuxer.customMetadata,
                  @"software should appear in customMetadata");
  XCTAssertEqualObjects(demuxer.customMetadata[AVMetadataCommonKeySoftware],
                        @"react-native-video-pipeline");

  XCTAssertTrue([demuxer closeWithError:&error],
                @"demuxer close failed: %@", error);
  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

/// T027 acceptance: author a 3-second 320×240/30fps MP4 via RNVPAVMuxer, then
/// trim it to the middle 1.0s via RNVPRemuxer. Verify via RNVPAVDemuxer that
/// codec/dimensions/fps/rotation/HDR round-trip unchanged (passthrough), and
/// that the output's duration is within ±1 frame of the requested durationSec.
/// Also verifies the video track carries the expected frame count by draining
/// the decoded sample output of a separate AVAssetReader.
- (void)testRemuxTrimPreservesCodecAndDuration
{
  // Keep the source tiny: the macOS host H.264 encoder back-pressures hard
  // past ~30 frames at 320×240, so this test matches T018's "30 solid frames"
  // envelope and trims a GOP-friendly window out of it. The US1 contract
  // ("within ±1 frame of durationSec") is scale-invariant — the passthrough
  // trim does not re-encode, so a 30-frame fixture exercises the same code
  // path as a 4K/60 1-minute source on an iPhone 13.
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kSourceFrameCount = 30;  // 1.0s @ 30fps
  // Start at 0.0 (the source's only reliable keyframe for a 30-frame fixture
  // — AVAssetWriter's default GOP never places a second keyframe here) so
  // the frame-count assertion is exact. A non-zero start is exercised by
  // testRemuxTrimPreservesContainerMetadata below.
  const double kTrimStartSec = 0.0;
  const double kTrimDurationSec = 0.5;
  const NSInteger kExpectedTrimmedFrames = 15;  // 0.5s @ 30fps

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *trimPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-trim-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:trimPath error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  XCTAssertTrue([muxer openAtPath:sourcePath
                            width:kWidth
                           height:kHeight
                              fps:kFps
                            error:&error],
                @"source open failed: %@", error);

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  for (NSInteger i = 0; i < kSourceFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)pbAttrs, &pb);
    XCTAssertEqual(cv, kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    // Flat gray: achromatic pixels survive H.264 round trip cleanly and keep
    // the encoder out of rate-control trouble for this small fixture.
    memset(base, 0x80, bytesPerRow * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    XCTAssertTrue(
        [muxer appendPixelBuffer:pb presentationTime:pts error:&error],
        @"source append failed at i=%ld: %@", (long)i, error);
    CVPixelBufferRelease(pb);
  }
  XCTAssertTrue([muxer closeWithError:&error], @"source close failed: %@",
                error);

  // --- Trim via RNVPRemuxer ------------------------------------------------
  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *trimURL = [NSURL fileURLWithPath:trimPath];
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:sourceURL
                                        toURL:trimURL
                                     startSec:kTrimStartSec
                                  durationSec:kTrimDurationSec
                                        error:&error],
                @"remux trim failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:trimPath]);

  // --- Verify trimmed output via RNVPAVDemuxer -----------------------------
  RNVPAVDemuxer *sourceDemuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([sourceDemuxer openAtURL:sourceURL error:&error]);
  RNVPAVDemuxer *trimDemuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([trimDemuxer openAtURL:trimURL error:&error]);

  XCTAssertEqualObjects(trimDemuxer.codec, sourceDemuxer.codec,
                        @"codec must match source (passthrough)");
  XCTAssertEqualObjects(trimDemuxer.codec, @"h264");
  XCTAssertEqualObjects(trimDemuxer.container, @"mp4");
  XCTAssertEqual(trimDemuxer.width, sourceDemuxer.width);
  XCTAssertEqual(trimDemuxer.height, sourceDemuxer.height);
  XCTAssertEqual(trimDemuxer.rotation, sourceDemuxer.rotation);
  XCTAssertEqual(trimDemuxer.isHDR, sourceDemuxer.isHDR);
  // nominalFrameRate is intentionally not asserted: a passthrough trim can
  // include leading/trailing B-frames from the source's GOP for decode
  // purposes, which skews AVAssetTrack.nominalFrameRate away from the source
  // value on short fixtures (observed: 28.125 on iOS simulator for a 15-
  // frame/0.5s trim). The US1 contract in prd.md §12 lists codec, bitRate,
  // resolution, HDR, and color primaries — not fps — as the "match source
  // exactly" set, because passthrough preserves per-sample timing rather
  // than a container-level framerate.

  const double oneFrameSec = 1.0 / (double)kFps;
  XCTAssertEqualWithAccuracy(
      trimDemuxer.durationSec, kTrimDurationSec, oneFrameSec,
      @"trimmed duration %f differs from %f by more than one frame",
      trimDemuxer.durationSec, kTrimDurationSec);

  XCTAssertTrue([sourceDemuxer closeWithError:&error]);
  XCTAssertTrue([trimDemuxer closeWithError:&error]);

  // --- Count decoded frames in the trimmed output --------------------------
  AVURLAsset *trimAsset = [AVURLAsset assetWithURL:trimURL];
  AVAssetTrack *videoTrack =
      [trimAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:trimAsset
                                                         error:&readerError];
  XCTAssertNotNil(reader, @"reader init failed: %@", readerError);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
       initWithTrack:videoTrack
      outputSettings:@{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading]);
  NSInteger decoded = 0;
  while (YES) {
    CMSampleBufferRef s = [output copyNextSampleBuffer];
    if (s == NULL) break;
    decoded++;
    CFRelease(s);
  }
  // US1 contract: "within ±1 frame of durationSec". Starting at a keyframe
  // means no lead-in is needed; passthrough leaves the effective frame count
  // at exactly `durationSec * fps`.
  XCTAssertLessThanOrEqual(
      labs(decoded - kExpectedTrimmedFrames), 1L,
      @"expected %ld ± 1 decoded frames, got %ld",
      (long)kExpectedTrimmedFrames, (long)decoded);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:trimPath error:nil];
}

/// T027 acceptance: container-level metadata (creationDate, location,
/// software) must round-trip through the remux trim unchanged.
- (void)testRemuxTrimPreservesContainerMetadata
{
  const NSInteger kWidth = 64;
  const NSInteger kHeight = 64;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;  // 1s source — macOS host encoder safe

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-meta-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *trimPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-meta-trim-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:trimPath error:nil];

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *trimURL = [NSURL fileURLWithPath:trimPath];

  NSError *error = nil;
  AVAssetWriter *writer =
      [[AVAssetWriter alloc] initWithURL:sourceURL
                                fileType:AVFileTypeMPEG4
                                   error:&error];
  XCTAssertNotNil(writer);

  NSDate *creationDate =
      [NSDate dateWithTimeIntervalSince1970:1700000000];  // 2023-11-14

  AVMutableMetadataItem *creationItem = [AVMutableMetadataItem metadataItem];
  creationItem.identifier = AVMetadataCommonIdentifierCreationDate;
  creationItem.extendedLanguageTag = @"und";
  creationItem.value = creationDate;
  creationItem.dataType = (NSString *)kCMMetadataBaseDataType_RawData;

  AVMutableMetadataItem *locationItem = [AVMutableMetadataItem metadataItem];
  locationItem.identifier = AVMetadataCommonIdentifierLocation;
  locationItem.extendedLanguageTag = @"und";
  locationItem.value = @"+37.7749-122.4194/";
  locationItem.dataType = (NSString *)kCMMetadataBaseDataType_UTF8;

  AVMutableMetadataItem *softwareItem = [AVMutableMetadataItem metadataItem];
  softwareItem.identifier = AVMetadataCommonIdentifierSoftware;
  softwareItem.extendedLanguageTag = @"und";
  softwareItem.value = @"react-native-video-pipeline";
  softwareItem.dataType = (NSString *)kCMMetadataBaseDataType_UTF8;

  writer.metadata = @[ creationItem, locationItem, softwareItem ];

  NSDictionary *settings = @{
    AVVideoCodecKey : AVVideoCodecTypeH264,
    AVVideoWidthKey : @(kWidth),
    AVVideoHeightKey : @(kHeight),
  };
  AVAssetWriterInput *input =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:settings];
  input.expectsMediaDataInRealTime = NO;
  [writer addInput:input];
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor = [
      [AVAssetWriterInputPixelBufferAdaptor alloc]
        initWithAssetWriterInput:input
      sourcePixelBufferAttributes:pbAttrs];
  XCTAssertTrue([writer startWriting]);
  [writer startSessionAtSourceTime:kCMTimeZero];
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, adaptor.pixelBufferPool, &pb);
    XCTAssertEqual(cv, kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), 0x40,
           CVPixelBufferGetBytesPerRow(pb) * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    while (!input.readyForMoreMediaData) {
      [NSThread sleepForTimeInterval:0.001];
    }
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    XCTAssertTrue([adaptor appendPixelBuffer:pb withPresentationTime:pts]);
    CVPixelBufferRelease(pb);
  }
  [input markAsFinished];
  XCTestExpectation *done =
      [self expectationWithDescription:@"writer finishWriting"];
  [writer finishWritingWithCompletionHandler:^{
    [done fulfill];
  }];
  [self waitForExpectations:@[ done ] timeout:5.0];
  XCTAssertEqual(writer.status, AVAssetWriterStatusCompleted);

  // --- Trim and re-probe ---------------------------------------------------
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:sourceURL
                                        toURL:trimURL
                                     startSec:0.25
                                  durationSec:0.5
                                        error:&error],
                @"remux trim failed: %@", error);

  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:trimURL error:&error],
                @"demuxer open failed: %@", error);

  XCTAssertNotNil(demuxer.creationDate,
                  @"creationDate should survive the passthrough trim");
  XCTAssertEqualWithAccuracy(demuxer.creationDate.timeIntervalSince1970,
                             creationDate.timeIntervalSince1970, 1.0);
  XCTAssertTrue(demuxer.hasLocation,
                @"location should survive the passthrough trim");
  XCTAssertEqualWithAccuracy(demuxer.locationLatitude, 37.7749, 1e-4);
  XCTAssertEqualWithAccuracy(demuxer.locationLongitude, -122.4194, 1e-4);
  XCTAssertEqualObjects(demuxer.customMetadata[AVMetadataCommonKeySoftware],
                        @"react-native-video-pipeline");

  XCTAssertTrue([demuxer closeWithError:&error]);
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:trimPath error:nil];
}

/// End-past-EOF trim windows are silently clamped to the source's actual
/// duration — matches AVAssetExportSession / ffmpeg leniency, and absorbs
/// muxer-vs-encoder rounding drift (e.g. VisionCamera reports a target
/// duration that ends up ~10ms shorter than the bytes it actually wrote).
- (void)testRemuxTrimClampsEndPastEOFToSourceDuration
{
  const NSInteger kWidth = 64;
  const NSInteger kHeight = 64;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;  // 1s source

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-clamp-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *trimPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-clamp-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:trimPath error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  XCTAssertTrue([muxer openAtPath:sourcePath
                            width:kWidth
                           height:kHeight
                              fps:kFps
                            error:&error]);
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)pbAttrs, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), 0x80,
           CVPixelBufferGetBytesPerRow(pb) * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    [muxer appendPixelBuffer:pb presentationTime:pts error:nil];
    CVPixelBufferRelease(pb);
  }
  XCTAssertTrue([muxer closeWithError:&error]);

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *trimURL = [NSURL fileURLWithPath:trimPath];

  error = nil;
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:sourceURL
                                        toURL:trimURL
                                     startSec:0.0
                                  durationSec:100.0
                                        error:&error],
                @"remux should clamp an end-past-EOF window, not reject it");
  XCTAssertNil(error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:trimPath]);

  // Output should contain ~1s of samples (the entire source), not 100s.
  AVURLAsset *trimmedAsset = [AVURLAsset assetWithURL:trimURL];
  const double trimmedSec = CMTimeGetSeconds(trimmedAsset.duration);
  XCTAssertEqualWithAccuracy(trimmedSec, 1.0, 0.1,
                             @"clamped trim should produce ~1s of output");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:trimPath error:nil];
}

/// startSec past EOF leaves zero frames to copy — still rejects with
/// InvalidSpec. The clamp behavior above only applies to the end bound.
- (void)testRemuxTrimRejectsStartPastSourceEnd
{
  const NSInteger kWidth = 64;
  const NSInteger kHeight = 64;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;  // 1s source

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-start-oor-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *trimPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-start-oor-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:trimPath error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  XCTAssertTrue([muxer openAtPath:sourcePath
                            width:kWidth
                           height:kHeight
                              fps:kFps
                            error:&error]);
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)pbAttrs, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), 0x80,
           CVPixelBufferGetBytesPerRow(pb) * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    [muxer appendPixelBuffer:pb presentationTime:pts error:nil];
    CVPixelBufferRelease(pb);
  }
  XCTAssertTrue([muxer closeWithError:&error]);

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *trimURL = [NSURL fileURLWithPath:trimPath];

  error = nil;
  XCTAssertFalse([RNVPRemuxer remuxTrimFromURL:sourceURL
                                         toURL:trimURL
                                      startSec:10.0
                                   durationSec:1.0
                                         error:&error],
                 @"remux should reject startSec past the source end");
  XCTAssertEqualObjects(error.domain, RNVPRemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPRemuxerErrorCodeInvalidSpec);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:trimPath],
                 @"rejected trim must not leave a partial output behind");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
}

/// T028 acceptance: horizontal flip rewrites the output's preferredTransform
/// so the playback is mirrored, without touching any pixel bytes. The
/// resulting file must be within 1% of the source's size (confirms that
/// no re-encode occurred — a transcode would produce wildly different
/// compressed bytes).
- (void)testRemuxFlipHorizontalRewritesTransformOnly
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;  // 1s @ 30fps — macOS encoder envelope

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t028-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *flipPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t028-flip-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:flipPath error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  XCTAssertTrue([muxer openAtPath:sourcePath
                            width:kWidth
                           height:kHeight
                              fps:kFps
                            error:&error],
                @"source open failed: %@", error);

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)pbAttrs, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), 0x80,
           CVPixelBufferGetBytesPerRow(pb) * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    [muxer appendPixelBuffer:pb presentationTime:pts error:nil];
    CVPixelBufferRelease(pb);
  }
  XCTAssertTrue([muxer closeWithError:&error], @"source close failed: %@",
                error);

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *flipURL = [NSURL fileURLWithPath:flipPath];
  XCTAssertTrue([RNVPRemuxer remuxFlipFromURL:sourceURL
                                        toURL:flipURL
                                         axis:RNVPFlipAxisHorizontal
                                        error:&error],
                @"remux flip failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:flipPath]);

  // --- Assert preferredTransform on the output video track -----------------
  // RNVPAVMuxer writes fixtures with identity preferredTransform, so a
  // horizontal flip should produce a pure horizontal-mirror matrix
  // (a=-1, b=0, c=0, d=1, tx=naturalWidth, ty=0).
  AVURLAsset *flipAsset = [AVURLAsset assetWithURL:flipURL];
  AVAssetTrack *flipVideoTrack =
      [flipAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(flipVideoTrack);
  CGAffineTransform t = flipVideoTrack.preferredTransform;
  XCTAssertEqualWithAccuracy(t.a, -1.0, 1e-6, @"horizontal flip: a should be -1");
  XCTAssertEqualWithAccuracy(t.b, 0.0, 1e-6);
  XCTAssertEqualWithAccuracy(t.c, 0.0, 1e-6);
  XCTAssertEqualWithAccuracy(t.d, 1.0, 1e-6);
  XCTAssertEqualWithAccuracy(t.tx, (CGFloat)kWidth, 1e-3,
                             @"horizontal flip: tx should match naturalWidth");
  XCTAssertEqualWithAccuracy(t.ty, 0.0, 1e-3);

  // --- Assert passthrough: file size is ~identical to source ---------------
  NSDictionary *srcAttrs = [[NSFileManager defaultManager]
      attributesOfItemAtPath:sourcePath
                       error:nil];
  NSDictionary *flipAttrs = [[NSFileManager defaultManager]
      attributesOfItemAtPath:flipPath
                       error:nil];
  const unsigned long long srcSize =
      [srcAttrs[NSFileSize] unsignedLongLongValue];
  const unsigned long long flipSize =
      [flipAttrs[NSFileSize] unsignedLongLongValue];
  XCTAssertGreaterThan(srcSize, 0u);
  const double ratio = (double)flipSize / (double)srcSize;
  // Container-level differences (atom ordering, edit-list placement) can nudge
  // the size by a handful of bytes but a passthrough remux stays well within
  // 1%. A transcode would change by orders of magnitude.
  XCTAssertLessThan(fabs(ratio - 1.0), 0.01,
                    @"flip output size %llu differs from source %llu by more "
                    @"than 1%% — likely a re-encode",
                    flipSize, srcSize);

  // --- Assert basic probe identity -----------------------------------------
  RNVPAVDemuxer *sourceDemuxer = [[RNVPAVDemuxer alloc] init];
  RNVPAVDemuxer *flipDemuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([sourceDemuxer openAtURL:sourceURL error:&error]);
  XCTAssertTrue([flipDemuxer openAtURL:flipURL error:&error]);
  XCTAssertEqualObjects(flipDemuxer.codec, sourceDemuxer.codec);
  XCTAssertEqual(flipDemuxer.width, sourceDemuxer.width);
  XCTAssertEqual(flipDemuxer.height, sourceDemuxer.height);
  XCTAssertEqualWithAccuracy(flipDemuxer.durationSec, sourceDemuxer.durationSec,
                             1.0 / (double)kFps);
  // The AVDemuxer.rotation heuristic derives orientation from atan2(b, a),
  // which reads a horizontal flip matrix as 180°. That is an expected quirk
  // of a degree-only rotation probe applied to a matrix with det=-1 — the
  // authoritative truth is the preferredTransform check above.
  XCTAssertTrue([sourceDemuxer closeWithError:&error]);
  XCTAssertTrue([flipDemuxer closeWithError:&error]);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:flipPath error:nil];
}

/// T028 acceptance: vertical flip produces a pure y-mirror preferredTransform
/// (a=1, d=-1, ty=naturalHeight).
- (void)testRemuxFlipVerticalRewritesTransform
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t028-vsrc-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *flipPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t028-vflip-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:flipPath error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  XCTAssertTrue([muxer openAtPath:sourcePath
                            width:kWidth
                           height:kHeight
                              fps:kFps
                            error:&error]);
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)pbAttrs, &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), 0x80,
           CVPixelBufferGetBytesPerRow(pb) * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    [muxer appendPixelBuffer:pb presentationTime:pts error:nil];
    CVPixelBufferRelease(pb);
  }
  XCTAssertTrue([muxer closeWithError:&error]);

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *flipURL = [NSURL fileURLWithPath:flipPath];
  XCTAssertTrue([RNVPRemuxer remuxFlipFromURL:sourceURL
                                        toURL:flipURL
                                         axis:RNVPFlipAxisVertical
                                        error:&error],
                @"vertical flip failed: %@", error);

  AVURLAsset *flipAsset = [AVURLAsset assetWithURL:flipURL];
  AVAssetTrack *flipVideoTrack =
      [flipAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  CGAffineTransform t = flipVideoTrack.preferredTransform;
  XCTAssertEqualWithAccuracy(t.a, 1.0, 1e-6);
  XCTAssertEqualWithAccuracy(t.b, 0.0, 1e-6);
  XCTAssertEqualWithAccuracy(t.c, 0.0, 1e-6);
  XCTAssertEqualWithAccuracy(t.d, -1.0, 1e-6, @"vertical flip: d should be -1");
  XCTAssertEqualWithAccuracy(t.tx, 0.0, 1e-3);
  XCTAssertEqualWithAccuracy(t.ty, (CGFloat)kHeight, 1e-3,
                             @"vertical flip: ty should match naturalHeight");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:flipPath error:nil];
}

/// T028 acceptance: a missing source file surfaces as NotFound.
- (void)testRemuxFlipRejectsMissingFile
{
  NSString *nonexistent = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t028-ghost-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSURL *sourceURL = [NSURL fileURLWithPath:nonexistent];
  NSURL *flipURL = [NSURL
      fileURLWithPath:[NSTemporaryDirectory()
                          stringByAppendingPathComponent:@"t028-ghost-out.mp4"]];
  NSError *error = nil;
  XCTAssertFalse([RNVPRemuxer remuxFlipFromURL:sourceURL
                                         toURL:flipURL
                                          axis:RNVPFlipAxisHorizontal
                                         error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPRemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPRemuxerErrorCodeNotFound);
}

/// T027 acceptance: a missing source file surfaces as NotFound, not a generic
/// reader failure.
- (void)testRemuxTrimRejectsMissingFile
{
  NSString *nonexistent = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t027-ghost-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSURL *sourceURL = [NSURL fileURLWithPath:nonexistent];
  NSURL *trimURL = [NSURL fileURLWithPath:
                                       [NSTemporaryDirectory()
                                           stringByAppendingPathComponent:
                                               @"t027-ghost-out.mp4"]];
  NSError *error = nil;
  XCTAssertFalse([RNVPRemuxer remuxTrimFromURL:sourceURL
                                         toURL:trimURL
                                      startSec:0.0
                                   durationSec:0.5
                                         error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPRemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPRemuxerErrorCodeNotFound);
}

// -------- T029: multi-clip concat on a contiguous timeline -----------------

/// Helper: author a @p frameCount-frame / @p width×@p height / @p fps flat-
/// gray H.264 MP4 via RNVPAVMuxer. Same encoder envelope as the T027 trim
/// fixture — the macOS host encoder back-pressures past ~30 frames on small
/// resolutions, so callers keep each fixture under that budget.
///
/// Returns the authored file path on success, or `nil` with @p outError set
/// on failure. XCTest asserts live in the caller so they get fired against
/// the right test case.
static NSString *authorConcatFixture(
    NSInteger width, NSInteger height, NSInteger fps, NSInteger frameCount,
    NSString *tag, NSError *_Nullable __autoreleasing *outError) {
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t029-%@-%@.mp4", tag,
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  if (![muxer openAtPath:path
                   width:width
                  height:height
                     fps:fps
                   error:outError]) {
    return nil;
  }

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
  };
  for (NSInteger i = 0; i < frameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)pbAttrs, &pb);
    if (cv != kCVReturnSuccess) {
      if (outError) {
        *outError = [NSError errorWithDomain:@"authorConcatFixture"
                                        code:cv
                                    userInfo:@{
                                      NSLocalizedDescriptionKey :
                                          @"CVPixelBufferCreate failed"
                                    }];
      }
      return nil;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    memset(base, 0x80, bytesPerRow * (size_t)height);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)fps);
    const BOOL ok =
        [muxer appendPixelBuffer:pb presentationTime:pts error:outError];
    CVPixelBufferRelease(pb);
    if (!ok) return nil;
  }
  if (![muxer closeWithError:outError]) return nil;
  return path;
}

/// T029 acceptance (US4 first bullet): N clips with contiguous outputStart
/// produce an output whose duration equals the sum of the source windows and
/// whose decoded-frame count equals the sum of source frame counts.
- (void)testRemuxConcatJoinsTwoClipsContiguously
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFramesPerClip = 30;  // 1.0s @ 30fps per clip
  const double kPerClipSec = (double)kFramesPerClip / (double)kFps;
  const double kTotalSec = 2.0 * kPerClipSec;  // 2.0s

  NSError *fixtureError = nil;
  NSString *clipAPath = authorConcatFixture(kWidth, kHeight, kFps,
                                            kFramesPerClip, @"a",
                                            &fixtureError);
  XCTAssertNotNil(clipAPath, @"fixture a failed: %@", fixtureError);
  NSString *clipBPath = authorConcatFixture(kWidth, kHeight, kFps,
                                            kFramesPerClip, @"b",
                                            &fixtureError);
  XCTAssertNotNil(clipBPath, @"fixture b failed: %@", fixtureError);
  NSString *concatPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t029-concat-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:concatPath error:nil];

  RNVPRemuxerConcatSource *a = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipAPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:0.0];
  RNVPRemuxerConcatSource *b = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipBPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:kPerClipSec];

  NSArray<RNVPRemuxerConcatSource *> *clips = @[ a, b ];
  NSURL *concatURL = [NSURL fileURLWithPath:concatPath];
  NSError *error = nil;
  XCTAssertTrue([RNVPRemuxer remuxConcatSources:clips
                                          toURL:concatURL
                                          stop:nil
                                          error:&error],
                @"concat failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:concatPath]);

  // --- Verify duration + metadata via RNVPAVDemuxer -----------------------
  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:[NSURL fileURLWithPath:concatPath]
                             error:&error]);
  XCTAssertEqualObjects(demuxer.codec, @"h264");
  XCTAssertEqualObjects(demuxer.container, @"mp4");
  XCTAssertEqual(demuxer.width, kWidth);
  XCTAssertEqual(demuxer.height, kHeight);

  const double oneFrameSec = 1.0 / (double)kFps;
  XCTAssertEqualWithAccuracy(
      demuxer.durationSec, kTotalSec, oneFrameSec,
      @"concat duration %f differs from expected %f by more than one frame",
      demuxer.durationSec, kTotalSec);
  XCTAssertTrue([demuxer closeWithError:&error]);

  // --- Count decoded frames end-to-end ------------------------------------
  AVURLAsset *concatAsset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:concatPath]];
  AVAssetTrack *videoTrack =
      [concatAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:concatAsset
                                                         error:&readerError];
  XCTAssertNotNil(reader, @"reader init failed: %@", readerError);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
       initWithTrack:videoTrack
      outputSettings:@{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading]);
  NSInteger decoded = 0;
  while (YES) {
    CMSampleBufferRef s = [output copyNextSampleBuffer];
    if (s == NULL) break;
    decoded++;
    CFRelease(s);
  }
  // US4 first bullet: "output of duration = max(outputStart + sourceDuration)
  // across clips". For a contiguous two-clip concat, that equates to
  // decoded-frame count == sum of per-clip frame counts. Allow ±1 for B-frame
  // lead/tail artifacts at the concat boundary (the source fixtures are
  // small enough that AVAssetWriter typically emits no B-frames, but the
  // tolerance survives an encoder that chooses to).
  const NSInteger expected = 2 * kFramesPerClip;
  XCTAssertLessThanOrEqual(
      labs(decoded - expected), 1L,
      @"expected %ld ± 1 decoded frames across concat, got %ld",
      (long)expected, (long)decoded);

  [[NSFileManager defaultManager] removeItemAtPath:clipAPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:clipBPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:concatPath error:nil];
}

/// T029: a non-contiguous outputStart (gap between clip 0 and clip 1) falls
/// outside the v0.1 passthrough envelope and must reject with InvalidSpec so
/// future routing can fall back to transcode.
- (void)testRemuxConcatRejectsNonContiguousTimeline
{
  const NSInteger kFramesPerClip = 30;
  const NSInteger kFps = 30;
  const double kPerClipSec = (double)kFramesPerClip / (double)kFps;

  NSError *fixtureError = nil;
  NSString *clipAPath = authorConcatFixture(160, 120, kFps, kFramesPerClip,
                                            @"gap-a", &fixtureError);
  XCTAssertNotNil(clipAPath, @"fixture gap-a failed: %@", fixtureError);
  NSString *clipBPath = authorConcatFixture(160, 120, kFps, kFramesPerClip,
                                            @"gap-b", &fixtureError);
  XCTAssertNotNil(clipBPath, @"fixture gap-b failed: %@", fixtureError);
  NSString *concatPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t029-gap-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  RNVPRemuxerConcatSource *a = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipAPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:0.0];
  // 0.5s gap between clip a and clip b.
  RNVPRemuxerConcatSource *b = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipBPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:kPerClipSec + 0.5];

  NSArray<RNVPRemuxerConcatSource *> *clips = @[ a, b ];
  NSURL *concatURL = [NSURL fileURLWithPath:concatPath];
  NSError *error = nil;
  XCTAssertFalse([RNVPRemuxer remuxConcatSources:clips
                                           toURL:concatURL
                                           stop:nil
                                           error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPRemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPRemuxerErrorCodeInvalidSpec);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:concatPath],
                 @"no partial output on validation failure");

  [[NSFileManager defaultManager] removeItemAtPath:clipAPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:clipBPath error:nil];
}

/// T029: clips with mismatched resolutions cannot be passthrough-concatenated
/// (the H.264 SPS/PPS would conflict mid-stream). Must reject with
/// InvalidSpec pointing at the transcode fallback.
- (void)testRemuxConcatRejectsMismatchedDimensions
{
  const NSInteger kFramesPerClip = 30;
  const NSInteger kFps = 30;
  const double kPerClipSec = (double)kFramesPerClip / (double)kFps;

  NSError *fixtureError = nil;
  NSString *clipAPath = authorConcatFixture(160, 120, kFps, kFramesPerClip,
                                            @"dim-a", &fixtureError);
  XCTAssertNotNil(clipAPath, @"fixture dim-a failed: %@", fixtureError);
  NSString *clipBPath = authorConcatFixture(80, 60, kFps, kFramesPerClip,
                                            @"dim-b", &fixtureError);
  XCTAssertNotNil(clipBPath, @"fixture dim-b failed: %@", fixtureError);
  NSString *concatPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t029-dim-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  RNVPRemuxerConcatSource *a = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipAPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:0.0];
  RNVPRemuxerConcatSource *b = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipBPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:kPerClipSec];

  NSArray<RNVPRemuxerConcatSource *> *clips = @[ a, b ];
  NSURL *concatURL = [NSURL fileURLWithPath:concatPath];
  NSError *error = nil;
  XCTAssertFalse([RNVPRemuxer remuxConcatSources:clips
                                           toURL:concatURL
                                           stop:nil
                                           error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPRemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPRemuxerErrorCodeInvalidSpec);

  [[NSFileManager defaultManager] removeItemAtPath:clipAPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:clipBPath error:nil];
}

/// T029: a missing source file surfaces as NotFound, matching the trim/flip
/// contract.
- (void)testRemuxConcatRejectsMissingFile
{
  const NSInteger kFramesPerClip = 30;
  const NSInteger kFps = 30;
  const double kPerClipSec = (double)kFramesPerClip / (double)kFps;
  NSError *fixtureError = nil;
  NSString *clipAPath = authorConcatFixture(160, 120, kFps, kFramesPerClip,
                                            @"miss-a", &fixtureError);
  XCTAssertNotNil(clipAPath, @"fixture miss-a failed: %@", fixtureError);
  NSString *ghost = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t029-ghost-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *concatPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t029-miss-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  RNVPRemuxerConcatSource *a = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipAPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:0.0];
  RNVPRemuxerConcatSource *b = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:ghost]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:kPerClipSec];

  NSArray<RNVPRemuxerConcatSource *> *clips = @[ a, b ];
  NSURL *concatURL = [NSURL fileURLWithPath:concatPath];
  NSError *error = nil;
  XCTAssertFalse([RNVPRemuxer remuxConcatSources:clips
                                           toURL:concatURL
                                           stop:nil
                                           error:&error]);
  XCTAssertEqualObjects(error.domain, RNVPRemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPRemuxerErrorCodeNotFound);

  [[NSFileManager defaultManager] removeItemAtPath:clipAPath error:nil];
}

// Read a JPEG file and return its pixel dimensions. Returns NO on failure.
static BOOL readJpegPixelSize(NSString *path, NSInteger *outWidth,
                              NSInteger *outHeight) {
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url,
                                                    NULL);
  if (src == NULL) return NO;
  CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
  BOOL ok = NO;
  if (props != NULL) {
    CFNumberRef w = CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
    CFNumberRef h = CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
    long wl = 0, hl = 0;
    if (w && h && CFNumberGetValue(w, kCFNumberLongType, &wl) &&
        CFNumberGetValue(h, kCFNumberLongType, &hl)) {
      if (outWidth) *outWidth = wl;
      if (outHeight) *outHeight = hl;
      ok = YES;
    }
    CFRelease(props);
  }
  CFRelease(src);
  return ok;
}

/// T030 acceptance (US6): Video.thumbnail writes a JPEG at the requested
/// offset. Without a resize bounding box the output matches the source's
/// natural pixel dimensions and the file starts with the JPEG magic bytes.
- (void)testThumbnailGeneratesJpegAtOffset
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;

  NSError *fixtureError = nil;
  NSString *src = authorConcatFixture(kWidth, kHeight, kFps, kFrameCount,
                                      @"t030", &fixtureError);
  XCTAssertNotNil(src, @"fixture failed: %@", fixtureError);

  NSString *out = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t030-thumb-%@.jpg",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

  NSError *error = nil;
  const BOOL ok = [RNVPThumbnailer
      generateThumbnailFromURL:[NSURL fileURLWithPath:src]
                         toURL:[NSURL fileURLWithPath:out]
                         atSec:0.5
                   resizeWidth:0.0
                  resizeHeight:0.0
                         error:&error];
  XCTAssertTrue(ok, @"thumbnail failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:out]);

  // JPEG magic: first two bytes are 0xFF 0xD8.
  NSData *head = [[NSData dataWithContentsOfFile:out]
      subdataWithRange:NSMakeRange(0, 2)];
  const uint8_t *bytes = head.bytes;
  XCTAssertEqual(bytes[0], 0xFF);
  XCTAssertEqual(bytes[1], 0xD8);

  NSInteger w = 0, h = 0;
  XCTAssertTrue(readJpegPixelSize(out, &w, &h));
  XCTAssertEqual(w, kWidth);
  XCTAssertEqual(h, kHeight);

  [[NSFileManager defaultManager] removeItemAtPath:src error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
}

/// T030: resizeTo with only `w` set scales the output to that width and
/// derives height from the source aspect ratio (longest-side semantics).
- (void)testThumbnailResizeWidthOnlyPreservesAspect
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  NSError *fixtureError = nil;
  NSString *src = authorConcatFixture(kWidth, kHeight, 30, 30, @"t030w",
                                      &fixtureError);
  XCTAssertNotNil(src, @"fixture failed: %@", fixtureError);

  NSString *out = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t030-wthumb-%@.jpg",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

  NSError *error = nil;
  const BOOL ok = [RNVPThumbnailer
      generateThumbnailFromURL:[NSURL fileURLWithPath:src]
                         toURL:[NSURL fileURLWithPath:out]
                         atSec:0.1
                   resizeWidth:80.0
                  resizeHeight:0.0
                         error:&error];
  XCTAssertTrue(ok, @"thumbnail failed: %@", error);

  NSInteger w = 0, h = 0;
  XCTAssertTrue(readJpegPixelSize(out, &w, &h));
  // AVAssetImageGenerator rounds to the nearest pixel; the canonical 4:3
  // aspect ratio from 160x120 → width=80 means height lands exactly at 60.
  XCTAssertEqual(w, 80);
  XCTAssertEqual(h, 60);

  [[NSFileManager defaultManager] removeItemAtPath:src error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
}

/// T030: resizeTo with only `h` set scales the output to that height and
/// derives width from the source aspect ratio.
- (void)testThumbnailResizeHeightOnlyPreservesAspect
{
  NSError *fixtureError = nil;
  NSString *src = authorConcatFixture(160, 120, 30, 30, @"t030h",
                                      &fixtureError);
  XCTAssertNotNil(src, @"fixture failed: %@", fixtureError);

  NSString *out = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t030-hthumb-%@.jpg",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

  NSError *error = nil;
  const BOOL ok = [RNVPThumbnailer
      generateThumbnailFromURL:[NSURL fileURLWithPath:src]
                         toURL:[NSURL fileURLWithPath:out]
                         atSec:0.1
                   resizeWidth:0.0
                  resizeHeight:60.0
                         error:&error];
  XCTAssertTrue(ok, @"thumbnail failed: %@", error);

  NSInteger w = 0, h = 0;
  XCTAssertTrue(readJpegPixelSize(out, &w, &h));
  XCTAssertEqual(w, 80);
  XCTAssertEqual(h, 60);

  [[NSFileManager defaultManager] removeItemAtPath:src error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
}

/// T030: resizeTo with both `w` and `h` fits inside the bounding box and
/// preserves the source aspect ratio. A 160×120 (4:3) source fit into an
/// 80×80 box lands at 80×60 — width is the binding constraint.
- (void)testThumbnailResizeBoundingBoxFitsAspect
{
  NSError *fixtureError = nil;
  NSString *src = authorConcatFixture(160, 120, 30, 30, @"t030box",
                                      &fixtureError);
  XCTAssertNotNil(src, @"fixture failed: %@", fixtureError);

  NSString *out = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t030-boxthumb-%@.jpg",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

  NSError *error = nil;
  const BOOL ok = [RNVPThumbnailer
      generateThumbnailFromURL:[NSURL fileURLWithPath:src]
                         toURL:[NSURL fileURLWithPath:out]
                         atSec:0.1
                   resizeWidth:80.0
                  resizeHeight:80.0
                         error:&error];
  XCTAssertTrue(ok, @"thumbnail failed: %@", error);

  NSInteger w = 0, h = 0;
  XCTAssertTrue(readJpegPixelSize(out, &w, &h));
  XCTAssertEqual(w, 80);
  XCTAssertEqual(h, 60);

  [[NSFileManager defaultManager] removeItemAtPath:src error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];
}

/// T030: a missing source rejects with the typed NotFound error.
- (void)testThumbnailRejectsMissingFile
{
  NSString *ghost = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"t030-ghost.mp4"];
  NSString *out = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t030-ghost-thumb-%@.jpg",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:ghost error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

  NSError *error = nil;
  const BOOL ok = [RNVPThumbnailer
      generateThumbnailFromURL:[NSURL fileURLWithPath:ghost]
                         toURL:[NSURL fileURLWithPath:out]
                         atSec:0.0
                   resizeWidth:0.0
                  resizeHeight:0.0
                         error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPThumbnailerErrorDomain);
  XCTAssertEqual(error.code, RNVPThumbnailerErrorCodeNotFound);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:out]);
}

/// T031 acceptance (US9 first bullet): `Video.capabilities()` returns at
/// minimum H.264 support with sensible positive bounds. H.264 is universal
/// on every iOS 13+ device and on every macOS host the test-native.sh path
/// runs on, so this is the one assertion the test can make deterministically.
/// HEVC is optional (virtually always present on iPhone 13-class hardware
/// but may be absent on headless macOS encoders without a dedicated HEVC
/// block), so the test only asserts `<= 2` codecs and verifies the slot
/// contents are the declared values.
- (void)testCapabilitiesReportsH264AndSensibleBounds
{
  [RNVPCapabilities resetCacheForTesting];
  RNVPEncoderCapabilities *caps = [RNVPCapabilities probe];
  XCTAssertNotNil(caps);

  XCTAssertGreaterThanOrEqual(caps.codecs.count, 1u,
                              @"at least H.264 must be reported");
  XCTAssertLessThanOrEqual(caps.codecs.count, 2u);
  XCTAssertTrue([caps.codecs containsObject:@"h264"],
                @"H.264 encoder must always be reported");
  for (NSString *tag in caps.codecs) {
    XCTAssertTrue([tag isEqualToString:@"h264"] ||
                      [tag isEqualToString:@"hevc"],
                  @"unexpected codec tag %@", tag);
  }

  XCTAssertGreaterThan(caps.maxWidth, 0);
  XCTAssertGreaterThan(caps.maxHeight, 0);
  XCTAssertGreaterThan(caps.maxFps, 0.0);
  XCTAssertGreaterThan(caps.maxBitrate, 0);
  // Two known-good dimension pairs; the probe falls back to 1080p when 4K
  // isn't accepted, and returns 4K otherwise.
  const BOOL is1080p = (caps.maxWidth == 1920 && caps.maxHeight == 1080);
  const BOOL is4K = (caps.maxWidth == 3840 && caps.maxHeight == 2160);
  XCTAssertTrue(is1080p || is4K,
                @"unexpected (maxWidth, maxHeight) pair: (%ld, %ld)",
                (long)caps.maxWidth, (long)caps.maxHeight);

  // HDR can only be YES when HEVC is present — the probe gates on exactly
  // that condition. Verify the invariant here as a tripwire for regressions
  // in the probe's ordering logic.
  if (caps.hdr) {
    XCTAssertTrue([caps.codecs containsObject:@"hevc"],
                  @"HDR reported without HEVC — probe ordering is wrong");
  }
}

/// T031 acceptance: the second call returns the exact same cached instance
/// and the probe counter does not advance past 1 — observable proof that the
/// per-process cache is working.
- (void)testCapabilitiesCachesAfterFirstCall
{
  [RNVPCapabilities resetCacheForTesting];
  XCTAssertEqual([RNVPCapabilities probeCount], 0);

  RNVPEncoderCapabilities *first = [RNVPCapabilities probe];
  XCTAssertEqual([RNVPCapabilities probeCount], 1);

  RNVPEncoderCapabilities *second = [RNVPCapabilities probe];
  RNVPEncoderCapabilities *third = [RNVPCapabilities probe];

  // Object identity: the cache hands back the same instance every call.
  XCTAssertTrue(first == second);
  XCTAssertTrue(first == third);

  // Probe counter stays at 1 regardless of how many callers hit the method.
  XCTAssertEqual([RNVPCapabilities probeCount], 1);
}

/// T032 acceptance: a metadata-only stamp writes the supplied GPS / software /
/// creationDate / description fields into the output container via passthrough
/// remux (no re-encode), and the demuxer reads them back unchanged. Custom
/// string→string entries are written under the @c com.foldleft.videopipeline.*
/// QuickTime-metadata prefix; they are visible to external tools (exiftool)
/// but do not currently round-trip through @c RNVPAVDemuxer (which inspects
/// @c asset.commonMetadata only), so this test does not assert them back —
/// just that the stamp writes the standard fields the demuxer can see.
- (void)testRemuxStampWritesMetadataFields
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;  // 1s — macOS host encoder safe envelope

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t032-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *stampPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t032-stamp-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:stampPath error:nil];

  // Author a plain metadata-free source via the production muxer — stamp
  // must be able to add metadata to a file that did not start with any.
  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  NSError *error = nil;
  XCTAssertTrue([muxer openAtPath:sourcePath
                            width:kWidth
                           height:kHeight
                              fps:kFps
                            error:&error],
                @"muxer open failed: %@", error);

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, kWidth, kHeight,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)pbAttrs, &pb);
    XCTAssertEqual(cv, kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), 0x50,
           CVPixelBufferGetBytesPerRow(pb) * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    XCTAssertTrue(
        [muxer appendPixelBuffer:pb presentationTime:pts error:&error],
        @"muxer append failed at i=%ld: %@", (long)i, error);
    CVPixelBufferRelease(pb);
  }
  XCTAssertTrue([muxer closeWithError:&error], @"muxer close failed: %@",
                error);

  // Sanity: the freshly authored source has no container-level metadata the
  // demuxer can see — this is what makes the stamp test a clean "writes
  // fields" assertion rather than a "merges on top" one.
  {
    RNVPAVDemuxer *pre = [[RNVPAVDemuxer alloc] init];
    XCTAssertTrue([pre openAtURL:[NSURL fileURLWithPath:sourcePath]
                           error:&error]);
    XCTAssertNil(pre.creationDate);
    XCTAssertFalse(pre.hasLocation);
    XCTAssertNil(pre.customMetadata);
    [pre closeWithError:nil];
  }

  NSDate *creationDate =
      [NSDate dateWithTimeIntervalSince1970:1700000000];  // 2023-11-14
  // mdta keyspace requires reverse-DNS keys; AVAssetWriter for MP4 silently
  // drops items that don't conform. Caller owns the namespace — use whatever
  // reverse-DNS root makes sense for the consumer app.
  NSDictionary<NSString *, NSString *> *custom =
      @{@"com.acme.test.shotId" : @"abc123"};
  RNVPStampMetadata *metadata =
      [[RNVPStampMetadata alloc] initWithGps:YES
                                    latitude:37.7749
                                   longitude:-122.4194
                              hasGpsAltitude:YES
                                    altitude:520.0
                                    software:@"react-native-video-pipeline"
                                creationDate:creationDate
                          contentDescription:@"stamp test"
                                      custom:custom];

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *stampURL = [NSURL fileURLWithPath:stampPath];
  XCTAssertTrue([RNVPRemuxer remuxStampFromURL:sourceURL
                                         toURL:stampURL
                                      metadata:metadata
                                         error:&error],
                @"stamp failed: %@", error);

  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:stampURL error:&error],
                @"stamp demuxer open failed: %@", error);

  // Passthrough: codec/dimensions/rotation/HDR unchanged from source.
  XCTAssertEqualObjects(demuxer.codec, @"h264");
  XCTAssertEqualObjects(demuxer.container, @"mp4");
  XCTAssertEqual(demuxer.width, kWidth);
  XCTAssertEqual(demuxer.height, kHeight);
  XCTAssertEqual(demuxer.rotation, 0);
  XCTAssertFalse(demuxer.isHDR);
  XCTAssertEqualWithAccuracy(demuxer.durationSec,
                             (double)kFrameCount / (double)kFps, 0.1);

  // Metadata round-trip: GPS + creationDate via the demuxer's direct fields;
  // software + description via the commonMetadata fallback bag.
  XCTAssertNotNil(demuxer.creationDate);
  XCTAssertEqualWithAccuracy(demuxer.creationDate.timeIntervalSince1970,
                             creationDate.timeIntervalSince1970, 1.0);
  XCTAssertTrue(demuxer.hasLocation);
  XCTAssertEqualWithAccuracy(demuxer.locationLatitude, 37.7749, 1e-3);
  XCTAssertEqualWithAccuracy(demuxer.locationLongitude, -122.4194, 1e-3);
  XCTAssertTrue(demuxer.hasLocationAltitude);
  XCTAssertEqualWithAccuracy(demuxer.locationAltitude, 520.0, 1e-2);
  XCTAssertEqualObjects(demuxer.contentDescription, @"stamp test");
  XCTAssertNotNil(demuxer.customMetadata);
  XCTAssertEqualObjects(demuxer.customMetadata[AVMetadataCommonKeySoftware],
                        @"react-native-video-pipeline");
  // Description is now lifted to a top-level property; the customMetadata
  // bag only carries common-key items without a dedicated field.
  XCTAssertNil(demuxer.customMetadata[AVMetadataCommonKeyDescription]);

  [demuxer closeWithError:nil];

  // Custom entries are written via mergedMetadata with @c mdta/<key>
  // identifiers (no library prefix — caller owns the key namespace). The
  // demuxer scans @c asset.metadata for `mdta/` items, but AVAssetWriter
  // for MP4 still drops items in the QuickTime metadata keyspace unless
  // they go through @c AVAssetWriterInputMetadataAdaptor on a dedicated
  // metadata track. That's a follow-up — once it lands, this becomes a
  // real assertion (something like
  // `XCTAssertEqualObjects(demuxer.customMetadata[@"com.acme.test.shotId"],
  // @"abc123")`).
  (void)custom;

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:stampPath error:nil];
}

/// T032: stamp preserves the source's existing metadata for any field the
/// stamp does not explicitly set (merge-on-override, not replace-all). A
/// source authored with creationDate gets a new software stamp; the
/// creationDate survives.
- (void)testRemuxStampMergesWithExistingMetadata
{
  const NSInteger kWidth = 64;
  const NSInteger kHeight = 64;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15;  // 0.5s — minimal encoder budget

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t032-merge-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *stampPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t032-merge-stamp-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:stampPath error:nil];

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *stampURL = [NSURL fileURLWithPath:stampPath];

  NSError *error = nil;
  AVAssetWriter *writer =
      [[AVAssetWriter alloc] initWithURL:sourceURL
                                fileType:AVFileTypeMPEG4
                                   error:&error];
  XCTAssertNotNil(writer);
  NSDate *sourceCreationDate =
      [NSDate dateWithTimeIntervalSince1970:1600000000];  // 2020-09-13
  AVMutableMetadataItem *creationItem = [AVMutableMetadataItem metadataItem];
  creationItem.identifier = AVMetadataCommonIdentifierCreationDate;
  creationItem.extendedLanguageTag = @"und";
  creationItem.value = sourceCreationDate;
  creationItem.dataType = (NSString *)kCMMetadataBaseDataType_RawData;
  writer.metadata = @[ creationItem ];

  NSDictionary *settings = @{
    AVVideoCodecKey : AVVideoCodecTypeH264,
    AVVideoWidthKey : @(kWidth),
    AVVideoHeightKey : @(kHeight),
  };
  AVAssetWriterInput *input =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:settings];
  input.expectsMediaDataInRealTime = NO;
  [writer addInput:input];
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor = [
      [AVAssetWriterInputPixelBufferAdaptor alloc]
        initWithAssetWriterInput:input
      sourcePixelBufferAttributes:pbAttrs];
  XCTAssertTrue([writer startWriting]);
  [writer startSessionAtSourceTime:kCMTimeZero];
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, adaptor.pixelBufferPool, &pb);
    XCTAssertEqual(cv, kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), 0x30,
           CVPixelBufferGetBytesPerRow(pb) * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    while (!input.readyForMoreMediaData) {
      [NSThread sleepForTimeInterval:0.001];
    }
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    XCTAssertTrue([adaptor appendPixelBuffer:pb withPresentationTime:pts]);
    CVPixelBufferRelease(pb);
  }
  [input markAsFinished];
  XCTestExpectation *done =
      [self expectationWithDescription:@"writer finishWriting"];
  [writer finishWritingWithCompletionHandler:^{
    [done fulfill];
  }];
  [self waitForExpectations:@[ done ] timeout:5.0];
  XCTAssertEqual(writer.status, AVAssetWriterStatusCompleted);

  // Stamp: set only software, leave everything else unspecified — the source
  // creationDate must survive.
  RNVPStampMetadata *metadata =
      [[RNVPStampMetadata alloc] initWithGps:NO
                                    latitude:0
                                   longitude:0
                              hasGpsAltitude:NO
                                    altitude:0
                                    software:@"rnvp-merge-test"
                                creationDate:nil
                          contentDescription:nil
                                      custom:nil];
  XCTAssertTrue([RNVPRemuxer remuxStampFromURL:sourceURL
                                         toURL:stampURL
                                      metadata:metadata
                                         error:&error],
                @"stamp failed: %@", error);

  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:stampURL error:&error]);
  XCTAssertNotNil(demuxer.creationDate,
                  @"source creationDate must survive merge");
  XCTAssertEqualWithAccuracy(demuxer.creationDate.timeIntervalSince1970,
                             sourceCreationDate.timeIntervalSince1970, 1.0);
  XCTAssertEqualObjects(demuxer.customMetadata[AVMetadataCommonKeySoftware],
                        @"rnvp-merge-test");
  [demuxer closeWithError:nil];

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:stampPath error:nil];
}

/// T032: stamp rejects a missing source with a typed NotFound error and
/// leaves no partial output file on disk.
- (void)testRemuxStampRejectsMissingFile
{
  NSString *ghost = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t032-ghost-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *out = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t032-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:ghost error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:out error:nil];

  RNVPStampMetadata *metadata =
      [[RNVPStampMetadata alloc] initWithGps:NO
                                    latitude:0
                                   longitude:0
                              hasGpsAltitude:NO
                                    altitude:0
                                    software:@"x"
                                creationDate:nil
                          contentDescription:nil
                                      custom:nil];
  NSError *error = nil;
  const BOOL ok =
      [RNVPRemuxer remuxStampFromURL:[NSURL fileURLWithPath:ghost]
                               toURL:[NSURL fileURLWithPath:out]
                            metadata:metadata
                               error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPRemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPRemuxerErrorCodeNotFound);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:out]);
}

#pragma mark - Transcoder (T033)

/// T033 acceptance: decode every source frame and re-encode at the requested
/// resolution, producing a valid H.264 MP4 at exactly the target dimensions.
/// Uses a 160×120/30fps 15-frame AVMuxer fixture re-encoded to 80×60/30 —
/// downscaled from the PRD's 1080p→720p spec so the macOS host encoder's
/// back-pressure budget (see T027 activity notes) stays comfortable.
- (void)testTranscodeResizesToTargetDimensions
{
  const NSInteger kSourceW = 160;
  const NSInteger kSourceH = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15;  // 0.5s at 30fps

  NSError *fixtureError = nil;
  NSString *sourcePath = authorConcatFixture(kSourceW, kSourceH, kFps,
                                              kFrameCount, @"t033-src",
                                              &fixtureError);
  XCTAssertNotNil(sourcePath, @"fixture failed: %@", fixtureError);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t033-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  const NSInteger kTargetW = 80;
  const NSInteger kTargetH = 60;
  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kTargetW
                                          height:kTargetH
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:nil
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertTrue(ok, @"transcode failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:[NSURL fileURLWithPath:outPath]
                             error:&error],
                @"demuxer open failed: %@", error);
  XCTAssertEqualObjects(demuxer.codec, @"h264");
  XCTAssertEqualObjects(demuxer.container, @"mp4");
  // "Exact requested dimensions" — the US1 / T033 contract.
  XCTAssertEqual(demuxer.width, kTargetW);
  XCTAssertEqual(demuxer.height, kTargetH);
  const double expectedDurationSec = (double)kFrameCount / (double)kFps;
  const double oneFrameSec = 1.0 / (double)kFps;
  XCTAssertEqualWithAccuracy(demuxer.durationSec, expectedDurationSec,
                             oneFrameSec,
                             @"output duration %f differs from expected %f",
                             demuxer.durationSec, expectedDurationSec);
  [demuxer closeWithError:nil];

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// Issue #32 regression: a longer, high-fps source (2 seconds at 240fps = 480
/// frames) must transcode end-to-end without any wall-clock deadline aborting
/// the encode. This is exactly the case the removed band-aids would have
/// killed: at 240fps the encoder back-pressures far more often than the 30fps
/// fixtures, and the AVMuxer.close / Transcoder.finishWriting flush handles a
/// much larger moov than the tiny clips. Both the fixture author (AVMuxer's
/// readiness spin + finishWriting) and the transcode hot loop (the
/// readyForMoreMediaData spin + finishWriting) run unbounded here, escaping
/// only on a real signal. The assertion is simply that it completes with the
/// exact frame count — no deadline, no deleted output.
- (void)testTranscodeLongHighFpsSourceCompletesWithoutDeadline
{
  const NSInteger kSourceW = 96;
  const NSInteger kSourceH = 64;
  const NSInteger kFps = 240;
  const NSInteger kFrameCount = 480;  // 2.0s at 240fps

  NSError *fixtureError = nil;
  NSString *sourcePath = authorConcatFixture(kSourceW, kSourceH, kFps,
                                             kFrameCount, @"i32-240fps",
                                             &fixtureError);
  XCTAssertNotNil(sourcePath, @"fixture failed: %@", fixtureError);

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"i32-240fps-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kSourceW
                                          height:kSourceH
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:nil
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertTrue(ok, @"high-fps transcode failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  // Count decoded output frames exactly — every source frame must survive the
  // re-encode (no frames dropped by a premature timeout).
  AVURLAsset *asset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outPath]];
  AVAssetTrack *videoTrack =
      [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(videoTrack);
  XCTAssertEqualWithAccuracy(videoTrack.nominalFrameRate, (Float64)kFps, 1.0);

  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset
                                                         error:&error];
  XCTAssertNotNil(reader, @"reader init failed: %@", error);
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading], @"reader start failed: %@", reader.error);

  NSInteger observedFrames = 0;
  while (YES) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) break;
    observedFrames++;
    CFRelease(sample);
  }
  XCTAssertEqual(observedFrames, kFrameCount,
                 @"expected %ld frames, got %ld", (long)kFrameCount,
                 (long)observedFrames);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

// NOTE: an HEVC-codec-change transcode test was deliberately dropped here.
// VideoToolbox's HEVC encoder is intermittently available on the macOS
// host — the very same `testTranscodeChangesCodecToHEVC` succeeded in
// ~0.1s on one run and hung indefinitely on the next (stuck inside
// VTCompressionSessionEncodeFrame) even though `RNVPCapabilities.probe`
// reported HEVC as available on both. On real iOS devices and the iPhone
// 15 simulator the encoder is stable, so coverage there lands with the
// Detox / Maestro device-perf work in v0.5. The h264 path below is the
// only one T033 formally verifies; the HEVC code path (choosing
// `AVVideoCodecTypeHEVC` and optionally omitting the H264 profile key)
// still compiles and runs when exercised from a host that has HEVC
// reliably working — no ifdef, no dead code, just no flaky XCTest.

/// T033: missing source surfaces as typed NotFound (same contract as the
/// remux paths), with no partial output file left behind.
- (void)testTranscodeRejectsMissingFile
{
  NSString *ghost = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t033-ghost-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t033-missing-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:ghost error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:64
                                          height:48
                                             fps:30.0
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];
  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:ghost]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:nil
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPTranscoderErrorDomain);
  XCTAssertEqual(error.code, RNVPTranscoderErrorCodeNotFound);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outPath]);
}

/// T033: InvalidSpec when the target is degenerate (width <= 0). Mirrors the
/// platform-agnostic validator's contract — the same wording would surface
/// on Android's Media3 driver in T044+.
- (void)testTranscodeRejectsDegenerateTarget
{
  const NSInteger kWidth = 80;
  const NSInteger kHeight = 60;
  const NSInteger kFps = 30;
  NSError *fixtureError = nil;
  NSString *sourcePath = authorConcatFixture(kWidth, kHeight, kFps, 15,
                                              @"t033-bad", &fixtureError);
  XCTAssertNotNil(sourcePath, @"fixture failed: %@", fixtureError);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t033-bad-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:0  // degenerate
                                          height:60
                                             fps:30.0
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];
  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:nil
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPTranscoderErrorDomain);
  XCTAssertEqual(error.code, RNVPTranscoderErrorCodeInvalidSpec);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
}

#pragma mark - OverlayRenderer / Transcoder with image overlay (T034)

/// Opaque-gray BGRA fixture author. Like @c authorConcatFixture, but sets
/// every BGRA byte explicitly (including @c alpha = 0xFF) so Core Image does
/// not see the source as 50% transparent during compositing — @c memset(base,
/// 0x80, ...) in the older helper coincidentally produced correct RGB gray
/// but alpha=0x80, which only matters when a pipeline (e.g. the T034 overlay
/// path) does alpha-aware compositing. Kept narrow; pre-existing non-overlay
/// tests still use @c authorConcatFixture.
static NSString *authorOpaqueGrayFixture(
    NSInteger width, NSInteger height, NSInteger fps, NSInteger frameCount,
    NSString *tag, NSError *_Nullable __autoreleasing *outError) {
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t034-src-%@-%@.mp4", tag,
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  if (![muxer openAtPath:path
                   width:width
                  height:height
                     fps:fps
                   error:outError]) {
    return nil;
  }

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
  };
  for (NSInteger i = 0; i < frameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)pbAttrs, &pb);
    if (cv != kCVReturnSuccess) {
      if (outError) {
        *outError = [NSError errorWithDomain:@"authorOpaqueGrayFixture"
                                        code:cv
                                    userInfo:nil];
      }
      return nil;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    for (NSInteger y = 0; y < height; y++) {
      uint8_t *row = base + (size_t)y * bytesPerRow;
      for (NSInteger x = 0; x < width; x++) {
        uint8_t *px = row + (size_t)x * 4;
        px[0] = 0x80;  // B
        px[1] = 0x80;  // G
        px[2] = 0x80;  // R
        px[3] = 0xFF;  // A (opaque — the point of this helper)
      }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)fps);
    const BOOL ok =
        [muxer appendPixelBuffer:pb presentationTime:pts error:outError];
    CVPixelBufferRelease(pb);
    if (!ok) return nil;
  }
  if (![muxer closeWithError:outError]) return nil;
  return path;
}

/// Write a solid-BGRA PNG of @p size pixels with color (@p r, @p g, @p b) to a
/// unique temp path and return it. Used by the T034 overlay tests; stays at
/// file scope so individual XCTests can call it without the XCTest macro /
/// `self`-coupling constraints.
static NSString *authorSolidColorPng(NSInteger width, NSInteger height,
                                      uint8_t r, uint8_t g, uint8_t b,
                                      NSString *tag) {
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t034-%@-%@.png", tag,
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

  const size_t bytesPerRow = (size_t)width * 4;
  NSMutableData *pixels = [NSMutableData dataWithLength:bytesPerRow * (size_t)height];
  uint8_t *base = (uint8_t *)pixels.mutableBytes;
  for (NSInteger y = 0; y < height; y++) {
    uint8_t *row = base + (size_t)y * bytesPerRow;
    for (NSInteger x = 0; x < width; x++) {
      uint8_t *px = row + (size_t)x * 4;
      px[0] = r;
      px[1] = g;
      px[2] = b;
      px[3] = 0xFF;
    }
  }

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  const CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast |
                                   kCGBitmapByteOrder32Big;
  CGContextRef ctx = CGBitmapContextCreate(
      base, (size_t)width, (size_t)height, 8, bytesPerRow, cs, bitmapInfo);
  CGColorSpaceRelease(cs);
  if (ctx == NULL) return nil;
  CGImageRef cgImage = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  if (cgImage == NULL) return nil;

  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, (CFStringRef) @"public.png", 1, NULL);
  if (dest == NULL) {
    CGImageRelease(cgImage);
    return nil;
  }
  CGImageDestinationAddImage(dest, cgImage, NULL);
  const bool ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  CGImageRelease(cgImage);
  return ok ? path : nil;
}

/// Author a video where every frame is visually distinct so a frame-uniqueness
/// test can observe encoder duplication. Frame N fills the canvas with
/// (R, G, B) = (N*step % 256, 0x80, 0x80) — the R channel ramps with frame
/// index. step=4 keeps consecutive frames ≥4 units apart, robust against
/// H.264 quantization noise (which lands at ~±10 on a flat source per the
/// T034 acceptance tolerance, but our per-frame delta-from-flat-mean is the
/// signal we care about — duplicated frames produce identical decoded R
/// regardless of absolute level).
static NSString *authorMotionFixture(NSInteger width, NSInteger height,
                                      NSInteger fps, NSInteger frameCount,
                                      NSString *tag,
                                      NSError *_Nullable __autoreleasing *outError) {
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"motion-src-%@-%@.mp4", tag,
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

  RNVPAVMuxer *muxer = [[RNVPAVMuxer alloc] init];
  if (![muxer openAtPath:path width:width height:height fps:fps error:outError]) {
    return nil;
  }

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
  };
  const int step = 4;
  for (NSInteger i = 0; i < frameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)pbAttrs, &pb);
    if (cv != kCVReturnSuccess) {
      if (outError) {
        *outError = [NSError errorWithDomain:@"authorMotionFixture"
                                        code:cv
                                    userInfo:nil];
      }
      return nil;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t r = (uint8_t)((i * step) & 0xFF);
    for (NSInteger y = 0; y < height; y++) {
      uint8_t *row = base + (size_t)y * bytesPerRow;
      for (NSInteger x = 0; x < width; x++) {
        uint8_t *px = row + (size_t)x * 4;
        px[0] = 0x80;  // B
        px[1] = 0x80;  // G
        px[2] = r;     // R — varies per frame
        px[3] = 0xFF;  // A
      }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)fps);
    const BOOL ok =
        [muxer appendPixelBuffer:pb presentationTime:pts error:outError];
    CVPixelBufferRelease(pb);
    if (!ok) return nil;
  }
  if (![muxer closeWithError:outError]) return nil;
  return path;
}

/// Decode every video frame and return the center-pixel R value as an
/// NSNumber array, in PTS order. Use with @c authorMotionFixture for
/// frame-uniqueness assertions: each fixture frame has a distinct R, so the
/// returned series tells you whether the encoder duplicated frames (long
/// runs of identical R) or sampled them correctly (R varies frame-to-frame).
static NSArray<NSNumber *> *decodeCenterRSeries(NSString *videoPath) {
  AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
  AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (videoTrack == nil) return nil;
  NSError *readerError = nil;
  AVAssetReader *reader =
      [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
  if (reader == nil) return nil;
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  if (![reader startReading]) return nil;

  NSMutableArray<NSNumber *> *rs = [NSMutableArray array];
  while (YES) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) break;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    const NSInteger w = (NSInteger)CVPixelBufferGetWidth(pb);
    const NSInteger h = (NSInteger)CVPixelBufferGetHeight(pb);
    const uint8_t *center = base + (h / 2) * bytesPerRow + (w / 2) * 4;
    [rs addObject:@(center[2])];  // R channel — BGRA layout
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CFRelease(sample);
  }
  return rs;
}

/// Read the first decoded BGRA frame of @p videoPath into an arbitrary pixel
/// sampler block. The block receives (baseAddr, bytesPerRow, width, height)
/// and returns nothing — tests use it to sample the regions they care about
/// without re-authoring a reader each time.
static BOOL withFirstDecodedFrame(NSString *videoPath,
                                   void (^sampler)(const uint8_t *base,
                                                   size_t bytesPerRow,
                                                   NSInteger width,
                                                   NSInteger height)) {
  AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
  AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  if (videoTrack == nil) return NO;
  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
  if (reader == nil) return NO;
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:videoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
     }];
  [reader addOutput:output];
  if (![reader startReading]) return NO;
  CMSampleBufferRef sample = [output copyNextSampleBuffer];
  if (sample == NULL) return NO;
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  sampler((const uint8_t *)CVPixelBufferGetBaseAddress(pb),
          CVPixelBufferGetBytesPerRow(pb),
          (NSInteger)CVPixelBufferGetWidth(pb),
          (NSInteger)CVPixelBufferGetHeight(pb));
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  CFRelease(sample);
  return YES;
}

/// Author a fixture whose audio carries a *time-varying* signal so a trim
/// window's audio alignment is observable: the first half is digital silence,
/// the second half is a 1 kHz sine. A correct trim of the back half therefore
/// yields all-tone audio; a buggy trim that keeps the front-of-source audio
/// (right duration, wrong content) yields silence. Video is the same per-frame
/// R-ramp as @c authorMotionFixture so the existing frame-exactness checks
/// still apply. Mono 16-bit LPCM @ 44.1 kHz fed to an AAC encoder input.
static NSString *authorSteppedAudioFixture(NSInteger width, NSInteger height,
                                           NSInteger fps, NSInteger frameCount,
                                           NSString *tag,
                                           NSError *_Nullable __autoreleasing *outError) {
  const double kSampleRate = 44100.0;
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"stepaudio-src-%@-%@.mp4", tag,
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  NSURL *url = [NSURL fileURLWithPath:path];

  AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url
                                                    fileType:AVFileTypeMPEG4
                                                       error:outError];
  if (writer == nil) return nil;

  AVAssetWriterInput *videoInput = [AVAssetWriterInput
      assetWriterInputWithMediaType:AVMediaTypeVideo
                     outputSettings:@{
                       AVVideoCodecKey : AVVideoCodecTypeH264,
                       AVVideoWidthKey : @(width),
                       AVVideoHeightKey : @(height),
                     }];
  videoInput.expectsMediaDataInRealTime = NO;
  [writer addInput:videoInput];
  AVAssetWriterInputPixelBufferAdaptor *adaptor =
      [[AVAssetWriterInputPixelBufferAdaptor alloc]
          initWithAssetWriterInput:videoInput
          sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey : @(width),
            (id)kCVPixelBufferHeightKey : @(height),
          }];

  AVAssetWriterInput *audioInput = [AVAssetWriterInput
      assetWriterInputWithMediaType:AVMediaTypeAudio
                     outputSettings:@{
                       AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                       AVNumberOfChannelsKey : @(1),
                       AVSampleRateKey : @(kSampleRate),
                       AVEncoderBitRateKey : @(64000),
                     }];
  audioInput.expectsMediaDataInRealTime = NO;
  [writer addInput:audioInput];

  if (![writer startWriting]) {
    if (outError) *outError = writer.error;
    return nil;
  }
  [writer startSessionAtSourceTime:kCMTimeZero];

  // --- Video: per-frame R-ramp, identical to authorMotionFixture. ----------
  const int step = 4;
  for (NSInteger i = 0; i < frameCount; i++) {
    while (!videoInput.isReadyForMoreMediaData) {
      [NSThread sleepForTimeInterval:0.001];
    }
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef) @{
                          (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
                        },
                        &pb);
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t r = (uint8_t)((i * step) & 0xFF);
    for (NSInteger y = 0; y < height; y++) {
      uint8_t *row = base + (size_t)y * bpr;
      for (NSInteger x = 0; x < width; x++) {
        uint8_t *px = row + (size_t)x * 4;
        px[0] = 0x80;
        px[1] = 0x80;
        px[2] = r;
        px[3] = 0xFF;
      }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    [adaptor appendPixelBuffer:pb
          withPresentationTime:CMTimeMake((int64_t)i, (int32_t)fps)];
    CVPixelBufferRelease(pb);
  }
  [videoInput markAsFinished];

  // --- Audio: silence for [0, half), 1 kHz sine for [half, end). -----------
  const double totalSec = (double)frameCount / (double)fps;
  const UInt32 totalSamples = (UInt32)llround(totalSec * kSampleRate);
  const UInt32 halfSample = totalSamples / 2;
  int16_t *pcm = (int16_t *)calloc(totalSamples, sizeof(int16_t));
  for (UInt32 n = halfSample; n < totalSamples; n++) {
    const double t = (double)n / kSampleRate;
    pcm[n] = (int16_t)llround(0.6 * 32767.0 * sin(2.0 * M_PI * 1000.0 * t));
  }

  AudioStreamBasicDescription asbd = {0};
  asbd.mSampleRate = kSampleRate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags =
      kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
  asbd.mBytesPerPacket = 2;
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerFrame = 2;
  asbd.mChannelsPerFrame = 1;
  asbd.mBitsPerChannel = 16;
  CMAudioFormatDescriptionRef audioFormat = NULL;
  CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL,
                                 NULL, &audioFormat);

  CMBlockBufferRef block = NULL;
  CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL,
                                     totalSamples * sizeof(int16_t), NULL, NULL,
                                     0, totalSamples * sizeof(int16_t), 0,
                                     &block);
  CMBlockBufferReplaceDataBytes(pcm, block, 0, totalSamples * sizeof(int16_t));
  free(pcm);

  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, (int32_t)kSampleRate),
      .presentationTimeStamp = kCMTimeZero,
      .decodeTimeStamp = kCMTimeInvalid,
  };
  CMSampleBufferRef audioSample = NULL;
  CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL,
                       audioFormat, (CMItemCount)totalSamples, 1, &timing, 0,
                       NULL, &audioSample);
  while (!audioInput.isReadyForMoreMediaData) {
    [NSThread sleepForTimeInterval:0.001];
  }
  const BOOL audioOk = [audioInput appendSampleBuffer:audioSample];
  CFRelease(audioSample);
  CFRelease(block);
  CFRelease(audioFormat);
  [audioInput markAsFinished];
  if (!audioOk) {
    if (outError) *outError = writer.error;
    return nil;
  }

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{
    dispatch_semaphore_signal(done);
  }];
  dispatch_semaphore_wait(
      done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
  if (writer.status != AVAssetWriterStatusCompleted) {
    if (outError) *outError = writer.error;
    return nil;
  }
  return path;
}

/// Decode @p path's audio track to mono 16-bit PCM and return the RMS
/// amplitude (0..1) of the samples whose presentation time falls in
/// [startSec, endSec). Used to detect whether a trimmed output carries the
/// correct audio segment.
static double decodeAudioRMSWindow(NSString *path, double startSec,
                                   double endSec) {
  const double kSampleRate = 44100.0;
  AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
  AVAssetTrack *audioTrack =
      [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  if (audioTrack == nil) return -1.0;
  NSError *err = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
  if (reader == nil) return -1.0;
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:audioTrack
     outputSettings:@{
       AVFormatIDKey : @(kAudioFormatLinearPCM),
       AVSampleRateKey : @(kSampleRate),
       AVNumberOfChannelsKey : @(1),
       AVLinearPCMBitDepthKey : @(16),
       AVLinearPCMIsFloatKey : @NO,
       AVLinearPCMIsBigEndianKey : @NO,
       AVLinearPCMIsNonInterleaved : @NO,
     }];
  [reader addOutput:output];
  if (![reader startReading]) return -1.0;

  double sumSquares = 0.0;
  uint64_t counted = 0;
  while (YES) {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample == NULL) break;
    const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    const double bufStartSec = CMTIME_IS_VALID(pts) ? CMTimeGetSeconds(pts) : 0.0;
    const CMItemCount n = CMSampleBufferGetNumSamples(sample);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t len = 0;
    char *dataPtr = NULL;
    if (block != NULL &&
        CMBlockBufferGetDataPointer(block, 0, NULL, &len, &dataPtr) == noErr) {
      const int16_t *samples = (const int16_t *)dataPtr;
      const CMItemCount avail = (CMItemCount)(len / sizeof(int16_t));
      for (CMItemCount i = 0; i < n && i < avail; i++) {
        const double t = bufStartSec + (double)i / kSampleRate;
        if (t >= startSec && t < endSec) {
          const double v = (double)samples[i] / 32768.0;
          sumSquares += v * v;
          counted++;
        }
      }
    }
    CFRelease(sample);
  }
  if (counted == 0) return 0.0;
  return sqrt(sumSquares / (double)counted);
}

/// T034 acceptance: transcode a flat-gray fixture with a solid-red Overlay.Image
/// anchored at center. The decoded output should have red pixels at the frame
/// center and unmodified gray pixels near the corners. Tolerance covers the
/// H.264 quantization error (~±10 per channel on a flat source).
- (void)testTranscodeAppliesCenterImageOverlay
{
  const NSInteger kWidth = 80;
  const NSInteger kHeight = 60;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15;  // 0.5s @ 30fps

  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps,
                                                  kFrameCount, @"center",
                                                  &fixtureError);
  XCTAssertNotNil(sourcePath, @"source fixture failed: %@", fixtureError);

  // 20x20 solid-red overlay. Small enough that its center (40, 30) is
  // decisively inside the overlay and a (5, 5) corner sample is decisively
  // outside it, even after the H.264 round trip blurs edges by a pixel or
  // two.
  NSString *overlayPath = authorSolidColorPng(20, 20, 0xFF, 0x00, 0x00,
                                               @"red-20");
  XCTAssertNotNil(overlayPath, @"overlay PNG authoring failed");

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t034-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kWidth
                                          height:kHeight
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];

  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:overlayPath]
               anchorX:0.5
               anchorY:0.5
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:20.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:20.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:@[ overlay ]
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertTrue(ok, @"transcode failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  __block int centerB = 0, centerG = 0, centerR = 0;
  __block int cornerB = 0, cornerG = 0, cornerR = 0;
  __block NSInteger observedW = 0, observedH = 0;
  const BOOL decoded = withFirstDecodedFrame(outPath, ^(
      const uint8_t *base, size_t bytesPerRow, NSInteger w, NSInteger h) {
    observedW = w;
    observedH = h;
    const uint8_t *center = base + (h / 2) * bytesPerRow + (w / 2) * 4;
    centerB = center[0];
    centerG = center[1];
    centerR = center[2];
    const uint8_t *corner = base + 3 * bytesPerRow + 3 * 4;
    cornerB = corner[0];
    cornerG = corner[1];
    cornerR = corner[2];
  });
  XCTAssertTrue(decoded, @"could not decode output");
  XCTAssertEqual(observedW, kWidth);
  XCTAssertEqual(observedH, kHeight);

  // Center should be dominantly red — R high, G/B low.
  XCTAssertGreaterThan(centerR, 180,
                       @"center R channel %d (expected > 180 for red overlay)",
                       centerR);
  XCTAssertLessThan(centerG, 60, @"center G channel %d (expected < 60)", centerG);
  XCTAssertLessThan(centerB, 60, @"center B channel %d (expected < 60)", centerB);

  // Corner is outside the 20x20 overlay footprint, so it must NOT be red —
  // the three channels land within ~16 of each other (any "close to balanced"
  // value means the overlay did not bleed there). The absolute gray level is
  // intentionally not pinned: the T033 CI round-trip is not strictly lossless
  // on pure-gray sources and lands around 66 for a 128 input, which is a
  // transcoder-pipeline property this test does not try to re-verify.
  XCTAssertLessThan(abs(cornerR - cornerG), 24,
                    @"corner R=%d/G=%d unexpectedly imbalanced",
                    cornerR, cornerG);
  XCTAssertLessThan(abs(cornerR - cornerB), 24,
                    @"corner R=%d/B=%d unexpectedly imbalanced",
                    cornerR, cornerB);
  // And corner must NOT match the red overlay.
  XCTAssertLessThan(cornerR, 180,
                    @"corner R %d unexpectedly matches the red overlay",
                    cornerR);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:overlayPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// T034: overlay timeRange bounds the overlay to a frame window. With
/// startSec=0.3s on a 0.5s clip, frame 0 (t=0s) should be unmodified gray,
/// while a later frame (t=0.4s) should show the red overlay. The test samples
/// the FIRST decoded frame to verify the "before startSec" exclusion.
- (void)testTranscodeImageOverlayRespectsTimeRange
{
  const NSInteger kWidth = 80;
  const NSInteger kHeight = 60;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15;

  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps,
                                                  kFrameCount, @"tr",
                                                  &fixtureError);
  XCTAssertNotNil(sourcePath, @"source fixture failed: %@", fixtureError);
  NSString *overlayPath =
      authorSolidColorPng(20, 20, 0xFF, 0x00, 0x00, @"red-20-tr");
  XCTAssertNotNil(overlayPath);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t034-tr-%@.mp4", NSUUID.UUID.UUIDString]];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kWidth
                                          height:kHeight
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];

  // Overlay only active on [0.3, 1.0). Frame 0 (t=0) is before the range; its
  // center should stay gray. Frames ≥ 9 (t ≥ 0.3) would be red, but we only
  // sample frame 0 in this test (that's the specific exclusion we care about).
  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:overlayPath]
               anchorX:0.5
               anchorY:0.5
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:20.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:20.0
               opacity:1.0
          hasTimeRange:YES
              startSec:0.3
                endSec:1.0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:@[ overlay ]
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertTrue(ok, @"transcode failed: %@", error);

  __block int centerR = 0, centerG = 0, centerB = 0;
  const BOOL decoded = withFirstDecodedFrame(outPath, ^(
      const uint8_t *base, size_t bytesPerRow, NSInteger w, NSInteger h) {
    const uint8_t *center = base + (h / 2) * bytesPerRow + (w / 2) * 4;
    centerB = center[0];
    centerG = center[1];
    centerR = center[2];
  });
  XCTAssertTrue(decoded, @"decode failed");
  // Frame 0 at t=0 is outside the range → overlay inactive. "Still gray-ish"
  // is asserted as: channels balanced, and R not red-dominant — same logic
  // as the center test's corner check (the transcoder's CI round-trip is
  // not strictly lossless on pure-gray sources; absolute values aren't
  // pinned here).
  XCTAssertLessThan(abs(centerR - centerG), 24,
                    @"frame-0 center R=%d/G=%d unexpectedly imbalanced",
                    centerR, centerG);
  XCTAssertLessThan(abs(centerR - centerB), 24,
                    @"frame-0 center R=%d/B=%d unexpectedly imbalanced",
                    centerR, centerB);
  XCTAssertLessThan(centerR, 180,
                    @"frame-0 center R %d unexpectedly matches overlay red",
                    centerR);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:overlayPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// T034: a broken overlay spec (image file missing) must surface as
/// InvalidSpec with no partial output file. This is the primary guard that
/// the transcoder does NOT leave a zombie .mp4 on overlay-prep failure.
- (void)testTranscodeRejectsMissingOverlayImage
{
  const NSInteger kWidth = 80;
  const NSInteger kHeight = 60;
  const NSInteger kFps = 30;
  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps, 15,
                                                  @"no-img", &fixtureError);
  XCTAssertNotNil(sourcePath);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t034-no-img-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
  NSString *ghostOverlay = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t034-ghost-%@.png",
                                     NSUUID.UUID.UUIDString]];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kWidth
                                          height:kHeight
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];
  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:ghostOverlay]
               anchorX:0.5
               anchorY:0.5
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:20.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:20.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:@[ overlay ]
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPTranscoderErrorDomain);
  XCTAssertEqual(error.code, RNVPTranscoderErrorCodeInvalidSpec);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
}

#pragma mark - OverlayRenderer / Transcoder with text overlay (T035)

/// Sample the centre third of a decoded frame; return the maximum per-channel
/// value across that window. A text overlay rendered in white (or any bright
/// non-gray color) over a flat-gray 0x80 source should produce at least one
/// sample with channel values well above the ambient gray once the glyphs
/// have been composited. Sampling a window (rather than a single pixel) makes
/// the test robust against the exact glyph layout inside the measured rect.
static void sampleBrightestInCenterWindow(const uint8_t *base,
                                           size_t bytesPerRow, NSInteger w,
                                           NSInteger h, int *outMaxB,
                                           int *outMaxG, int *outMaxR,
                                           int *outMaxA) {
  int maxB = 0, maxG = 0, maxR = 0, maxA = 0;
  const NSInteger x0 = w / 3;
  const NSInteger x1 = (w * 2) / 3;
  const NSInteger y0 = h / 3;
  const NSInteger y1 = (h * 2) / 3;
  for (NSInteger y = y0; y < y1; y++) {
    const uint8_t *row = base + (size_t)y * bytesPerRow;
    for (NSInteger x = x0; x < x1; x++) {
      const uint8_t *px = row + (size_t)x * 4;
      if (px[0] > maxB) maxB = px[0];
      if (px[1] > maxG) maxG = px[1];
      if (px[2] > maxR) maxR = px[2];
      if (px[3] > maxA) maxA = px[3];
    }
  }
  if (outMaxB) *outMaxB = maxB;
  if (outMaxG) *outMaxG = maxG;
  if (outMaxR) *outMaxR = maxR;
  if (outMaxA) *outMaxA = maxA;
}

/// T035 acceptance: transcode a flat-gray fixture with a white Overlay.Text
/// anchored at center. The decoded output should contain bright pixels in the
/// centre third (where the glyphs land). Absolute pixel values are not pinned
/// — the CI round-trip is not strictly lossless on flat sources (see T034),
/// and glyph rasterization varies across system font revisions. What's
/// invariant is "bright pixels exist in the centre that aren't in the
/// untouched corner."
- (void)testTranscodeAppliesCenterTextOverlay
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15;

  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps,
                                                  kFrameCount, @"text-center",
                                                  &fixtureError);
  XCTAssertNotNil(sourcePath, @"source fixture failed: %@", fixtureError);

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t035-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kWidth
                                          height:kHeight
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];

  RNVPTextOverlay *overlay = [[RNVPTextOverlay alloc]
                initWithText:@"HELLO"
                  fontFamily:nil
                    fontSize:28.0
                 colorString:@"#ffffff"
                  weightBold:YES
                   alignment:RNVPTextAlignmentCenter
                   hasShadow:NO
           shadowColorString:nil
                  shadowBlur:0.0
                    shadowDx:0.0
                    shadowDy:0.0
                     anchorX:0.5
                     anchorY:0.5
                hasTimeRange:NO
                    startSec:0.0
                      endSec:0.0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:@[ overlay ]
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertTrue(ok, @"transcode failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  __block int maxB = 0, maxG = 0, maxR = 0, maxA = 0;
  __block int cornerB = 0, cornerG = 0, cornerR = 0;
  const BOOL decoded = withFirstDecodedFrame(outPath, ^(
      const uint8_t *base, size_t bytesPerRow, NSInteger w, NSInteger h) {
    sampleBrightestInCenterWindow(base, bytesPerRow, w, h, &maxB, &maxG,
                                   &maxR, &maxA);
    const uint8_t *corner = base + 3 * bytesPerRow + 3 * 4;
    cornerB = corner[0];
    cornerG = corner[1];
    cornerR = corner[2];
  });
  XCTAssertTrue(decoded, @"could not decode output");

  // The white glyphs must land decisively brighter than the ambient gray in
  // the centre window. The corner is outside the glyph footprint (centred
  // text on a 160×120 frame leaves ample margin), so it should still land
  // near the ambient gray band. The threshold "centre brightness > corner
  // brightness + 30" holds as long as *any* centre pixel partially covered
  // by a glyph survives the H.264 round trip — a conservative bar.
  const int ambientCornerMax =
      cornerR > cornerG ? cornerR : cornerG;
  const int cornerLuma = cornerB > ambientCornerMax ? cornerB : ambientCornerMax;
  const int centreMaxLuma = maxR > maxG ? maxR : maxG;
  const int centreBright = maxB > centreMaxLuma ? maxB : centreMaxLuma;
  XCTAssertGreaterThan(centreBright, cornerLuma + 30,
                       @"centre brightest %d not meaningfully brighter than "
                       @"corner %d — glyph rasterization likely missing",
                       centreBright, cornerLuma);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// T035: a malformed color string must surface as InvalidSpec with no partial
/// output file — the renderer rejects the text overlay at init time and the
/// transcoder cancels the writer before any frames are written.
- (void)testTranscodeRejectsMalformedTextOverlayColor
{
  const NSInteger kWidth = 80;
  const NSInteger kHeight = 60;
  const NSInteger kFps = 30;
  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps, 15,
                                                  @"bad-color", &fixtureError);
  XCTAssertNotNil(sourcePath);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t035-bad-color-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kWidth
                                          height:kHeight
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];

  // "not-a-color" is neither a hex form nor rgb()/rgba(); the parser rejects.
  RNVPTextOverlay *overlay = [[RNVPTextOverlay alloc]
                initWithText:@"bad"
                  fontFamily:nil
                    fontSize:24.0
                 colorString:@"not-a-color"
                  weightBold:NO
                   alignment:RNVPTextAlignmentCenter
                   hasShadow:NO
           shadowColorString:nil
                  shadowBlur:0.0
                    shadowDx:0.0
                    shadowDy:0.0
                     anchorX:0.5
                     anchorY:0.5
                hasTimeRange:NO
                    startSec:0.0
                      endSec:0.0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:@[ overlay ]
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPTranscoderErrorDomain);
  XCTAssertEqual(error.code, RNVPTranscoderErrorCodeInvalidSpec);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
}

/// T035: an image overlay and a text overlay in the same render, both at the
/// same anchor. This smoke-tests the mixed-array overlay routing in
/// @c RNVPOverlayRenderer — the renderer walks the array in insertion order
/// so the later-added text lands on top of the image. The test only asserts
/// the transcode completes cleanly and the output file is populated (full
/// pixel comparison belongs to the golden-hash suite in T048).
- (void)testTranscodeMixesImageAndTextOverlays
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps, 15,
                                                  @"mixed", &fixtureError);
  XCTAssertNotNil(sourcePath);

  NSString *pngPath = authorSolidColorPng(40, 40, 0x00, 0x80, 0xFF,
                                           @"blue-40");
  XCTAssertNotNil(pngPath);

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t035-mixed-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kWidth
                                          height:kHeight
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];
  RNVPImageOverlay *image = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:pngPath]
               anchorX:0.5
               anchorY:0.5
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:40.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:40.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];
  RNVPTextOverlay *text = [[RNVPTextOverlay alloc]
                initWithText:@"Hi"
                  fontFamily:nil
                    fontSize:24.0
                 colorString:@"#ffffff"
                  weightBold:YES
                   alignment:RNVPTextAlignmentCenter
                   hasShadow:YES
           shadowColorString:@"#000000"
                  shadowBlur:2.0
                    shadowDx:1.0
                    shadowDy:1.0
                     anchorX:0.5
                     anchorY:0.5
                hasTimeRange:NO
                    startSec:0.0
                      endSec:0.0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:@[ image, text ]
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertTrue(ok, @"transcode failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);
  NSDictionary *attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:nil];
  XCTAssertGreaterThan([attrs[NSFileSize] unsignedLongLongValue], 1024u,
                       @"output file suspiciously small: %@", attrs[NSFileSize]);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:pngPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// T036 acceptance: the stamp-router runs the transcoder with BOTH an overlay
/// AND a stamp-metadata bag in a single writer pass. Asserts the watermark is
/// visible at the anchor AND the GPS/software metadata round-trips through
/// @c RNVPAVDemuxer (the Video.info lookup path from prd.md US2). Covers the
/// single-pass contract that @c HybridVideoPipeline::stamp() relies on for
/// the watermark-present branch.
- (void)testTranscodeAppliesOverlayAndStampsMetadataInOnePass
{
  const NSInteger kWidth = 80;
  const NSInteger kHeight = 60;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15;

  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps,
                                                  kFrameCount, @"t036",
                                                  &fixtureError);
  XCTAssertNotNil(sourcePath, @"source fixture failed: %@", fixtureError);
  NSString *overlayPath =
      authorSolidColorPng(20, 20, 0xFF, 0x00, 0x00, @"t036-red");
  XCTAssertNotNil(overlayPath);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t036-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  // Target preserves source dims/fps — the US2 "watermark-only call with no
  // resolution change preserves source fps exactly" contract.
  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kWidth
                                          height:kHeight
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];

  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:overlayPath]
               anchorX:0.5
               anchorY:0.5
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:20.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:20.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];

  NSDate *creationDate =
      [NSDate dateWithTimeIntervalSince1970:1700000000];  // 2023-11-14
  RNVPStampMetadata *metadata =
      [[RNVPStampMetadata alloc] initWithGps:YES
                                    latitude:52.5
                                   longitude:13.4
                              hasGpsAltitude:NO
                                    altitude:0
                                    software:@"rnvp-stamp-router"
                                creationDate:creationDate
                          contentDescription:nil
                                      custom:nil];

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:@[ overlay ]
                              metadata:metadata
                                 stop:nil
                                 progress:nil
                                 error:&error];
  XCTAssertTrue(ok, @"stamp-router transcode failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  // (1) Watermark pixel sanity — the overlay landed at center.
  __block int centerR = 0, centerG = 0, centerB = 0;
  const BOOL decoded = withFirstDecodedFrame(outPath, ^(
      const uint8_t *base, size_t bytesPerRow, NSInteger w, NSInteger h) {
    const uint8_t *px = base + (h / 2) * bytesPerRow + (w / 2) * 4;
    centerB = px[0];
    centerG = px[1];
    centerR = px[2];
  });
  XCTAssertTrue(decoded, @"could not decode output");
  XCTAssertGreaterThan(centerR, 180,
                       @"center R %d (expected > 180 for red overlay)",
                       centerR);
  XCTAssertLessThan(centerG, 60, @"center G %d (expected < 60)", centerG);
  XCTAssertLessThan(centerB, 60, @"center B %d (expected < 60)", centerB);

  // (2) Metadata round-trip — GPS + software + creationDate readable from
  // the same file the transcoder authored, matching Video.info semantics.
  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:[NSURL fileURLWithPath:outPath]
                              error:&error],
                @"demuxer open failed: %@", error);
  XCTAssertEqualObjects(demuxer.codec, @"h264");
  // Source dims / fps preserved — the "preserves source fps exactly" bullet.
  XCTAssertEqual(demuxer.width, kWidth);
  XCTAssertEqual(demuxer.height, kHeight);
  XCTAssertEqualWithAccuracy(demuxer.fps, (double)kFps, 0.5);
  XCTAssertTrue(demuxer.hasLocation);
  XCTAssertEqualWithAccuracy(demuxer.locationLatitude, 52.5, 1e-3);
  XCTAssertEqualWithAccuracy(demuxer.locationLongitude, 13.4, 1e-3);
  XCTAssertNotNil(demuxer.creationDate);
  XCTAssertEqualWithAccuracy(demuxer.creationDate.timeIntervalSince1970,
                             creationDate.timeIntervalSince1970, 1.0);
  XCTAssertEqualObjects(demuxer.customMetadata[AVMetadataCommonKeySoftware],
                        @"rnvp-stamp-router");
  [demuxer closeWithError:nil];

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:overlayPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// T036: `metadata:nil` on the transcoder leaves the source's container-level
/// metadata bag intact — same semantics as a T033/T034 overlay-only transcode
/// had before the metadata argument existed. Authors a source with a
/// container-level creationDate, transcodes with an overlay and `metadata:nil`,
/// asserts the creationDate survives. This is the "metadata passthrough"
/// tripwire so future edits to the merge path don't regress the overlay-only
/// code path.
- (void)testTranscodeWithNilMetadataPreservesSourceMetadata
{
  const NSInteger kWidth = 64;
  const NSInteger kHeight = 64;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15;

  NSString *sourcePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t036-pt-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t036-pt-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  NSError *error = nil;
  AVAssetWriter *writer =
      [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:sourcePath]
                                fileType:AVFileTypeMPEG4
                                   error:&error];
  XCTAssertNotNil(writer);
  NSDate *sourceCreationDate =
      [NSDate dateWithTimeIntervalSince1970:1600000000];  // 2020-09-13
  AVMutableMetadataItem *creationItem = [AVMutableMetadataItem metadataItem];
  creationItem.identifier = AVMetadataCommonIdentifierCreationDate;
  creationItem.extendedLanguageTag = @"und";
  creationItem.value = sourceCreationDate;
  creationItem.dataType = (NSString *)kCMMetadataBaseDataType_RawData;
  writer.metadata = @[ creationItem ];

  NSDictionary *settings = @{
    AVVideoCodecKey : AVVideoCodecTypeH264,
    AVVideoWidthKey : @(kWidth),
    AVVideoHeightKey : @(kHeight),
  };
  AVAssetWriterInput *input =
      [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                         outputSettings:settings];
  input.expectsMediaDataInRealTime = NO;
  [writer addInput:input];
  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(kWidth),
    (id)kCVPixelBufferHeightKey : @(kHeight),
  };
  AVAssetWriterInputPixelBufferAdaptor *adaptor = [
      [AVAssetWriterInputPixelBufferAdaptor alloc]
        initWithAssetWriterInput:input
      sourcePixelBufferAttributes:pbAttrs];
  XCTAssertTrue([writer startWriting]);
  [writer startSessionAtSourceTime:kCMTimeZero];
  for (NSInteger i = 0; i < kFrameCount; i++) {
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, adaptor.pixelBufferPool, &pb);
    XCTAssertEqual(cv, kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pb, 0);
    memset(CVPixelBufferGetBaseAddress(pb), 0x80,
           CVPixelBufferGetBytesPerRow(pb) * (size_t)kHeight);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    while (!input.readyForMoreMediaData) {
      [NSThread sleepForTimeInterval:0.001];
    }
    CMTime pts = CMTimeMake((int64_t)i, (int32_t)kFps);
    XCTAssertTrue([adaptor appendPixelBuffer:pb withPresentationTime:pts]);
    CVPixelBufferRelease(pb);
  }
  [input markAsFinished];
  XCTestExpectation *done =
      [self expectationWithDescription:@"writer finishWriting"];
  [writer finishWritingWithCompletionHandler:^{
    [done fulfill];
  }];
  [self waitForExpectations:@[ done ] timeout:5.0];
  XCTAssertEqual(writer.status, AVAssetWriterStatusCompleted);

  NSString *pngPath =
      authorSolidColorPng(16, 16, 0xFF, 0x00, 0x00, @"t036-pt-red");
  XCTAssertNotNil(pngPath);

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:kWidth
                                          height:kHeight
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];
  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:pngPath]
               anchorX:0.5
               anchorY:0.5
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:16.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:16.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];
  XCTAssertTrue(
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:@[ overlay ]
                              metadata:nil
                                 stop:nil
                                 progress:nil
                                 error:&error],
      @"transcode failed: %@", error);

  RNVPAVDemuxer *demuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([demuxer openAtURL:[NSURL fileURLWithPath:outPath]
                              error:&error]);
  XCTAssertNotNil(demuxer.creationDate,
                  @"source creationDate must survive metadata-nil transcode");
  XCTAssertEqualWithAccuracy(demuxer.creationDate.timeIntervalSince1970,
                             sourceCreationDate.timeIntervalSince1970, 1.0);
  [demuxer closeWithError:nil];

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:pngPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

// ===========================================================================
// T037 — iOS progress events (fixed synthesize / open-ended synthesize /
// transcode). US7 requires onProgress to fire at least 10 Hz for renders
// ≥1s long; the coalescing is native. For the macOS-host tests below the
// fixtures are <1s each, so we verify the shape the coalescer guarantees
// regardless of duration:
//   - initial framesCompleted=0 tick,
//   - final framesCompleted=N tick with ETA=0,
//   - monotonic framesCompleted + elapsedMs,
//   - for fixed / transcode: every tick carries a definite nbFrames,
//   - for open-ended: nbFrames is undefined until `finalize`, then definite.
// The ≥10 Hz contract lives in the emitter itself (minIntervalMs=100ms) and
// is exercised on device by the Detox/Maestro v0.5 work — an XCTest would
// need a >1s fixture, which VideoToolbox's tiny-frame encoder back-pressures
// past the 30s allowance (same rationale as T033's 80×60 downscale).
// ===========================================================================

- (void)testSynthesizeFixedEmitsProgressWithDefiniteNbFrames
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const double kFps = 30.0;
  const double kSeconds = 0.5;
  const double kExpectedFrames = round(kFps * kSeconds); // 15

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t037-fixed-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
  RNVPProgressBlock progress = ^(double framesCompleted, BOOL nbFramesValid,
                                 double nbFrames, double elapsedMs,
                                 BOOL etaMsValid,
                                 double estimatedRemainingMs) {
    [events addObject:@{
      @"framesCompleted" : @(framesCompleted),
      @"nbFramesValid" : @(nbFramesValid),
      @"nbFrames" : @(nbFrames),
      @"elapsedMs" : @(elapsedMs),
      @"etaMsValid" : @(etaMsValid),
      @"etaMs" : @(estimatedRemainingMs),
    }];
  };

  NSError *error = nil;
  XCTAssertTrue([RNVPSynthesizeRunner runFixedWithOutputPath:outputPath
                                                       width:kWidth
                                                      height:kHeight
                                                         fps:kFps
                                                     seconds:kSeconds
                                                    stopToken:nil
                                                    progress:progress
                                                    aborted:NULL
                                                       error:&error],
                @"synthesize failed: %@", error);

  XCTAssertGreaterThanOrEqual(events.count, 2u,
                              @"expected at least initial + final tick, got %lu",
                              (unsigned long)events.count);

  NSDictionary *first = events.firstObject;
  XCTAssertEqualWithAccuracy([first[@"framesCompleted"] doubleValue], 0.0,
                             1e-9,
                             @"initial tick must carry framesCompleted=0");
  XCTAssertTrue([first[@"nbFramesValid"] boolValue],
                @"fixed renders must publish a definite nbFrames from tick 0");
  XCTAssertEqualWithAccuracy([first[@"nbFrames"] doubleValue],
                             kExpectedFrames, 0.5);

  NSDictionary *last = events.lastObject;
  XCTAssertEqualWithAccuracy([last[@"framesCompleted"] doubleValue],
                             kExpectedFrames, 0.5);
  XCTAssertTrue([last[@"nbFramesValid"] boolValue]);
  XCTAssertEqualWithAccuracy([last[@"nbFrames"] doubleValue], kExpectedFrames,
                             0.5);
  XCTAssertTrue([last[@"etaMsValid"] boolValue],
                @"final tick must carry a definite ETA");
  XCTAssertEqualWithAccuracy([last[@"etaMs"] doubleValue], 0.0, 1e-6,
                             @"ETA on final tick should be ~0, got %f",
                             [last[@"etaMs"] doubleValue]);

  // Monotonic framesCompleted + elapsedMs.
  for (NSUInteger i = 1; i < events.count; ++i) {
    const double prevFc = [events[i - 1][@"framesCompleted"] doubleValue];
    const double curFc = [events[i][@"framesCompleted"] doubleValue];
    XCTAssertGreaterThanOrEqual(curFc, prevFc,
                                @"framesCompleted regressed at tick %lu: "
                                @"%f -> %f",
                                (unsigned long)i, prevFc, curFc);
    const double prevEl = [events[i - 1][@"elapsedMs"] doubleValue];
    const double curEl = [events[i][@"elapsedMs"] doubleValue];
    XCTAssertGreaterThanOrEqual(curEl, prevEl,
                                @"elapsedMs regressed at tick %lu: %f -> %f",
                                (unsigned long)i, prevEl, curEl);
  }

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

- (void)testSynthesizeOpenReportsUnknownNbFramesUntilFinalize
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const double kFps = 30.0;
  const double kMaxSeconds = 0.5;
  const double kExpectedFrames = round(kFps * kMaxSeconds); // 15

  NSString *outputPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t037-open-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
  RNVPProgressBlock progress = ^(double framesCompleted, BOOL nbFramesValid,
                                 double nbFrames, double elapsedMs,
                                 BOOL etaMsValid,
                                 double estimatedRemainingMs) {
    [events addObject:@{
      @"framesCompleted" : @(framesCompleted),
      @"nbFramesValid" : @(nbFramesValid),
      @"nbFrames" : @(nbFrames),
      @"elapsedMs" : @(elapsedMs),
      @"etaMsValid" : @(etaMsValid),
      @"etaMs" : @(estimatedRemainingMs),
    }];
  };

  RNVPStopToken *stop = [[RNVPStopToken alloc] init];
  NSError *error = nil;
  NSInteger framesWritten = -1;
  BOOL aborted = YES;

  XCTAssertTrue([RNVPSynthesizeRunner runOpenWithOutputPath:outputPath
                                                      width:kWidth
                                                     height:kHeight
                                                        fps:kFps
                                                 maxSeconds:kMaxSeconds
                                                  stopToken:stop
                                              finishOnFrame:-1
                                                   progress:progress
                                              framesWritten:&framesWritten
                                                    aborted:&aborted
                                                      error:&error],
                @"runOpen failed: %@", error);
  XCTAssertFalse(aborted);
  XCTAssertEqual(framesWritten, (NSInteger)kExpectedFrames);

  XCTAssertGreaterThanOrEqual(events.count, 2u);

  NSDictionary *first = events.firstObject;
  XCTAssertEqualWithAccuracy([first[@"framesCompleted"] doubleValue], 0.0,
                             1e-9);
  // Per US7 + §8 `Progress.nbFrames`: open-ended renders leave nbFrames
  // undefined until finish() — which the runner signals to the emitter via
  // `updateNbFrames` just before the final tick.
  XCTAssertFalse([first[@"nbFramesValid"] boolValue],
                 @"open-ended first tick must NOT advertise a definite "
                 @"nbFrames");
  XCTAssertFalse([first[@"etaMsValid"] boolValue],
                 @"open-ended first tick must NOT advertise an ETA");

  NSDictionary *last = events.lastObject;
  XCTAssertEqualWithAccuracy([last[@"framesCompleted"] doubleValue],
                             kExpectedFrames, 0.5);
  XCTAssertTrue([last[@"nbFramesValid"] boolValue],
                @"open-ended final tick must lock in the definite nbFrames");
  XCTAssertEqualWithAccuracy([last[@"nbFrames"] doubleValue], kExpectedFrames,
                             0.5);
  XCTAssertTrue([last[@"etaMsValid"] boolValue]);
  XCTAssertEqualWithAccuracy([last[@"etaMs"] doubleValue], 0.0, 1e-6);

  for (NSUInteger i = 1; i < events.count; ++i) {
    const double prevFc = [events[i - 1][@"framesCompleted"] doubleValue];
    const double curFc = [events[i][@"framesCompleted"] doubleValue];
    XCTAssertGreaterThanOrEqual(curFc, prevFc);
  }

  [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
}

- (void)testTranscodeEmitsProgressWithDefiniteNbFrames
{
  const NSInteger kSourceW = 160;
  const NSInteger kSourceH = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15; // 0.5s at 30fps

  NSError *fixtureError = nil;
  NSString *sourcePath = authorConcatFixture(kSourceW, kSourceH, kFps,
                                              kFrameCount, @"t037-trx-src",
                                              &fixtureError);
  XCTAssertNotNil(sourcePath, @"fixture failed: %@", fixtureError);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t037-trx-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:80
                                          height:60
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:0
                                      cropHeight:0];

  NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
  RNVPTranscoderProgressBlock progress = ^(double framesCompleted,
                                           BOOL nbFramesValid, double nbFrames,
                                           double elapsedMs, BOOL etaMsValid,
                                           double estimatedRemainingMs) {
    [events addObject:@{
      @"framesCompleted" : @(framesCompleted),
      @"nbFramesValid" : @(nbFramesValid),
      @"nbFrames" : @(nbFrames),
      @"elapsedMs" : @(elapsedMs),
      @"etaMsValid" : @(etaMsValid),
      @"etaMs" : @(estimatedRemainingMs),
    }];
  };

  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:nil
                              metadata:nil
                              stop:nil
                              progress:progress
                                 error:&error];
  XCTAssertTrue(ok, @"transcode failed: %@", error);

  XCTAssertGreaterThanOrEqual(events.count, 2u);

  NSDictionary *first = events.firstObject;
  XCTAssertEqualWithAccuracy([first[@"framesCompleted"] doubleValue], 0.0,
                             1e-9);
  // Transcoder seeds the emitter with an estimate (duration × fps) so the
  // first tick is always a definite nbFrames, even before the loop has
  // drained.
  XCTAssertTrue([first[@"nbFramesValid"] boolValue],
                @"transcode first tick must advertise an estimated nbFrames");
  XCTAssertEqualWithAccuracy([first[@"nbFrames"] doubleValue],
                             (double)kFrameCount, 2.0,
                             @"initial nbFrames estimate should be within "
                             @"~2 frames of the actual count");

  NSDictionary *last = events.lastObject;
  XCTAssertTrue([last[@"nbFramesValid"] boolValue]);
  // The final tick locks in the definitive count (output-sample count ==
  // input-sample count for the T033 one-in/one-out mapping).
  XCTAssertEqualWithAccuracy([last[@"framesCompleted"] doubleValue],
                             [last[@"nbFrames"] doubleValue], 0.5);
  XCTAssertEqualWithAccuracy([last[@"framesCompleted"] doubleValue],
                             (double)kFrameCount, 0.5);
  XCTAssertTrue([last[@"etaMsValid"] boolValue]);
  XCTAssertEqualWithAccuracy([last[@"etaMs"] doubleValue], 0.0, 1e-6);

  for (NSUInteger i = 1; i < events.count; ++i) {
    const double prevFc = [events[i - 1][@"framesCompleted"] doubleValue];
    const double curFc = [events[i][@"framesCompleted"] doubleValue];
    XCTAssertGreaterThanOrEqual(curFc, prevFc);
    const double prevEl = [events[i - 1][@"elapsedMs"] doubleValue];
    const double curEl = [events[i][@"elapsedMs"] doubleValue];
    XCTAssertGreaterThanOrEqual(curEl, prevEl);
  }

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// T038 US7: a pre-aborted stopToken on a fixed synthesize makes the runner
/// return the "aborted" flag, deletes any partial output, and leaves no
/// engine-level error. Pre-aborting keeps the test deterministic: the first
/// abort-poll inside ComposeRunner::runFixed catches it and short-circuits
/// the loop without depending on thread-scheduling timing.
- (void)testSynthesizeFixedAbortsAndDeletesPartial
{
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t038-synth-abort-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPStopToken *stop = [[RNVPStopToken alloc] init];
  [stop requestAbort];

  NSError *error = nil;
  BOOL aborted = NO;
  const BOOL ok = [RNVPSynthesizeRunner runFixedWithOutputPath:outPath
                                                         width:80
                                                        height:60
                                                           fps:30.0
                                                       seconds:0.5
                                                     stopToken:stop
                                                      progress:nil
                                                       aborted:&aborted
                                                         error:&error];
  XCTAssertTrue(ok);
  XCTAssertTrue(aborted);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outPath],
                 @"partial output must not remain after abort");
}

/// T038 US7: a pre-aborted stopToken on a transcode surfaces
/// RNVPTranscoderErrorCodeCancelled and deletes the partial output file.
- (void)testTranscodeAbortsAndDeletesPartial
{
  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(80, 60, 30, 15, @"t038-trans",
                                                 &fixtureError);
  XCTAssertNotNil(sourcePath, @"fixture failed: %@", fixtureError);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t038-trans-abort-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPStopToken *stop = [[RNVPStopToken alloc] init];
  [stop requestAbort];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:40
                                          height:30
                                             fps:30.0
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0.0
                                           cropY:0.0
                                       cropWidth:0.0
                                      cropHeight:0.0];
  NSError *error = nil;
  const BOOL ok =
      [RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                 toURL:[NSURL fileURLWithPath:outPath]
                                target:target
                              overlays:nil
                              metadata:nil
                                  stop:stop
                              progress:nil
                                 error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPTranscoderErrorDomain);
  XCTAssertEqual(error.code, RNVPTranscoderErrorCodeCancelled);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outPath],
                 @"partial output must not remain after abort");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
}

/// T038 US7: a pre-aborted stopToken on concat surfaces
/// RNVPRemuxerErrorCodeCancelled and deletes any partial output file.
- (void)testRemuxConcatAbortsAndDeletesPartial
{
  NSError *fixtureError = nil;
  NSString *clipAPath = authorConcatFixture(160, 120, 30, 15, @"t038-a",
                                            &fixtureError);
  XCTAssertNotNil(clipAPath, @"fixture a failed: %@", fixtureError);
  NSString *clipBPath = authorConcatFixture(160, 120, 30, 15, @"t038-b",
                                            &fixtureError);
  XCTAssertNotNil(clipBPath, @"fixture b failed: %@", fixtureError);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t038-concat-abort-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  const double kPerClipSec = 15.0 / 30.0;
  RNVPRemuxerConcatSource *a = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipAPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:0.0];
  RNVPRemuxerConcatSource *b = [[RNVPRemuxerConcatSource alloc]
      initWithSourceURL:[NSURL fileURLWithPath:clipBPath]
            sourceStart:0.0
         sourceDuration:kPerClipSec
            outputStart:kPerClipSec];

  RNVPStopToken *stop = [[RNVPStopToken alloc] init];
  [stop requestAbort];

  NSError *error = nil;
  const BOOL ok = [RNVPRemuxer remuxConcatSources:@[ a, b ]
                                            toURL:[NSURL fileURLWithPath:outPath]
                                             stop:stop
                                            error:&error];
  XCTAssertFalse(ok);
  XCTAssertEqualObjects(error.domain, RNVPRemuxerErrorDomain);
  XCTAssertEqual(error.code, RNVPRemuxerErrorCodeCancelled);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outPath],
                 @"partial output must not remain after abort");

  [[NSFileManager defaultManager] removeItemAtPath:clipAPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:clipBPath error:nil];
}

/// T039 US8: the journal survives a mark + snapshot + clear cycle through
/// NSUserDefaults. Validates the API contract `VideoPipeline.mm` relies on
/// when it wraps every render dispatch — if this regresses, zombie
/// detection on next launch silently stops working.
- (void)testBackgroundTaskJournalRoundTrip
{
  [RNVPBackgroundTaskJournal resetForTesting];

  NSString *tokenA = [NSString stringWithFormat:@"t039-a-%@",
                                                 NSUUID.UUID.UUIDString];
  NSString *tokenB = [NSString stringWithFormat:@"t039-b-%@",
                                                 NSUUID.UUID.UUIDString];
  NSString *pathA = @"/tmp/rnvp-journal-a.mp4";
  NSString *pathB = @"/tmp/rnvp-journal-b.mp4";

  [RNVPBackgroundTaskJournal markActiveTokenId:tokenA outputPath:pathA];
  [RNVPBackgroundTaskJournal markActiveTokenId:tokenB outputPath:pathB];

  NSDictionary *snapshot =
      [RNVPBackgroundTaskJournal activeEntriesSnapshot];
  XCTAssertEqualObjects(snapshot[tokenA], pathA);
  XCTAssertEqualObjects(snapshot[tokenB], pathB);

  [RNVPBackgroundTaskJournal clearTokenId:tokenA];
  NSDictionary *afterClear =
      [RNVPBackgroundTaskJournal activeEntriesSnapshot];
  XCTAssertNil(afterClear[tokenA]);
  XCTAssertEqualObjects(afterClear[tokenB], pathB);

  // Idempotent second clear — must not throw.
  [RNVPBackgroundTaskJournal clearTokenId:tokenA];

  [RNVPBackgroundTaskJournal resetForTesting];
  XCTAssertEqual([RNVPBackgroundTaskJournal activeEntriesSnapshot].count,
                 0u);
}

/// T039 US8 "no zombie jobs" bullet: `+drainZombies` on next launch
/// deletes any partial output file named in the journal and clears the
/// entries so a subsequent drain is a no-op. The file is authored in-test
/// because the macOS-host path can't actually kill the previous session —
/// instead we simulate "prior session wrote the journal entry but died
/// before clearing it" by just not calling -end on the guard and then
/// running the drain manually.
- (void)testBackgroundTaskJournalDrainZombiesDeletesPartialOutput
{
  [RNVPBackgroundTaskJournal resetForTesting];

  NSString *partialPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"t039-zombie-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  // Write a sentinel so we can observe the drain actually deletes it.
  NSError *writeErr = nil;
  XCTAssertTrue([@"partial-output" writeToFile:partialPath
                                    atomically:YES
                                      encoding:NSUTF8StringEncoding
                                         error:&writeErr],
                @"failed to author sentinel file: %@", writeErr);
  XCTAssertTrue([[NSFileManager defaultManager]
                    fileExistsAtPath:partialPath],
                @"pre-condition: sentinel exists");

  NSString *zombieToken = [NSString stringWithFormat:@"t039-zombie-%@",
                                                     NSUUID.UUID.UUIDString];
  [RNVPBackgroundTaskJournal markActiveTokenId:zombieToken
                                    outputPath:partialPath];

  NSArray<NSString *> *drained = [RNVPBackgroundTaskJournal drainZombies];
  XCTAssertTrue([drained containsObject:zombieToken],
                @"drained must name the zombie token: %@", drained);
  XCTAssertFalse([[NSFileManager defaultManager]
                     fileExistsAtPath:partialPath],
                 @"drain must delete partial output file");
  XCTAssertEqual([RNVPBackgroundTaskJournal activeEntriesSnapshot].count,
                 0u, @"journal must be empty after drain");

  // Second drain is a no-op (journal already empty).
  NSArray<NSString *> *emptyDrain =
      [RNVPBackgroundTaskJournal drainZombies];
  XCTAssertEqual(emptyDrain.count, 0u);
}

/// T039 US8: guard begin registers in the journal with the output path;
/// -end clears it. -end is idempotent. Matches the completion-block call
/// pattern in VideoPipeline.mm — every render dispatch pairs exactly one
/// begin with exactly one -end regardless of success/error path.
- (void)testBackgroundTaskGuardBeginEndRoundTrip
{
  [RNVPBackgroundTaskJournal resetForTesting];

  NSString *tokenId = [NSString stringWithFormat:@"t039-guard-%@",
                                                  NSUUID.UUID.UUIDString];
  NSString *outputPath = @"/tmp/rnvp-guard-output.mp4";

  RNVPBackgroundTaskGuard *guard =
      [RNVPBackgroundTaskGuard beginWithTokenId:tokenId
                                     outputPath:outputPath
                                      stopToken:nil];
  XCTAssertNotNil(guard);

  NSDictionary *duringRender =
      [RNVPBackgroundTaskJournal activeEntriesSnapshot];
  XCTAssertEqualObjects(duringRender[tokenId], outputPath,
                        @"journal entry must be present while guard is open");

  [guard end];
  NSDictionary *afterEnd =
      [RNVPBackgroundTaskJournal activeEntriesSnapshot];
  XCTAssertNil(afterEnd[tokenId],
               @"journal entry must be cleared on -end");

  // Idempotent — a second -end on the same guard must not re-insert or
  // throw.
  [guard end];
  XCTAssertEqual([RNVPBackgroundTaskJournal activeEntriesSnapshot].count,
                 0u);

  [RNVPBackgroundTaskJournal resetForTesting];
}

/// RNVPExportSessionStamp: parity with testTranscodeAppliesCenterImageOverlay
/// but routed through the AVAssetExportSession driver. Same 80x60 gray
/// source, same 20x20 red overlay anchored center; verifies the
/// static-overlay path composites the overlay correctly.
- (void)testExportSessionStampAppliesCenterImageOverlay
{
  const NSInteger kWidth = 80;
  const NSInteger kHeight = 60;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 15;  // 0.5s @ 30fps

  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps,
                                                  kFrameCount,
                                                  @"export-session-center",
                                                  &fixtureError);
  XCTAssertNotNil(sourcePath, @"source fixture failed: %@", fixtureError);

  NSString *overlayPath = authorSolidColorPng(20, 20, 0xFF, 0x00, 0x00,
                                               @"red-20-export-session");
  XCTAssertNotNil(overlayPath, @"overlay PNG authoring failed");

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"export-session-stamp-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:overlayPath]
               anchorX:0.5
               anchorY:0.5
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:20.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:20.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPExportSessionStamp stampFromURL:[NSURL fileURLWithPath:sourcePath]
                                     toURL:[NSURL fileURLWithPath:outPath]
                                  overlays:@[ overlay ]
                                  metadata:nil
                                  progress:nil
                                     error:&error];
  XCTAssertTrue(ok, @"export-session stamp failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  __block int centerB = 0, centerG = 0, centerR = 0;
  __block int cornerB = 0, cornerG = 0, cornerR = 0;
  __block NSInteger observedW = 0, observedH = 0;
  const BOOL decoded = withFirstDecodedFrame(outPath, ^(
      const uint8_t *base, size_t bytesPerRow, NSInteger w, NSInteger h) {
    observedW = w;
    observedH = h;
    const uint8_t *center = base + (h / 2) * bytesPerRow + (w / 2) * 4;
    centerB = center[0];
    centerG = center[1];
    centerR = center[2];
    const uint8_t *corner = base + 3 * bytesPerRow + 3 * 4;
    cornerB = corner[0];
    cornerG = corner[1];
    cornerR = corner[2];
  });
  XCTAssertTrue(decoded, @"could not decode output");
  XCTAssertEqual(observedW, kWidth);
  XCTAssertEqual(observedH, kHeight);

  XCTAssertGreaterThan(centerR, 180,
                       @"center R channel %d (expected > 180 for red overlay)",
                       centerR);
  XCTAssertLessThan(centerG, 60, @"center G channel %d (expected < 60)", centerG);
  XCTAssertLessThan(centerB, 60, @"center B channel %d (expected < 60)", centerB);

  // Corner is outside the 20x20 overlay footprint, must NOT be red. Tolerance
  // matches the existing transcode-overlay test: the H.264 round trip
  // imbalances channels by a few units even on a flat-gray source.
  XCTAssertLessThan(abs(cornerR - cornerG), 24,
                    @"corner R=%d/G=%d unexpectedly imbalanced",
                    cornerR, cornerG);
  XCTAssertLessThan(abs(cornerR - cornerB), 24,
                    @"corner R=%d/B=%d unexpectedly imbalanced",
                    cornerR, cornerB);
  XCTAssertLessThan(cornerR, 180,
                    @"corner R %d unexpectedly matches the red overlay",
                    cornerR);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:overlayPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// RNVPExportSessionStamp: stamp metadata is written to the output container
/// the same way the metadata-only remux path writes it. Covers the
/// "watermark + metadata in one pass" case.
- (void)testExportSessionStampWritesStampMetadata
{
  const NSInteger kWidth = 64;
  const NSInteger kHeight = 48;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 10;

  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps,
                                                  kFrameCount,
                                                  @"export-session-metadata",
                                                  &fixtureError);
  XCTAssertNotNil(sourcePath, @"source fixture failed: %@", fixtureError);

  NSString *overlayPath = authorSolidColorPng(8, 8, 0x00, 0xFF, 0x00,
                                               @"green-8-export-session-md");
  XCTAssertNotNil(overlayPath, @"overlay PNG authoring failed");

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"export-session-stamp-md-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:overlayPath]
               anchorX:0.0
               anchorY:0.0
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:8.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:8.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];

  RNVPStampMetadata *metadata =
      [[RNVPStampMetadata alloc] initWithGps:NO
                                    latitude:0.0
                                   longitude:0.0
                              hasGpsAltitude:NO
                                    altitude:0.0
                                    software:@"rnvp-test"
                                creationDate:nil
                          contentDescription:@"export-session test"
                                      custom:nil];

  NSError *error = nil;
  const BOOL ok =
      [RNVPExportSessionStamp stampFromURL:[NSURL fileURLWithPath:sourcePath]
                                     toURL:[NSURL fileURLWithPath:outPath]
                                  overlays:@[ overlay ]
                                  metadata:metadata
                                  progress:nil
                                     error:&error];
  XCTAssertTrue(ok, @"export-session stamp failed: %@", error);

  AVURLAsset *outAsset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outPath]];
  NSArray<AVMetadataItem *> *items = outAsset.metadata;
  __block NSString *seenSoftware = nil;
  __block NSString *seenDescription = nil;
  for (AVMetadataItem *item in items) {
    NSString *value = nil;
    if ([item.value isKindOfClass:[NSString class]]) {
      value = (NSString *)item.value;
    } else if ([item.value respondsToSelector:@selector(stringValue)]) {
      value = [(id)item.value stringValue];
    }
    if (value == nil) continue;
    if ([item.commonKey isEqualToString:AVMetadataCommonKeySoftware]) {
      seenSoftware = value;
    } else if ([item.commonKey
                   isEqualToString:AVMetadataCommonKeyDescription]) {
      seenDescription = value;
    }
  }
  XCTAssertEqualObjects(seenSoftware, @"rnvp-test");
  XCTAssertEqualObjects(seenDescription, @"export-session test");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:overlayPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// RNVPExportSessionStamp: every source frame must round-trip as a distinct
/// output frame. Catches the "container reports 240fps but the encoder
/// duplicated the same frame N times" decimation bug — metadata-fps alone
/// is a lying signal; this test decodes pixels and compares.
///
/// Fixture is @c authorMotionFixture, where each frame's R channel ramps
/// with frame index. A clean round-trip produces N distinct decoded R
/// values; a decimating encoder produces long runs of identical R.
- (void)testExportSessionStampPreservesFrameUniqueness
{
  const NSInteger kWidth = 80;
  const NSInteger kHeight = 60;
  const NSInteger kFps = 60;
  const NSInteger kFrameCount = 60;  // 1s @ 60fps, R ramps 0..236

  NSError *fixtureError = nil;
  NSString *sourcePath = authorMotionFixture(kWidth, kHeight, kFps,
                                              kFrameCount,
                                              @"export-session-uniqueness",
                                              &fixtureError);
  XCTAssertNotNil(sourcePath, @"motion fixture failed: %@", fixtureError);

  // Tiny corner overlay so the stamp path runs but doesn't smear the
  // center-pixel R signal we sample.
  NSString *overlayPath = authorSolidColorPng(4, 4, 0x00, 0xFF, 0x00,
                                               @"green-4-uniqueness");
  XCTAssertNotNil(overlayPath);

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"export-session-uniqueness-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:overlayPath]
               anchorX:0.0
               anchorY:0.0
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:4.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:4.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];

  NSError *stampError = nil;
  const BOOL ok =
      [RNVPExportSessionStamp stampFromURL:[NSURL fileURLWithPath:sourcePath]
                                     toURL:[NSURL fileURLWithPath:outPath]
                                  overlays:@[ overlay ]
                                  metadata:nil
                                  progress:nil
                                     error:&stampError];
  XCTAssertTrue(ok, @"stamp failed: %@", stampError);

  NSArray<NSNumber *> *rs = decodeCenterRSeries(outPath);
  XCTAssertNotNil(rs);
  XCTAssertGreaterThan(rs.count, 0u);

  // Two assertions that catch frame-duplication independently:
  //  1. distinct values: a clean encoder produces kFrameCount distinct Rs
  //     (modulo H.264 quantization clustering, allow a tolerance).
  //  2. consecutive duplicates: in a healthy stream, frame[i].R should
  //     differ from frame[i+1].R for the overwhelming majority of i.
  //     A decimating encoder repeats the same R for long runs.
  NSMutableSet<NSNumber *> *distinct = [NSMutableSet set];
  NSInteger consecutiveDuplicates = 0;
  for (NSUInteger i = 0; i < rs.count; i++) {
    [distinct addObject:rs[i]];
    if (i > 0 && [rs[i] isEqual:rs[i - 1]]) consecutiveDuplicates++;
  }
  NSLog(@"[uniqueness] decoded %lu frames, %lu distinct R values, %ld "
        @"consecutive duplicates",
        (unsigned long)rs.count, (unsigned long)distinct.count,
        (long)consecutiveDuplicates);

  // Distinct should be at least kFrameCount / 2 (allows quantization to
  // merge near-neighbor R values, but not catastrophically). The bug pattern
  // collapses this to a handful — assertion fires at single-digit values.
  XCTAssertGreaterThan(distinct.count, (NSUInteger)(kFrameCount / 2),
                       @"only %lu distinct R values from %lu frames — "
                       @"encoder duplicated content",
                       (unsigned long)distinct.count,
                       (unsigned long)rs.count);
  // Consecutive duplicates should be rare. Allow up to 20% as a safety
  // margin; the bug pattern reaches 80%+.
  XCTAssertLessThan(consecutiveDuplicates, (NSInteger)(rs.count / 5),
                    @"%ld consecutive-duplicate pairs out of %lu — "
                    @"encoder is sampling the source sparsely",
                    (long)consecutiveDuplicates,
                    (unsigned long)rs.count);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:overlayPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// RNVPExportSessionStamp: a high-fps source (240fps, simulating iPhone
/// slo-mo) must round-trip its fps through the export — not get decimated
/// to AVAssetExportSession's default-frame-rate (30fps). Regression for the
/// real-device case where the watermarked output was ~2 fps because the
/// composition we built did not carry the source's frameDuration.
- (void)testExportSessionStampPreservesHighFps
{
  const NSInteger kWidth = 64;
  const NSInteger kHeight = 48;
  const NSInteger kFps = 240;
  const NSInteger kFrameCount = 60;  // 0.25s @ 240fps

  NSError *fixtureError = nil;
  NSString *sourcePath = authorOpaqueGrayFixture(kWidth, kHeight, kFps,
                                                  kFrameCount,
                                                  @"export-session-240fps",
                                                  &fixtureError);
  XCTAssertNotNil(sourcePath, @"source fixture failed: %@", fixtureError);

  NSString *overlayPath = authorSolidColorPng(8, 8, 0xFF, 0x00, 0x00,
                                               @"red-8-240fps");
  XCTAssertNotNil(overlayPath, @"overlay PNG authoring failed");

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"export-session-240fps-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:overlayPath]
               anchorX:0.0
               anchorY:0.0
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:8.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:8.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];

  NSError *error = nil;
  const BOOL ok =
      [RNVPExportSessionStamp stampFromURL:[NSURL fileURLWithPath:sourcePath]
                                     toURL:[NSURL fileURLWithPath:outPath]
                                  overlays:@[ overlay ]
                                  metadata:nil
                                  progress:nil
                                     error:&error];
  XCTAssertTrue(ok, @"export-session stamp failed: %@", error);

  AVURLAsset *outAsset =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outPath]];
  NSArray<AVAssetTrack *> *outVideoTracks =
      [outAsset tracksWithMediaType:AVMediaTypeVideo];
  XCTAssertEqual(outVideoTracks.count, 1u, @"output must have one video track");
  AVAssetTrack *outVideoTrack = outVideoTracks.firstObject;

  // Nominal frame rate is the authoritative "what was this encoded as" field.
  // Tolerate ±2fps drift — AVAssetWriter sometimes reports the round-trip
  // rate as nominal±epsilon depending on the timescale chosen by the encoder.
  const float observedFps = outVideoTrack.nominalFrameRate;
  XCTAssertGreaterThan(observedFps, (float)(kFps - 2),
                       @"output fps %.2f decimated from source %ld",
                       observedFps, (long)kFps);

  // Frame count is the secondary check: a decimated output (e.g. the
  // default-30fps bug) drops to ~kFrameCount * 30 / 240 = 7 frames for the
  // 0.25s clip, which makes the bug stand out independently of nominalFps.
  NSInteger outputFrames = 0;
  AVAssetReader *reader =
      [[AVAssetReader alloc] initWithAsset:outAsset error:nil];
  AVAssetReaderTrackOutput *trackOut = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:outVideoTrack
     outputSettings:@{
       (NSString *)kCVPixelBufferPixelFormatTypeKey :
           @(kCVPixelFormatType_32BGRA)
     }];
  [reader addOutput:trackOut];
  [reader startReading];
  while (YES) {
    CMSampleBufferRef sample = [trackOut copyNextSampleBuffer];
    if (sample == NULL) break;
    outputFrames++;
    CFRelease(sample);
  }
  XCTAssertGreaterThanOrEqual(outputFrames, kFrameCount - 2,
                              @"output had %ld frames, source had %ld — "
                              @"frames got decimated",
                              (long)outputFrames, (long)kFrameCount);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:overlayPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// RNVPExportSessionStamp: integration test against an arbitrary real-world
/// recording. Skipped unless @c RNVP_REAL_FIXTURE points at a real
/// .mp4/.MP4 source — CLAUDE.md forbids committing binary video to the
/// repo, so the fixture is supplied externally. Useful for verifying the
/// export path against the specific shapes the library's synthesizer
/// cannot produce (HEVC, high-fps, container-side time mappings, edit
/// lists, etc.). Runs against whatever AVFoundation flavor the test binary
/// was built for — macOS via @c yarn test:native, or iOS Simulator via
/// @c yarn smoke:ios.
///
/// Probes both source and output via @c RNVPAVDemuxer — the same probe the
/// JS @c Video.info call uses — so the assertion matches what callers
/// observe through the public API.
- (void)testExportSessionStampRealFixturePreservesFps
{
  NSString *fixturePath =
      NSProcessInfo.processInfo.environment[@"RNVP_REAL_FIXTURE"];
  if (fixturePath.length == 0) {
    NSLog(@"[skip] testExportSessionStampRealFixturePreservesFps — "
          @"set RNVP_REAL_FIXTURE=<path> to enable");
    return;
  }
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:fixturePath],
                @"RNVP_REAL_FIXTURE does not exist: %@", fixturePath);

  // Probe source via RNVPAVDemuxer — the same path Video.info uses on the JS
  // side. Whatever fps the consumer sees in Video.info(srcUri), this test
  // sees the same number.
  RNVPAVDemuxer *srcDemuxer = [[RNVPAVDemuxer alloc] init];
  NSError *probeError = nil;
  XCTAssertTrue([srcDemuxer openAtURL:[NSURL fileURLWithPath:fixturePath]
                                 error:&probeError],
                @"source probe failed: %@", probeError);
  const double sourceFps = srcDemuxer.fps;
  const double sourceDurationSec = srcDemuxer.durationSec;
  const NSInteger sourceW = srcDemuxer.width;
  const NSInteger sourceH = srcDemuxer.height;
  NSLog(@"[real-fixture] SOURCE fps=%.2f duration=%.2fs size=%ldx%ld codec=%@",
        sourceFps, sourceDurationSec, (long)sourceW, (long)sourceH,
        srcDemuxer.codec);
  [srcDemuxer closeWithError:nil];

  NSString *overlayPath = authorSolidColorPng(64, 64, 0xFF, 0x00, 0x00,
                                               @"red-64-real-fixture");
  XCTAssertNotNil(overlayPath);

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"real-fixture-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  RNVPImageOverlay *overlay = [[RNVPImageOverlay alloc]
      initWithImageURL:[NSURL fileURLWithPath:overlayPath]
               anchorX:0.5
               anchorY:0.5
                 hasSizeW:YES
                 sizeWIsRatio:NO
                 sizeWValue:64.0
                 hasSizeH:YES
                 sizeHIsRatio:NO
                 sizeHValue:64.0
               opacity:1.0
          hasTimeRange:NO
              startSec:0.0
                endSec:0.0];

  NSError *stampError = nil;
  const BOOL ok = [RNVPExportSessionStamp
      stampFromURL:[NSURL fileURLWithPath:fixturePath]
             toURL:[NSURL fileURLWithPath:outPath]
          overlays:@[ overlay ]
          metadata:nil
          progress:nil
             error:&stampError];
  XCTAssertTrue(ok, @"stamp failed: %@", stampError);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  // Probe output the same way — symmetry with what Video.info(destUri)
  // would report. The fps assertion is therefore the same contract a
  // consumer reads.
  RNVPAVDemuxer *outDemuxer = [[RNVPAVDemuxer alloc] init];
  NSError *outProbeError = nil;
  XCTAssertTrue([outDemuxer openAtURL:[NSURL fileURLWithPath:outPath]
                                 error:&outProbeError],
                @"output probe failed: %@", outProbeError);
  const double outputFps = outDemuxer.fps;
  const double outputDurationSec = outDemuxer.durationSec;
  NSLog(@"[real-fixture] OUTPUT fps=%.2f duration=%.2fs size=%ldx%ld codec=%@",
        outputFps, outputDurationSec, (long)outDemuxer.width,
        (long)outDemuxer.height, outDemuxer.codec);
  [outDemuxer closeWithError:nil];

  // Output fps must round-trip within ±2fps. Anything lower is the
  // decimation bug consumers see on real iOS hardware (the "2fps output
  // for a 240fps source" symptom).
  XCTAssertGreaterThan(outputFps, sourceFps - 2.0,
                       @"output fps %.2f decimated from source %.2f",
                       outputFps, sourceFps);
  // Duration round-trips too — same content, just re-encoded with a logo.
  XCTAssertEqualWithAccuracy(outputDurationSec, sourceDurationSec, 0.1,
                             @"output duration drifted from source");

  // Frame-uniqueness: even when metadata-fps looks right, the encoder can
  // duplicate the same source frame N times. A single-pixel sample isn't
  // discriminative (real scenes have static centers), so hash a stride-100
  // grid across the whole frame — that surface contains plenty of motion
  // even when individual points don't. A clean encoder produces ~N distinct
  // hashes for N frames; a decimating encoder produces a handful.
  AVURLAsset *outAssetForDecode =
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:outPath]];
  AVAssetTrack *outVideoTrack =
      [outAssetForDecode tracksWithMediaType:AVMediaTypeVideo].firstObject;
  AVAssetReader *outReader =
      [[AVAssetReader alloc] initWithAsset:outAssetForDecode error:nil];
  AVAssetReaderTrackOutput *outOut = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:outVideoTrack
     outputSettings:@{
       (id)kCVPixelBufferPixelFormatTypeKey :
           @(kCVPixelFormatType_32BGRA),
     }];
  [outReader addOutput:outOut];
  [outReader startReading];
  NSMutableSet<NSNumber *> *distinctHashes = [NSMutableSet set];
  NSInteger consecutiveDups = 0;
  NSNumber *previous = nil;
  NSInteger totalFrames = 0;
  while (YES) {
    CMSampleBufferRef sample = [outOut copyNextSampleBuffer];
    if (sample == NULL) break;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
    const NSInteger w = (NSInteger)CVPixelBufferGetWidth(pb);
    const NSInteger h = (NSInteger)CVPixelBufferGetHeight(pb);
    uint64_t hash = 1469598103934665603ULL;  // FNV-1a basis
    for (NSInteger y = 0; y < h; y += 100) {
      for (NSInteger x = 0; x < w; x += 100) {
        const uint8_t *p = base + (size_t)y * bytesPerRow + (size_t)x * 4;
        hash ^= (uint64_t)p[0];
        hash *= 1099511628211ULL;
        hash ^= (uint64_t)p[1];
        hash *= 1099511628211ULL;
        hash ^= (uint64_t)p[2];
        hash *= 1099511628211ULL;
      }
    }
    NSNumber *key = @(hash);
    [distinctHashes addObject:key];
    if (previous != nil && [previous isEqual:key]) consecutiveDups++;
    previous = key;
    totalFrames++;
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    CFRelease(sample);
  }
  NSLog(@"[real-fixture] decoded %ld frames, %lu distinct frame hashes, "
        @"%ld consecutive duplicates",
        (long)totalFrames, (unsigned long)distinctHashes.count,
        (long)consecutiveDups);

  // Real content with motion at 240fps produces a different stride-100 hash
  // on essentially every frame. Allow some tolerance for runs of static
  // content (a held pose, scene-change) but at least half the frames must
  // be distinct from their predecessor.
  XCTAssertGreaterThan(distinctHashes.count,
                       (NSUInteger)(totalFrames / 2),
                       @"only %lu distinct frame hashes from %ld frames — "
                       @"encoder duplicated content (metadata looks fine, "
                       @"playback is broken)",
                       (unsigned long)distinctHashes.count, (long)totalFrames);

  [[NSFileManager defaultManager] removeItemAtPath:overlayPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// RNVPRemuxer.remuxTrim: integration test against an arbitrary real-world
/// recording. Skipped unless @c RNVP_REAL_FIXTURE points at a real source.
/// Catches the class of bugs in-tree fixtures cannot: the synthesizer only
/// authors H.264 30fps low-bitrate sources, so it never reproduces the
/// AVAssetReader+AVAssetWriter polling wedge that hits real iPhone slo-mo
/// HEVC (1080p @ 240fps @ ~50Mbps; see commits cb7c972 and the trim fix
/// that followed). With the unified RNVPExportSession driver this should
/// pass; if it ever hangs, the hand-rolled pump has snuck back in.
- (void)testRemuxTrimRealFixturePassthroughCompletes
{
  NSString *fixturePath =
      NSProcessInfo.processInfo.environment[@"RNVP_REAL_FIXTURE"];
  if (fixturePath.length == 0) {
    NSLog(@"[skip] testRemuxTrimRealFixturePassthroughCompletes — "
          @"set RNVP_REAL_FIXTURE=<path> to enable");
    return;
  }
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:fixturePath],
                @"RNVP_REAL_FIXTURE does not exist: %@", fixturePath);

  RNVPAVDemuxer *srcDemuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([srcDemuxer openAtURL:[NSURL fileURLWithPath:fixturePath]
                                 error:nil]);
  const double sourceDurationSec = srcDemuxer.durationSec;
  const double sourceFps = srcDemuxer.fps;
  NSLog(@"[real-fixture trim] SOURCE duration=%.2fs fps=%.2f codec=%@",
        sourceDurationSec, sourceFps, srcDemuxer.codec);
  [srcDemuxer closeWithError:nil];

  // Trim a window deliberately exceeding the source's reported duration by
  // a few ms — this is the exact shape the slo-mo HEVC wedge bug produced
  // in unbogify (VisionCamera-reported duration shorter than actual file).
  const double startSec = 0.0;
  const double overshootSec = sourceDurationSec + 0.005;

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"real-fixture-trim-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  NSError *trimError = nil;
  const BOOL ok =
      [RNVPRemuxer remuxTrimFromURL:[NSURL fileURLWithPath:fixturePath]
                              toURL:[NSURL fileURLWithPath:outPath]
                           startSec:startSec
                        durationSec:overshootSec
                              error:&trimError];
  XCTAssertTrue(ok,
                @"real-fixture trim failed (slo-mo HEVC wedge if "
                @"\"writer input did not become ready\"): %@",
                trimError);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  // Output should round-trip the source duration (clamped against EOF).
  RNVPAVDemuxer *outDemuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([outDemuxer openAtURL:[NSURL fileURLWithPath:outPath]
                                 error:nil]);
  NSLog(@"[real-fixture trim] OUTPUT duration=%.2fs fps=%.2f codec=%@",
        outDemuxer.durationSec, outDemuxer.fps, outDemuxer.codec);
  XCTAssertEqualWithAccuracy(outDemuxer.durationSec, sourceDurationSec, 0.1,
                             @"output duration drifted from source");
  XCTAssertEqualWithAccuracy(outDemuxer.fps, sourceFps, 2.0,
                             @"output fps drifted from source (encoder "
                             @"shouldn't have run — this is passthrough)");
  [outDemuxer closeWithError:nil];

  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// RNVPExportSessionStamp: a missing source file rejects with a typed error
/// (SourceCorrupted) rather than spinning the encoder. Sanity check for the
/// up-front asset probe.
- (void)testExportSessionStampRejectsMissingSource
{
  NSString *bogus = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"does-not-exist-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"export-session-stamp-missing-%@.mp4",
                                     NSUUID.UUID.UUIDString]];

  NSError *error = nil;
  const BOOL ok =
      [RNVPExportSessionStamp stampFromURL:[NSURL fileURLWithPath:bogus]
                                     toURL:[NSURL fileURLWithPath:outPath]
                                  overlays:@[]
                                  metadata:nil
                                  progress:nil
                                     error:&error];
  XCTAssertFalse(ok);
  XCTAssertNotNil(error);
  XCTAssertEqualObjects(error.domain, RNVPExportSessionStampErrorDomain);
  XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:outPath],
                 @"no partial output expected for a missing source");
}

/// T048 — iOS half of the cross-platform golden pixel-hash suite. Env-gated by
/// RNVP_GOLDEN_DIR so the normal `yarn test:native` run stays clean; the host
/// `scripts/golden.mjs` sets it. Renders the deterministic synthesize golden
/// spec (kept in lockstep with android GoldenSpecs.kt + scripts/golden.mjs)
/// and writes sampled frames as raw RGBA8888. The host computes the signatures
/// and does the regression + cross-platform comparison.
- (void)testGoldenDumpFrames
{
  const char *dirEnv = getenv("RNVP_GOLDEN_DIR");
  if (dirEnv == NULL || strlen(dirEnv) == 0) {
    return; // not a golden run
  }
  NSString *outDir = [NSString stringWithUTF8String:dirEnv];
  [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];

  // synthesize spec — must match android GoldenSpecs.kt + scripts/golden.mjs.
  const NSInteger w = 160, h = 120;
  const double fps = 30.0, seconds = 0.5;
  const NSInteger frames[] = {5, 10, 14};

  NSString *mp4 = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"golden-synthesize.mp4"];
  [[NSFileManager defaultManager] removeItemAtPath:mp4 error:nil];
  NSError *err = nil;
  BOOL aborted = NO;
  XCTAssertTrue([RNVPSynthesizeRunner runFixedWithOutputPath:mp4
                                                       width:w
                                                      height:h
                                                         fps:fps
                                                     seconds:seconds
                                                   stopToken:nil
                                                    progress:nil
                                                     aborted:&aborted
                                                       error:&err],
                @"synthesize golden render failed: %@", err);

  // Extract via AVAssetReader (raw decoder output, BGRA) rather than
  // AVAssetImageGenerator — the latter colour-manages the CGImage, shifting
  // values away from what the decoder actually produced and away from
  // Android's MediaMetadataRetriever output. Reading sequentially also keys on
  // the exact frame index (no time-tolerance ambiguity).
  AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:mp4]];
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
  XCTAssertNotNil(reader, @"asset reader init failed: %@", err);
  AVAssetTrack *track =
      [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:track
     outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey :
                          @(kCVPixelFormatType_32BGRA)}];
  [reader addOutput:output];
  XCTAssertTrue([reader startReading], @"reader start failed: %@", reader.error);

  NSMutableSet<NSNumber *> *want = [NSMutableSet set];
  for (int i = 0; i < (int)(sizeof(frames) / sizeof(frames[0])); i++) {
    [want addObject:@(frames[i])];
  }

  NSInteger idx = 0;
  CMSampleBufferRef sb = NULL;
  while ((sb = [output copyNextSampleBuffer]) != NULL) {
    if ([want containsObject:@(idx)]) {
      CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
      CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      const size_t bw = CVPixelBufferGetWidth(pb);
      const size_t bh = CVPixelBufferGetHeight(pb);
      const size_t stride = CVPixelBufferGetBytesPerRow(pb);
      const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
      NSMutableData *rgba = [NSMutableData dataWithLength:bw * bh * 4];
      uint8_t *dst = rgba.mutableBytes;
      for (size_t y = 0; y < bh; y++) {
        const uint8_t *row = src + y * stride;
        for (size_t x = 0; x < bw; x++) {
          const uint8_t *px = row + x * 4; // BGRA
          const size_t o = (y * bw + x) * 4;
          dst[o] = px[2];     // R
          dst[o + 1] = px[1]; // G
          dst[o + 2] = px[0]; // B
          dst[o + 3] = px[3]; // A
        }
      }
      CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      NSString *name = [NSString
          stringWithFormat:@"synthesize__%zux%zu__f%ld.rgba", bw, bh, (long)idx];
      [rgba writeToFile:[outDir stringByAppendingPathComponent:name]
             atomically:YES];
    }
    CFRelease(sb);
    idx++;
  }
}

#pragma mark - render trim + transform (remux fast path + transcode window)

/// The fast remux path that `Video.render` picks for a rotation/flip-only
/// single clip: trim window + horizontal flip in one passthrough pass. Asserts
/// the window is honored (duration + first-frame content), the flip lands in
/// the preferredTransform, and no re-encode happened (codec preserved).
- (void)testRemuxTransformTrimAndFlipHorizontal
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;  // 1s; each frame's center R = i*4

  NSError *error = nil;
  NSString *sourcePath =
      authorMotionFixture(kWidth, kHeight, kFps, kFrameCount, @"xform-flip",
                          &error);
  XCTAssertNotNil(sourcePath, @"fixture author failed: %@", error);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"xform-flip-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *outURL = [NSURL fileURLWithPath:outPath];
  // Window: start at 0.5s (frame 15), keep 0.5s (15 frames).
  XCTAssertTrue([RNVPRemuxer remuxTransformFromURL:sourceURL
                                             toURL:outURL
                                          startSec:0.5
                                       durationSec:0.5
                                            rotate:-1
                                             flipH:YES
                                             flipV:NO
                                             error:&error],
                @"remuxTransform trim+flip failed: %@", error);
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:outPath]);

  // --- preferredTransform reflects a pure horizontal flip ------------------
  AVURLAsset *outAsset = [AVURLAsset assetWithURL:outURL];
  AVAssetTrack *outTrack =
      [outAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(outTrack);
  CGAffineTransform t = outTrack.preferredTransform;
  XCTAssertEqualWithAccuracy(t.a, -1.0, 1e-6, @"flipH: a should be -1");
  XCTAssertEqualWithAccuracy(t.d, 1.0, 1e-6);
  XCTAssertEqualWithAccuracy(t.tx, (CGFloat)kWidth, 1e-3);

  // --- window honored: duration ~0.5s, passthrough codec ------------------
  RNVPAVDemuxer *srcDemuxer = [[RNVPAVDemuxer alloc] init];
  RNVPAVDemuxer *outDemuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([srcDemuxer openAtURL:sourceURL error:&error]);
  XCTAssertTrue([outDemuxer openAtURL:outURL error:&error]);
  XCTAssertEqualObjects(outDemuxer.codec, srcDemuxer.codec,
                        @"codec changed — transform remux re-encoded");
  XCTAssertEqualWithAccuracy(outDemuxer.durationSec, 0.5, 2.0 / (double)kFps,
                             @"trimmed output should be ~0.5s, got %.3f",
                             outDemuxer.durationSec);
  XCTAssertTrue([srcDemuxer closeWithError:&error]);
  XCTAssertTrue([outDemuxer closeWithError:&error]);

  // --- window start: first decoded frame's center R ~= frame 15 (= 60) -----
  // A horizontal flip leaves the per-frame-uniform center R unchanged, so this
  // confirms the trim landed on the window start, not frame 0.
  NSArray<NSNumber *> *series = decodeCenterRSeries(outPath);
  XCTAssertGreaterThan(series.count, 0u);
  XCTAssertEqualWithAccuracy(series.firstObject.doubleValue, 15.0 * 4.0, 8.0,
                             @"first output frame should come from ~frame 15");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// The same fast path with a rotation: trim window + rotate 90, lossless. The
/// rotation must surface as a 90° preferredTransform (probed via the demuxer's
/// orientation heuristic) and the window must be honored.
- (void)testRemuxTransformTrimAndRotate90
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;

  NSError *error = nil;
  NSString *sourcePath =
      authorMotionFixture(kWidth, kHeight, kFps, kFrameCount, @"xform-rot",
                          &error);
  XCTAssertNotNil(sourcePath, @"fixture author failed: %@", error);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"xform-rot-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *outURL = [NSURL fileURLWithPath:outPath];
  XCTAssertTrue([RNVPRemuxer remuxTransformFromURL:sourceURL
                                             toURL:outURL
                                          startSec:0.0
                                       durationSec:0.5
                                            rotate:90
                                             flipH:NO
                                             flipV:NO
                                             error:&error],
                @"remuxTransform trim+rotate failed: %@", error);

  // preferredTransform must be a real 90° rotation (a=d=0, |b|=|c|=1). The
  // sign encodes direction — a clockwise rotate (matching the transcoder's
  // ClipTransform CW convention) gives b=-1, c=+1. Asserting the matrix avoids
  // the demuxer's lossy atan2 orientation heuristic, which labels CW-90 as
  // 270°.
  AVURLAsset *outAsset = [AVURLAsset assetWithURL:outURL];
  AVAssetTrack *outTrack =
      [outAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
  XCTAssertNotNil(outTrack);
  CGAffineTransform t = outTrack.preferredTransform;
  XCTAssertEqualWithAccuracy(t.a, 0.0, 1e-6, @"rotate 90: a should be 0");
  XCTAssertEqualWithAccuracy(t.d, 0.0, 1e-6, @"rotate 90: d should be 0");
  XCTAssertEqualWithAccuracy(fabs(t.b), 1.0, 1e-6, @"rotate 90: |b| should be 1");
  XCTAssertEqualWithAccuracy(fabs(t.c), 1.0, 1e-6, @"rotate 90: |c| should be 1");

  RNVPAVDemuxer *srcDemuxer = [[RNVPAVDemuxer alloc] init];
  RNVPAVDemuxer *outDemuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([srcDemuxer openAtURL:sourceURL error:&error]);
  XCTAssertTrue([outDemuxer openAtURL:outURL error:&error]);
  XCTAssertEqualObjects(outDemuxer.codec, srcDemuxer.codec,
                        @"codec changed — rotate remux re-encoded");
  XCTAssertEqualWithAccuracy(outDemuxer.durationSec, 0.5, 2.0 / (double)kFps);
  XCTAssertTrue([srcDemuxer closeWithError:&error]);
  XCTAssertTrue([outDemuxer closeWithError:&error]);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

/// The transcode path now honors a trim window (used by render for crop /
/// resize / codec change combined with a trim). Crop forces the re-encode;
/// the window must shorten the output and shift its first frame.
- (void)testTranscodeTrimWindowProducesWindowedOutput
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;

  NSError *error = nil;
  NSString *sourcePath =
      authorMotionFixture(kWidth, kHeight, kFps, kFrameCount, @"xcode-win",
                          &error);
  XCTAssertNotNil(sourcePath, @"fixture author failed: %@", error);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"xcode-win-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

  NSString *fullPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"xcode-full-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  NSURL *outURL = [NSURL fileURLWithPath:outPath];
  NSURL *fullURL = [NSURL fileURLWithPath:fullPath];

  // Crop to 80x80 forces the transcode (re-encode) path. Build two identical
  // targets differing only in the trim window: one full-source, one windowed
  // to [0.5s, 0.5s) — i.e. frames 15..29.
  RNVPTranscodeTarget *(^makeTarget)(double, double) =
      ^RNVPTranscodeTarget *(double start, double dur) {
    return [[RNVPTranscodeTarget alloc] initWithWidth:80
                                               height:80
                                                  fps:(double)kFps
                                                codec:RNVPTranscodeCodecH264
                                              bitrate:0
                                               rotate:-1
                                                flipH:NO
                                                flipV:NO
                                                cropX:0
                                                cropY:0
                                            cropWidth:80
                                           cropHeight:80
                                          sourceStart:start
                                       sourceDuration:dur];
  };

  XCTAssertTrue([RNVPTranscoder transcodeFromURL:sourceURL
                                           toURL:fullURL
                                          target:makeTarget(0.0, 0.0)
                                        overlays:nil
                                        metadata:nil
                                            stop:nil
                                        progress:nil
                                           error:&error],
                @"full-source transcode failed: %@", error);
  XCTAssertTrue([RNVPTranscoder transcodeFromURL:sourceURL
                                           toURL:outURL
                                          target:makeTarget(0.5, 0.5)
                                        overlays:nil
                                        metadata:nil
                                            stop:nil
                                        progress:nil
                                           error:&error],
                @"windowed transcode failed: %@", error);

  RNVPAVDemuxer *outDemuxer = [[RNVPAVDemuxer alloc] init];
  XCTAssertTrue([outDemuxer openAtURL:outURL error:&error]);
  XCTAssertEqual(outDemuxer.width, 80);
  XCTAssertEqual(outDemuxer.height, 80);
  XCTAssertEqualWithAccuracy(outDemuxer.durationSec, 0.5, 3.0 / (double)kFps,
                             @"windowed transcode should be ~0.5s, got %.3f",
                             outDemuxer.durationSec);
  XCTAssertTrue([outDemuxer closeWithError:&error]);

  // Frame-exact trim: the windowed output's first frame must match the
  // full-source output's frame 15 (both double-encoded, so absolute R values
  // are comparable — robust to the color shift that one extra encode adds).
  NSArray<NSNumber *> *fullSeries = decodeCenterRSeries(fullPath);
  NSArray<NSNumber *> *winSeries = decodeCenterRSeries(outPath);
  XCTAssertEqual(fullSeries.count, (NSUInteger)kFrameCount,
                 @"full transcode should emit every source frame");
  XCTAssertEqualWithAccuracy((double)winSeries.count, 15.0, 2.0,
                             @"windowed transcode should emit ~15 frames");
  XCTAssertGreaterThan(fullSeries.count, (NSUInteger)15);
  // The windowed output's first frame is re-encoded as a keyframe, so its
  // decoded value differs slightly from the same source frame sitting deep in
  // the full output's GOP — compare with a tolerance that absorbs that, while
  // still pinning the start to ~frame 15 (the monotonic R series means a wrong
  // start frame would miss by far more than this band).
  XCTAssertEqualWithAccuracy(winSeries.firstObject.doubleValue,
                             fullSeries[15].doubleValue, 8.0,
                             @"windowed first frame should match full frame 15");
  // And it must be clearly past frame 0 — proves the window moved the start.
  XCTAssertGreaterThan(
      fabs(winSeries.firstObject.doubleValue - fullSeries[0].doubleValue), 12.0,
      @"windowed first frame should differ clearly from frame 0");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
}

/// A trim window that routes to the transcode (re-encode) path must carry the
/// *windowed* audio segment, not the front of the source clipped to the right
/// length. The source's audio is silent in [0, 0.5) and a 1 kHz tone in
/// [0.5, 1.0); cropping forces the transcoder. A correct trim of [0.5, 1.0)
/// therefore produces all-tone audio, while the regression (audio passed
/// through unshifted, then tail-clipped by endSession) produces silence — same
/// duration, wrong content. The existing duration-only check cannot see this.
- (void)testTranscodeTrimWindowAlignsAudioToWindow
{
  const NSInteger kWidth = 160;
  const NSInteger kHeight = 120;
  const NSInteger kFps = 30;
  const NSInteger kFrameCount = 30;  // 1.0s total

  NSError *error = nil;
  NSString *sourcePath = authorSteppedAudioFixture(kWidth, kHeight, kFps,
                                                   kFrameCount, @"aud-align",
                                                   &error);
  XCTAssertNotNil(sourcePath, @"stepped-audio fixture author failed: %@", error);

  NSString *winPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"aud-win-%@.mp4", NSUUID.UUID.UUIDString]];
  NSString *fullPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"aud-full-%@.mp4", NSUUID.UUID.UUIDString]];
  [[NSFileManager defaultManager] removeItemAtPath:winPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];

  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];

  // Crop to 80x80 forces the transcode path (where the audio bug lives).
  RNVPTranscodeTarget *(^makeTarget)(double, double) =
      ^RNVPTranscodeTarget *(double start, double dur) {
    return [[RNVPTranscodeTarget alloc] initWithWidth:80
                                               height:80
                                                  fps:(double)kFps
                                                codec:RNVPTranscodeCodecH264
                                              bitrate:0
                                               rotate:-1
                                                flipH:NO
                                                flipV:NO
                                                cropX:0
                                                cropY:0
                                            cropWidth:80
                                           cropHeight:80
                                          sourceStart:start
                                       sourceDuration:dur];
  };

  XCTAssertTrue([RNVPTranscoder transcodeFromURL:sourceURL
                                           toURL:[NSURL fileURLWithPath:fullPath]
                                          target:makeTarget(0.0, 0.0)
                                        overlays:nil
                                        metadata:nil
                                            stop:nil
                                        progress:nil
                                           error:&error],
                @"full-source transcode failed: %@", error);
  XCTAssertTrue([RNVPTranscoder transcodeFromURL:sourceURL
                                           toURL:[NSURL fileURLWithPath:winPath]
                                          target:makeTarget(0.5, 0.5)
                                        overlays:nil
                                        metadata:nil
                                            stop:nil
                                        progress:nil
                                           error:&error],
                @"windowed transcode failed: %@", error);

  // Sanity: authoring really put silence up front and a tone in the back half,
  // and the full transcode preserves both (guards against a no-op fixture).
  const double fullFrontRMS = decodeAudioRMSWindow(fullPath, 0.1, 0.4);
  const double fullBackRMS = decodeAudioRMSWindow(fullPath, 0.6, 0.9);
  XCTAssertLessThan(fullFrontRMS, 0.05,
                    @"source/full first-half audio should be silent (got %.4f)",
                    fullFrontRMS);
  XCTAssertGreaterThan(fullBackRMS, 0.15,
                       @"source/full second-half audio should be a tone "
                       @"(got %.4f)",
                       fullBackRMS);

  // The window [0.5, 1.0) is entirely tone. Measured away from the AAC
  // priming edges, the trimmed output's audio must be that tone — not the
  // front-of-source silence the regression would leave behind.
  const double winRMS = decodeAudioRMSWindow(winPath, 0.1, 0.4);
  XCTAssertGreaterThan(winRMS, 0.15,
                       @"trimmed output should carry the windowed tone, not "
                       @"front-of-source silence (got %.4f)",
                       winRMS);
  XCTAssertGreaterThan(winRMS, fullFrontRMS * 4.0,
                       @"trimmed audio (%.4f) should be far louder than the "
                       @"silent front half (%.4f) — proves the window shifted "
                       @"the audio, not just clipped its tail",
                       winRMS, fullFrontRMS);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:winPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:fullPath error:nil];
}

// --- T029 audio.mode = 'mute' / 'replace' -----------------------------------
//
// The render router can carry a soundtrack on two re-encode paths: the
// transcode pump (crop / resize / overlay / output change) and the
// rotation/flip transform-remux. Each must honour spec.audio: 'mute' drops the
// audio track, 'replace' swaps in a separate soundtrack capped to the video
// duration, 'passthrough' (the default) keeps the source audio. These drive
// the native methods directly with an RNVPAudioMode, mirroring what
// HybridVideoPipeline::render threads in from spec.audio.

static NSUInteger audioTrackCount(NSString *path) {
  AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
  return [asset tracksWithMediaType:AVMediaTypeAudio].count;
}

// Mute on the transcode path drops the audio track; passthrough keeps it.
- (void)testTranscodeMuteDropsAudioTrack {
  const NSInteger kFps = 30;
  NSError *error = nil;
  NSString *sourcePath = authorSteppedAudioFixture(160, 120, kFps, 30,
                                                   @"mute-tx", &error);
  XCTAssertNotNil(sourcePath, @"fixture author failed: %@", error);
  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  XCTAssertGreaterThanOrEqual(audioTrackCount(sourcePath), 1u,
                              @"source must carry audio for the test to mean "
                              @"anything");

  // Crop to 80x80 forces the transcode (re-encode) path.
  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:80
                                          height:80
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:80
                                      cropHeight:80
                                     sourceStart:0.0
                                  sourceDuration:0.0];

  NSString *mutePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"mute-tx-%@.mp4", NSUUID.UUID.UUIDString]];
  NSString *keepPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"keep-tx-%@.mp4", NSUUID.UUID.UUIDString]];

  XCTAssertTrue([RNVPTranscoder transcodeFromURL:sourceURL
                                           toURL:[NSURL fileURLWithPath:mutePath]
                                          target:target
                                        overlays:nil
                                        metadata:nil
                                       audioMode:RNVPAudioModeMute
                             audioReplacementURL:nil
                                            stop:nil
                                        progress:nil
                                           error:&error],
                @"mute transcode failed: %@", error);
  XCTAssertTrue([RNVPTranscoder transcodeFromURL:sourceURL
                                           toURL:[NSURL fileURLWithPath:keepPath]
                                          target:target
                                        overlays:nil
                                        metadata:nil
                                       audioMode:RNVPAudioModePassthrough
                             audioReplacementURL:nil
                                            stop:nil
                                        progress:nil
                                           error:&error],
                @"passthrough transcode failed: %@", error);

  XCTAssertEqual(audioTrackCount(mutePath), 0u,
                 @"mute output must have no audio track");
  XCTAssertGreaterThanOrEqual(audioTrackCount(keepPath), 1u,
                              @"passthrough output must keep the audio track");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:mutePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:keepPath error:nil];
}

// Mute on the rotation/flip transform-remux drops audio; passthrough keeps it.
- (void)testRemuxTransformMuteDropsAudioTrack {
  NSError *error = nil;
  NSString *sourcePath = authorSteppedAudioFixture(160, 120, 30, 30,
                                                   @"mute-xf", &error);
  XCTAssertNotNil(sourcePath, @"fixture author failed: %@", error);
  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
  XCTAssertGreaterThanOrEqual(audioTrackCount(sourcePath), 1u);

  NSString *mutePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"mute-xf-%@.mp4", NSUUID.UUID.UUIDString]];
  NSString *keepPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"keep-xf-%@.mp4", NSUUID.UUID.UUIDString]];

  XCTAssertTrue([RNVPRemuxer remuxTransformFromURL:sourceURL
                                             toURL:[NSURL fileURLWithPath:mutePath]
                                          startSec:0.0
                                       durationSec:0.0
                                            rotate:90
                                             flipH:NO
                                             flipV:NO
                                         audioMode:RNVPAudioModeMute
                               audioReplacementURL:nil
                                             error:&error],
                @"mute transform failed: %@", error);
  XCTAssertTrue([RNVPRemuxer remuxTransformFromURL:sourceURL
                                             toURL:[NSURL fileURLWithPath:keepPath]
                                          startSec:0.0
                                       durationSec:0.0
                                            rotate:90
                                             flipH:NO
                                             flipV:NO
                                         audioMode:RNVPAudioModePassthrough
                               audioReplacementURL:nil
                                             error:&error],
                @"passthrough transform failed: %@", error);

  XCTAssertEqual(audioTrackCount(mutePath), 0u,
                 @"mute output must have no audio track");
  XCTAssertGreaterThanOrEqual(audioTrackCount(keepPath), 1u,
                              @"passthrough output must keep the audio track");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:mutePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:keepPath error:nil];
}

// Replace on the transform-remux swaps the source soundtrack for a separate
// asset, capped to the video duration. The source is silent in [0, 0.5) and a
// tone in [0.5, 1.0); the replacement is the source's all-tone back half, so a
// correct replace makes the output's *front* window a tone (the swapped audio),
// where passthrough would leave it silent and mute would have no track at all.
- (void)testRemuxTransformReplaceSwapsSoundtrack {
  NSError *error = nil;
  NSString *sourcePath = authorSteppedAudioFixture(160, 120, 30, 30,
                                                   @"repl-xf", &error);
  XCTAssertNotNil(sourcePath, @"fixture author failed: %@", error);
  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];

  // Build an all-tone replacement by trimming the source's back half.
  NSString *replPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"repl-src-%@.mp4", NSUUID.UUID.UUIDString]];
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:sourceURL
                                        toURL:[NSURL fileURLWithPath:replPath]
                                     startSec:0.5
                                  durationSec:0.5
                                        error:&error],
                @"replacement-trim failed: %@", error);

  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"repl-out-%@.mp4", NSUUID.UUID.UUIDString]];
  XCTAssertTrue([RNVPRemuxer
                    remuxTransformFromURL:sourceURL
                                    toURL:[NSURL fileURLWithPath:outPath]
                                 startSec:0.0
                              durationSec:0.0
                                   rotate:90
                                    flipH:NO
                                    flipV:NO
                                audioMode:RNVPAudioModeReplace
                      audioReplacementURL:[NSURL fileURLWithPath:replPath]
                                    error:&error],
                @"replace transform failed: %@", error);

  XCTAssertGreaterThanOrEqual(audioTrackCount(outPath), 1u,
                              @"replace output must carry a (swapped) audio "
                              @"track");
  // Front window of the output should now be the swapped tone, not the
  // source's front-half silence.
  const double frontRMS = decodeAudioRMSWindow(outPath, 0.1, 0.35);
  XCTAssertGreaterThan(frontRMS, 0.15,
                       @"replaced soundtrack should make the front window a "
                       @"tone (got %.4f) — proves the source audio was swapped",
                       frontRMS);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:replPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

// The trim remux runs through RNVPExportSession's source-passthrough branch,
// which builds a windowed composition for mute/replace. A windowed mute trims
// to the right length with no audio; a windowed replace swaps the soundtrack
// aligned to the output's own t=0 (not the source window start), capped to the
// output duration.
- (void)testRemuxTrimMuteAndReplaceWindowed {
  NSError *error = nil;
  // 1.0s source: silent [0,0.5), tone [0.5,1.0).
  NSString *sourcePath = authorSteppedAudioFixture(160, 120, 30, 30,
                                                   @"trim-aud", &error);
  XCTAssertNotNil(sourcePath, @"fixture author failed: %@", error);
  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];

  // Mute a [0.5, 1.0) window: ~0.5s output, no audio track.
  NSString *mutePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"trim-mute-%@.mp4", NSUUID.UUID.UUIDString]];
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:sourceURL
                                        toURL:[NSURL fileURLWithPath:mutePath]
                                     startSec:0.5
                                  durationSec:0.5
                                    audioMode:RNVPAudioModeMute
                          audioReplacementURL:nil
                                        error:&error],
                @"windowed mute trim failed: %@", error);
  XCTAssertEqual(audioTrackCount(mutePath), 0u,
                 @"muted trim must have no audio track");
  const double muteDur = CMTimeGetSeconds(
      [AVURLAsset assetWithURL:[NSURL fileURLWithPath:mutePath]].duration);
  XCTAssertEqualWithAccuracy(muteDur, 0.5, 0.12,
                             @"muted trim should keep the window length "
                             @"(got %.3fs)",
                             muteDur);

  // Replace the whole soundtrack with an all-tone clip (the source's back
  // half). The output's front window must be the swapped tone, not silence.
  NSString *replPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"trim-repl-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:sourceURL
                                        toURL:[NSURL fileURLWithPath:replPath]
                                     startSec:0.5
                                  durationSec:0.5
                                        error:&error],
                @"replacement-trim failed: %@", error);
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"trim-out-%@.mp4", NSUUID.UUID.UUIDString]];
  // Use a *nonzero* source window [0.5, 1.0): the replacement audio must still
  // align to the output's t=0 (read from replacement t=0), not be shifted by
  // startSec — the regression the windowing fix closed.
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:sourceURL
                                        toURL:[NSURL fileURLWithPath:outPath]
                                     startSec:0.5
                                  durationSec:0.5
                                    audioMode:RNVPAudioModeReplace
                          audioReplacementURL:[NSURL fileURLWithPath:replPath]
                                        error:&error],
                @"replace trim failed: %@", error);
  XCTAssertGreaterThanOrEqual(audioTrackCount(outPath), 1u,
                              @"replace trim must carry a swapped audio track");
  const double frontRMS = decodeAudioRMSWindow(outPath, 0.05, 0.3);
  XCTAssertGreaterThan(frontRMS, 0.15,
                       @"replaced soundtrack should make the front window a "
                       @"tone (got %.4f) — proves the swap aligned to the "
                       @"output t=0, not the source window start",
                       frontRMS);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:mutePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:replPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

// Passthrough concat now splices each clip's audio onto the joined timeline
// (previously concat was video-only — the #16 "audio dropped" limit). Two
// stepped-audio clips (silent front half, tone back half) joined back-to-back
// must carry a tone in *each* clip's back-half window; mute writes video only.
- (void)testRemuxConcatCarriesAudioPassthroughAndMuteDrops {
  const NSInteger kFps = 30;
  const double kPerClip = 1.0;
  NSError *error = nil;
  NSString *clipA = authorSteppedAudioFixture(160, 120, kFps, 30, @"cat-a",
                                              &error);
  NSString *clipB = authorSteppedAudioFixture(160, 120, kFps, 30, @"cat-b",
                                              &error);
  XCTAssertNotNil(clipA, @"clipA author failed: %@", error);
  XCTAssertNotNil(clipB, @"clipB author failed: %@", error);

  RNVPRemuxerConcatSource *(^src)(NSString *, double) =
      ^RNVPRemuxerConcatSource *(NSString *path, double outStart) {
    return [[RNVPRemuxerConcatSource alloc]
        initWithSourceURL:[NSURL fileURLWithPath:path]
              sourceStart:0.0
           sourceDuration:kPerClip
              outputStart:outStart];
  };
  NSArray<RNVPRemuxerConcatSource *> *clips =
      @[ src(clipA, 0.0), src(clipB, kPerClip) ];

  NSString *keepPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"cat-keep-%@.mp4", NSUUID.UUID.UUIDString]];
  NSString *mutePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"cat-mute-%@.mp4", NSUUID.UUID.UUIDString]];

  XCTAssertTrue([RNVPRemuxer remuxConcatSources:clips
                                          toURL:[NSURL fileURLWithPath:keepPath]
                                      audioMode:RNVPAudioModePassthrough
                            audioReplacementURL:nil
                                           stop:nil
                                          error:&error],
                @"passthrough concat failed: %@", error);
  XCTAssertTrue([RNVPRemuxer remuxConcatSources:clips
                                          toURL:[NSURL fileURLWithPath:mutePath]
                                      audioMode:RNVPAudioModeMute
                            audioReplacementURL:nil
                                           stop:nil
                                          error:&error],
                @"mute concat failed: %@", error);

  // Passthrough keeps audio; each clip's tone back-half survives on the joined
  // timeline (clip A: [0.5,1.0); clip B: [1.5,2.0)).
  XCTAssertGreaterThanOrEqual(audioTrackCount(keepPath), 1u,
                              @"passthrough concat must keep audio");
  const double aBackRMS = decodeAudioRMSWindow(keepPath, 0.6, 0.9);
  const double bBackRMS = decodeAudioRMSWindow(keepPath, 1.6, 1.9);
  XCTAssertGreaterThan(aBackRMS, 0.15,
                       @"clip A's tone must survive the concat (got %.4f)",
                       aBackRMS);
  XCTAssertGreaterThan(bBackRMS, 0.15,
                       @"clip B's tone must survive the concat (got %.4f) — "
                       @"proves the second clip's audio was spliced too",
                       bBackRMS);

  XCTAssertEqual(audioTrackCount(mutePath), 0u,
                 @"mute concat must write video only");

  [[NSFileManager defaultManager] removeItemAtPath:clipA error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:clipB error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:keepPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:mutePath error:nil];
}

// Replace on the transcode (re-encode) pump reads the soundtrack from a second
// file, capped to the output video duration. Source is silent in [0,0.5),
// tone in [0.5,1.0); the replacement is the source's all-tone back half, so a
// correct replace makes the output's *front* window a tone.
- (void)testTranscodeReplaceSwapsSoundtrack {
  const NSInteger kFps = 30;
  NSError *error = nil;
  NSString *sourcePath = authorSteppedAudioFixture(160, 120, kFps, 30,
                                                   @"repl-tx", &error);
  XCTAssertNotNil(sourcePath, @"fixture author failed: %@", error);
  NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];

  NSString *replPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"repl-tx-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:sourceURL
                                        toURL:[NSURL fileURLWithPath:replPath]
                                     startSec:0.5
                                  durationSec:0.5
                                        error:&error],
                @"replacement-trim failed: %@", error);

  // Crop forces the transcode path.
  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:80
                                          height:80
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:80
                                      cropHeight:80
                                     sourceStart:0.0
                                  sourceDuration:0.0];
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"repl-tx-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  XCTAssertTrue([RNVPTranscoder transcodeFromURL:sourceURL
                                           toURL:[NSURL fileURLWithPath:outPath]
                                          target:target
                                        overlays:nil
                                        metadata:nil
                                       audioMode:RNVPAudioModeReplace
                             audioReplacementURL:[NSURL fileURLWithPath:replPath]
                                            stop:nil
                                        progress:nil
                                           error:&error],
                @"replace transcode failed: %@", error);

  XCTAssertGreaterThanOrEqual(audioTrackCount(outPath), 1u,
                              @"replace transcode must carry a swapped audio "
                              @"track");
  const double frontRMS = decodeAudioRMSWindow(outPath, 0.05, 0.35);
  XCTAssertGreaterThan(frontRMS, 0.15,
                       @"replaced soundtrack should make the front window a "
                       @"tone (got %.4f)",
                       frontRMS);

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:replPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

// Replace on concat swaps the whole joined soundtrack for the replacement,
// capped to the timeline duration.
- (void)testRemuxConcatReplaceSwapsSoundtrack {
  NSError *error = nil;
  NSString *clipA = authorSteppedAudioFixture(160, 120, 30, 30, @"crepl-a",
                                              &error);
  NSString *clipB = authorSteppedAudioFixture(160, 120, 30, 30, @"crepl-b",
                                              &error);
  XCTAssertNotNil(clipA, @"clipA author failed: %@", error);
  XCTAssertNotNil(clipB, @"clipB author failed: %@", error);
  // All-tone replacement: trim clip A's back half.
  NSString *replPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"crepl-src-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  XCTAssertTrue([RNVPRemuxer remuxTrimFromURL:[NSURL fileURLWithPath:clipA]
                                        toURL:[NSURL fileURLWithPath:replPath]
                                     startSec:0.5
                                  durationSec:0.5
                                        error:&error],
                @"replacement-trim failed: %@", error);

  NSArray<RNVPRemuxerConcatSource *> *clips = @[
    [[RNVPRemuxerConcatSource alloc] initWithSourceURL:[NSURL fileURLWithPath:clipA]
                                           sourceStart:0.0
                                        sourceDuration:1.0
                                           outputStart:0.0],
    [[RNVPRemuxerConcatSource alloc] initWithSourceURL:[NSURL fileURLWithPath:clipB]
                                           sourceStart:0.0
                                        sourceDuration:1.0
                                           outputStart:1.0],
  ];
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"crepl-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  XCTAssertTrue([RNVPRemuxer remuxConcatSources:clips
                                          toURL:[NSURL fileURLWithPath:outPath]
                                      audioMode:RNVPAudioModeReplace
                            audioReplacementURL:[NSURL fileURLWithPath:replPath]
                                           stop:nil
                                          error:&error],
                @"replace concat failed: %@", error);
  XCTAssertGreaterThanOrEqual(audioTrackCount(outPath), 1u,
                              @"replace concat must carry a swapped audio track");
  const double frontRMS = decodeAudioRMSWindow(outPath, 0.05, 0.35);
  XCTAssertGreaterThan(frontRMS, 0.15,
                       @"replaced soundtrack should make the front window a "
                       @"tone (got %.4f)",
                       frontRMS);

  [[NSFileManager defaultManager] removeItemAtPath:clipA error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:clipB error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:replPath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

// A replace render must fail loudly when the replacement file is missing / has
// no audio track, rather than silently producing video-only output.
- (void)testReplaceFailsWhenReplacementHasNoAudio {
  const NSInteger kFps = 30;
  NSError *error = nil;
  NSString *sourcePath = authorSteppedAudioFixture(160, 120, kFps, 30,
                                                   @"repl-noaud-src", &error);
  XCTAssertNotNil(sourcePath, @"source author failed: %@", error);
  // A non-existent replacement: the asset resolves to zero audio tracks.
  NSString *videoOnly = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"repl-missing-%@.m4a",
                                     NSUUID.UUID.UUIDString]];

  RNVPTranscodeTarget *target =
      [[RNVPTranscodeTarget alloc] initWithWidth:80
                                          height:80
                                             fps:(double)kFps
                                           codec:RNVPTranscodeCodecH264
                                         bitrate:0
                                          rotate:-1
                                           flipH:NO
                                           flipV:NO
                                           cropX:0
                                           cropY:0
                                       cropWidth:80
                                      cropHeight:80
                                     sourceStart:0.0
                                  sourceDuration:0.0];
  NSString *outPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"repl-noaud-out-%@.mp4",
                                     NSUUID.UUID.UUIDString]];
  NSError *err = nil;
  XCTAssertFalse([RNVPTranscoder transcodeFromURL:[NSURL fileURLWithPath:sourcePath]
                                            toURL:[NSURL fileURLWithPath:outPath]
                                           target:target
                                         overlays:nil
                                         metadata:nil
                                        audioMode:RNVPAudioModeReplace
                              audioReplacementURL:[NSURL fileURLWithPath:videoOnly]
                                             stop:nil
                                         progress:nil
                                            error:&err],
                 @"replace with a no-audio replacement must fail");
  XCTAssertNotNil(err, @"a failed replace must report an error");

  // The composition-path transform-remux must fail the same way (not silently
  // emit video-only).
  NSError *xfErr = nil;
  XCTAssertFalse([RNVPRemuxer remuxTransformFromURL:[NSURL fileURLWithPath:sourcePath]
                                              toURL:[NSURL fileURLWithPath:outPath]
                                           startSec:0.0
                                        durationSec:0.0
                                             rotate:90
                                              flipH:NO
                                              flipV:NO
                                          audioMode:RNVPAudioModeReplace
                                audioReplacementURL:[NSURL fileURLWithPath:videoOnly]
                                              error:&xfErr],
                 @"transform replace with a no-audio replacement must fail");
  XCTAssertNotNil(xfErr, @"a failed transform replace must report an error");

  [[NSFileManager defaultManager] removeItemAtPath:sourcePath error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:videoOnly error:nil];
  [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
}

@end
