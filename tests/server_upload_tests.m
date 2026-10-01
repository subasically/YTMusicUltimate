#import <Foundation/Foundation.h>
#import "YTMUServerUpload.h"

static void Check(BOOL value, NSString *name) {
    if (!value) {
        fprintf(stderr, "FAIL: %s\n", name.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        NSString *suite = [@"ytmu-local-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Check([YTMUServerEndpoint(defaults, @"uploadEndpoint", @"/api/upload") isEqual:@"https://radio.subasically.me/api/upload"], @"V3 upload default");
        Check([YTMUServerEndpoint(defaults, @"libraryExistsEndpoint", @"/api/tracks/exists") isEqual:@"https://radio.subasically.me/api/tracks/exists"], @"V3 exists default");
        [defaults setObject:@{@"uploadEndpoint": @"https://radio-v2.subasically.me/api/upload", @"libraryExistsEndpoint": @"https://radio-v2.subasically.me/api/tracks/exists/", @"unrelated": @YES} forKey:@"YTMUltimate"];
        Check([YTMUServerEndpoint(defaults, @"uploadEndpoint", @"/api/upload") isEqual:@"https://radio.subasically.me/api/upload"], @"migrate upload");
        Check([YTMUServerEndpoint(defaults, @"libraryExistsEndpoint", @"/api/tracks/exists") isEqual:@"https://radio.subasically.me/api/tracks/exists"], @"migrate exists");
        Check([defaults dictionaryForKey:@"YTMUltimate"][@"unrelated"] != nil, @"preserve other settings");
        [defaults setObject:@{@"uploadEndpoint": @"https://custom.example/api/upload"} forKey:@"YTMUltimate"];
        Check([YTMUServerEndpoint(defaults, @"uploadEndpoint", @"/api/upload") isEqual:@"https://custom.example/api/upload"], @"preserve custom endpoint");
        Check([YTMUServerUploadLanguage(defaults) isEqual:@"bs"], @"default Bosnian");
        [defaults setObject:@{@"uploadLanguage": @"en"} forKey:@"YTMUltimate"];
        Check([YTMUServerUploadLanguage(defaults) isEqual:@"en"], @"English selection");
        [defaults setObject:@{@"uploadLanguage": @"unsupported"} forKey:@"YTMUltimate"];
        Check([YTMUServerUploadLanguage(defaults) isEqual:@"bs"], @"invalid language fallback");
        Check(YTMUIsSecureServerURL([NSURL URLWithString:@"https://radio.subasically.me/api/upload"]), @"secure URL");
        Check(!YTMUIsSecureServerURL([NSURL URLWithString:@"http://custom.example/upload"]), @"reject HTTP");
        Check(!YTMUIsSecureServerURL([NSURL URLWithString:@"https://user:password@custom.example/upload"]), @"reject URL credentials");
        Check(!YTMUIsSecureServerURL([NSURL URLWithString:@"file:///tmp/audio"]), @"reject nonnetwork URL");

        NSData *audio = [@"fake-audio" dataUsingEncoding:NSUTF8StringEncoding];
        for (NSString *language in @[@"bs", @"en"]) {
            NSData *body = YTMUServerUploadBody(audio, @"Song.m4a", @"local-boundary", language);
            NSString *expected = [NSString stringWithFormat:@"--local-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"Song.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nfake-audio\r\n--local-boundary\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n%@\r\n--local-boundary--\r\n", language];
            Check([body isEqual:[expected dataUsingEncoding:NSUTF8StringEncoding]], @"exact multipart fields and closing boundary");
        }
        NSString *mp3 = [[NSString alloc] initWithData:YTMUServerUploadBody(audio, @"Song.mp3", @"boundary", @"en") encoding:NSUTF8StringEncoding];
        Check([mp3 containsString:@"Content-Type: audio/mpeg"], @"MP3 MIME");
        NSString *unsafe = [[NSString alloc] initWithData:YTMUServerUploadBody(audio, @"Song\"\r\nInjected.m4a", @"boundary", @"xx") encoding:NSUTF8StringEncoding];
        Check([unsafe containsString:@"filename=\"Song_Injected.m4a\""], @"filename escaping");
        Check([unsafe containsString:@"\r\n\r\nbs\r\n"], @"multipart language fallback");

        NSArray *cases = @[
            @[@201, @"{\"success\":true}", @YES, @""],
            @[@200, @"{\"message\":\"File already exists\"}", @YES, @"Already exists"],
            @[@401, @"{\"error\":\"Invalid API key\"}", @NO, @"Invalid API key"],
            @[@400, @"{\"error\":\"Unsupported language\",\"message\":\"fallback\"}", @NO, @"Unsupported language"],
            @[@200, @"{\"success\":false,\"message\":\"Ingest failed\"}", @NO, @"Ingest failed"],
            @[@200, @"{\"success\":false}", @NO, @"Server rejected upload"],
            @[@200, @"{\"error\":\"Ingest failed\"}", @NO, @"Ingest failed"],
            @[@409, @"{\"message\":\"File already exists\"}", @NO, @"File already exists"],
            @[@502, @"not JSON", @NO, @"HTTP 502"],
            @[@400, @"[]", @NO, @"HTTP 400"],
            @[@403, @"{\"error\":{},\"message\":42,\"success\":null}", @NO, @"HTTP 403"],
            @[@200, @"[]", @YES, @""],
            @[@204, @"", @YES, @""],
            @[@302, @"", @NO, @"HTTP 302"]
        ];
        for (NSArray *test in cases) {
            NSData *data = [test[1] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *result = YTMUServerUploadResult(data, [test[0] integerValue]);
            Check([result[@"success"] isEqual:test[2]], @"upload response success state");
            Check([(result[@"message"] ?: @"") isEqual:test[3]], @"upload response message");
        }
        Check([YTMUServerErrorMessage([@"{\"error\":\"Missing title\"}" dataUsingEncoding:NSUTF8StringEncoding]) isEqual:@"Missing title"], @"exists error envelope");
        Check([YTMURedactServerCredential(@"synthetic-placeholder echoed", @"synthetic-placeholder") isEqual:@"[redacted] echoed"], @"credential redaction using synthetic placeholder");
        [defaults removePersistentDomainForName:suite];
        puts("server_upload_regressions=ok");
    }
    return 0;
}
