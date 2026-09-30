#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <math.h>
#import <stdarg.h>

static NSTimeInterval gLastConfirmedTap = 0.0;
static NSTimeInterval gReelsIntentUntil = 0.0;
static NSMapTable<UITouch *, NSValue *> *gTouchStarts = nil;
static NSMapTable<UITouch *, NSNumber *> *gTouchStartTimes = nil;
static BOOL gAllowedExclusivePlayback = NO;
static NSTimeInterval gLastExclusivePlayback = 0.0;
static NSTimeInterval gSuppressPlaybackUntil = 0.0;
static BOOL gMediaControllerAppearedAfterPlayback = NO;
static BOOL gExclusiveBeforeResignActive = NO;
static BOOL gEnteredBackgroundAfterResign = NO;
static NSTimeInterval gResumeExclusiveIntentUntil = 0.0;
static NSTimeInterval gExternalDeepLinkIntentUntil = 0.0;
static BOOL gExternalDeepLinkPlaybackObserved = NO;
static NSString * const FBPExternalDeepLinkNotification = @"FBPExternalDeepLinkDidOpenNotification";

static void (*oSendEvent)(UIApplication *, SEL, UIEvent *) = NULL;
static BOOL (*oCategoryError)(AVAudioSession *, SEL, AVAudioSessionCategory, NSError **) = NULL;
static BOOL (*oCategoryOptions)(AVAudioSession *, SEL, AVAudioSessionCategory, AVAudioSessionCategoryOptions, NSError **) = NULL;
static BOOL (*oCategoryModeOptions)(AVAudioSession *, SEL, AVAudioSessionCategory, AVAudioSessionMode, AVAudioSessionCategoryOptions, NSError **) = NULL;
static BOOL (*oCategoryModeRouteOptions)(AVAudioSession *, SEL, AVAudioSessionCategory, AVAudioSessionMode, AVAudioSessionRouteSharingPolicy, AVAudioSessionCategoryOptions, NSError **) = NULL;

static void (*oVCViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static void (*oVCViewDidDisappear)(UIViewController *, SEL, BOOL) = NULL;
static void (*oStoryBucketViewDidDisappear)(UIViewController *, SEL, BOOL) = NULL;

static void FBLog(NSString *format, ...) { (void)format; }

static inline BOOL FBIsPlayback(AVAudioSessionCategory category) {
    return [category isEqualToString:AVAudioSessionCategoryPlayback];
}

static inline BOOL FBIsAmbient(AVAudioSessionCategory category) {
    return [category isEqualToString:AVAudioSessionCategoryAmbient];
}

static inline BOOL FBRecentConfirmedTap(void) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    return gLastConfirmedTap > 0.0 && (now - gLastConfirmedTap) <= 0.85;
}

static inline BOOL FBExternalDeepLinkWindowActive(void) {
    return NSProcessInfo.processInfo.systemUptime < gExternalDeepLinkIntentUntil;
}

static void FBExternalDeepLinkDidOpen(NSNotification *note) {
    (void)note;
    gExternalDeepLinkIntentUntil = NSProcessInfo.processInfo.systemUptime + 6.0;
    gExternalDeepLinkPlaybackObserved = NO;
}

static inline BOOL FBPostReleaseGuardActive(void) {
    return NSProcessInfo.processInfo.systemUptime < gSuppressPlaybackUntil;
}

static inline void FBArmPostReleaseGuard(NSTimeInterval seconds) {
    gSuppressPlaybackUntil = NSProcessInfo.processInfo.systemUptime + seconds;
}

static inline BOOL FBShouldSuppressPlayback(AVAudioSession *session,
                                            AVAudioSessionCategory requestedCategory) {
    if (!FBIsPlayback(requestedCategory)) return NO;

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL reelsIntent = gReelsIntentUntil > now;
    BOOL resumeExclusiveIntent = gResumeExclusiveIntentUntil > now;
    if (reelsIntent || resumeExclusiveIntent) {
        return NO;
    }

    if (FBExternalDeepLinkWindowActive()) {
        gExternalDeepLinkPlaybackObserved = YES;
        gLastConfirmedTap = now;
        gExternalDeepLinkIntentUntil = 0.0;
        return NO;
    }

    if (FBPostReleaseGuardActive()) {
        return YES;
    }

    return session.isOtherAudioPlaying && !FBRecentConfirmedTap();
}

static NSString *FBViewChain(UIView *view) {
    if (!view) return @"(null)";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;

    for (NSUInteger i = 0; cursor && i < 8; i++) {
        NSString *name = NSStringFromClass([cursor class]);
        if (name.length == 0) name = @"(unknown)";
        [parts addObject:name];
        cursor = cursor.superview;
    }

    return [parts componentsJoinedByString:@" <- "];
}

static BOOL FBIsMenuNavigationTap(UIView *view) {
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 12; i++) {
        NSString *identifier = cursor.accessibilityIdentifier;
        if ([identifier isEqualToString:@"left-nav-button"] ||
            [identifier isEqualToString:@"side-panel-left-nav-button"]) {
            return YES;
        }
        cursor = cursor.superview;
    }
    return NO;
}

static BOOL FBIsReelsBottomTab(UIView *view) {
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 8; i++) {
        NSString *name = NSStringFromClass([cursor class]);
        if ([name isEqualToString:@"FBTabBarItemDefaultView"] ||
            [name isEqualToString:@"FBFloatingTabBar.FBFloatingTabBarItemView"]) {
            NSString *identifier = cursor.accessibilityIdentifier;
            NSString *label = cursor.accessibilityLabel ?: @"";
            if ([identifier isEqualToString:@"tab-bar-item-2392950137"]) return YES;
            if ([label rangeOfString:@"reel" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [label rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        }
        cursor = cursor.superview;
    }
    return NO;
}

static BOOL FBIsBottomTabTap(UIView *view) {
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 8; i++) {
        NSString *name = NSStringFromClass([cursor class]);
        if ([name isEqualToString:@"FBTabBarItemDefaultView"] ||
            [name isEqualToString:@"FBFloatingTabBar.FBFloatingTabBarItemView"] ||
            [name isEqualToString:@"FBFloatingTabBar"] ||
            [name isEqualToString:@"FBTabBar"]) {
            return YES;
        }
        cursor = cursor.superview;
    }
    return NO;
}

static void FBRecordTouchBegan(UITouch *touch) {
    CGPoint point = [touch locationInView:nil];
    [gTouchStarts setObject:[NSValue valueWithCGPoint:point] forKey:touch];
    [gTouchStartTimes setObject:@(NSProcessInfo.processInfo.systemUptime) forKey:touch];
}

static void FBFinishTouch(UITouch *touch) {
    NSValue *startValue = [gTouchStarts objectForKey:touch];
    NSNumber *startTimeValue = [gTouchStartTimes objectForKey:touch];

    [gTouchStarts removeObjectForKey:touch];
    [gTouchStartTimes removeObjectForKey:touch];

    if (!startValue || !startTimeValue) return;

    CGPoint start = startValue.CGPointValue;
    CGPoint end = [touch locationInView:nil];
    CGFloat dx = end.x - start.x;
    CGFloat dy = end.y - start.y;
    CGFloat distanceSquared = dx * dx + dy * dy;

    NSTimeInterval duration = NSProcessInfo.processInfo.systemUptime - startTimeValue.doubleValue;

    const CGFloat maxDistance = 14.0;
    const NSTimeInterval maxDuration = 0.45;

    if (touch.phase == UITouchPhaseEnded &&
        duration <= maxDuration &&
        distanceSquared <= maxDistance * maxDistance) {
        UIView *targetView = touch.view;
        if (FBIsBottomTabTap(targetView)) {
            if (FBIsReelsBottomTab(targetView)) {
                NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
                gLastConfirmedTap = now;
                gReelsIntentUntil = now + 3.0;
                FBLog(@"REELS TAB media intent duration=%.3f distance=%.1f target=%@ chain=%@",
                      duration,
                      sqrt(distanceSquared),
                      targetView ? NSStringFromClass([targetView class]) : @"(null)",
                      FBViewChain(targetView));
            } else {
                gLastConfirmedTap = 0.0;
                FBLog(@"TAB TAP ignored duration=%.3f distance=%.1f target=%@ chain=%@",
                      duration,
                      sqrt(distanceSquared),
                      targetView ? NSStringFromClass([targetView class]) : @"(null)",
                      FBViewChain(targetView));
            }
        } else if (FBIsMenuNavigationTap(targetView)) {
            gLastConfirmedTap = 0.0;
            FBLog(@"MENU TAP ignored duration=%.3f distance=%.1f target=%@ chain=%@",
                  duration,
                  sqrt(distanceSquared),
                  targetView ? NSStringFromClass([targetView class]) : @"(null)",
                  FBViewChain(targetView));
        } else {
            gLastConfirmedTap = NSProcessInfo.processInfo.systemUptime;
            FBLog(@"TAP confirmed duration=%.3f distance=%.1f target=%@ chain=%@",
                  duration,
                  sqrt(distanceSquared),
                  targetView ? NSStringFromClass([targetView class]) : @"(null)",
                  FBViewChain(targetView));
        }
    } else {
        FBLog(@"GESTURE rejected phase=%ld duration=%.3f distance=%.1f",
              (long)touch.phase, duration, sqrt(distanceSquared));
    }
}

static void hSendEvent(UIApplication *app, SEL cmd, UIEvent *event) {
    if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan) {
                FBRecordTouchBegan(touch);
            } else if (touch.phase == UITouchPhaseEnded ||
                       touch.phase == UITouchPhaseCancelled) {
                FBFinishTouch(touch);
            }
        }
    }
    oSendEvent(app, cmd, event);
}

static BOOL hCategoryError(AVAudioSession *session, SEL cmd,
                           AVAudioSessionCategory category, NSError **error) {
    if (FBShouldSuppressPlayback(session, category)) {
        FBLog(@"Playback SUPPRESS setter=category1 otherAudio=YES recentTap=NO");
        if (error) *error = nil;
        return YES;
    }

    if (FBIsPlayback(category)) {
        gAllowedExclusivePlayback = YES;
        gLastExclusivePlayback = NSProcessInfo.processInfo.systemUptime;
        gMediaControllerAppearedAfterPlayback = NO;
        FBLog(@"Playback ALLOW setter=category1 otherAudio=%@ recentTap=%@",
              session.isOtherAudioPlaying ? @"YES" : @"NO",
              FBRecentConfirmedTap() ? @"YES" : @"NO");
    } else if (FBIsAmbient(category)) {
        gAllowedExclusivePlayback = NO;
        gMediaControllerAppearedAfterPlayback = NO;
        FBLog(@"Ambient ALLOW setter=category1");
    }

    return oCategoryError(session, cmd, category, error);
}

static BOOL hCategoryOptions(AVAudioSession *session, SEL cmd,
                             AVAudioSessionCategory category,
                             AVAudioSessionCategoryOptions options,
                             NSError **error) {
    if (FBShouldSuppressPlayback(session, category)) {
        FBLog(@"Playback SUPPRESS setter=category2 guard=%@ otherAudio=%@ requestedOptions=0x%lx", FBPostReleaseGuardActive() ? @"YES" : @"NO", session.isOtherAudioPlaying ? @"YES" : @"NO",
              (unsigned long)options);
        if (error) *error = nil;
        return YES;
    }

    if (FBIsPlayback(category)) {
        BOOL recentTap = FBRecentConfirmedTap();
        gAllowedExclusivePlayback = YES;
        gLastExclusivePlayback = NSProcessInfo.processInfo.systemUptime;
        gMediaControllerAppearedAfterPlayback = NO;
        if (recentTap) options &= ~AVAudioSessionCategoryOptionMixWithOthers;
        FBLog(@"Playback ALLOW setter=category2 otherAudio=%@ recentTap=%@ finalOptions=0x%lx",
              session.isOtherAudioPlaying ? @"YES" : @"NO",
              recentTap ? @"YES" : @"NO",
              (unsigned long)options);
    } else if (FBIsAmbient(category)) {
        gAllowedExclusivePlayback = NO;
        gMediaControllerAppearedAfterPlayback = NO;
        options |= AVAudioSessionCategoryOptionMixWithOthers;
        FBLog(@"Ambient ALLOW setter=category2 finalOptions=0x%lx",
              (unsigned long)options);
    }

    return oCategoryOptions(session, cmd, category, options, error);
}

static BOOL hCategoryModeOptions(AVAudioSession *session, SEL cmd,
                                 AVAudioSessionCategory category,
                                 AVAudioSessionMode mode,
                                 AVAudioSessionCategoryOptions options,
                                 NSError **error) {
    if (FBShouldSuppressPlayback(session, category)) {
        FBLog(@"Playback SUPPRESS setter=categoryMode guard=%@ otherAudio=%@ requestedOptions=0x%lx", FBPostReleaseGuardActive() ? @"YES" : @"NO", session.isOtherAudioPlaying ? @"YES" : @"NO",
              (unsigned long)options);
        if (error) *error = nil;
        return YES;
    }

    if (FBIsPlayback(category)) {
        BOOL recentTap = FBRecentConfirmedTap();
        if (recentTap) options &= ~AVAudioSessionCategoryOptionMixWithOthers;
        FBLog(@"Playback ALLOW setter=categoryMode otherAudio=%@ recentTap=%@ finalOptions=0x%lx",
              session.isOtherAudioPlaying ? @"YES" : @"NO",
              recentTap ? @"YES" : @"NO",
              (unsigned long)options);
    } else if (FBIsAmbient(category)) {
        gAllowedExclusivePlayback = NO;
        gMediaControllerAppearedAfterPlayback = NO;
        options |= AVAudioSessionCategoryOptionMixWithOthers;
        FBLog(@"Ambient ALLOW setter=categoryMode finalOptions=0x%lx",
              (unsigned long)options);
    }

    return oCategoryModeOptions(session, cmd, category, mode, options, error);
}

static BOOL hCategoryModeRouteOptions(AVAudioSession *session, SEL cmd,
                                      AVAudioSessionCategory category,
                                      AVAudioSessionMode mode,
                                      AVAudioSessionRouteSharingPolicy policy,
                                      AVAudioSessionCategoryOptions options,
                                      NSError **error) {
    if (FBShouldSuppressPlayback(session, category)) {
        FBLog(@"Playback SUPPRESS setter=categoryModeRoute guard=%@ otherAudio=%@ requestedOptions=0x%lx", FBPostReleaseGuardActive() ? @"YES" : @"NO", session.isOtherAudioPlaying ? @"YES" : @"NO",
              (unsigned long)options);
        if (error) *error = nil;
        return YES;
    }

    if (FBIsPlayback(category)) {
        BOOL recentTap = FBRecentConfirmedTap();
        if (recentTap) options &= ~AVAudioSessionCategoryOptionMixWithOthers;
        FBLog(@"Playback ALLOW setter=categoryModeRoute otherAudio=%@ recentTap=%@ finalOptions=0x%lx",
              session.isOtherAudioPlaying ? @"YES" : @"NO",
              recentTap ? @"YES" : @"NO",
              (unsigned long)options);
    } else if (FBIsAmbient(category)) {
        gAllowedExclusivePlayback = NO;
        gMediaControllerAppearedAfterPlayback = NO;
        options |= AVAudioSessionCategoryOptionMixWithOthers;
        FBLog(@"Ambient ALLOW setter=categoryModeRoute finalOptions=0x%lx",
              (unsigned long)options);
    }

    return oCategoryModeRouteOptions(session, cmd, category, mode, policy, options, error);
}


static void FBRestoreAmbientAndRelease(NSString *reason) {
    if (!gAllowedExclusivePlayback) {
        FBLog(@"RELEASE skip reason=%@ exclusiveState=NO", reason);
        return;
    }

    NSTimeInterval age = NSProcessInfo.processInfo.systemUptime - gLastExclusivePlayback;
    AVAudioSession *session = AVAudioSession.sharedInstance;

    NSError *__autoreleasing categoryError = nil;
    BOOL categoryOK = [session setCategory:AVAudioSessionCategoryAmbient
                               withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                     error:&categoryError];

    NSError *__autoreleasing activeError = nil;
    BOOL activeOK = [session setActive:NO
                           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                 error:&activeError];

    gAllowedExclusivePlayback = NO;
    gMediaControllerAppearedAfterPlayback = NO;

    FBLog(@"RELEASE reason=%@ age=%.3f categoryOK=%@ categoryError=%@ activeOK=%@ activeError=%@",
          reason,
          age,
          categoryOK ? @"YES" : @"NO",
          categoryError ?: @"(null)",
          activeOK ? @"YES" : @"NO",
          activeError ?: @"(null)");
}

static void FBWillResignActive(NSNotification *note) {
    (void)note;
    gExclusiveBeforeResignActive = gAllowedExclusivePlayback;
    gEnteredBackgroundAfterResign = NO;
    FBLog(@"APP willResignActive exclusiveState=%@",
          gAllowedExclusivePlayback ? @"YES" : @"NO");
}

static void FBDidEnterBackground(NSNotification *note) {
    (void)note;
    gEnteredBackgroundAfterResign = YES;
    gResumeExclusiveIntentUntil = 0.0;
    FBLog(@"APP didEnterBackground exclusiveState=%@",
          gAllowedExclusivePlayback ? @"YES" : @"NO");
    FBRestoreAmbientAndRelease(@"didEnterBackground");
}

static void FBDidBecomeActive(NSNotification *note) {
    (void)note;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    BOOL reclaim = gExclusiveBeforeResignActive && !gEnteredBackgroundAfterResign;
    if (reclaim) {
        gResumeExclusiveIntentUntil = now + 2.0;
    }
    FBLog(@"APP didBecomeActive exclusiveState=%@ reclaimExclusive=%@ window=%.1f",
          gAllowedExclusivePlayback ? @"YES" : @"NO",
          reclaim ? @"YES" : @"NO",
          reclaim ? 2.0 : 0.0);
    gExclusiveBeforeResignActive = NO;
    gEnteredBackgroundAfterResign = NO;
}


static BOOL FBInterestingControllerName(NSString *name) {
    if (name.length == 0) return NO;
    NSArray<NSString *> *needles = @[
        @"Video", @"Reel", @"Short", @"Story", @"Stories",
        @"Feed", @"Home", @"Watch", @"Media", @"Player"
    ];
    for (NSString *needle in needles) {
        if ([name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}


static void FBReleaseOnNewsFeedReturn(NSString *reason) {
    if (!gAllowedExclusivePlayback) return;

    gLastConfirmedTap = 0.0;
    gReelsIntentUntil = 0.0;
    FBArmPostReleaseGuard(3.0);
    FBLog(@"POST-RELEASE GUARD armed seconds=3.0 reason=%@", reason);

    NSTimeInterval age = NSProcessInfo.processInfo.systemUptime - gLastExclusivePlayback;
    AVAudioSession *session = AVAudioSession.sharedInstance;

    NSError *__autoreleasing categoryError = nil;
    BOOL categoryOK = [session setCategory:AVAudioSessionCategoryAmbient
                               withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                     error:&categoryError];

    NSError *__autoreleasing activeError = nil;
    BOOL activeOK = [session setActive:NO
                           withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                 error:&activeError];

    gAllowedExclusivePlayback = NO;
    gMediaControllerAppearedAfterPlayback = NO;

    FBLog(@"NEWSFEED RELEASE reason=%@ age=%.3f categoryOK=%@ categoryError=%@ activeOK=%@ activeError=%@",
          reason,
          age,
          categoryOK ? @"YES" : @"NO",
          categoryError ?: @"(null)",
          activeOK ? @"YES" : @"NO",
          activeError ?: @"(null)");
}

static void hVCViewDidAppear(UIViewController *vc, SEL cmd, BOOL animated) {
    oVCViewDidAppear(vc, cmd, animated);

    if (!gAllowedExclusivePlayback) return;

    NSString *name = NSStringFromClass([vc class]);

    if ([name isEqualToString:@"FBNewsFeedViewController"]) {
        NSString *parent = vc.parentViewController ? NSStringFromClass([vc.parentViewController class]) : @"(null)";
        NSString *presenting = vc.presentingViewController ? NSStringFromClass([vc.presentingViewController class]) : @"(null)";
        NSString *navTop = vc.navigationController.topViewController ? NSStringFromClass([vc.navigationController.topViewController class]) : @"(null)";
        FBLog(@"VC APPEAR class=%@ parent=%@ presenting=%@ navTop=%@ exclusive=YES -> RELEASE",
              name, parent, presenting, navTop);
        FBReleaseOnNewsFeedReturn(@"FBNewsFeedViewController viewDidAppear");
        return;
    }

    if (!FBInterestingControllerName(name)) return;

    gMediaControllerAppearedAfterPlayback = YES;

    NSString *parent = vc.parentViewController ? NSStringFromClass([vc.parentViewController class]) : @"(null)";
    NSString *presenting = vc.presentingViewController ? NSStringFromClass([vc.presentingViewController class]) : @"(null)";
    NSString *navTop = vc.navigationController.topViewController ? NSStringFromClass([vc.navigationController.topViewController class]) : @"(null)";

    FBLog(@"VC APPEAR class=%@ parent=%@ presenting=%@ navTop=%@ exclusive=YES",
          name, parent, presenting, navTop);
}

static void hVCViewDidDisappear(UIViewController *vc, SEL cmd, BOOL animated) {
    oVCViewDidDisappear(vc, cmd, animated);

    if (!gAllowedExclusivePlayback) return;

    NSString *name = NSStringFromClass([vc class]);
    if (!FBInterestingControllerName(name)) return;

    NSString *parent = vc.parentViewController ? NSStringFromClass([vc.parentViewController class]) : @"(null)";
    NSString *presenting = vc.presentingViewController ? NSStringFromClass([vc.presentingViewController class]) : @"(null)";
    NSString *navTop = vc.navigationController.topViewController ? NSStringFromClass([vc.navigationController.topViewController class]) : @"(null)";

    FBLog(@"VC DISAPPEAR class=%@ parent=%@ presenting=%@ navTop=%@ exclusive=YES",
          name, parent, presenting, navTop);
}

static void hStoryBucketViewDidDisappear(UIViewController *vc, SEL cmd, BOOL animated) {
    oStoryBucketViewDidDisappear(vc, cmd, animated);

    if (!gAllowedExclusivePlayback) return;

    // Switching between Story items only replaces media/container children.
    // The bucket viewer itself disappearing means the Story surface is closing.
    // Defer one run-loop turn so UIKit has finished the dismissal before releasing
    // Facebook's exclusive audio session and notifying background audio to resume.
    __weak UIViewController *weakVC = vc;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (!strongVC || !gAllowedExclusivePlayback) return;

        BOOL stillVisible = strongVC.viewIfLoaded.window != nil;
        BOOL beingDismissed = strongVC.isBeingDismissed ||
                              strongVC.navigationController.isBeingDismissed;
        BOOL detached = strongVC.presentingViewController == nil &&
                        strongVC.parentViewController == nil;

        FBLog(@"STORY BUCKET DISAPPEAR visible=%@ beingDismissed=%@ detached=%@",
              stillVisible ? @"YES" : @"NO",
              beingDismissed ? @"YES" : @"NO",
              detached ? @"YES" : @"NO");

        // A bucket may become detached while Facebook swaps Story internals.
        // Only an actual UIKit dismissal is authoritative enough to release audio.
        if (!stillVisible && beingDismissed) {
            FBReleaseOnNewsFeedReturn(@"FBSnacksBucketViewController dismissed");
        }
    });
}

static void FBHook(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    MSHookMessageEx(cls, sel, replacement, original);
}

__attribute__((constructor))
static void InitFBAudioFix(void) {
    @autoreleasepool {
        gTouchStarts = [NSMapTable weakToStrongObjectsMapTable];
        gTouchStartTimes = [NSMapTable weakToStrongObjectsMapTable];

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:FBPExternalDeepLinkNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            FBExternalDeepLinkDidOpen(note);
        }];
        [nc addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            FBWillResignActive(note);
        }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            FBDidEnterBackground(note);
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            FBDidBecomeActive(note);
        }];

        Class appClass = objc_getClass("UIApplication");
        if (appClass) {
            FBHook(appClass, @selector(sendEvent:),
                   (IMP)hSendEvent, (IMP *)&oSendEvent);
        }

        Class vcClass = objc_getClass("UIViewController");
        if (vcClass) {
            FBHook(vcClass, @selector(viewDidAppear:),
                   (IMP)hVCViewDidAppear, (IMP *)&oVCViewDidAppear);
            FBHook(vcClass, @selector(viewDidDisappear:),
                   (IMP)hVCViewDidDisappear, (IMP *)&oVCViewDidDisappear);
        }

        Class storyBucketClass = objc_getClass("FBSnacksBucketViewController");
        if (storyBucketClass) {
            FBHook(storyBucketClass, @selector(viewDidDisappear:),
                   (IMP)hStoryBucketViewDidDisappear,
                   (IMP *)&oStoryBucketViewDidDisappear);
        }

        Class audioClass = objc_getClass("AVAudioSession");
        if (!audioClass) return;

        FBHook(audioClass, @selector(setCategory:error:),
               (IMP)hCategoryError, (IMP *)&oCategoryError);
        FBHook(audioClass, @selector(setCategory:withOptions:error:),
               (IMP)hCategoryOptions, (IMP *)&oCategoryOptions);
        FBHook(audioClass, @selector(setCategory:mode:options:error:),
               (IMP)hCategoryModeOptions, (IMP *)&oCategoryModeOptions);
        FBHook(audioClass, @selector(setCategory:mode:routeSharingPolicy:options:error:),
               (IMP)hCategoryModeRouteOptions, (IMP *)&oCategoryModeRouteOptions);
    }
}
