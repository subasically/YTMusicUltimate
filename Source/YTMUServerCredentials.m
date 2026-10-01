#import "YTMUServerCredentials.h"
#import <Security/Security.h>

static NSDictionary *YTMUServerKeyQuery(void) {
    // Let the signed host choose its default access group; never use Google's namespace.
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"me.subasically.ytmusicultimate.server-upload",
             (__bridge id)kSecAttrAccount: @"v3-api-key"};
}

NSString *YTMUCopyServerAPIKey(OSStatus *status) {
    NSMutableDictionary *query = [YTMUServerKeyQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus code = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status) *status = code;
    NSData *data = CFBridgingRelease(result);
    return code == errSecSuccess ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

BOOL YTMUStoreServerAPIKey(NSString *key, OSStatus *status) {
    NSString *trimmed = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
        if (status) *status = errSecParam;
        return NO;
    }
    NSDictionary *attributes = @{(__bridge id)kSecValueData: [trimmed dataUsingEncoding:NSUTF8StringEncoding],
                                (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    OSStatus code = SecItemUpdate((__bridge CFDictionaryRef)YTMUServerKeyQuery(), (__bridge CFDictionaryRef)attributes);
    if (code == errSecItemNotFound) {
        NSMutableDictionary *item = [YTMUServerKeyQuery() mutableCopy];
        [item addEntriesFromDictionary:attributes];
        code = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    if (status) *status = code;
    return code == errSecSuccess;
}

void YTMUPresentServerAPIKeyEntry(UIViewController *controller, void (^completion)(void)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Server API key"
        message:@"Copy the V3 API key, then tap Paste and Save. The value stays hidden and is stored only in this iPhone’s Keychain. After saving, tap Save to Server again."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Paste and Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        OSStatus status = errSecSuccess;
        BOOL saved = YTMUStoreServerAPIKey(UIPasteboard.generalPasteboard.string, &status);
        if (saved) {
            if (completion) completion();
            return;
        }
        NSString *message = status == errSecParam ? @"Copy a valid API key before pasting." :
            [NSString stringWithFormat:@"Keychain save failed (%d). Unlock the iPhone and check the app’s signing entitlements, then try again.", (int)status];
        UIAlertController *failure = [UIAlertController alertControllerWithTitle:@"API key not saved" message:message preferredStyle:UIAlertControllerStyleAlert];
        [failure addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [controller presentViewController:failure animated:YES completion:nil];
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}
