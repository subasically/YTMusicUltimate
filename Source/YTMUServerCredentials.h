#import <UIKit/UIKit.h>
#import <Security/Security.h>

NSString *YTMUCopyServerAPIKey(OSStatus *status);
BOOL YTMUStoreServerAPIKey(NSString *key, OSStatus *status);
void YTMUPresentServerAPIKeyEntry(UIViewController *controller, void (^completion)(void));
