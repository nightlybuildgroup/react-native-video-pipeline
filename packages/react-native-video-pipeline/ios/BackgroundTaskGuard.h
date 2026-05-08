///
/// BackgroundTaskGuard.h
///
/// US8 iOS support: wrap every render dispatch in
/// `UIApplication -beginBackgroundTaskWithName:expirationHandler:` so an
/// in-progress export continues running for up to ~30s after the app
/// backgrounds. If the OS kills the process mid-render, the next launch's
/// drain-zombies pass cleans up any partial output files so "no zombie
/// jobs" holds on cold start.
///
/// The header is Foundation-only so pure-`.m` test targets can import it
/// without pulling UIKit — the UIApplication calls live behind
/// `#if TARGET_OS_IPHONE` inside the `.mm`.
///
/// Two layers:
///  1. `RNVPBackgroundTaskJournal` — platform-agnostic persistent map of
///     in-flight renders (`tokenId` → `outputPath`) backed by
///     `NSUserDefaults`. Survives process death; readable on next launch.
///  2. `RNVPBackgroundTaskGuard` — lifecycle wrapper: on `begin`, writes to
///     the journal AND (iOS only) asks the OS for a background time
///     extension. On `end`, clears the journal entry AND releases the
///     extension.
///
/// Expiration handler: if the OS decides the 30s budget is up, the guard
/// calls `[stopToken requestAbort]` so the render's existing T038 abort
/// wiring (already polled by every runner) tears down cleanly and deletes
/// the partial output.
///

#import <Foundation/Foundation.h>

#import "SynthesizeRunner.h"

NS_ASSUME_NONNULL_BEGIN

/// NSUserDefaults key under which the journal stores its active-render
/// dictionary (tokenId → outputPath). Exposed for XCTests that need to
/// bypass the journal API and inspect persistence directly.
extern NSString* const RNVPBackgroundTaskJournalDefaultsKey;

/// Persistent record of in-flight renders. Writes go through
/// `NSUserDefaults standardUserDefaults` so they survive process death.
/// Thread-safe: every mutator reads, mutates, and writes under a single
/// lock — callers don't need to coordinate.
@interface RNVPBackgroundTaskJournal : NSObject

/// Record a render as "in flight" under `tokenId`. If `outputPath` is
/// non-nil it's stored alongside so the next-launch zombie drain can
/// delete the partial file. Overwrites any existing entry for `tokenId`.
+ (void)markActiveTokenId:(NSString*)tokenId
               outputPath:(nullable NSString*)outputPath;

/// Clear the entry for `tokenId`. No-op if absent. Call this on render
/// completion (success, error, or abort) so the journal reflects "no
/// active renders" when the current process exits cleanly.
+ (void)clearTokenId:(NSString*)tokenId;

/// Snapshot of the current active-renders map (copy; safe to mutate).
/// Keys are tokenIds; values are outputPaths (NSString) or NSNull if the
/// original mark omitted a path. Intended mainly for XCTests — the
/// journal is otherwise a write-only API from production code.
+ (NSDictionary<NSString*, id>*)activeEntriesSnapshot;

/// Process zombies from a prior launch: for each entry currently in the
/// journal, delete its `outputPath` on disk if the file exists, then
/// remove the entry. Returns the list of tokenIds that were drained so
/// callers can log or count them. Safe to call on every launch — if the
/// previous session ended cleanly the journal is empty and this is a
/// no-op.
///
/// The "surface Cancelled on next launch" contract from US8 is this
/// cleanup: any consumer who persisted a `renderToken` across launches
/// (e.g., to AsyncStorage) will see the output file missing, so the
/// render is observably incomplete. There is no JS-reachable promise to
/// reject from the prior session — the JS runtime that owned it is
/// gone.
+ (NSArray<NSString*>*)drainZombies;

/// Clears every entry without touching output files. Intended for tests
/// that need to start from a known-empty state without racing the
/// default-domain's other users.
+ (void)resetForTesting;

@end

/// Lifecycle wrapper: `+begin…` records the render in the journal and
/// requests a background-time extension from UIKit (iOS only). `-end`
/// clears both. Always pair a `begin` with exactly one `end`; double-end
/// is idempotent.
@interface RNVPBackgroundTaskGuard : NSObject

/// Start guarding a render.
/// - `tokenId` is the opaque renderToken the Nitro spec passes through;
///   `nil` or empty string is allowed for callers that opted out of
///   cancellation (e.g., the metadata-only stamp remux branch). No journal
///   entry is written in that case — the guard becomes a pure UIKit
///   background-time wrapper.
/// - `outputPath` is the render's final file path (stored in the
///   journal so the next-launch drain can delete it).
/// - `stopToken` is the render's existing `RNVPStopToken`. If UIKit's
///   30s budget expires the guard calls `[stopToken requestAbort]` so
///   the runner's T038 polling picks it up immediately.
+ (instancetype)beginWithTokenId:(nullable NSString*)tokenId
                      outputPath:(nullable NSString*)outputPath
                       stopToken:(nullable RNVPStopToken*)stopToken;

/// Release the background-time extension and clear the journal entry.
/// Idempotent: safe to call from every completion branch without
/// tracking whether it already fired.
- (void)end;

@end

NS_ASSUME_NONNULL_END
