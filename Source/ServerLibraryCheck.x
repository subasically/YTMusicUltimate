#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTMNowPlayingView.h"
#import "Headers/YTMWatchViewController.h"
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTPlayerResponse.h"
#import "Headers/YTIPlayerResponse.h"
#import "Headers/YTIVideoDetails.h"
#import "YTMUMetadataProbe.h"

extern void YTMULogFetchedMetadataSnapshotForPlayer(YTPlayerViewController *playerVC);

static NSMutableDictionary<NSString *, NSMutableArray<void (^)(NSDictionary *result)> *> *pendingLibraryChecks = nil;

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

static NSDictionary *YTMUSettings(void) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [settings isKindOfClass:[NSDictionary class]] ? settings : @{};
}

static NSString *YTMUTrimmedStringValue(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;

    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

static BOOL YTMULibraryLoggingEnabled(void) {
    id configuredValue = YTMUSettings()[@"ntfyMetadataLogging"];
    if ([configuredValue respondsToSelector:@selector(boolValue)]) {
        return [configuredValue boolValue];
    }

    return YES;
}

/// Still logs to NSLog; only error/warn library topics are sent to ntfy.
static BOOL YTMUShouldPostLibraryNtfy(NSString *title) {
    if (title.length == 0) {
        return NO;
    }
    NSString *normalized = title.lowercaseString;
    return [normalized rangeOfString:@"error"].location != NSNotFound || [normalized rangeOfString:@"warn"].location != NSNotFound;
}

static NSString *YTMULibraryExistsEndpoint(void) {
    return YTMUTrimmedStringValue(YTMUSettings()[@"libraryExistsEndpoint"]) ?: @"https://radio-v2.subasically.me/api/tracks/exists";
}

static NSString *YTMUSafeString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *YTMUSerializedJSONFragment(id value) {
    if (!value) return nil;

    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }

    if (![NSJSONSerialization isValidJSONObject:value]) {
        return [value description];
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!jsonData) return [value description];

    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return jsonString.length > 400 ? [[jsonString substringToIndex:400] stringByAppendingString:@"..."] : jsonString;
}

static void YTMUSendLibraryLog(NSString *title, NSDictionary<NSString *, NSString *> *fields) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    for (NSString *key in fields) {
        NSString *value = fields[key];
        if (value.length > 0) {
            [lines addObject:[NSString stringWithFormat:@"%@: %@", key, value]];
        }
    }

    NSString *body = [lines componentsJoinedByString:@"\n"];
    NSLog(@"[YTMU] %@\n%@", title, body);

    if (!YTMULibraryLoggingEnabled()) return;
    if (!YTMUShouldPostLibraryNtfy(title)) return;

    NSString *topic = YTMUTrimmedStringValue(YTMUSettings()[@"ntfyTopic"]) ?: @"ytmusicultimate";
    NSString *server = YTMUTrimmedStringValue(YTMUSettings()[@"ntfyServer"]) ?: @"https://ntfy.subasically.me";
    NSString *baseURL = [server hasSuffix:@"/"] ? [server substringToIndex:server.length - 1] : server;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", baseURL, topic]];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 10;
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:title ?: @"YTMU library" forHTTPHeaderField:@"Title"];

    NSString *token = YTMUTrimmedStringValue(YTMUSettings()[@"ntfyToken"]);
    if (token.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[YTMU] ntfy library log failed: %@", error.localizedDescription);
            return;
        }

        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (statusCode < 200 || statusCode >= 300) {
            NSLog(@"[YTMU] ntfy library log returned HTTP %ld", (long)statusCode);
        }
    }] resume];
}

static void YTMUSendLibraryRequestLog(NSString *phase, NSString *queryTitle, NSString *queryArtist, NSDictionary *result) {
    NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
    fields[@"phase"] = phase ?: @"unknown";
    fields[@"query_title"] = queryTitle ?: @"<none>";
    fields[@"query_artist"] = queryArtist ?: @"<none>";
    fields[@"endpoint"] = YTMULibraryExistsEndpoint();

    NSNumber *statusCode = result[@"statusCode"];
    if ([statusCode respondsToSelector:@selector(stringValue)]) {
        fields[@"status_code"] = statusCode.stringValue;
    }

    NSString *state = YTMUSafeString(result[@"state"]);
    if (state.length > 0) {
        fields[@"state"] = state;
    }

    NSString *detail = YTMUSafeString(result[@"detail"]);
    if (detail.length > 0) {
        fields[@"detail"] = detail;
    }

    NSString *responseSummary = YTMUSafeString(result[@"responseSummary"]);
    if (responseSummary.length > 0) {
        fields[@"response"] = responseSummary;
    }

    id existsValue = result[@"exists"];
    if ([existsValue respondsToSelector:@selector(boolValue)]) {
        fields[@"exists"] = [existsValue boolValue] ? @"yes" : @"no";
    }

    YTMUSendLibraryLog([NSString stringWithFormat:@"YTMU library-request-%@", phase ?: @"state"], fields);
}

static void YTMUSendLibraryResultLog(NSString *queryTitle, NSString *queryArtist, NSDictionary *result) {
    NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
    fields[@"phase"] = @"result";
    fields[@"query_title"] = queryTitle ?: @"<none>";
    fields[@"query_artist"] = queryArtist ?: @"<none>";
    fields[@"endpoint"] = YTMULibraryExistsEndpoint();

    NSString *state = YTMUSafeString(result[@"state"]) ?: @"unknown";
    fields[@"state"] = state;

    id existsValue = result[@"exists"];
    if ([existsValue respondsToSelector:@selector(boolValue)]) {
        fields[@"exists"] = [existsValue boolValue] ? @"yes" : @"no";
    }

    NSNumber *statusCode = result[@"statusCode"];
    if ([statusCode respondsToSelector:@selector(stringValue)]) {
        fields[@"status_code"] = statusCode.stringValue;
    }

    NSString *detail = YTMUSafeString(result[@"detail"]);
    if (detail.length > 0) {
        fields[@"detail"] = detail;
    }

    NSString *responseSummary = YTMUSafeString(result[@"responseSummary"]);
    if (responseSummary.length > 0) {
        fields[@"response"] = responseSummary;
    }

    NSString *matchType = YTMUSafeString(result[@"matchType"]);
    if (matchType.length > 0) {
        fields[@"match_type"] = matchType;
    }

    NSString *confidence = YTMUSafeString(result[@"confidence"]);
    if (confidence.length > 0) {
        fields[@"confidence"] = confidence;
    }

    NSString *matchedTitle = YTMUSafeString(result[@"matchedTitle"]);
    if (matchedTitle.length > 0) {
        fields[@"matched_title"] = matchedTitle;
    }

    NSString *matchedArtist = YTMUSafeString(result[@"matchedArtist"]);
    if (matchedArtist.length > 0) {
        fields[@"matched_artist"] = matchedArtist;
    }

    YTMUSendLibraryLog(@"YTMU library-result", fields);
}

@interface YTMNowPlayingViewController (ServerCheck)
- (void)updateServerCheckIndicator;
- (void)refreshLibraryAndUpdate;
@end

@interface ServerLibraryChecker : NSObject
+ (void)checkTrackWithTitle:(NSString *)title artist:(NSString *)artist completion:(void (^)(NSDictionary *result))completion;
@end

@implementation ServerLibraryChecker

+ (NSString *)requestKeyForTitle:(NSString *)title artist:(NSString *)artist {
    NSString *normalizedTitle = [[YTMUTrimmedStringValue(title) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *normalizedArtist = [[YTMUTrimmedStringValue(artist) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [NSString stringWithFormat:@"%@\n%@", normalizedArtist, normalizedTitle];
}

+ (NSDictionary *)resultWithState:(NSString *)state
                           exists:(BOOL)exists
                       statusCode:(NSInteger)statusCode
                           detail:(NSString *)detail
                  responseSummary:(NSString *)responseSummary {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"state"] = state ?: @"unknown";
    result[@"exists"] = @(exists);
    if (statusCode > 0) {
        result[@"statusCode"] = @(statusCode);
    }
    if (detail.length > 0) {
        result[@"detail"] = detail;
    }
    if (responseSummary.length > 0) {
        result[@"responseSummary"] = responseSummary;
    }
    return result;
}

+ (NSDictionary *)resultByMergingMetadataFromDictionary:(NSDictionary *)dictionary intoResult:(NSDictionary *)baseResult {
    NSMutableDictionary *result = [baseResult mutableCopy];

    NSString *matchType = YTMUSafeString(dictionary[@"match_type"]) ?: YTMUSafeString(dictionary[@"matchType"]);
    if (matchType.length > 0) {
        result[@"matchType"] = matchType;
    }

    id confidenceValue = dictionary[@"confidence"];
    if ([confidenceValue respondsToSelector:@selector(stringValue)]) {
        result[@"confidence"] = [confidenceValue stringValue];
    }

    NSDictionary *matchedTrack = [dictionary[@"matched_track"] isKindOfClass:[NSDictionary class]] ? dictionary[@"matched_track"] : nil;
    if (matchedTrack) {
        NSString *matchedTitle = YTMUSafeString(matchedTrack[@"title"]);
        NSString *matchedArtist = YTMUSafeString(matchedTrack[@"artist"]);
        if (matchedTitle.length > 0) {
            result[@"matchedTitle"] = matchedTitle;
        }
        if (matchedArtist.length > 0) {
            result[@"matchedArtist"] = matchedArtist;
        }
    }

    return result;
}

+ (NSDictionary *)parsedExistsResultFromObject:(id)object statusCode:(NSInteger)statusCode {
    NSString *responseSummary = YTMUSerializedJSONFragment(object);

    if ([object respondsToSelector:@selector(boolValue)] && [object isKindOfClass:[NSNumber class]]) {
        return [self resultWithState:@"success"
                              exists:[object boolValue]
                          statusCode:statusCode
                              detail:@"boolean response"
                     responseSummary:responseSummary];
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        NSArray<NSString *> *booleanKeys = @[@"exists", @"found", @"inLibrary", @"in_library", @"isInLibrary", @"matched", @"present"];
        for (NSString *key in booleanKeys) {
            id value = dictionary[key];
            if ([value respondsToSelector:@selector(boolValue)]) {
                NSDictionary *result = [self resultWithState:@"success"
                                                      exists:[value boolValue]
                                                  statusCode:statusCode
                                                      detail:[NSString stringWithFormat:@"parsed %@", key]
                                             responseSummary:responseSummary];
                return [self resultByMergingMetadataFromDictionary:dictionary intoResult:result];
            }
        }

        NSDictionary *dataDictionary = [dictionary[@"data"] isKindOfClass:[NSDictionary class]] ? dictionary[@"data"] : nil;
        if (dataDictionary) {
            for (NSString *key in booleanKeys) {
                id value = dataDictionary[key];
                if ([value respondsToSelector:@selector(boolValue)]) {
                    NSDictionary *result = [self resultWithState:@"success"
                                                          exists:[value boolValue]
                                                      statusCode:statusCode
                                                          detail:[NSString stringWithFormat:@"parsed data.%@", key]
                                                 responseSummary:responseSummary];
                    return [self resultByMergingMetadataFromDictionary:dataDictionary intoResult:result];
                }
            }
        }

        id trackValue = dictionary[@"track"] ?: dictionary[@"result"] ?: dictionary[@"match"];
        if ([trackValue isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = [self resultWithState:@"success"
                                                  exists:YES
                                              statusCode:statusCode
                                                  detail:@"track object present"
                                         responseSummary:responseSummary];
            return [self resultByMergingMetadataFromDictionary:dictionary intoResult:result];
        }

        if ([trackValue isKindOfClass:[NSArray class]]) {
            NSDictionary *result = [self resultWithState:@"success"
                                                  exists:[(NSArray *)trackValue count] > 0
                                              statusCode:statusCode
                                                  detail:@"track array present"
                                         responseSummary:responseSummary];
            return [self resultByMergingMetadataFromDictionary:dictionary intoResult:result];
        }

        id nestedTrackValue = dataDictionary[@"track"] ?: dataDictionary[@"result"] ?: dataDictionary[@"match"] ?: dataDictionary[@"matched_track"];
        if ([nestedTrackValue isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = [self resultWithState:@"success"
                                                  exists:YES
                                              statusCode:statusCode
                                                  detail:@"data track object present"
                                         responseSummary:responseSummary];
            return [self resultByMergingMetadataFromDictionary:dataDictionary intoResult:result];
        }

        if ([nestedTrackValue isKindOfClass:[NSArray class]]) {
            NSDictionary *result = [self resultWithState:@"success"
                                                  exists:[(NSArray *)nestedTrackValue count] > 0
                                              statusCode:statusCode
                                                  detail:@"data track array present"
                                         responseSummary:responseSummary];
            return [self resultByMergingMetadataFromDictionary:dataDictionary intoResult:result];
        }

        NSString *message = YTMUSafeString(dictionary[@"message"]) ?: YTMUSafeString(dictionary[@"detail"]);
        return [self resultWithState:@"unrecognized-response"
                              exists:NO
                          statusCode:statusCode
                              detail:message ?: @"unrecognized JSON response"
                     responseSummary:responseSummary];
    }

    if ([object isKindOfClass:[NSString class]]) {
        NSString *normalized = [[(NSString *)object stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if ([normalized isEqualToString:@"true"] || [normalized isEqualToString:@"yes"] || [normalized isEqualToString:@"found"] || [normalized isEqualToString:@"exists"]) {
            return [self resultWithState:@"success" exists:YES statusCode:statusCode detail:@"string response" responseSummary:responseSummary];
        }

        if ([normalized isEqualToString:@"false"] || [normalized isEqualToString:@"no"] || [normalized isEqualToString:@"missing"] || [normalized isEqualToString:@"not_found"]) {
            return [self resultWithState:@"success" exists:NO statusCode:statusCode detail:@"string response" responseSummary:responseSummary];
        }
    }

    return [self resultWithState:@"unrecognized-response"
                          exists:NO
                      statusCode:statusCode
                          detail:@"could not parse exists response"
                 responseSummary:responseSummary];
}

+ (void)finishPendingChecksForKey:(NSString *)key result:(NSDictionary *)result {
    NSArray *completions = [pendingLibraryChecks[key] copy] ?: @[];
    [pendingLibraryChecks removeObjectForKey:key];

    for (id completion in completions) {
        void (^block)(NSDictionary *) = completion;
        if (block) block(result);
    }
}

+ (void)checkTrackWithTitle:(NSString *)title artist:(NSString *)artist completion:(void (^)(NSDictionary *result))completion {
    NSString *requestTitle = YTMUTrimmedStringValue(title) ?: @"";
    NSString *requestArtist = YTMUTrimmedStringValue(artist) ?: @"";
    NSString *requestKey = [self requestKeyForTitle:requestTitle artist:requestArtist];

    if (!pendingLibraryChecks) {
        pendingLibraryChecks = [NSMutableDictionary dictionary];
    }

    NSMutableArray *pending = pendingLibraryChecks[requestKey];
    if (!pending) {
        pending = [NSMutableArray array];
        pendingLibraryChecks[requestKey] = pending;
    }
    if (completion) {
        [pending addObject:[completion copy]];
    }

    if (pending.count > 1) {
        NSLog(@"[YTMU] Library request already in flight for %@ - %@", requestArtist, requestTitle);
        return;
    }

    NSURL *url = [NSURL URLWithString:YTMULibraryExistsEndpoint()];
    if (!url) {
        NSDictionary *result = [self resultWithState:@"invalid-endpoint" exists:NO statusCode:0 detail:@"library exists endpoint is invalid" responseSummary:nil];
        YTMUSendLibraryRequestLog(@"error", requestTitle, requestArtist, result);
        [self finishPendingChecksForKey:requestKey result:result];
        return;
    }

    NSDictionary *payload = @{
        @"title": requestTitle,
        @"artist": requestArtist
    };

    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (!bodyData || jsonError) {
        NSDictionary *result = [self resultWithState:@"request-build-error" exists:NO statusCode:0 detail:jsonError.localizedDescription ?: @"failed to encode request body" responseSummary:nil];
        YTMUSendLibraryRequestLog(@"error", requestTitle, requestArtist, result);
        [self finishPendingChecksForKey:requestKey result:result];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 20;
    request.HTTPBody = bodyData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    YTMUSendLibraryRequestLog(@"start", requestTitle, requestArtist, @{
        @"state": @"start",
        @"detail": @"POST /api/tracks/exists"
    });

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];

        if (error) {
            NSDictionary *result = [self resultWithState:@"network-error" exists:NO statusCode:statusCode detail:error.localizedDescription ?: @"network error" responseSummary:nil];
            YTMUSendLibraryRequestLog(@"error", requestTitle, requestArtist, result);
            [self finishPendingChecksForKey:requestKey result:result];
            return;
        }

        if (statusCode < 200 || statusCode >= 300) {
            NSString *responseText = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            NSDictionary *result = [self resultWithState:@"http-error" exists:NO statusCode:statusCode detail:[NSString stringWithFormat:@"HTTP %ld", (long)statusCode] responseSummary:responseText];
            YTMUSendLibraryRequestLog(@"error", requestTitle, requestArtist, result);
            [self finishPendingChecksForKey:requestKey result:result];
            return;
        }

        if (!data || data.length == 0) {
            NSDictionary *result = [self resultWithState:@"success" exists:NO statusCode:statusCode detail:@"empty response body" responseSummary:nil];
            YTMUSendLibraryRequestLog(@"success", requestTitle, requestArtist, result);
            [self finishPendingChecksForKey:requestKey result:result];
            return;
        }

        NSError *parseError = nil;
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        if (parseError) {
            NSString *responseText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSDictionary *result = [self resultWithState:@"json-error" exists:NO statusCode:statusCode detail:parseError.localizedDescription ?: @"json parse error" responseSummary:responseText];
            YTMUSendLibraryRequestLog(@"error", requestTitle, requestArtist, result);
            [self finishPendingChecksForKey:requestKey result:result];
            return;
        }

        NSDictionary *result = [self parsedExistsResultFromObject:object statusCode:statusCode];
        NSString *phase = [YTMUSafeString(result[@"state"]) isEqualToString:@"success"] ? @"success" : @"error";
        YTMUSendLibraryRequestLog(phase, requestTitle, requestArtist, result);
        [self finishPendingChecksForKey:requestKey result:result];
    }];

    [task resume];
}

@end

%hook YTMNowPlayingViewController

- (void)viewDidLoad {
    %orig;

    if (!YTMU(@"YTMUltimateIsEnabled")) return;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateServerCheckIndicator)
                                                 name:@"ServerLibraryCheckUpdate"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshLibraryAndUpdate)
                                                 name:@"ServerLibraryRefreshNeeded"
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    if (!YTMU(@"YTMUltimateIsEnabled")) return;

    NSLog(@"[YTMU] YTMNowPlayingViewController viewWillAppear");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateServerCheckIndicator];
    });
}

%new
- (void)updateServerCheckIndicator {
    NSLog(@"[YTMU] updateServerCheckIndicator called");

    YTMWatchViewController *watchVC = (YTMWatchViewController *)self.parentViewController;
    if (!watchVC) {
        NSLog(@"[YTMU] No watchVC");
        return;
    }

    YTPlayerViewController *playerVC = watchVC.playerViewController;
    if (!playerVC) {
        NSLog(@"[YTMU] No playerVC");
        return;
    }

    YTPlayerResponse *playerResponse = playerVC.playerResponse;
    if (!playerResponse) {
        NSLog(@"[YTMU] No playerResponse");
        return;
    }

    NSString *title = YTMUTrimmedStringValue(playerResponse.playerData.videoDetails.title);
    NSString *artist = YTMUTrimmedStringValue(playerResponse.playerData.videoDetails.author);

    NSLog(@"[YTMU] Checking track: %@ - %@", artist, title);

    if (title.length == 0) {
        NSLog(@"[YTMU] No title");
        return;
    }

    UIView *nowPlayingView = self.view;
    if (!nowPlayingView) {
        NSLog(@"[YTMU] No nowPlayingView");
        return;
    }

    static NSInteger const INDICATOR_TAG = 7777;

    UIView *existingIndicator = [nowPlayingView viewWithTag:INDICATOR_TAG];
    [existingIndicator removeFromSuperview];

    UILabel *checkingIndicator = [[UILabel alloc] init];
    checkingIndicator.tag = INDICATOR_TAG;
    checkingIndicator.textAlignment = NSTextAlignmentCenter;
    checkingIndicator.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    checkingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    checkingIndicator.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    checkingIndicator.layer.cornerRadius = 10;
    checkingIndicator.clipsToBounds = YES;
    checkingIndicator.text = @"  ⏳ Checking library...  ";
    checkingIndicator.textColor = [UIColor systemGrayColor];

    [nowPlayingView addSubview:checkingIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [checkingIndicator.topAnchor constraintEqualToAnchor:nowPlayingView.topAnchor constant:50],
        [checkingIndicator.centerXAnchor constraintEqualToAnchor:nowPlayingView.centerXAnchor],
        [checkingIndicator.heightAnchor constraintEqualToConstant:20]
    ]];

    NSDate *checkStartTime = [NSDate date];

    [ServerLibraryChecker checkTrackWithTitle:title artist:artist completion:^(NSDictionary *result) {
        YTMUSendLibraryResultLog(title, artist, result);

        BOOL requestSucceeded = [[YTMUSafeString(result[@"state"]) ?: @"" lowercaseString] isEqualToString:@"success"];
        BOOL inLibrary = [result[@"exists"] boolValue];
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:checkStartTime];
        NSTimeInterval minDisplayTime = 1.0;
        NSTimeInterval delay = MAX(0, minDisplayTime - elapsed);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *existing = [nowPlayingView viewWithTag:INDICATOR_TAG];
            [existing removeFromSuperview];

            UILabel *indicator = [[UILabel alloc] init];
            indicator.tag = INDICATOR_TAG;
            indicator.textAlignment = NSTextAlignmentCenter;
            indicator.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
            indicator.translatesAutoresizingMaskIntoConstraints = NO;
            indicator.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
            indicator.layer.cornerRadius = 10;
            indicator.clipsToBounds = YES;

            if (!requestSucceeded) {
                indicator.text = @"  ⚠ Library check failed  ";
                indicator.textColor = [UIColor systemRedColor];
            } else if (inLibrary) {
                indicator.text = @"  ✓ In library  ";
                indicator.textColor = [UIColor systemGreenColor];
            } else {
                indicator.text = @"  ⚠ Not in library  ";
                indicator.textColor = [UIColor systemOrangeColor];
            }

            [nowPlayingView addSubview:indicator];
            [NSLayoutConstraint activateConstraints:@[
                [indicator.topAnchor constraintEqualToAnchor:nowPlayingView.topAnchor constant:50],
                [indicator.centerXAnchor constraintEqualToAnchor:nowPlayingView.centerXAnchor],
                [indicator.heightAnchor constraintEqualToConstant:20]
            ]];

            NSLog(@"[YTMU] Added indicator label: %@", indicator.text);
        });
    }];
}

%new
- (void)refreshLibraryAndUpdate {
    NSLog(@"[YTMU] refreshLibraryAndUpdate called");

    UIView *nowPlayingView = self.view;
    if (!nowPlayingView) return;

    static NSInteger const INDICATOR_TAG = 7777;

    UIView *existingIndicator = [nowPlayingView viewWithTag:INDICATOR_TAG];
    [existingIndicator removeFromSuperview];

    UILabel *checkingIndicator = [[UILabel alloc] init];
    checkingIndicator.tag = INDICATOR_TAG;
    checkingIndicator.textAlignment = NSTextAlignmentCenter;
    checkingIndicator.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    checkingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    checkingIndicator.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    checkingIndicator.layer.cornerRadius = 10;
    checkingIndicator.clipsToBounds = YES;
    checkingIndicator.text = @"  ⏳ Updating library...  ";
    checkingIndicator.textColor = [UIColor systemGrayColor];

    [nowPlayingView addSubview:checkingIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [checkingIndicator.topAnchor constraintEqualToAnchor:nowPlayingView.topAnchor constant:50],
        [checkingIndicator.centerXAnchor constraintEqualToAnchor:nowPlayingView.centerXAnchor],
        [checkingIndicator.heightAnchor constraintEqualToConstant:20]
    ]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateServerCheckIndicator];
    });
}

%end

%hook YTPlayerViewController

- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)data {
    %orig;

    if (!YTMU(@"YTMUltimateIsEnabled")) return;

    NSLog(@"[YTMU] didActivateVideo called - song changed!");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *vid = self.contentVideoID;
        if (vid.length > 0) {
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                UIView *rv = win.rootViewController.view;
                if (rv) {
                    YTMUMetadataProbeScanRootViewForByline(vid, rv);
                }
            }
        }
        NSLog(@"[YTMU] Posting ServerLibraryCheckUpdate notification");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ServerLibraryCheckUpdate" object:nil];
        YTMUMetadataProbeOnTrackActivated(self.contentVideoID, self.playerResponse, @"YTPlayerViewController.didActivateVideo");
        // Delay the discovery/fetched snapshot by 3s so it fires after the async
        // WEB_REMIX nextAPI call has had time to populate album + year in the cache.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTMULogFetchedMetadataSnapshotForPlayer(weakSelf);
        });
    });
}

%end
