#import "FBPUpdateChecker.h"
#import "FBPUpdateController.h"
#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"
#import "FBPToast.h"

#ifndef FBP_VERSION
#define FBP_VERSION @"0.0.0"
#endif

static NSString *const kUpstreamReleasesAPI =
    @"https://api.github.com/repos/SHAJON-404/Facebook-Plus/releases/latest";
static NSString *const kForkReleasesAPI =
    @"https://api.github.com/repos/ttlongdl/Facebook-Plus/releases/latest";

/// Compare dotted versions plus an optional Debian-style numeric revision.
/// Examples: 1.0.1 < 1.0.1-2 < 1.0.1-5.
static NSArray<NSNumber *> *FBPVersionParts(NSString *version) {
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@"vV \t"];
    NSString *clean = [version stringByTrimmingCharactersInSet:trim];
    NSArray<NSString *> *dash = [clean componentsSeparatedByString:@"-"];
    NSMutableArray<NSNumber *> *parts = [NSMutableArray array];
    for (NSString *piece in [dash.firstObject componentsSeparatedByString:@"."]) {
        [parts addObject:@(piece.integerValue)];
    }
    [parts addObject:@(dash.count > 1 ? dash[1].integerValue : 0)];
    return parts;
}

static NSInteger FBPVersionCompare(NSString *a, NSString *b) {
    NSArray<NSNumber *> *pa = FBPVersionParts(a);
    NSArray<NSNumber *> *pb = FBPVersionParts(b);
    NSUInteger count = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger va = i < pa.count ? pa[i].integerValue : 0;
        NSInteger vb = i < pb.count ? pb[i].integerValue : 0;
        if (va != vb) return va > vb ? 1 : -1;
    }
    return 0;
}

static void FBPFetchRelease(NSString *apiURL,
                            void (^completion)(NSString *version, NSString *body, NSError *error)) {
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:apiURL]];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Facebook-Plus" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || ![data isKindOfClass:NSData.class]) {
            completion(nil, nil, error ?: [NSError errorWithDomain:@"FBPUpdate" code:1 userInfo:nil]);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *tag = [json isKindOfClass:NSDictionary.class] ? json[@"tag_name"] : nil;
        if (![tag isKindOfClass:NSString.class] || tag.length == 0) {
            completion(nil, nil, [NSError errorWithDomain:@"FBPUpdate" code:2 userInfo:nil]);
            return;
        }
        NSString *body = [json[@"body"] isKindOfClass:NSString.class] ? json[@"body"] : @"";
        completion(tag, body, nil);
    }];
    [task resume];
}

@implementation FBPUpdateChecker

+ (void)fetchStatus:(void (^)(NSString *upstreamVersion, NSString *forkVersion,
                                  NSString *forkChangelog, NSError *error))completion {
    dispatch_group_t group = dispatch_group_create();
    __block NSString *upstreamVersion = nil;
    __block NSString *forkVersion = nil;
    __block NSString *forkChangelog = nil;
    __block NSError *forkError = nil;

    dispatch_group_enter(group);
    FBPFetchRelease(kUpstreamReleasesAPI, ^(NSString *v, NSString *body, NSError *error) {
        upstreamVersion = v;
        dispatch_group_leave(group);
    });

    dispatch_group_enter(group);
    FBPFetchRelease(kForkReleasesAPI, ^(NSString *v, NSString *body, NSError *error) {
        forkVersion = v;
        forkChangelog = body;
        forkError = error;
        dispatch_group_leave(group);
    });

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(upstreamVersion, forkVersion, forkChangelog, forkError);
    });
}

+ (void)presentStatusWithUpstream:(NSString *)upstream
                                  fork:(NSString *)fork
                             changelog:(NSString *)changelog {
    UIViewController *host = [FBPSheetPresenter topViewController];
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host || [host isKindOfClass:FBPUpdateController.class]) return;

    FBPUpdateController *update =
        [[FBPUpdateController alloc] initWithInstalledVersion:FBP_VERSION
                                             upstreamVersion:upstream
                                                 forkVersion:fork
                                                   changelog:changelog];
    update.modalPresentationStyle = UIModalPresentationOverFullScreen;
    [host presentViewController:update animated:YES completion:nil];
}

+ (void)checkOnLaunch {
    if (!FBPEnabled(FBPKeyNotifyUpdates)) return;

    [self fetchStatus:^(NSString *upstream, NSString *fork, NSString *changelog, NSError *error) {
        if (error || !fork) return;
        if (FBPVersionCompare(fork, FBP_VERSION) <= 0) return;

        NSString *last = [FBPPrefs.shared stringForKey:FBPKeyLastNotifiedVersion];
        if (last && FBPVersionCompare(fork, last) <= 0) return;
        [FBPPrefs.shared setString:fork forKey:FBPKeyLastNotifiedVersion];
        [FBPPrefs.shared commit];

        [self presentStatusWithUpstream:upstream fork:fork changelog:changelog];
    }];
}

+ (void)checkManuallyFromViewController:(UIViewController *)controller {
    (void)controller;
    [self fetchStatus:^(NSString *upstream, NSString *fork, NSString *changelog, NSError *error) {
        if (error || !fork) {
            [FBPToastManager.shared showMessage:FBPL(@"update.failed") success:NO];
            return;
        }
        [self presentStatusWithUpstream:upstream fork:fork changelog:changelog];
    }];
}

@end
