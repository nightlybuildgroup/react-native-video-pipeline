///
/// RNVPAudio.h
///
/// Shared audio-handling vocabulary for the iOS render paths. Every path that
/// can carry a soundtrack (trim, flip, transform, transcode, stamp, compose)
/// consults an @c RNVPAudioMode so @c spec.audio is honoured consistently:
///
///   - @c Passthrough — keep the source audio track verbatim (the default).
///   - @c Mute        — drop the audio track; the output is video-only.
///   - @c Replace     — swap the soundtrack for a separate asset
///                      (@c replacementURL), capped to the video duration.
///
/// Mirrors the nitrogen-generated @c AudioMode union
/// (`passthrough` | `mute` | `replace`) so @c HybridVideoPipeline can map
/// without a lookup table. Tests drive the native paths directly with these
/// values without crossing the Nitro boundary.
///

#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RNVPAudioMode) {
  RNVPAudioModePassthrough = 0,
  RNVPAudioModeMute = 1,
  RNVPAudioModeReplace = 2,
};
