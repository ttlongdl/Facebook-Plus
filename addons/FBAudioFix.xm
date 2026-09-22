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

static void (*oSendEvent)(UIApplication *, SEL, UIEvent *) = NULL;
static BOOL (*oCategoryError)(AVAudioSession *, SEL, AVAudioSessionCategory, NSError **) = NULL;
static BOOL (*oCategoryOptions)(AVAudioSession *, SEL, AVAudioSessionCategory, AVAudioSessionCategoryOptions, NSError **) = NULL;
static BOOL (*oCategoryModeOptions)(AVAudioSession *, SEL, AVAudioSessionCategory, AVAudioSessionMode, AVAudioSessionCategoryOptions, NSError **) = NULL;
static BOOL (*oCategoryModeRouteOptions)(AVAudioSession *, SEL, AVAudioSessionCategory, AVAudioSessionMode, AVAudioSessionRouteSharingPolicy, AVAudioSessionCategoryOptions, NSError **) = NULL;

static void (*oVCViewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static void (*oVCViewDidDisappear)(UIViewController *, SEL, BOOL) = NULL;

static NSString *FBLogPath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return nil;
    return [paths.firstObject stringByAppendingPathComponent:@"FBAudioFix-v0.3.14.txt"];
}

static void FBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void FBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *path = FBLogPath();
    if (!path) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], body];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

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
    if (reelsIntent) {
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

static NSString *FBSafeAccessibilityText(UIView *view) {
    if (!view) return @"(null)";
    NSString *identifier = view.accessibilityIdentifier ?: @"";
    NSString *label = view.accessibilityLabel ?: @"";
    NSString *value = [view.accessibilityValue isKindOfClass:[NSString class]] ? (NSString *)view.accessibilityValue : @"";
    return [NSString stringWithFormat:@"id='%@' label='%@' value='%@'", identifier, label, value];
}

static NSString *FBTabProbeDescription(UIView *view, UITouch *touch) {
    if (!view) return @"target=(null)";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;
    UIView *tabBar = nil;

    for (NSUInteger i = 0; cursor && i < 8; i++) {
        NSString *name = NSStringFromClass([cursor class]);
        CGRect f = cursor.frame;
        NSString *a11y = FBSafeAccessibilityText(cursor);
        [parts addObject:[NSString stringWithFormat:@"%@ frame=(%.1f,%.1f,%.1f,%.1f) %@",
                          name, f.origin.x, f.origin.y, f.size.width, f.size.height, a11y]];
        if ([name isEqualToString:@"FBTabBar"]) tabBar = cursor;
        cursor = cursor.superview;
    }

    CGPoint pWindow = [touch locationInView:nil];
    NSString *tabPoint = @"(n/a)";
    if (tabBar) {
        CGPoint pTab = [touch locationInView:tabBar];
        tabPoint = [NSString stringWithFormat:@"(%.1f,%.1f)", pTab.x, pTab.y];
    }

    return [NSString stringWithFormat:@"windowPoint=(%.1f,%.1f) tabPoint=%@ responders=%@",
            pWindow.x, pWindow.y, tabPoint, [parts componentsJoinedByString:@" || "]];
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

static BOOL FBIsInNavigationBar(UIView *view) {
    UIView *cursor = view;
    for (NSUInteger i = 0; cursor && i < 12; i++) {
        NSString *name = NSStringFromClass([cursor class]);
        if ([name isEqualToString:@"FBNavigationBar"] ||
            [name isEqualToString:@"FBAnimatedNavigationBar"] ||
            [name isEqualToString:@"UINavigationBar"]) {
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
        if ([name isEqualToString:@"FBTabBarItemDefaultView"]) {
            NSString *identifier = cursor.accessibilityIdentifier;
            return [identifier isEqualToString:@"tab-bar-item-2392950137"];
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
            (void)FBTabProbeDescription(targetView, touch);
        } else if (FBIsMenuNavigationTap(targetView)) {
            gLastConfirmedTap = 0.0;
            FBLog(@"MENU TAP ignored duration=%.3f distance=%.1f target=%@ chain=%@",
                  duration,
                  sqrt(distanceSquared),
                  targetView ? NSStringFromClass([targetView class]) : @"(null)",
                  FBViewChain(targetView));
            (void)FBTabProbeDescription(targetView, touch);
        } else {
            gLastConfirmedTap = NSProcessInfo.processInfo.systemUptime;
            FBLog(@"TAP confirmed duration=%.3f distance=%.1f target=%@ chain=%@",
                  duration,
                  sqrt(distanceSquared),
                  targetView ? NSStringFromClass([targetView class]) : @"(null)",
                  FBViewChain(targetView));
            if (FBIsInNavigationBar(targetView)) {
                (void)FBTabProbeDescription(targetView, touch);
            }
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
        gAllowedExclusivePlayback = YES;
        gLastExclusivePlayback = NSProcessInfo.processInfo.systemUptime;
        gMediaControllerAppearedAfterPlayback = NO;
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
    FBLog(@"APP willResignActive exclusiveState=%@",
          gAllowedExclusivePlayback ? @"YES" : @"NO");
}

static void FBDidEnterBackground(NSNotification *note) {
    (void)note;
    FBLog(@"APP didEnterBackground exclusiveState=%@",
          gAllowedExclusivePlayback ? @"YES" : @"NO");
    FBRestoreAmbientAndRelease(@"didEnterBackground");
}

static void FBDidBecomeActive(NSNotification *note) {
    (void)note;
    FBLog(@"APP didBecomeActive exclusiveState=%@",
          gAllowedExclusivePlayback ? @"YES" : @"NO");
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

        NSString *path = FBLogPath();
        if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        FBLog(@"INIT FBAudioFix v0.3.14");

        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
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
