#import <Foundation/Foundation.h>

NSString *YTMUServerEndpoint(NSUserDefaults *defaults, NSString *setting, NSString *path);
NSString *YTMUServerUploadLanguage(NSUserDefaults *defaults);
NSData *YTMUServerUploadBody(NSData *fileData, NSString *filename, NSString *boundary, NSString *language);
NSDictionary *YTMUServerUploadResult(NSData *data, NSInteger statusCode);
NSString *YTMUServerErrorMessage(NSData *data);
NSString *YTMURedactServerCredential(NSString *text, NSString *credential);
BOOL YTMUIsSecureServerURL(NSURL *url);
