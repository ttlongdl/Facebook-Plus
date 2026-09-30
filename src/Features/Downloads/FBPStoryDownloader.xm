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

static NSString *FBPStoryLogPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                           NSUserDomainMask,
                                                           YES) firstObject];
    return [docs stringByAppendingPathComponent:@"FBP-StoryDownload.txt"];
}

static void FBPStoryLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = FBPStoryLogPath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    [fh seekToEndOfFile];
    [fh writeData:data];
    [fh closeFile];
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

static void FBPStoryDumpPhotoProbe(id controller, id mediaView) {
    FBPStoryLog(@"PHOTO-PROBE controllerClass=%@ mediaClass=%@", NSStringFromClass([controller class]), NSStringFromClass([mediaView class]));
    unsigned int count=0; Method *methods=class_copyMethodList([mediaView class], &count); NSUInteger n=0;
    for(unsigned int i=0;i<count && n<40;i++){ Method m=methods[i]; if(method_getNumberOfArguments(m)!=2) continue; char ret[16]={0}; method_getReturnType(m,ret,sizeof(ret)); if(ret[0]!='@') continue; NSString *s=NSStringFromSelector(method_getName(m)); NSString *l=s.lowercaseString; if(!([l containsString:@"image"]||[l containsString:@"photo"]||[l containsString:@"media"]||[l containsString:@"url"]||[l containsString:@"model"])) continue; id v=FBPStoryObjectGetter(mediaView,s); FBPStoryLog(@"PHOTO-PROBE getter %@ -> <%@> %@",s,v?NSStringFromClass([v class]):@"nil",[v description]); n++; } free(methods);
    if([mediaView isKindOfClass:UIView.class]){ NSMutableArray *q=[NSMutableArray arrayWithObject:mediaView]; NSUInteger seen=0; while(q.count&&seen<80){ UIView *v=q.firstObject; [q removeObjectAtIndex:0]; NSString *x=@""; if([v isKindOfClass:UIImageView.class]){UIImage *im=((UIImageView*)v).image;x=[NSString stringWithFormat:@" image=%@ %.0fx%.0f",im?@"YES":@"NO",im.size.width,im.size.height];} FBPStoryLog(@"PHOTO-PROBE view <%@> frame=%@%@",NSStringFromClass(v.class),NSStringFromCGRect(v.frame),x); [q addObjectsFromArray:v.subviews]; seen++; }}
}

static BOOL FBPStoryInterestingSourceName(NSString *name) {
    NSString *s = name.lowercaseString;
    return [s containsString:@"image"] || [s containsString:@"photo"] ||
           [s containsString:@"media"] || [s containsString:@"url"] ||
           [s containsString:@"source"] || [s containsString:@"request"] ||
           [s containsString:@"model"] || [s containsString:@"content"];
}

static void FBPStoryLogObjectSourceGetters(id obj, NSString *label) {
    if (!obj) return;
    for (Class cls = [obj class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        NSUInteger emitted = 0;
        for (unsigned int i = 0; i < count && emitted < 50; i++) {
            Method method = methods[i];
            if (method_getNumberOfArguments(method) != 2) continue;
            char ret[16] = {0};
            method_getReturnType(method, ret, sizeof(ret));
            if (ret[0] != '@') continue;
            NSString *name = NSStringFromSelector(method_getName(method));
            if (!FBPStoryInterestingSourceName(name)) continue;
            id value = FBPStoryObjectGetter(obj, name);
            if (!value) continue;
            NSString *desc = [value description] ?: @"";
            if (desc.length > 700) desc = [[desc substringToIndex:700] stringByAppendingString:@"…"];
            FBPStoryLog(@"SOURCE-DEEP %@ getter=%@ class=%@ value=%@",
                        label, name, NSStringFromClass([value class]), desc);
            emitted++;
        }
        free(methods);
    }
}

static void FBPStoryLogClassMetadata(id obj, NSString *label) {
    if (!obj) return;
    for (Class cls = [obj class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int pc = 0;
        objc_property_t *ps = class_copyPropertyList(cls, &pc);
        for (unsigned int i = 0; i < pc && i < 160; i++)
            FBPStoryLog(@"SOURCE-META %@ class=%@ property=%s attrs=%s", label, NSStringFromClass(cls),
                        property_getName(ps[i]) ?: "", property_getAttributes(ps[i]) ?: "");
        free(ps);
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(cls, &mc);
        for (unsigned int i = 0; i < mc && i < 240; i++)
            FBPStoryLog(@"SOURCE-META %@ class=%@ method=%@ types=%s", label, NSStringFromClass(cls),
                        NSStringFromSelector(method_getName(ms[i])), method_getTypeEncoding(ms[i]) ?: "");
        free(ms);
    }
}

static void FBPStoryLogObjectSourceIvars(id obj, NSString *label) {
    if (!obj) return;
    for (Class cls = [obj class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        NSUInteger emitted = 0;
        for (unsigned int i = 0; i < count && emitted < 60; i++) {
            Ivar iv = ivars[i];
            const char *encoding = ivar_getTypeEncoding(iv);
            if (!encoding || encoding[0] != '@') continue;
            NSString *name = [NSString stringWithUTF8String:ivar_getName(iv) ?: ""];
            if (!FBPStoryInterestingSourceName(name)) continue;
            id value = nil;
            @try { value = object_getIvar(obj, iv); } @catch (__unused NSException *e) {}
            if (!value) continue;
            NSString *desc = [value description] ?: @"";
            if (desc.length > 900) desc = [[desc substringToIndex:900] stringByAppendingString:@"…"];
            FBPStoryLog(@"SOURCE-IVAR %@ ivar=%@ class=%@ value=%@",
                        label, name, NSStringFromClass([value class]), desc);
            emitted++;

            // FBSnacksWebPhotoView wraps the actual FBWebPhotoView in _photoView.
            // Probe that inner object one level deeper; it owns the concrete photoID.
            if ([label isEqualToString:@"photoView"] &&
                [name isEqualToString:@"_photoView"] &&
                [NSStringFromClass([value class]) isEqualToString:@"FBWebPhotoView"]) {
                FBPStoryLog(@"SOURCE-INNER begin class=%@ value=%@",
                            NSStringFromClass([value class]), desc);
                FBPStoryLogObjectSourceGetters(value, @"innerFBWebPhotoView");
                // Avoid recursion through this helper; enumerate inner ivars inline.
                for (Class innerCls = [value class]; innerCls && innerCls != NSObject.class;
                     innerCls = class_getSuperclass(innerCls)) {
                    unsigned int innerCount = 0;
                    Ivar *innerIvars = class_copyIvarList(innerCls, &innerCount);
                    NSUInteger innerEmitted = 0;
                    for (unsigned int j = 0; j < innerCount && innerEmitted < 80; j++) {
                        Ivar innerIvar = innerIvars[j];
                        const char *innerEncoding = ivar_getTypeEncoding(innerIvar);
                        if (!innerEncoding || innerEncoding[0] != '@') continue;
                        NSString *innerName =
                            [NSString stringWithUTF8String:ivar_getName(innerIvar) ?: ""];
                        if (!FBPStoryInterestingSourceName(innerName)) continue;
                        id innerValue = nil;
                        @try { innerValue = object_getIvar(value, innerIvar); }
                        @catch (__unused NSException *e) {}
                        if (!innerValue) continue;
                        NSString *innerDesc = [innerValue description] ?: @"";
                        if (innerDesc.length > 1200) {
                            innerDesc = [[innerDesc substringToIndex:1200]
                                         stringByAppendingString:@"…"];
                        }
                        FBPStoryLog(@"SOURCE-INNER-IVAR ivar=%@ class=%@ value=%@",
                                    innerName, NSStringFromClass([innerValue class]), innerDesc);
                        innerEmitted++;

                        NSString *innerClassName = NSStringFromClass([innerValue class]);
                        if ([innerClassName isEqualToString:@"FBMemPhoto"] ||
                            [innerClassName isEqualToString:@"FBMemImage"] ||
                            [innerClassName isEqualToString:@"MOSCachedImage"] ||
                            [innerClassName isEqualToString:@"FBWebImageNetworkStreamingSpecifier"]) {
                            NSString *probeLabel = [NSString stringWithFormat:@"inner.%@.%@", innerName, innerClassName];
                            FBPStoryLogObjectSourceGetters(innerValue, probeLabel);
                            FBPStoryLogObjectSourceIvars(innerValue, probeLabel);
                            if ([innerClassName isEqualToString:@"FBWebImageNetworkStreamingSpecifier"])
                                FBPStoryLogClassMetadata(innerValue, probeLabel);

                            if ([innerClassName isEqualToString:@"FBMemPhoto"]) {
                                FBPStoryLog(@"SOURCE-PRE-SPEC begin class=%@", NSStringFromClass([innerValue class]));
                                for (Class probeCls = [innerValue class]; probeCls && probeCls != NSObject.class;
                                     probeCls = class_getSuperclass(probeCls)) {
                                    unsigned int methodCount = 0;
                                    Method *methods = class_copyMethodList(probeCls, &methodCount);
                                    for (unsigned int mi = 0; mi < methodCount && mi < 1200; mi++) {
                                        SEL sel = method_getName(methods[mi]);
                                        NSString *selName = NSStringFromSelector(sel);
                                        NSString *lower = selName.lowercaseString;
                                        if ([lower containsString:@"specifier"] ||
                                            [lower containsString:@"imageflag"] ||
                                            [lower containsString:@"image"] ||
                                            [lower containsString:@"size"] ||
                                            [lower containsString:@"encoding"] ||
                                            [lower containsString:@"photo"]) {
                                            const char *types = method_getTypeEncoding(methods[mi]);
                                            FBPStoryLog(@"SOURCE-PRE-SPEC class=%@ method=%@ types=%s",
                                                        NSStringFromClass(probeCls), selName, types ?: "");
                                        }
                                    }
                                    free(methods);

                                    unsigned int propertyCount = 0;
                                    objc_property_t *properties = class_copyPropertyList(probeCls, &propertyCount);
                                    for (unsigned int pi = 0; pi < propertyCount && pi < 600; pi++) {
                                        NSString *propName = [NSString stringWithUTF8String:property_getName(properties[pi]) ?: ""];
                                        NSString *lower = propName.lowercaseString;
                                        if ([lower containsString:@"specifier"] ||
                                            [lower containsString:@"imageflag"] ||
                                            [lower containsString:@"image"] ||
                                            [lower containsString:@"size"] ||
                                            [lower containsString:@"encoding"] ||
                                            [lower containsString:@"photo"]) {
                                            FBPStoryLog(@"SOURCE-PRE-SPEC class=%@ property=%@ attrs=%s",
                                                        NSStringFromClass(probeCls), propName,
                                                        property_getAttributes(properties[pi]) ?: "");
                                        }
                                    }
                                    free(properties);
                                }

                                id snacksMedia = FBPStoryObjectGetter(innerValue, @"asFBSnacksMedia");
                                if (snacksMedia) {
                                    FBPStoryLog(@"SOURCE-SNACKS-MEDIA class=%@ value=%@",
                                                NSStringFromClass([snacksMedia class]), [snacksMedia description]);
                                    FBPStoryLogObjectSourceGetters(snacksMedia, @"FBMemPhoto.asFBSnacksMedia");
                                    FBPStoryLogObjectSourceIvars(snacksMedia, @"FBMemPhoto.asFBSnacksMedia");
                                }

                                NSArray *imageFieldNames = @[@"image2048", @"image1286", @"image960", @"image720", @"image600"];
                                NSMutableDictionary *seenImageObjects = [NSMutableDictionary dictionary];
                                for (NSString *fieldName in imageFieldNames) {
                                    id fieldImage = FBPStoryObjectGetter(innerValue, fieldName);
                                    if (!fieldImage) {
                                        FBPStoryLog(@"SOURCE-IMAGE-FIELD %@ unavailable", fieldName);
                                        continue;
                                    }
                                    NSString *pointerKey = [NSString stringWithFormat:@"%p", fieldImage];
                                    NSString *priorField = seenImageObjects[pointerKey];
                                    FBPStoryLog(@"SOURCE-IMAGE-FIELD %@ ptr=%p class=%@ sameAs=%@ value=%@",
                                                fieldName, fieldImage, NSStringFromClass([fieldImage class]),
                                                priorField ?: @"none", [fieldImage description]);
                                    if (!priorField) seenImageObjects[pointerKey] = fieldName;

                                    for (Class fieldCls = [fieldImage class]; fieldCls && fieldCls != NSObject.class;
                                         fieldCls = class_getSuperclass(fieldCls)) {
                                        unsigned int methodCount = 0;
                                        Method *methods = class_copyMethodList(fieldCls, &methodCount);
                                        for (unsigned int mi = 0; mi < methodCount && mi < 1000; mi++) {
                                            SEL sel = method_getName(methods[mi]);
                                            NSString *name = NSStringFromSelector(sel);
                                            NSString *lower = name.lowercaseString;
                                            if ([lower containsString:@"url"] || [lower containsString:@"uri"] ||
                                                [lower containsString:@"source"] || [lower containsString:@"encoding"] ||
                                                [lower containsString:@"width"] || [lower containsString:@"height"] ||
                                                [lower containsString:@"size"] || [lower containsString:@"dimension"] ||
                                                [lower containsString:@"specifier"] || [lower containsString:@"image"]) {
                                                FBPStoryLog(@"SOURCE-IMAGE-META %@ class=%@ method=%@ types=%s",
                                                            fieldName, NSStringFromClass(fieldCls), name,
                                                            method_getTypeEncoding(methods[mi]) ?: "");
                                            }
                                        }
                                        free(methods);

                                        unsigned int propCount = 0;
                                        objc_property_t *props = class_copyPropertyList(fieldCls, &propCount);
                                        for (unsigned int pi = 0; pi < propCount && pi < 500; pi++) {
                                            NSString *name = [NSString stringWithUTF8String:property_getName(props[pi]) ?: ""];
                                            NSString *lower = name.lowercaseString;
                                            if ([lower containsString:@"url"] || [lower containsString:@"uri"] ||
                                                [lower containsString:@"source"] || [lower containsString:@"encoding"] ||
                                                [lower containsString:@"width"] || [lower containsString:@"height"] ||
                                                [lower containsString:@"size"] || [lower containsString:@"dimension"] ||
                                                [lower containsString:@"specifier"] || [lower containsString:@"image"]) {
                                                FBPStoryLog(@"SOURCE-IMAGE-META %@ class=%@ property=%@ attrs=%s",
                                                            fieldName, NSStringFromClass(fieldCls), name,
                                                            property_getAttributes(props[pi]) ?: "");
                                            }
                                        }
                                        free(props);
                                    }
                                }

                                id image2048 = FBPStoryObjectGetter(innerValue, @"image2048");
                                if (image2048) {
                                    NSString *imageLabel = @"FBMemPhoto.image2048";
                                    FBPStoryLog(@"SOURCE-2048 class=%@ value=%@",
                                                NSStringFromClass([image2048 class]), [image2048 description]);
                                    FBPStoryLogObjectSourceGetters(image2048, imageLabel);
                                    FBPStoryLogObjectSourceIvars(image2048, imageLabel);

                                    for (Class imgCls = [image2048 class]; imgCls && imgCls != NSObject.class;
                                         imgCls = class_getSuperclass(imgCls)) {
                                        unsigned int imgCount = 0;
                                        Ivar *imgIvars = class_copyIvarList(imgCls, &imgCount);
                                        for (unsigned int k = 0; k < imgCount && k < 120; k++) {
                                            Ivar iv = imgIvars[k];
                                            const char *enc = ivar_getTypeEncoding(iv);
                                            if (!enc || enc[0] != '@') continue;
                                            NSString *n = [NSString stringWithUTF8String:ivar_getName(iv) ?: ""];
                                            id v = nil;
                                            @try { v = object_getIvar(image2048, iv); }
                                            @catch (__unused NSException *e) {}
                                            if (!v) continue;
                                            NSString *d = [v description] ?: @"";
                                            if (d.length > 1600) d = [[d substringToIndex:1600] stringByAppendingString:@"…"];
                                            FBPStoryLog(@"SOURCE-2048-ALL ivar=%@ class=%@ value=%@",
                                                        n, NSStringFromClass([v class]), d);
                                        }
                                        free(imgIvars);
                                    }
                                } else {
                                    FBPStoryLog(@"SOURCE-2048 unavailable");
                                }
                            }

                            if ([innerClassName isEqualToString:@"FBWebImageNetworkStreamingSpecifier"]) {
                                NSUInteger (*sendUInt)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
                                NSInteger (*sendInt)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
                                SEL targetFlagSel = NSSelectorFromString(@"targetImageFlag");
                                SEL imageSourceSel = NSSelectorFromString(@"imageSource");
                                if ([innerValue respondsToSelector:targetFlagSel])
                                    FBPStoryLog(@"SOURCE-PRIMITIVE specifier targetImageFlag=%llu",
                                                (unsigned long long)sendUInt(innerValue, targetFlagSel));
                                if ([innerValue respondsToSelector:imageSourceSel])
                                    FBPStoryLog(@"SOURCE-PRIMITIVE specifier imageSource=%lld",
                                                (long long)sendInt(innerValue, imageSourceSel));

                                id targetNode = FBPStoryObjectGetter(innerValue, @"targetNode");
                                FBPStoryLog(@"SOURCE-TARGET-NODE class=%@ value=%@",
                                            NSStringFromClass([targetNode class]), [targetNode description]);
                                if (targetNode) {
                                    id targetURL = FBPStoryObjectGetter(targetNode, @"url");
                                    SEL desiredSel = NSSelectorFromString(@"desiredImageFlag");
                                    SEL imageFlagSel = NSSelectorFromString(@"imageFlag");
                                    unsigned long long desired = [targetNode respondsToSelector:desiredSel]
                                        ? (unsigned long long)sendUInt(targetNode, desiredSel) : 0;
                                    unsigned long long imageFlag = [targetNode respondsToSelector:imageFlagSel]
                                        ? (unsigned long long)sendUInt(targetNode, imageFlagSel) : 0;
                                    FBPStoryLog(@"SOURCE-TARGET-NODE url=%@ desiredImageFlag=%llu imageFlag=%llu",
                                                targetURL, desired, imageFlag);
                                }

                                id infoNodes = FBPStoryObjectGetter(innerValue, @"infoNodes");
                                if ([infoNodes conformsToProtocol:@protocol(NSFastEnumeration)]) {
                                    NSUInteger infoIndex = 0;
                                    for (id infoNode in infoNodes) {
                                        id infoURL = FBPStoryObjectGetter(infoNode, @"url");
                                        SEL desiredSel = NSSelectorFromString(@"desiredImageFlag");
                                        SEL imageFlagSel = NSSelectorFromString(@"imageFlag");
                                        unsigned long long desired = [infoNode respondsToSelector:desiredSel]
                                            ? (unsigned long long)sendUInt(infoNode, desiredSel) : 0;
                                        unsigned long long imageFlag = [infoNode respondsToSelector:imageFlagSel]
                                            ? (unsigned long long)sendUInt(infoNode, imageFlagSel) : 0;
                                        FBPStoryLog(@"SOURCE-INFO-NODE[%lu] class=%@ url=%@ desiredImageFlag=%llu imageFlag=%llu value=%@",
                                                    (unsigned long)infoIndex++, NSStringFromClass([infoNode class]),
                                                    infoURL, desired, imageFlag, [infoNode description]);
                                    }
                                } else {
                                    FBPStoryLog(@"SOURCE-INFO-NODES unavailable class=%@ value=%@",
                                                NSStringFromClass([infoNodes class]), [infoNodes description]);
                                }

                                id nodes = FBPStoryObjectGetter(innerValue, @"downloadNodes");
                                if ([nodes conformsToProtocol:@protocol(NSFastEnumeration)]) {
                                    NSUInteger nodeIndex = 0;
                                    for (id node in nodes) {
                                        NSString *nodeLabel = [NSString stringWithFormat:@"downloadNode[%lu]", (unsigned long)nodeIndex++];
                                        NSString *nodeDesc = [node description] ?: @"";
                                        if (nodeDesc.length > 1200) nodeDesc = [[nodeDesc substringToIndex:1200] stringByAppendingString:@"…"];
                                        FBPStoryLog(@"SOURCE-NODE %@ class=%@ value=%@", nodeLabel,
                                                    NSStringFromClass([node class]), nodeDesc);
                                        SEL desiredSel = NSSelectorFromString(@"desiredImageFlag");
                                        SEL imageFlagSel = NSSelectorFromString(@"imageFlag");
                                        unsigned long long desired = [node respondsToSelector:desiredSel]
                                            ? (unsigned long long)sendUInt(node, desiredSel) : 0;
                                        unsigned long long imageFlag = [node respondsToSelector:imageFlagSel]
                                            ? (unsigned long long)sendUInt(node, imageFlagSel) : 0;
                                        FBPStoryLog(@"SOURCE-NODE-FLAGS %@ desiredImageFlag=%llu imageFlag=%llu",
                                                    nodeLabel, desired, imageFlag);
                                        FBPStoryLogObjectSourceGetters(node, nodeLabel);
                                        FBPStoryLogObjectSourceIvars(node, nodeLabel);
                                        FBPStoryLogClassMetadata(node, nodeLabel);
                                    }
                                } else {
                                    FBPStoryLog(@"SOURCE-NODE downloadNodes unavailable class=%@ value=%@",
                                                NSStringFromClass([nodes class]), [nodes description]);
                                }
                            }
                        }
                    }
                    free(innerIvars);
                }
            }
        }
        free(ivars);
    }
}

static void FBPStoryLogPhotoSourceCandidates(id mediaView) {
    NSArray<NSString *> *names = @[@"photoView", @"mediaViewLoadedInfo", @"media", @"model", @"content",
                                   @"imageURL", @"photoURL", @"mediaURL", @"sourceURL", @"URL"];
    for (NSString *name in names) {
        id value = FBPStoryObjectGetter(mediaView, name);
        if (!value) continue;
        NSString *desc = [value description] ?: @"";
        if (desc.length > 500) desc = [[desc substringToIndex:500] stringByAppendingString:@"…"];
        FBPStoryLog(@"SOURCE-CANDIDATE getter=%@ class=%@ value=%@",
                    name, NSStringFromClass([value class]), desc);
        if ([name isEqualToString:@"photoView"] || [name isEqualToString:@"mediaViewLoadedInfo"]) {
            FBPStoryLogObjectSourceGetters(value, name);
            FBPStoryLogObjectSourceIvars(value, name);
        }
    }
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

static void FBPStoryCaptureCurrentVideo(id controller, id mediaView) {
    Class videoClass = objc_getClass("FBSnacksNewVideoView");
    if (!videoClass || !mediaView || ![mediaView isKindOfClass:videoClass]) return;

    id playbackController = FBPStoryObjectGetter(mediaView, @"playbackController");
    id item = FBPStoryObjectGetter(playbackController, @"currentVideoPlaybackItem");
    if (!item) return;

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

    if (!url || ![url.scheme.lowercaseString hasPrefix:@"http"]) return;

    gStoryController = controller;
    gStoryMediaView = mediaView;
    gStoryMediaIsVideo = YES;
    gStoryRenderedImage = nil;
    gStoryVideoURL = [url copy];
    gStoryVideoID = [videoID isKindOfClass:NSString.class] ? [videoID copy] : [videoID description];

    FBPStoryLog(@"captured videoID=%@ url=%@", gStoryVideoID, gStoryVideoURL.absoluteString);

    dispatch_async(dispatch_get_main_queue(), ^{
        FBPStoryInstallOrUpdateButton((UIViewController *)controller);
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
            FBPStoryDumpPhotoProbe(controller, mediaView);
            return;
        }
        FBPStoryLog(@"photo fallback resolved FBWebPhotoView response URL=%@", url.absoluteString);
        FBPStoryLogPhotoSourceCandidates(mediaView);
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

    Class videoClass = objc_getClass("FBSnacksNewVideoView");
    if (videoClass && mediaView && [mediaView isKindOfClass:videoClass]) {
        FBPStoryCaptureCurrentVideo(self, mediaView);
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
