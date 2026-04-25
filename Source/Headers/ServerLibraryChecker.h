#import <Foundation/Foundation.h>

@interface ServerLibraryChecker : NSObject
+ (void)checkTrackWithTitle:(NSString *)title artist:(NSString *)artist completion:(void (^)(NSDictionary *result))completion;
@end
