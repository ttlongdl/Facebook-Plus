#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <stdarg.h>
#import <string.h>

// Story Downloader
// iOS 17 / Facebook 578.1.0 discovery path:
// FBSnacksNewVideoView -> playbackController
// -> currentVideoPlaybackItem -> HDPlaybackURL (fallback SDPlaybackURL)
//
// Downloads current Story video/photo media and saves it to Photos.

static void (*gOrigStoryDidStartPlaying)(id, SEL, id, id) = NULL;
static BOOL gStoryHookInstalled = NO;


static __weak UIViewController *gStoryController = nil;
static __weak UIView *gStoryMediaView = nil;
static NSURL *gStoryVideoURL = nil;
static UIImage *gStoryRenderedImage = nil;
static NSString *gStoryVideoID = nil;
static BOOL gStoryMediaIsVideo = NO;
static UIButton *gStoryDownloadButton = nil;
static UIProgressView *gStoryProgress = nil;
static BOOL gStoryDownloading = NO;

static const NSInteger kFBPStoryDownloadTag = 0x53444C31; // SDL1
static const NSInteger kFBPStoryProgressTag = 0x53445031; // SDP1

static void FBPStoryLog(NSString *format, ...) {
    // Intentionally disabled in release builds. Keep call sites lightweight and
    // avoid creating persistent Story Downloader log files in the app sandbox.
    (void)format;
}

static Method FBPStoryObjectGetterMethod(id obj, NSString *name) {
    if (!obj || !name.length) return NULL;
    SEL sel = NSSelectorFromString(name);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NULL;

    char ret[32] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == '@' ? m : NULL;
}

static id FBPStoryObjectGetter(id obj, NSString *name) {
    if (!FBPStoryObjectGetterMethod(obj, name)) return nil;
    @try {
        id (*sendObj)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return sendObj(obj, NSSelectorFromString(name));
    } @catch (__unused NSException *e) {
        return nil;
    }
}


static NSURL *FBPStoryResponseImageURLFromMediaView(id mediaView) {
    if (![mediaView isKindOfClass:UIView.class]) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(UIView *)mediaView];
    NSUInteger seen = 0;
    while (queue.count && seen < 100) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass(view.class) isEqualToString:@"FBWebPhotoView"]) {
            Ivar iv = class_getInstanceVariable(view.class, "_responseImageURL");
            if (iv) {
                id raw = nil;
                @try { raw = object_getIvar(view, iv); } @catch (__unused NSException *e) {}
                NSURL *url = nil;
                if ([raw isKindOfClass:NSURL.class]) url = raw;
                else if ([raw isKindOfClass:NSString.class]) url = [NSURL URLWithString:raw];
                if ([url.scheme.lowercaseString hasPrefix:@"http"]) return url;
            }
        }
        [queue addObjectsFromArray:view.subviews];
        seen++;
    }
    return nil;
}

static BOOL FBPStoryControllerVisible(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded || !vc.view.window) return NO;
    UIView *v = vc.view;
    for (UIView *p = v; p; p = p.superview) {
        if (p.hidden || p.alpha < 0.05) return NO;
        if ([p isKindOfClass:UIWindow.class]) break;
    }
    return YES;
}

static BOOL FBPStoryDownloaderEnabled(void) {
    return [FBPPrefs.shared boolForKey:FBPKeyStoryDownloaderEnabled];
}

static void FBPStoryHideButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gStoryDownloadButton.hidden = YES;
        gStoryDownloadButton.userInteractionEnabled = NO;
        gStoryProgress.hidden = YES;
    });
}

static void FBPStorySetButtonState(BOOL enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gStoryDownloadButton.enabled = enabled;
        gStoryDownloadButton.alpha = enabled ? 1.0 : 0.45;
    });
}

static void FBPStorySetProgress(CGFloat value, BOOL visible) {
    // V1.1: Story files are small; user requested no visible "downloading" UI.
    // Keep the progress object hidden for compatibility with the existing flow.
    (void)value;
    (void)visible;
    dispatch_async(dispatch_get_main_queue(), ^{
        gStoryProgress.hidden = YES;
    });
}

static void FBPStoryShowSavedPopup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = gStoryController;
        if (!vc || !vc.view.window || vc.presentedViewController) return;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:nil
                                                message:FBPL(@"download.story.saved")
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.ok")
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static void FBPStoryFlashSymbol(NSString *symbol) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gStoryDownloadButton) return;
        UIImage *old = [gStoryDownloadButton imageForState:UIControlStateNormal];
        UIImage *img = [UIImage systemImageNamed:symbol];
        if (img) [gStoryDownloadButton setImage:img forState:UIControlStateNormal];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gStoryDownloadButton && old)
                [gStoryDownloadButton setImage:old forState:UIControlStateNormal];
        });
    });
}

@interface FBPStoryDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) NSURL *sourceURL;
@end

@implementation FBPStoryDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite > 0) {
        CGFloat p = (CGFloat)totalBytesWritten / (CGFloat)totalBytesExpectedToWrite;
        FBPStorySetProgress(p, YES);
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSString *extension = gStoryMediaIsVideo ? @"mp4" : @"jpg";
    NSString *tmpName = [NSString stringWithFormat:@"FBP-Story-%@-%@.%@",
                         gStoryVideoID ?: (gStoryMediaIsVideo ? @"video" : @"photo"),
                         NSUUID.UUID.UUIDString,
                         extension];
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName];
    NSURL *dstURL = [NSURL fileURLWithPath:dst];

    [[NSFileManager defaultManager] removeItemAtURL:dstURL error:nil];
    NSError *moveError = nil;
    if (![[NSFileManager defaultManager] moveItemAtURL:location
                                                 toURL:dstURL
                                                 error:&moveError]) {
        FBPStoryLog(@"move failed: %@", moveError);
        dispatch_async(dispatch_get_main_queue(), ^{
            gStoryDownloading = NO;
            FBPStorySetButtonState(YES);
            FBPStorySetProgress(0, NO);
            FBPStoryFlashSymbol(@"xmark");
        });
        [session finishTasksAndInvalidate];
        return;
    }

    FBPStoryLog(@"download complete: %@", dst);

    BOOL isVideo = gStoryMediaIsVideo;
    [[PHPhotoLibrary sharedPhotoLibrary]
     performChanges:^{
        if (isVideo) {
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:dstURL];
        } else {
            [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:dstURL];
        }
    } completionHandler:^(BOOL success, NSError *error) {
        FBPStoryLog(@"Photos save success=%d type=%@ error=%@",
                    success, isVideo ? @"video" : @"photo", error);

        [[NSFileManager defaultManager] removeItemAtURL:dstURL error:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            gStoryDownloading = NO;
            FBPStorySetButtonState(YES);
            FBPStorySetProgress(0, NO);
            FBPStoryFlashSymbol(success ? @"checkmark" : @"xmark");
            if (success) FBPStoryShowSavedPopup();
        });

        [session finishTasksAndInvalidate];
    }];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;

    FBPStoryLog(@"download error: %@", error);
    dispatch_async(dispatch_get_main_queue(), ^{
        gStoryDownloading = NO;
        FBPStorySetButtonState(YES);
        FBPStorySetProgress(0, NO);
        FBPStoryFlashSymbol(@"xmark");
    });
    [session finishTasksAndInvalidate];
}

@end

static NSMutableSet *gStoryDownloadDelegates = nil;

static UIImage *FBPStoryRenderMediaView(UIView *view) {
    if (!view || CGRectIsEmpty(view.bounds)) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithBounds:view.bounds format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        BOOL drew = [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
        if (!drew) [view.layer renderInContext:ctx.CGContext];
    }];
}

static void FBPStoryStartDownload(void) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (gStoryDownloading || !gStoryVideoURL) return;

    NSURL *url = [gStoryVideoURL copy];
    if (![url.scheme.lowercaseString hasPrefix:@"http"]) return;

    gStoryDownloading = YES;
    FBPStorySetButtonState(NO);
    FBPStorySetProgress(0.01, YES);

    FBPStoryLog(@"download start mediaID=%@ type=%@ url=%@", gStoryVideoID, gStoryMediaIsVideo ? @"video" : @"photo", url.absoluteString);

    FBPStoryDownloadDelegate *delegate = [FBPStoryDownloadDelegate new];
    delegate.sourceURL = url;

    if (!gStoryDownloadDelegates) gStoryDownloadDelegates = [NSMutableSet set];
    [gStoryDownloadDelegates addObject:delegate];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 300.0;

    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg
                                                         delegate:delegate
                                                    delegateQueue:queue];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request];
    [task resume];

    // Keep delegate alive for the transfer; release it later after the normal max resource window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(310.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [gStoryDownloadDelegates removeObject:delegate];
    });
}

@interface FBPStoryDownloadTarget : NSObject
+ (instancetype)shared;
- (void)downloadTapped:(UIButton *)sender;
@end

@implementation FBPStoryDownloadTarget
+ (instancetype)shared {
    static FBPStoryDownloadTarget *obj;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ obj = [FBPStoryDownloadTarget new]; });
    return obj;
}
- (void)downloadTapped:(UIButton *)sender {
    FBPStoryLog(@"button tapped currentVideoID=%@", gStoryVideoID);
    FBPStoryStartDownload();
}
@end

static void FBPStoryInstallOrUpdateButton(UIViewController *vc) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (!vc || !FBPStoryControllerVisible(vc) || !gStoryVideoURL) return;

    UIView *host = vc.view;
    if (!host) return;

    UIButton *button = (UIButton *)[host viewWithTag:kFBPStoryDownloadTag];
    if (![button isKindOfClass:UIButton.class]) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kFBPStoryDownloadTag;
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = UIColor.clearColor;
        button.frame = CGRectMake(0, 0, 38, 38);
        button.accessibilityLabel = FBPL(@"download.story.a11y");
        [button setImage:[UIImage fbp_imageNamed:@"download"]
                forState:UIControlStateNormal];
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        // Match the eye (mark-as-seen) button's glyph size in FBPStoryHooks.xm,
        // which in turn matches Facebook's own header controls.
        button.contentEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
        [button addTarget:[FBPStoryDownloadTarget shared]
                   action:@selector(downloadTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:button];
    }

    UIProgressView *progress = (UIProgressView *)[host viewWithTag:kFBPStoryProgressTag];
    if (![progress isKindOfClass:UIProgressView.class]) {
        progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        progress.tag = kFBPStoryProgressTag;
        progress.hidden = YES;
        [host addSubview:progress];
    }

    // Sit directly under the eye (mark-as-seen) button, on the same right-hand
    // axis and one row-gap below it. This mirrors the eye button's grid in
    // FBPStoryHooks.xm: centre = safe-area top + header row (41) + one gap (44)
    // per row. The eye is at row 1 (safeTop + 41 + 44); Download is the next row.
    static const CGFloat kHeaderRowCentre = 41.0;
    static const CGFloat kCloseCentreFromRight = 24.0;
    static const CGFloat kRowGap = 44.0;
    CGFloat cx = CGRectGetWidth(host.bounds) - host.safeAreaInsets.right - kCloseCentreFromRight;
    CGFloat cy = host.safeAreaInsets.top + kHeaderRowCentre + kRowGap * 2.0;
    button.center = CGPointMake(cx, cy);
    progress.frame = CGRectMake(cx - 15.0, cy + 21.0, 30.0, 2.0);

    [host bringSubviewToFront:button];
    [host bringSubviewToFront:progress];

    button.hidden = NO;
    button.enabled = !gStoryDownloading;
    button.alpha = button.enabled ? 1.0 : 0.45;

    gStoryDownloadButton = button;
    gStoryProgress = progress;
}

static id FBPStoryFindVideoPlaybackItem(id mediaView) {
    if (!mediaView) return nil;

    id playbackController = FBPStoryObjectGetter(mediaView, @"playbackController");
    id item = FBPStoryObjectGetter(playbackController, @"currentVideoPlaybackItem");
    if (item) return item;

    // Some Story variants (notably FBSnacksLiveVideoView) wrap the real
    // FBSnacksNewVideoView/player. Walk only this Story's view tree so a late
    // player can be found without broad runtime scanning.
    if (![mediaView isKindOfClass:UIView.class]) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(UIView *)mediaView];
    NSUInteger seen = 0;
    while (queue.count && seen < 120) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];

        playbackController = FBPStoryObjectGetter(view, @"playbackController");
        item = FBPStoryObjectGetter(playbackController, @"currentVideoPlaybackItem");
        if (item) return item;

        [queue addObjectsFromArray:view.subviews];
        seen++;
    }
    return nil;
}

static BOOL FBPStoryCaptureCurrentVideo(id controller, id mediaView) {
    if (!controller || !mediaView) return NO;

    id item = FBPStoryFindVideoPlaybackItem(mediaView);
    if (!item) return NO;

    id videoID = FBPStoryObjectGetter(item, @"videoID");
    id hd = FBPStoryObjectGetter(item, @"HDPlaybackURL");
    id sd = FBPStoryObjectGetter(item, @"SDPlaybackURL");

    NSURL *url = nil;
    if ([hd isKindOfClass:NSURL.class]) url = hd;
    else if ([hd isKindOfClass:NSString.class]) url = [NSURL URLWithString:hd];

    if (!url) {
        if ([sd isKindOfClass:NSURL.class]) url = sd;
        else if ([sd isKindOfClass:NSString.class]) url = [NSURL URLWithString:sd];
    }

    if (!url || ![url.scheme.lowercaseString hasPrefix:@"http"]) return NO;

    gStoryController = controller;
    gStoryMediaView = mediaView;
    gStoryMediaIsVideo = YES;
    gStoryRenderedImage = nil;
    gStoryVideoURL = [url copy];
    gStoryVideoID = [videoID isKindOfClass:NSString.class] ? [videoID copy] : [videoID description];

    FBPStoryLog(@"captured videoID=%@ mediaClass=%@ url=%@",
                gStoryVideoID, NSStringFromClass([mediaView class]),
                gStoryVideoURL.absoluteString);

    dispatch_async(dispatch_get_main_queue(), ^{
        FBPStoryInstallOrUpdateButton((UIViewController *)controller);
    });
    return YES;
}

static void FBPStoryRetryVideoCapture(id controller, id mediaView, NSUInteger attempt) {
    if (!controller || !mediaView || !FBPStoryControllerVisible((UIViewController *)controller))
        return;

    if (FBPStoryCaptureCurrentVideo(controller, mediaView)) {
        FBPStoryLog(@"VIDEO-113 late capture success mediaClass=%@ attempt=%llu",
                    NSStringFromClass([mediaView class]), (unsigned long long)attempt);
        return;
    }

    if (attempt >= 12) {
        FBPStoryLog(@"VIDEO-113 late capture exhausted mediaClass=%@",
                    NSStringFromClass([mediaView class]));
        return;
    }

    __weak UIViewController *weakController = (UIViewController *)controller;
    __weak id weakMediaView = mediaView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *vc = weakController;
        id view = weakMediaView;
        if (vc && view)
            FBPStoryRetryVideoCapture(vc, view, attempt + 1);
    });
}

static void FBPStoryCaptureVideoWithRetry(id controller, id mediaView) {
    if (FBPStoryCaptureCurrentVideo(controller, mediaView)) return;

    NSString *mediaClass = mediaView ? NSStringFromClass([mediaView class]) : @"(nil)";
    NSString *lower = mediaClass.lowercaseString;
    if (![lower containsString:@"video"]) return;

    // The LiveVideo Story creates its playback item after didStartPlaying.
    // Retry briefly while the same controller is still visible; stop as soon
    // as the URL is available. 12 x 250 ms covers the observed late-player
    // race without retaining a self-referencing block.
    FBPStoryLog(@"VIDEO-113 late capture scheduled mediaClass=%@", mediaClass);

    __weak UIViewController *weakController = (UIViewController *)controller;
    __weak id weakMediaView = mediaView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *vc = weakController;
        id view = weakMediaView;
        if (vc && view)
            FBPStoryRetryVideoCapture(vc, view, 1);
    });
}

static void FBPStoryCaptureCurrentPhoto(id controller, id mediaView) {
    // Photo/composed Stories do not always arrive as FBSnacksPhotoView. In
    // particular mood/template Stories can use a different media-view class.
    // _getMediaUrl was already verified to expose the real image URL for normal
    // photo Stories, so probe it for every non-video Story instead of rejecting
    // unknown view classes before Facebook has a chance to tell us the media URL.
    NSString *mediaClass = mediaView ? NSStringFromClass([mediaView class]) : @"(nil)";
    NSString *superClass = (mediaView && [mediaView superclass])
        ? NSStringFromClass([mediaView superclass]) : @"(nil)";
    id raw = FBPStoryObjectGetter(controller, @"_getMediaUrl");
    FBPStoryLog(@"photo probe mediaClass=%@ super=%@ mediaURL=%@",
                mediaClass, superClass, raw);
    NSURL *url = nil;
    if ([raw isKindOfClass:NSURL.class]) url = raw;
    else if ([raw isKindOfClass:NSString.class]) url = [NSURL URLWithString:raw];

    if (!url || ![url.scheme.lowercaseString hasPrefix:@"http"]) {
        url = FBPStoryResponseImageURLFromMediaView(mediaView);
        if (!url) {
            FBPStoryLog(@"photo fallback rejected: no direct URL and no FBWebPhotoView response URL");
            return;
        }
        FBPStoryLog(@"photo fallback resolved FBWebPhotoView response URL=%@", url.absoluteString);
        if ([mediaView isKindOfClass:UIView.class]) {
            gStoryRenderedImage = FBPStoryRenderMediaView((UIView *)mediaView);
            if (gStoryRenderedImage) {
                FBPStoryLog(@"photo fallback rendered mediaView points=%.0fx%.0f scale=%.1f pixels=%.0fx%.0f",
                            gStoryRenderedImage.size.width, gStoryRenderedImage.size.height,
                            gStoryRenderedImage.scale,
                            gStoryRenderedImage.size.width * gStoryRenderedImage.scale,
                            gStoryRenderedImage.size.height * gStoryRenderedImage.scale);
            }
        }
    }

    gStoryController = controller;
    gStoryMediaView = mediaView;
    gStoryMediaIsVideo = NO;
    // Keep the rendered fallback for composed/other_media_type Stories.
    // Direct photo URLs still clear it so normal Stories retain original CDN downloads.
    if ([raw isKindOfClass:NSURL.class] || ([raw isKindOfClass:NSString.class] &&
        [[NSURL URLWithString:raw].scheme.lowercaseString hasPrefix:@"http"])) {
        gStoryRenderedImage = nil;
    }
    gStoryVideoURL = [url copy];
    gStoryVideoID = [NSString stringWithFormat:@"photo-%lu",
                     (unsigned long)url.absoluteString.hash];

    FBPStoryLog(@"captured PHOTO mediaClass=%@ url=%@", mediaClass, url.absoluteString);

    dispatch_async(dispatch_get_main_queue(), ^{
        FBPStoryInstallOrUpdateButton((UIViewController *)controller);
    });
}

static void FBPStoryDidStartPlayingHook(id self, SEL _cmd, id mediaView, id info) {
    if (gOrigStoryDidStartPlaying)
        gOrigStoryDidStartPlaying(self, _cmd, mediaView, info);

    if (!FBPStoryDownloaderEnabled()) {
        FBPStoryHideButton();
        return;
    }

    NSString *mediaClass = mediaView ? NSStringFromClass([mediaView class]) : @"";
    if ([mediaClass.lowercaseString containsString:@"video"]) {
        FBPStoryCaptureVideoWithRetry(self, mediaView);
        return;
    }
    FBPStoryCaptureCurrentPhoto(self, mediaView);
}

static void FBPInstallStoryDownloader(void) {
    if (gStoryHookInstalled) return;

    Class cls = objc_getClass("FBSnacksBucketViewController");
    if (!cls) return;

    SEL sel = NSSelectorFromString(@"mediaView:didStartPlayingWithInfo:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *enc = method_getTypeEncoding(m);
    if (!enc || strcmp(enc, "v32@0:8@16@24") != 0) {
        FBPStoryLog(@"REFUSED hook unexpected encoding=%s", enc ?: "(null)");
        return;
    }

    @synchronized (cls) {
        if (gStoryHookInstalled) return;
        MSHookMessageEx(cls, sel,
                        (IMP)FBPStoryDidStartPlayingHook,
                        (IMP *)&gOrigStoryDidStartPlaying);
        gStoryHookInstalled = YES;
    }

    FBPStoryLog(@"Story Downloader V1.0 installed");
}

__attribute__((constructor))
static void FBPStoryDownloaderCtor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        FBPInstallStoryDownloader();

        if (!gStoryHookInstalled) {
            __block NSInteger attempts = 0;
            __block NSTimer *timer = nil;
            timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *t) {
                attempts++;
                FBPInstallStoryDownloader();
                if (gStoryHookInstalled || attempts >= 30) {
                    [timer invalidate];
                    timer = nil;
                }
            }];
        }
    });
}
