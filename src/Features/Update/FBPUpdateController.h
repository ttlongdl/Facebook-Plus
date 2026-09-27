#import <UIKit/UIKit.h>

@interface FBPUpdateController : UIViewController
- (instancetype)initWithInstalledVersion:(NSString *)installedVersion
                         upstreamVersion:(NSString *)upstreamVersion
                             forkVersion:(NSString *)forkVersion
                               changelog:(NSString *)changelog;
@end
