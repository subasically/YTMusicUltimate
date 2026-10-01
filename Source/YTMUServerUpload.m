#import "YTMUServerUpload.h"

static NSString *YTMUUploadString(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}

NSString *YTMUServerEndpoint(NSUserDefaults *defaults, NSString *setting, NSString *path) {
    NSDictionary *settings = [defaults dictionaryForKey:@"YTMUltimate"] ?: @{};
    NSString *configured = YTMUUploadString(settings[setting]);
    NSString *endpoint = [@"https://radio.subasically.me" stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:configured ?: @""];
    NSString *configuredPath = [url.path hasSuffix:@"/"] ? [url.path substringToIndex:url.path.length - 1] : url.path;
    if ([url.host.lowercaseString isEqualToString:@"radio-v2.subasically.me"] && [configuredPath isEqualToString:path]) {
        NSMutableDictionary *updated = [settings mutableCopy];
        updated[setting] = endpoint;
        [defaults setObject:updated forKey:@"YTMUltimate"];
        return endpoint;
    }
    return configured ?: endpoint;
}

BOOL YTMUIsSecureServerURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length > 0 && !url.user && !url.password;
}

NSString *YTMUServerUploadLanguage(NSUserDefaults *defaults) {
    return [[[defaults dictionaryForKey:@"YTMUltimate"] objectForKey:@"uploadLanguage"] isEqual:@"en"] ? @"en" : @"bs";
}

NSData *YTMUServerUploadBody(NSData *fileData, NSString *filename, NSString *boundary, NSString *language) {
    // Keep user-provided filenames inside the quoted multipart parameter.
    NSString *safeFilename = [[[[filename stringByReplacingOccurrencesOfString:@"\r" withString:@""]
        stringByReplacingOccurrencesOfString:@"\n" withString:@""]
        stringByReplacingOccurrencesOfString:@"\\" withString:@"_"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"_"];
    NSString *contentType = [filename.pathExtension.lowercaseString isEqualToString:@"mp3"] ? @"audio/mpeg" : @"audio/mp4";
    NSMutableData *body = [NSMutableData data];
    NSString *header = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\nContent-Type: %@\r\n\r\n", boundary, safeFilename, contentType];
    [body appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    NSString *footer = [NSString stringWithFormat:@"\r\n--%@\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n%@\r\n--%@--\r\n", boundary, [language isEqualToString:@"en"] ? @"en" : @"bs", boundary];
    [body appendData:[footer dataUsingEncoding:NSUTF8StringEncoding]];
    return body;
}

static NSDictionary *YTMUUploadJSON(NSData *data) {
    id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

NSString *YTMUServerErrorMessage(NSData *data) {
    NSDictionary *json = YTMUUploadJSON(data);
    return YTMUUploadString(json[@"error"]) ?: YTMUUploadString(json[@"message"]) ?: YTMUUploadString(json[@"detail"]);
}

NSDictionary *YTMUServerUploadResult(NSData *data, NSInteger statusCode) {
    NSDictionary *json = YTMUUploadJSON(data);
    NSString *message = YTMUUploadString(json[@"message"]);
    NSString *error = YTMUUploadString(json[@"error"]);
    BOOL httpSuccess = statusCode >= 200 && statusCode < 300;
    // Preserve the legacy duplicate success envelope on 2xx only.
    if (httpSuccess && !error && [message isEqualToString:@"File already exists"]) {
        return @{@"success": @YES, @"message": @"Already exists"};
    }
    id success = json[@"success"];
    BOOL apiFailure = [success isKindOfClass:NSNumber.class] && ![success boolValue];
    if (!httpSuccess || error || apiFailure) {
        return @{@"success": @NO, @"message": error ?: message ?: (httpSuccess ? @"Server rejected upload" : [NSString stringWithFormat:@"HTTP %ld", (long)statusCode])};
    }
    return @{@"success": @YES};
}

NSString *YTMURedactServerCredential(NSString *text, NSString *credential) {
    if (credential.length == 0 || text.length == 0) return text;
    return [text stringByReplacingOccurrencesOfString:credential withString:@"[redacted]"];
}
