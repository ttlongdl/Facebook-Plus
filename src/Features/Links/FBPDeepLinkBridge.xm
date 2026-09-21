#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static BOOL (*FBPBridgeOriginalOpenURL)(id, SEL, UIApplication *, NSURL *, NSDictionary *);

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
    Class delegateClass = objc_getClass("FBBaseAppDelegate");
    if (!delegateClass) return;

    SEL selector = NSSelectorFromString(@"application:openURL:options:");
    Method method = class_getInstanceMethod(delegateClass, selector);
    if (!method) return;

    MSHookMessageEx(delegateClass, selector, (IMP)FBPBridgeOpenURL, (IMP *)&FBPBridgeOriginalOpenURL);
}

__attribute__((constructor))
static void FBPDeepLinkBridgeEntry(void) {
    FBPInstallDeepLinkBridge();
}
