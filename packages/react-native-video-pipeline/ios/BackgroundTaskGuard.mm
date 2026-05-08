///
/// BackgroundTaskGuard.mm
///
/// See BackgroundTaskGuard.h for the full rationale. This file splits into
/// two compilation-time islands:
///   - Always-compiled journal + lifecycle bookkeeping (NSUserDefaults,
///     NSFileManager — portable across iOS + macOS so
///     `yarn test:native` can exercise the drain-zombies logic).
///   - `#if TARGET_OS_IPHONE` block that calls
///     `[UIApplication beginBackgroundTaskWithName:…]`. Only compiled on
///     device/simulator builds; the macOS-host test bundle skips it.
///

#import "BackgroundTaskGuard.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NSString* const RNVPBackgroundTaskJournalDefaultsKey =
    @"com.unbogify.rnvp.activeRenders";

#pragma mark - Journal

@implementation RNVPBackgroundTaskJournal

/// Serializes every read-modify-write on the journal's persistent map.
/// NSUserDefaults mutators are themselves thread-safe but a read +
/// mutate + write sequence is not atomic — this lock closes that gap.
+ (NSLock*)lock {
  static NSLock* sLock = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ sLock = [[NSLock alloc] init]; });
  return sLock;
}

+ (NSMutableDictionary<NSString*, id>*)_loadLocked {
  NSDictionary* stored = [[NSUserDefaults standardUserDefaults]
      dictionaryForKey:RNVPBackgroundTaskJournalDefaultsKey];
  return stored != nil ? [stored mutableCopy]
                       : [NSMutableDictionary dictionary];
}

+ (void)_storeLocked:(NSDictionary*)dict {
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  if (dict.count == 0) {
    [defaults removeObjectForKey:RNVPBackgroundTaskJournalDefaultsKey];
  } else {
    [defaults setObject:dict forKey:RNVPBackgroundTaskJournalDefaultsKey];
  }
}

+ (void)markActiveTokenId:(NSString*)tokenId
               outputPath:(nullable NSString*)outputPath {
  if (tokenId.length == 0) return;
  NSLock* lock = [self lock];
  [lock lock];
  NSMutableDictionary* dict = [self _loadLocked];
  dict[tokenId] = outputPath.length > 0 ? (id)outputPath : (id)[NSNull null];
  [self _storeLocked:dict];
  [lock unlock];
}

+ (void)clearTokenId:(NSString*)tokenId {
  if (tokenId.length == 0) return;
  NSLock* lock = [self lock];
  [lock lock];
  NSMutableDictionary* dict = [self _loadLocked];
  if (dict[tokenId] == nil) {
    [lock unlock];
    return;
  }
  [dict removeObjectForKey:tokenId];
  [self _storeLocked:dict];
  [lock unlock];
}

+ (NSDictionary<NSString*, id>*)activeEntriesSnapshot {
  NSLock* lock = [self lock];
  [lock lock];
  NSDictionary* copy = [[self _loadLocked] copy];
  [lock unlock];
  return copy;
}

+ (NSArray<NSString*>*)drainZombies {
  NSLock* lock = [self lock];
  [lock lock];
  NSMutableDictionary* dict = [self _loadLocked];
  if (dict.count == 0) {
    [lock unlock];
    return @[];
  }
  NSArray<NSString*>* tokenIds = [dict.allKeys copy];
  NSFileManager* fm = [NSFileManager defaultManager];
  for (NSString* tokenId in tokenIds) {
    id value = dict[tokenId];
    if ([value isKindOfClass:[NSString class]]) {
      NSString* outputPath = (NSString*)value;
      if (outputPath.length > 0 && [fm fileExistsAtPath:outputPath]) {
        // Best-effort cleanup — if the file can't be deleted (wrong
        // permissions, already removed) the journal entry is still
        // cleared so the drain is idempotent next time.
        [fm removeItemAtPath:outputPath error:nil];
      }
    }
  }
  [dict removeAllObjects];
  [self _storeLocked:dict];
  [lock unlock];
  return tokenIds;
}

+ (void)resetForTesting {
  NSLock* lock = [self lock];
  [lock lock];
  [[NSUserDefaults standardUserDefaults]
      removeObjectForKey:RNVPBackgroundTaskJournalDefaultsKey];
  [lock unlock];
}

@end

#pragma mark - Guard

@interface RNVPBackgroundTaskGuard () {
  NSString* _tokenId;
  RNVPStopToken* _stopToken;
  BOOL _ended;
#if TARGET_OS_IPHONE
  UIBackgroundTaskIdentifier _taskId;
#endif
}
@end

@implementation RNVPBackgroundTaskGuard

+ (instancetype)beginWithTokenId:(nullable NSString*)tokenId
                      outputPath:(nullable NSString*)outputPath
                       stopToken:(nullable RNVPStopToken*)stopToken {
  RNVPBackgroundTaskGuard* g = [[RNVPBackgroundTaskGuard alloc] init];
  g->_tokenId = [tokenId copy];
  g->_stopToken = stopToken;
  g->_ended = NO;

  if (tokenId.length > 0) {
    [RNVPBackgroundTaskJournal markActiveTokenId:tokenId
                                      outputPath:outputPath];
  }

#if TARGET_OS_IPHONE
  g->_taskId = UIBackgroundTaskInvalid;
  UIApplication* app = [UIApplication sharedApplication];
  // Capture a weak ref to the guard so the expiration handler can release
  // its UIKit task id without forcing the guard to outlive the runner.
  __weak RNVPBackgroundTaskGuard* weakGuard = g;
  g->_taskId = [app beginBackgroundTaskWithName:@"rnvp-render"
                              expirationHandler:^{
    // OS wants the task gone — cascade to the runner's abort path so the
    // stop-token polling T038 already wired picks it up on the next
    // loop iteration.
    RNVPBackgroundTaskGuard* strongGuard = weakGuard;
    [strongGuard->_stopToken requestAbort];
    // Release the task id immediately. The runner will wind down on its
    // own thread; nothing else we can do to extend the budget.
    if (strongGuard != nil && strongGuard->_taskId != UIBackgroundTaskInvalid) {
      UIBackgroundTaskIdentifier toEnd = strongGuard->_taskId;
      strongGuard->_taskId = UIBackgroundTaskInvalid;
      [[UIApplication sharedApplication] endBackgroundTask:toEnd];
    }
  }];
#endif
  return g;
}

- (void)end {
  if (_ended) return;
  _ended = YES;

  if (_tokenId.length > 0) {
    [RNVPBackgroundTaskJournal clearTokenId:_tokenId];
  }

#if TARGET_OS_IPHONE
  if (_taskId != UIBackgroundTaskInvalid) {
    UIBackgroundTaskIdentifier toEnd = _taskId;
    _taskId = UIBackgroundTaskInvalid;
    // -endBackgroundTask: expects the main thread / main-queue-safe
    // context; we're already dispatched there for UIKit calls and the
    // Promise completion paths in VideoPipeline.mm hop back to the
    // caller's thread. Nitro's Promise completion runs on the pool
    // thread, so bounce to main to stay within UIApplication's
    // contract.
    dispatch_async(dispatch_get_main_queue(), ^{
      [[UIApplication sharedApplication] endBackgroundTask:toEnd];
    });
  }
#endif
}

- (void)dealloc {
  // Safety net: if a caller forgets to -end the guard, don't leak either
  // the journal entry or (iOS) the background task id. The normal path
  // is an explicit -end in the completion block.
  [self end];
}

@end
