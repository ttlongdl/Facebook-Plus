#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static BOOL (*FBPBridgeOriginalOpenURL)(id, SEL, UIApplication *, NSURL *, NSDictionary *);
static BOOL gFBPDeepLinkBridgeInstalled = NO;
static NSInteger gFBPDeepLinkBridgeAttempts = 0;

static NSURL *FBPBridgeTargetURL(NSURL *incomingURL) {
    if (![incomingURL isKindOfClass:NSURL.class]) return nil;

    NSString *scheme = incomingURL.scheme.lowercaseString ?: @"";
    NSString *host = incomingURL.host.lowercaseString ?: @"";

    BOOL legacyRoute = [scheme isEqualToString:@"fbbridge"] && [host isEqualToString:@"open"];
    BOOL existingSchemeRoute = [scheme isEqualToString:@"fb"] && [host isEqualToString:@"fbbridge"];
    if (!legacyRoute && !existingSchemeRoute) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:incomingURL resolvingAgainstBaseURL:NO];
    NSString *targetString = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"url"]) {
            targetString = item.value;
            break;
        }
    }
    if (!targetString.length) return nil;

    NSURL *targetURL = [NSURL URLWithString:targetString];
    NSString *targetScheme = targetURL.scheme.lowercaseString ?: @"";
    if (![targetScheme isEqualToString:@"http"] && ![targetScheme isEqualToString:@"https"]) return nil;

    // Canonicalize Facebook's mobile/web host variants before invoking its
    // Universal Link handler. Preserve path/query/fragment so reels, posts,
    // story.php, permalink.php, groups, watch/share URLs, etc. keep identity.
    NSURLComponents *targetComponents = [NSURLComponents componentsWithURL:targetURL resolvingAgainstBaseURL:NO];
    NSString *targetHost = targetComponents.host.lowercaseString ?: @"";
    BOOL facebookHost = [targetHost isEqualToString:@"facebook.com"] ||
        [targetHost hasSuffix:@".facebook.com"];
    if (facebookHost) {
        targetComponents.scheme = @"https";
        targetComponents.host = @"www.facebook.com";
        NSURL *canonicalURL = targetComponents.URL;
        if (canonicalURL) targetURL = canonicalURL;
    }

    return targetURL;
}

static BOOL FBPBridgeOpenURL(id self, SEL _cmd, UIApplication *application, NSURL *url, NSDictionary *options) {
    NSURL *targetURL = FBPBridgeTargetURL(url);
    if (!targetURL) {
        return FBPBridgeOriginalOpenURL ? FBPBridgeOriginalOpenURL(self, _cmd, application, url, options) : NO;
    }

    SEL universalLinkSelector = NSSelectorFromString(@"application:continueUserActivity:restorationHandler:");
    if (![self respondsToSelector:universalLinkSelector]) return NO;

    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = targetURL;

    void (^restorationHandler)(NSArray *) = ^(NSArray *restorableObjects) {
        (void)restorableObjects;
    };

    BOOL (*sendUniversalLink)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)) =
        (BOOL (*)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)))objc_msgSend;

    return sendUniversalLink(self, universalLinkSelector, application, activity, restorationHandler);
}

static void FBPInstallDeepLinkBridge(void) {
    if (gFBPDeepLinkBridgeInstalled) return;

    Class delegateClass = objc_getClass("FBBaseAppDelegate");
    SEL selector = NSSelectorFromString(@"application:openURL:options:");
    Method method = delegateClass ? class_getInstanceMethod(delegateClass, selector) : NULL;

    if (delegateClass && method) {
        MSHookMessageEx(delegateClass, selector, (IMP)FBPBridgeOpenURL, (IMP *)&FBPBridgeOriginalOpenURL);
        gFBPDeepLinkBridgeInstalled = YES;
        return;
    }

    // FacebookPlus may be injected before FBBaseAppDelegate is registered.
    // Retry on the main queue instead of permanently missing the hook because
    // constructor timing happened to be earlier on a particular launch/build.
    if (gFBPDeepLinkBridgeAttempts >= 40) return;
    gFBPDeepLinkBridgeAttempts += 1;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            FBPInstallDeepLinkBridge();
        }
    );
}

__attribute__((constructor))
static void FBPDeepLinkBridgeEntry(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        FBPInstallDeepLinkBridge();
    });
}
