///
/// Remuxer+Internal.h
///
/// Internal-only helpers exposed by the Remuxer translation unit so other
/// native drivers can reuse them without duplicating the container-metadata
/// authoring logic. Not part of the public Remuxer.h surface — keeps the
/// Foundation-only header small.
///
/// Currently exposes:
///   - @c RNVPStampMetadata (MergeWriting): a category that builds the full
///     @c NSArray<AVMetadataItem *> an @c AVAssetWriter accepts for its
///     @c .metadata property, merging this stamp's fields on top of a
///     source's existing metadata (same semantics as T032's metadata-only
///     remux path). Used by the transcode path in T036 so a stamp with a
///     watermark can author the same metadata bag the metadata-only remux
///     path would have produced.
///

#pragma once

#import "Remuxer.h"

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RNVPStampMetadata (MergeWriting)

/// Build a metadata bag suitable for @c AVAssetWriter.metadata: every item
/// from @p sourceMetadata whose identifier is NOT overridden by this stamp
/// is forwarded verbatim; every field this stamp sets is appended using the
/// canonical @c AVMetadataCommonIdentifier* for standard fields and the
/// @c mdta/<caller-supplied-key> namespace for custom entries. The
/// resulting array is suitable to assign directly to
/// @c AVAssetWriter.metadata.
- (NSArray<AVMetadataItem *> *)mergedWithSourceMetadata:
    (nullable NSArray<AVMetadataItem *> *)sourceMetadata;

@end

NS_ASSUME_NONNULL_END
