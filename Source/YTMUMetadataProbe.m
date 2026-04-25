#import "YTMUMetadataProbe.h"
#import "FFMpegDownloader.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSLock *YTMUProbeCacheLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

static NSMutableDictionary<NSString *, NSMutableDictionary *> *YTMUProbeCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static NSString *YTMUProbeTrim(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *t = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t.length > 0 ? t : nil;
}

static id YTMUProbeKVC(id root, NSString *keyPath) {
    if (!root || keyPath.length == 0) {
        return nil;
    }
    @try {
        return [root valueForKeyPath:keyPath];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *YTMUProbeStringFromValue(id value) {
    if (!value || value == [NSNull null]) {
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return YTMUProbeTrim(value);
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

/// Protobuf / YT formatted fields are often objects (runs, formatted strings), not plain NSString.
static NSString *YTMUProbeCoerceToString(id value) {
    if (!value || value == [NSNull null]) {
        return nil;
    }
    NSString *direct = YTMUProbeStringFromValue(value);
    if (direct.length > 0) {
        return direct;
    }
    if ([value isKindOfClass:[NSDate class]]) {
        return [NSString stringWithFormat:@"%@", (NSDate *)value];
    }
    NSArray<NSString *> *nestedKeys = @[ @"simpleText", @"text", @"content", @"title", @"label", @"name", @"value" ];
    for (NSString *nk in nestedKeys) {
        id inner = nil;
        @try {
            inner = [value valueForKey:nk];
        } @catch (__unused NSException *e) {
            inner = nil;
        }
        NSString *s = YTMUProbeCoerceToString(inner);
        if (s.length > 0) {
            return s;
        }
    }
    return nil;
}

static NSString *YTMUProbeStringAtKeyPath(id root, NSString *keyPath) {
    return YTMUProbeCoerceToString(YTMUProbeKVC(root, keyPath));
}

static NSString *YTMUProbeHumanizeMusicVideoType(id value) {
    if (!value || value == [NSNull null]) {
        return nil;
    }
    NSInteger v = NSNotFound;
    if ([value isKindOfClass:[NSNumber class]]) {
        v = [(NSNumber *)value integerValue];
    } else if ([value isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0) {
            return nil;
        }
        if ([s hasPrefix:@"MUSIC_VIDEO_TYPE_"]) {
            return [s substringFromIndex:[@"MUSIC_VIDEO_TYPE_" length]];
        }
        v = (NSInteger)[s integerValue];
    } else {
        return nil;
    }
    switch (v) {
        case 0:
            return @"UNSPECIFIED";
        case 1:
            return @"ATV";
        case 2:
            return @"UGC";
        case 3:
            return @"OFFICIAL";
        case 4:
            return @"NON_MUSIC";
        case 5:
            return @"EPISODE";
        case 6:
            return @"MOVIE_TRAILER";
        default:
            return [NSString stringWithFormat:@"MVT_%ld", (long)v];
    }
}

static void YTMUProbeMergeFirstString(NSMutableDictionary *out, NSString *outKey, NSString *s) {
    if (out[outKey] || s.length == 0) {
        return;
    }
    out[outKey] = s;
}

static void YTMUProbeMergeFromKeyPaths(id root, NSArray<NSString *> *paths, NSMutableDictionary *out, NSString *outKey) {
    if (!root) {
        return;
    }
    for (NSString *kp in paths) {
        NSString *s = YTMUProbeStringAtKeyPath(root, kp);
        if (s.length > 0) {
            YTMUProbeMergeFirstString(out, outKey, s);
            return;
        }
    }
}

static void YTMUProbeMergeFromLeafKeys(id obj, NSArray<NSString *> *leafKeys, NSMutableDictionary *out, NSString *outKey) {
    if (!obj || out[outKey]) {
        return;
    }
    for (NSString *k in leafKeys) {
        id v = nil;
        @try {
            v = [obj valueForKey:k];
        } @catch (__unused NSException *e) {
            v = nil;
        }
        NSString *s = YTMUProbeCoerceToString(v);
        if (s.length > 0) {
            out[outKey] = s;
            return;
        }
    }
}

static BOOL YTMUProbeLoggingEnabled(void) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    if (![settings isKindOfClass:[NSDictionary class]]) {
        settings = @{};
    }
    if ([settings objectForKey:@"ntfyProbeLogging"] != nil) {
        id v = settings[@"ntfyProbeLogging"];
        return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
    }
    id meta = settings[@"ntfyMetadataLogging"];
    if ([meta respondsToSelector:@selector(boolValue)]) {
        return [meta boolValue];
    }
    return YES;
}

static NSString *YTMUProbeTrimmedSetting(NSString *key) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    if (![settings isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id v = settings[key];
    if (![v isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *t = [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t.length > 0 ? t : nil;
}

static BOOL YTMUProbeShouldPostNtfy(NSString *title, NSString *body) {
    NSString *normalized = (title ?: @"").lowercaseString;
    return [normalized rangeOfString:@"error"].location != NSNotFound || [normalized rangeOfString:@"warn"].location != NSNotFound;
}

static void YTMUProbePostNtfy(NSString *title, NSString *body) {
    if (!YTMUProbeLoggingEnabled()) {
        return;
    }
    if (!YTMUProbeShouldPostNtfy(title, body)) {
        return;
    }
    NSString *topic = YTMUProbeTrimmedSetting(@"ntfyTopic") ?: @"ytmusicultimate";
    NSString *server = YTMUProbeTrimmedSetting(@"ntfyServer") ?: @"https://ntfy.subasically.me";
    NSString *baseURL = [server hasSuffix:@"/"] ? [server substringToIndex:server.length - 1] : server;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", baseURL, topic]];
    if (!url) {
        return;
    }
    NSMutableString *b = [body mutableCopy];
    if (b.length > 8000) {
        [b deleteCharactersInRange:NSMakeRange(8000, b.length - 8000)];
        [b appendString:@"\n…(truncated)"];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 12;
    request.HTTPBody = [b dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    NSString *safeTitle = title.length > 200 ? [title substringToIndex:200] : title;
    [request setValue:safeTitle forHTTPHeaderField:@"Title"];
    NSString *token = YTMUProbeTrimmedSetting(@"ntfyToken");
    if (token.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[YTMU] ntfy probe failed: %@", error.localizedDescription);
        } else {
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            if (code < 200 || code >= 300) {
                NSLog(@"[YTMU] ntfy probe HTTP %ld", (long)code);
            }
        }
    }] resume];
}

static void YTMUProbeMergeFieldsIntoCache(NSString *videoId, NSString *source, NSDictionary<NSString *, NSString *> *fields) {
    if (videoId.length == 0 || fields.count == 0) {
        return;
    }
    [YTMUProbeCacheLock() lock];
    NSMutableDictionary *entry = YTMUProbeCache()[videoId];
    if (!entry) {
        entry = [NSMutableDictionary dictionary];
        YTMUProbeCache()[videoId] = entry;
    }
    __block BOOL addedNewValue = NO;
    [fields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *obj, __unused BOOL *stop) {
        if (obj.length == 0) {
            return;
        }
        if (![entry[key] isKindOfClass:[NSString class]] || [(NSString *)entry[key] length] == 0) {
            entry[key] = obj;
            addedNewValue = YES;
        }
    }];
    if (addedNewValue && source.length > 0) {
        NSString *prev = entry[@"source"];
        if (prev.length > 0 && ![prev isEqualToString:source] && [prev rangeOfString:source].location == NSNotFound) {
            entry[@"source"] = [NSString stringWithFormat:@"%@ | %@", prev, source];
        } else if (prev.length == 0) {
            entry[@"source"] = source;
        }
    }
    entry[@"updated"] = @([[NSDate date] timeIntervalSince1970]);
    [YTMUProbeCacheLock() unlock];
}

static NSString *YTMUProbeTextFromView(id view) {
    if (!view || view == [NSNull null]) {
        return nil;
    }
    if ([view isKindOfClass:[UILabel class]]) {
        return YTMUProbeTrim([(UILabel *)view text]);
    }
    if ([view isKindOfClass:[UITextView class]]) {
        return YTMUProbeTrim([(UITextView *)view text]);
    }
    if ([view isKindOfClass:[UIButton class]]) {
        return YTMUProbeTrim([[(UIButton *)view titleLabel] text]);
    }
    if ([view respondsToSelector:@selector(attributedText)]) {
        NSAttributedString *as = [view attributedText];
        if (as.length > 0) {
            return YTMUProbeTrim(as.string);
        }
    }
    if ([view respondsToSelector:@selector(text)]) {
        id t = nil;
        @try {
            t = [view valueForKey:@"text"];
        } @catch (__unused NSException *e) {
            t = nil;
        }
        if ([t isKindOfClass:[NSString class]]) {
            return YTMUProbeTrim(t);
        }
    }
    return nil;
}

static void YTMUProbeCollectBylineCandidates(UIView *view, NSUInteger depth, NSUInteger maxDepth, NSUInteger *nodeCount, NSUInteger maxNodes, NSMutableArray<NSString *> *out) {
    if (!view || depth > maxDepth || *nodeCount >= maxNodes) {
        return;
    }
    (*nodeCount)++;
    NSString *t = YTMUProbeTextFromView(view);
    if (t.length > 6 && [t rangeOfString:@"\u2022"].location != NSNotFound) {
        NSArray *parts = [t componentsSeparatedByString:@"\u2022"];
        if (parts.count >= 2) {
            [out addObject:t];
        }
    }
    if (view.accessibilityLabel.length > 6 && [view.accessibilityLabel rangeOfString:@"\u2022"].location != NSNotFound) {
        NSString *al = YTMUProbeTrim(view.accessibilityLabel);
        if (al.length > 6) {
            [out addObject:al];
        }
    }
    if (depth >= maxDepth) {
        return;
    }
    for (UIView *sub in view.subviews) {
        YTMUProbeCollectBylineCandidates(sub, depth + 1, maxDepth, nodeCount, maxNodes, out);
    }
}

/// Returns YES if the string looks like a track duration (e.g. "3:01", "1:02:34").
static BOOL YTMUStringLooksLikeDuration(NSString *s) {
    if (s.length == 0) {
        return NO;
    }
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:0 error:&err];
    if (err) { return NO; }
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] == 1;
}

/// Web + iOS player bar: "Tea Tairovic • TEA • 2024" (bullet U+2022). Middle dot (·) normalized to bullet.
/// Skips segments that look like durations (e.g. "3:01") so they are not mistaken for an album name.
static NSDictionary<NSString *, NSString *> *YTMUProbeParseMusicByline(NSString *raw) {
    if (raw.length < 5) {
        return @{};
    }
    NSString *n = [raw stringByReplacingOccurrencesOfString:@"\u00b7" withString:@"\u2022"];
    NSArray *parts = [n componentsSeparatedByString:@"\u2022"];
    NSMutableArray<NSString *> *trimmed = [NSMutableArray array];
    for (NSString *p in parts) {
        NSString *t = YTMUProbeTrim(p);
        if (t.length > 0) {
            [trimmed addObject:t];
        }
    }
    if (trimmed.count < 2) {
        return @{};
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    // Find the year (4-digit number in range) as the last eligible segment.
    NSError *yrErr = nil;
    NSRegularExpression *yrRe = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}$" options:0 error:&yrErr];
    for (NSString *seg in [trimmed reverseObjectEnumerator]) {
        if (!yrErr && [yrRe numberOfMatchesInString:seg options:0 range:NSMakeRange(0, seg.length)] == 1) {
            NSInteger y = [seg integerValue];
            if (y >= 1900 && y <= 2100) {
                out[@"date"] = seg;
                break;
            }
        }
    }
    // Find album: second segment that is not a duration and not the artist (first segment).
    for (NSUInteger i = 1; i < trimmed.count; i++) {
        NSString *seg = trimmed[i];
        if (YTMUStringLooksLikeDuration(seg)) { continue; }
        if ([seg isEqualToString:out[@"date"]]) { continue; }
        out[@"album"] = seg;
        break;
    }
    return [out copy];
}

void YTMUMetadataProbeScanRootViewForByline(NSString *videoId, UIView *root) {
    if (videoId.length == 0 || !root) {
        return;
    }
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    NSUInteger nodes = 0;
    YTMUProbeCollectBylineCandidates(root, 0, 14, &nodes, 450, cands);
    NSString *best = nil;
    NSUInteger bestScore = 0;
    for (NSString *s in cands) {
        NSUInteger bullets = [[s componentsSeparatedByString:@"\u2022"] count];
        NSUInteger score = bullets * 100 + s.length;
        if (score > bestScore) {
            bestScore = score;
            best = s;
        }
    }
    if (best.length == 0) {
        return;
    }
    NSDictionary *parsed = YTMUProbeParseMusicByline(best);
    if (parsed.count == 0) {
        return;
    }
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    if (parsed[@"album"]) {
        fields[@"album"] = parsed[@"album"];
    }
    if (parsed[@"date"]) {
        fields[@"date"] = parsed[@"date"];
    }
    fields[@"byline"] = best;
    YTMUProbeMergeFieldsIntoCache(videoId, @"player_bar.view_scan", [fields copy]);
    NSLog(@"[YTMU] player_bar merged videoId=%@ album=%@ date=%@", videoId, parsed[@"album"] ?: @"", parsed[@"date"] ?: @"");
    static NSString *YTMULastPlayerBarNtfyKey;
    NSString *dedupe = [NSString stringWithFormat:@"%@|%@", videoId, best];
    if ([dedupe isEqualToString:YTMULastPlayerBarNtfyKey]) {
        return;
    }
    YTMULastPlayerBarNtfyKey = dedupe;
    NSString *body = [NSString stringWithFormat:@"video_id: %@\nraw_byline: %@\nalbum: %@\ndate: %@\n", videoId, best, fields[@"album"] ?: @"<none>", fields[@"date"] ?: @"<none>"];
    YTMUProbePostNtfy(@"YTMU probe: player_bar", body);
}

static NSDictionary<NSString *, NSString *> *YTMUProbeExtractFromPlayerResponse(id playerResponse) {
    if (!playerResponse) {
        return @{};
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    NSArray<NSString *> *albumPaths = @[
        @"playerData.videoDetails.musicTrack.album",
        @"playerData.videoDetails.musicTrack.albumTitle",
        @"playerData.videoDetails.musicTrack.albumName",
        @"playerData.videoDetails.musicMetadata.album",
        @"playerData.videoDetails.musicMetadata.albumName",
        @"playerData.videoDetails.musicVideoDetails.album",
        @"playerData.videoDetails.musicArtistAndTrackDetails.album",
        @"playerData.videoDetails.album",
        @"playerData.videoDetails.albumTitle",
        @"playerData.microformat.playerMicroformatRenderer.album",
        @"playerData.microformat.playerMicroformatRenderer.albumName",
    ];
    YTMUProbeMergeFromKeyPaths(playerResponse, albumPaths, out, @"album");

    NSArray<NSString *> *aaPaths = @[
        @"playerData.videoDetails.musicTrack.albumArtist",
        @"playerData.videoDetails.musicMetadata.albumArtist",
        @"playerData.videoDetails.albumArtist",
        @"playerData.videoDetails.musicArtistAndTrackDetails.albumArtist",
        @"playerData.microformat.playerMicroformatRenderer.albumArtist",
    ];
    YTMUProbeMergeFromKeyPaths(playerResponse, aaPaths, out, @"albumArtist");

    NSArray<NSString *> *genrePaths = @[
        @"playerData.videoDetails.genre",
        @"playerData.videoDetails.musicGenre",
        @"playerData.microformat.playerMicroformatRenderer.genre",
        @"playerData.microformat.playerMicroformatRenderer.category",
    ];
    YTMUProbeMergeFromKeyPaths(playerResponse, genrePaths, out, @"genre");

    NSArray<NSString *> *datePaths = @[
        @"playerData.videoDetails.releaseDate",
        @"playerData.videoDetails.publishDate",
        @"playerData.microformat.playerMicroformatRenderer.releaseDate",
        @"playerData.microformat.playerMicroformatRenderer.publishDate",
        @"playerData.microformat.playerMicroformatRenderer.uploadDate",
    ];
    YTMUProbeMergeFromKeyPaths(playerResponse, datePaths, out, @"date");

    NSArray<NSString *> *lyricsPaths = @[
        @"playerData.videoDetails.lyrics",
        @"playerData.lyrics",
        @"playerData.musicLyrics",
        @"playerData.microformat.playerMicroformatRenderer.lyrics",
    ];
    YTMUProbeMergeFromKeyPaths(playerResponse, lyricsPaths, out, @"lyrics");

    NSArray<NSString *> *copyrightPaths = @[
        @"playerData.videoDetails.musicTrack.copyright",
        @"playerData.videoDetails.musicMetadata.copyright",
    ];
    YTMUProbeMergeFromKeyPaths(playerResponse, copyrightPaths, out, @"copyright");

    id mvt = YTMUProbeKVC(playerResponse, @"playerData.videoDetails.musicVideoType");
    if (!mvt) {
        mvt = YTMUProbeKVC(playerResponse, @"playerData.videoDetails.music_video_type");
    }
    NSString *humanMvt = YTMUProbeHumanizeMusicVideoType(mvt);
    NSString *genreExisting = out[@"genre"];
    BOOL genreIsDigitsOnly = (genreExisting.length > 0 &&
                              [genreExisting rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound);
    if (genreExisting.length > 0 && !genreIsDigitsOnly) {
        // keep textual genre
    } else if (humanMvt.length > 0) {
        YTMUProbeMergeFirstString(out, @"genre", humanMvt);
    }

    id vd = YTMUProbeKVC(playerResponse, @"playerData.videoDetails");
    NSArray<NSString *> *nestedBases = @[ @"musicTrack", @"musicMetadata", @"musicVideoDetails", @"musicArtistAndTrackDetails" ];
    NSArray<NSString *> *albumLeaves = @[ @"album", @"albumTitle", @"albumName", @"musicAlbumTitle", @"musicAlbumName" ];
    NSArray<NSString *> *aaLeaves = @[ @"albumArtist", @"artistName" ];
    for (NSString *base in nestedBases) {
        id node = nil;
        @try {
            node = [vd valueForKey:base];
        } @catch (__unused NSException *e) {
            node = nil;
        }
        YTMUProbeMergeFromLeafKeys(node, albumLeaves, out, @"album");
        YTMUProbeMergeFromLeafKeys(node, aaLeaves, out, @"albumArtist");
    }

    id microRoot = YTMUProbeKVC(playerResponse, @"playerData.microformat.playerMicroformatRenderer");
    YTMUProbeMergeFromLeafKeys(microRoot, albumLeaves, out, @"album");
    YTMUProbeMergeFromLeafKeys(microRoot, aaLeaves, out, @"albumArtist");

    return [out copy];
}

static NSString *YTMUProbeBodyForHook(NSString *hook, NSString *videoId, id playerResponse, NSString *extra) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"hook: %@", hook ?: @"?"]];
    [lines addObject:[NSString stringWithFormat:@"video_id: %@", videoId.length ? videoId : @"<none>"]];
    if (playerResponse) {
        NSDictionary *ex = YTMUProbeExtractFromPlayerResponse(playerResponse);
        [lines addObject:[NSString stringWithFormat:@"cache_extract_album: %@", ex[@"album"] ?: @"<none>"]];
        [lines addObject:[NSString stringWithFormat:@"cache_extract_album_artist: %@", ex[@"albumArtist"] ?: @"<none>"]];
        [lines addObject:[NSString stringWithFormat:@"cache_extract_genre: %@", ex[@"genre"] ?: @"<none>"]];
        [lines addObject:[NSString stringWithFormat:@"cache_extract_date: %@", ex[@"date"] ?: @"<none>"]];
        NSString *title = YTMUProbeStringAtKeyPath(playerResponse, @"playerData.videoDetails.title");
        NSString *author = YTMUProbeStringAtKeyPath(playerResponse, @"playerData.videoDetails.author");
        [lines addObject:[NSString stringWithFormat:@"player_title: %@", title ?: @"<none>"]];
        [lines addObject:[NSString stringWithFormat:@"player_author: %@", author ?: @"<none>"]];
    } else {
        [lines addObject:@"playerResponse: <none>"];
    }
    if (extra.length > 0) {
        [lines addObject:@""];
        [lines addObject:@"extra:"];
        [lines addObject:extra];
    }
    [YTMUProbeCacheLock() lock];
    NSUInteger n = YTMUProbeCache().count;
    [YTMUProbeCacheLock() unlock];
    [lines addObject:[NSString stringWithFormat:@"probe_cache_entries: %lu", (unsigned long)n]];
    return [lines componentsJoinedByString:@"\n"];
}

void YTMUMetadataProbeOnTrackActivated(NSString *videoId, id playerResponse, NSString *source) {
    NSString *hook = source ?: @"track";
    NSDictionary *fields = YTMUProbeExtractFromPlayerResponse(playerResponse);
    YTMUProbeMergeFieldsIntoCache(videoId, source, fields);
    NSString *body = YTMUProbeBodyForHook(hook, videoId, playerResponse, nil);
    NSLog(@"[YTMU] probe %@\n%@", hook, body);
    YTMUProbePostNtfy([NSString stringWithFormat:@"YTMU probe: %@", hook], body);
    // The iOS playerResponse never carries album/year. Fire a WEB_REMIX next-API
    // call to fetch the full byline and merge album + year into the cache.
    YTMUFetchAlbumMetadataForVideoId(videoId);
}

// Forward declarations — these functions are defined later in the file (queue probe section).
static NSString *YTMUQueueScalar(id value);
static void YTMUQueueWalkObject(id obj, NSString *prefix, NSUInteger depth,
                                NSMutableArray<NSString *> *lines, NSMutableSet<NSString *> *seen);

/// Appends a runtime-walk section onto `lines` for `obj` under the given label.
static void YTMUProbeAppendVCWalk(id obj, NSString *label, NSMutableArray<NSString *> *lines) {
    if (!obj) {
        [lines addObject:[NSString stringWithFormat:@"%@: <nil>", label]];
        return;
    }
    [lines addObject:@""];
    [lines addObject:[NSString stringWithFormat:@"--- %@ (%@) ---", label, NSStringFromClass([obj class])]];
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger before = lines.count;
    YTMUQueueWalkObject(obj, label, 4, lines, seen);
    if (lines.count == before) {
        [lines addObject:@"(no interesting properties found)"];
    }
}

/// Unwraps a YTIFormattedString into a plain NSString.
/// YTIFormattedString is a GPBMessage with a repeated `runsArray` field; each run has a `text` property.
/// Some simpler instances use `simpleText` directly.
static NSString *YTMUFormattedStringToPlainText(id formattedString) {
    if (!formattedString || formattedString == [NSNull null]) {
        return nil;
    }
    // Simplest case: proto uses simpleText instead of runs.
    id simpleText = nil;
    @try { simpleText = [formattedString valueForKey:@"simpleText"]; } @catch (__unused NSException *e) {}
    if ([simpleText isKindOfClass:[NSString class]] && [(NSString *)simpleText length] > 0) {
        return YTMUProbeTrim(simpleText);
    }
    // GPBMessage repeated fields use the `fieldNameArray` convention (e.g. runsArray).
    // Try both `runsArray` and `runs` for safety.
    id runsArray = nil;
    for (NSString *key in @[@"runsArray", @"runs"]) {
        @try { runsArray = [formattedString valueForKey:key]; } @catch (__unused NSException *e) { runsArray = nil; }
        if ([runsArray isKindOfClass:[NSArray class]] && [(NSArray *)runsArray count] > 0) {
            break;
        }
        runsArray = nil;
    }
    if ([runsArray isKindOfClass:[NSArray class]]) {
        NSMutableString *out = [NSMutableString string];
        for (id run in (NSArray *)runsArray) {
            id text = nil;
            @try { text = [run valueForKey:@"text"]; } @catch (__unused NSException *e) {}
            if ([text isKindOfClass:[NSString class]] && [(NSString *)text length] > 0) {
                [out appendString:(NSString *)text];
            }
        }
        NSString *t = YTMUProbeTrim(out);
        if (t.length > 0) {
            return t;
        }
    }
    return nil;
}

/// Dumps ALL ObjC properties of `obj` (unconstrained by term filter) up to `maxLines`.
/// Values that look like protobuf debug dumps or nil are skipped.
/// Returns a flat array of "prefix.key -> value" strings.
static NSArray<NSString *> *YTMUDumpAllProperties(id obj, NSString *prefix, NSUInteger depth,
                                                   NSMutableSet<NSString *> *seen, NSUInteger maxLines) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (!obj || depth == 0 || lines.count >= maxLines) {
        return lines;
    }
    NSString *ptr = [NSString stringWithFormat:@"%p", (void *)obj];
    if ([seen containsObject:ptr]) {
        return lines;
    }
    [seen addObject:ptr];

    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    Class cls = [obj class];
    while (cls && cls != [NSObject class]) {
        unsigned int n = 0;
        objc_property_t *props = class_copyPropertyList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
            if (name.length > 0 &&
                ![name isEqualToString:@"description"] &&
                ![name isEqualToString:@"debugDescription"]) {
                [keys addObject:name];
            }
        }
        free(props);
        cls = class_getSuperclass(cls);
    }

    for (NSString *key in keys) {
        if (lines.count >= maxLines) { break; }
        id val = nil;
        @try { val = [obj valueForKey:key]; } @catch (__unused NSException *e) { continue; }
        if (!val || val == [NSNull null]) { continue; }

        NSString *scalar = YTMUQueueScalar(val);
        if (scalar.length > 0) {
            [lines addObject:[NSString stringWithFormat:@"%@.%@ -> %@", prefix, key, scalar]];
            continue;
        }
        // For non-scalar objects, log the class name and optionally recurse one level.
        NSString *className = NSStringFromClass([val class]);
        [lines addObject:[NSString stringWithFormat:@"%@.%@ = <%@>", prefix, key, className]];
        if (depth > 1 && ![val isKindOfClass:[NSArray class]]) {
            NSArray<NSString *> *sub = YTMUDumpAllProperties(val, [NSString stringWithFormat:@"%@.%@", prefix, key],
                                                               depth - 1, seen, maxLines - lines.count);
            [lines addObjectsFromArray:sub];
        }
        if ([val isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)val;
            for (NSUInteger i = 0; i < MIN(arr.count, 2) && lines.count < maxLines; i++) {
                NSString *scalar2 = YTMUQueueScalar(arr[i]);
                if (scalar2.length > 0) {
                    [lines addObject:[NSString stringWithFormat:@"%@.%@[%lu] -> %@", prefix, key, (unsigned long)i, scalar2]];
                } else {
                    [lines addObject:[NSString stringWithFormat:@"%@.%@[%lu] = <%@>", prefix, key, (unsigned long)i, NSStringFromClass([arr[i] class])]];
                }
            }
        }
    }
    return lines;
}

/// Reads the now-playing queue item renderer from WatchVC and extracts album / date from its byline.
/// Path: watchVC.queueController.nowPlayingMusicQueueItem.videoRenderer
static NSDictionary<NSString *, NSString *> *YTMUProbeExtractFromQueueRenderer(id watchVC) {
    if (!watchVC) {
        return @{};
    }
    id queueController = YTMUProbeKVC(watchVC, @"queueController");
    if (!queueController) {
        return @{};
    }
    id queueItem = YTMUProbeKVC(queueController, @"nowPlayingMusicQueueItem");
    if (!queueItem) {
        return @{};
    }
    id renderer = YTMUProbeKVC(queueItem, @"videoRenderer");
    if (!renderer) {
        return @{};
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // longBylineText is a YTIFormattedString — "Artist • Album • Year"
    id longByline = YTMUProbeKVC(renderer, @"longBylineText");
    NSString *longBylineStr = YTMUFormattedStringToPlainText(longByline);
    if (longBylineStr.length > 0) {
        out[@"longBylineText"] = longBylineStr;
        NSDictionary *parsed = YTMUProbeParseMusicByline(longBylineStr);
        if (parsed[@"album"]) { out[@"album"] = parsed[@"album"]; }
        if (parsed[@"date"])  { out[@"date"]  = parsed[@"date"];  }
    }

    // shortBylineText is usually just the artist name — useful for cross-check.
    id shortByline = YTMUProbeKVC(renderer, @"shortBylineText");
    NSString *shortBylineStr = YTMUFormattedStringToPlainText(shortByline);
    if (shortBylineStr.length > 0) {
        out[@"shortBylineText"] = shortBylineStr;
    }

    // musicAttributes may carry structured album / releaseYear fields (supplement to byline parse).
    id musicAttrs = YTMUProbeKVC(renderer, @"musicAttributes");
    if (musicAttrs) {
        out[@"musicAttributesClass"] = NSStringFromClass([musicAttrs class]);
        for (NSString *leaf in @[@"album", @"albumTitle", @"albumName", @"musicAlbumTitle"]) {
            NSString *s = YTMUProbeStringAtKeyPath(musicAttrs, leaf);
            if (!s.length) { s = YTMUFormattedStringToPlainText(YTMUProbeKVC(musicAttrs, leaf)); }
            if (s.length > 0 && !out[@"album"]) { out[@"album"] = s; break; }
        }
        for (NSString *leaf in @[@"releaseYear", @"year", @"releaseDate", @"publishDate"]) {
            NSString *s = YTMUProbeStringAtKeyPath(musicAttrs, leaf);
            if (!s.length) { s = YTMUFormattedStringToPlainText(YTMUProbeKVC(musicAttrs, leaf)); }
            if (s.length > 0 && !out[@"date"]) { out[@"date"] = s; break; }
        }
        // Full property dump of musicAttributes — unconstrained so we see every field name.
        NSMutableSet *attrSeen = [NSMutableSet set];
        NSArray<NSString *> *attrLines = YTMUDumpAllProperties(musicAttrs, @"musicAttrs", 2, attrSeen, 50);
        if (attrLines.count > 0) {
            out[@"musicAttributesWalk"] = [attrLines componentsJoinedByString:@"\n"];
        }
    }

    // Full property dump of the queue item itself (not just videoRenderer).
    NSMutableSet *qiSeen = [NSMutableSet set];
    NSArray<NSString *> *qiLines = YTMUDumpAllProperties(queueItem, @"queueItem", 2, qiSeen, 60);
    if (qiLines.count > 0) {
        out[@"queueItemClass"] = NSStringFromClass([queueItem class]);
        out[@"queueItemDump"] = [qiLines componentsJoinedByString:@"\n"];
    }

    // title for cross-check — also a YTIFormattedString.
    id title = YTMUProbeKVC(renderer, @"title");
    NSString *titleStr = YTMUFormattedStringToPlainText(title);
    if (!titleStr.length) { titleStr = YTMUProbeCoerceToString(title); }
    if (titleStr.length > 0) { out[@"title"] = titleStr; }

    return [out copy];
}

/// Returns the videoId from the now-playing queue item navigation endpoint.
static NSString *YTMUProbeVideoIdFromQueueItem(id watchVC) {
    id queueController = YTMUProbeKVC(watchVC, @"queueController");
    id queueItem = YTMUProbeKVC(queueController, @"nowPlayingMusicQueueItem");
    id renderer = YTMUProbeKVC(queueItem, @"videoRenderer");
    // videoId lives on the queue navigation endpoint's watch endpoint.
    NSArray<NSString *> *vidPaths = @[
        @"queueNavigationEndpoint.watchEndpoint.videoId",
        @"queueNavigationEndpoint.videoId",
        @"videoId",
    ];
    for (NSString *p in vidPaths) {
        NSString *s = YTMUProbeStringAtKeyPath(renderer, p);
        if (s.length > 0) { return s; }
    }
    return nil;
}

void YTMUMetadataProbeOnWatchViewController(id watchVC) {
    Class wClass = NSClassFromString(@"YTMWatchViewController");
    if (!wClass || ![watchVC isKindOfClass:wClass]) {
        return;
    }
    id pvc = [watchVC valueForKey:@"playerViewController"];
    NSString *vid = YTMUProbeStringFromValue([pvc valueForKey:@"contentVideoID"]);
    // Fallback: try to get videoId from the queue item renderer.
    if (vid.length == 0) {
        vid = YTMUProbeVideoIdFromQueueItem(watchVC);
    }
    id pr = [pvc valueForKey:@"playerResponse"];
    NSString *hook = @"YTMWatchViewController.viewDidAppear";

    // Extract from playerResponse (usually misses album/date).
    NSDictionary *prFields = YTMUProbeExtractFromPlayerResponse(pr);
    YTMUProbeMergeFieldsIntoCache(vid, hook, prFields);

    // Extract album/date from the queue renderer — this is where it actually lives.
    NSDictionary *queueFields = YTMUProbeExtractFromQueueRenderer(watchVC);
    NSMutableDictionary *mergeFields = [NSMutableDictionary dictionary];
    if (queueFields[@"album"]) { mergeFields[@"album"] = queueFields[@"album"]; }
    if (queueFields[@"date"])  { mergeFields[@"date"]  = queueFields[@"date"];  }
    YTMUProbeMergeFieldsIntoCache(vid, @"queueRenderer", mergeFields);

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"hook: %@", hook]];
    [lines addObject:[NSString stringWithFormat:@"video_id: %@", vid.length ? vid : @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"queue_longBylineText: %@", queueFields[@"longBylineText"] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"queue_shortBylineText: %@", queueFields[@"shortBylineText"] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"queue_title: %@", queueFields[@"title"] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"queue_album: %@", queueFields[@"album"] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"queue_date: %@", queueFields[@"date"] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"musicAttributesClass: %@", queueFields[@"musicAttributesClass"] ?: @"<nil>"]];
    if ([(NSString *)queueFields[@"musicAttributesWalk"] length] > 0) {
        [lines addObject:@""];
        [lines addObject:@"--- musicAttributes dump (YTIVideoMusicAttributes) ---"];
        [lines addObject:queueFields[@"musicAttributesWalk"]];
    }
    if ([(NSString *)queueFields[@"queueItemDump"] length] > 0) {
        [lines addObject:@""];
        [lines addObject:[NSString stringWithFormat:@"--- queueItem dump (%@) ---", queueFields[@"queueItemClass"] ?: @"?"]];
        [lines addObject:queueFields[@"queueItemDump"]];
    }
    [lines addObject:[NSString stringWithFormat:@"pr_album: %@", prFields[@"album"] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"pr_date: %@", prFields[@"date"] ?: @"<none>"]];

    NSString *body = [lines componentsJoinedByString:@"\n"];
    NSLog(@"[YTMU] probe %@\n%@", hook, body);
    YTMUProbePostNtfy([NSString stringWithFormat:@"YTMU probe: %@", hook], body);
}

void YTMUMetadataProbeOnNowPlayingViewController(id playingVC) {
    Class npClass = NSClassFromString(@"YTMNowPlayingViewController");
    if (!npClass || ![playingVC isKindOfClass:npClass]) {
        return;
    }
    // Walk the NowPlayingVC itself — it may hold a track/item model with album/year.
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:@"hook: YTMNowPlayingViewController.viewDidAppear"];

    UIViewController *parent = [playingVC valueForKey:@"parentViewController"];
    Class wClass = NSClassFromString(@"YTMWatchViewController");
    NSString *vid = nil;
    id pr = nil;
    if (wClass && [parent isKindOfClass:wClass]) {
        id pvc = [parent valueForKey:@"playerViewController"];
        vid = YTMUProbeStringFromValue([pvc valueForKey:@"contentVideoID"]);
        pr = [pvc valueForKey:@"playerResponse"];
        NSDictionary *fields = YTMUProbeExtractFromPlayerResponse(pr);
        YTMUProbeMergeFieldsIntoCache(vid, @"YTMNowPlayingViewController.viewDidAppear", fields);
    }
    [lines addObject:[NSString stringWithFormat:@"video_id: %@", vid.length ? vid : @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"parent_class: %@", parent ? NSStringFromClass([parent class]) : @"nil"]];

    // Deep walk of NowPlayingVC itself.
    YTMUProbeAppendVCWalk(playingVC, @"nowPlayingVC", lines);

    NSString *body = [lines componentsJoinedByString:@"\n"];
    if (body.length > 8000) {
        body = [[body substringToIndex:8000] stringByAppendingString:@"\n…(truncated)"];
    }
    NSLog(@"[YTMU] probe YTMNowPlayingViewController.viewDidAppear\n%@", body);
    YTMUProbePostNtfy(@"YTMU probe: YTMNowPlayingViewController.viewDidAppear", body);
}

void YTMUMetadataProbeMergeIntoDownloader(FFMpegDownloader *ffmpeg, NSString *videoId) {
    if (!ffmpeg || videoId.length == 0) {
        return;
    }
    [YTMUProbeCacheLock() lock];
    NSDictionary *entry = [YTMUProbeCache()[videoId] copy];
    [YTMUProbeCacheLock() unlock];
    if (!entry) {
        return;
    }
    NSString *(^trim)(id) = ^NSString *(id v) {
        return [v isKindOfClass:[NSString class]] ? YTMUProbeTrim(v) : nil;
    };
    if (ffmpeg.album.length == 0) {
        NSString *s = trim(entry[@"album"]);
        if (s.length) {
            ffmpeg.album = s;
        }
    }
    if (ffmpeg.albumArtist.length == 0) {
        NSString *s = trim(entry[@"albumArtist"]);
        if (s.length) {
            ffmpeg.albumArtist = s;
        }
    }
    if (ffmpeg.genre.length == 0) {
        NSString *s = trim(entry[@"genre"]);
        if (s.length) {
            ffmpeg.genre = s;
        }
    }
    if (ffmpeg.date.length == 0) {
        NSString *s = trim(entry[@"date"]);
        if (s.length) {
            ffmpeg.date = s;
        }
    }
    if (ffmpeg.lyrics.length == 0) {
        NSString *s = trim(entry[@"lyrics"]);
        if (s.length) {
            ffmpeg.lyrics = s;
        }
    }
}

NSString *YTMUMetadataProbeDiscoveryAppendixForVideoId(NSString *videoId) {
    if (videoId.length == 0) {
        return @"";
    }
    [YTMUProbeCacheLock() lock];
    NSDictionary *entry = [YTMUProbeCache()[videoId] copy];
    [YTMUProbeCacheLock() unlock];
    if (!entry.count) {
        return @"";
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:@"--- probe_cache (hooks / KVC extract) ---"];
    [lines addObject:[NSString stringWithFormat:@"video_id: %@", videoId]];
    NSArray<NSString *> *keys = @[ @"album", @"albumArtist", @"genre", @"date", @"lyrics", @"comment", @"copyright", @"byline" ];
    for (NSString *k in keys) {
        id v = entry[k];
        NSString *s = [v isKindOfClass:[NSString class]] ? YTMUProbeTrim(v) : nil;
        if (s.length > 0) {
            [lines addObject:[NSString stringWithFormat:@"%@: %@", k, s]];
        }
    }
    NSString *src = [entry[@"source"] isKindOfClass:[NSString class]] ? YTMUProbeTrim(entry[@"source"]) : nil;
    if (src.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"source: %@", src]];
    }
    NSNumber *ts = entry[@"updated"];
    if ([ts respondsToSelector:@selector(doubleValue)]) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:[ts doubleValue]];
        [lines addObject:[NSString stringWithFormat:@"cache_updated: %@", d]];
    }
    NSString *out = [lines componentsJoinedByString:@"\n"];
    if (out.length > 12000) {
        return [[out substringToIndex:12000] stringByAppendingString:@"\n…(truncated)"];
    }
    return out;
}

// ---------------------------------------------------------------------------
// MARK: - YTMUMetadataProbeOnVideoActivated  (queue-item runtime discovery)
// ---------------------------------------------------------------------------

static BOOL YTMUQueueTermLooksInteresting(NSString *key) {
    if (key.length == 0) {
        return NO;
    }
    if ([key isEqualToString:@"description"] || [key isEqualToString:@"debugDescription"]) {
        return NO;
    }
    NSString *low = key.lowercaseString;
    NSArray<NSString *> *terms = @[
        @"album", @"genre", @"date", @"year", @"lyric", @"subtitle",
        @"byline", @"music", @"track", @"metadata", @"release",
        @"renderer", @"column", @"flex", @"row", @"item", @"queue",
        @"title", @"artist", @"author", @"composer", @"copyright"
    ];
    for (NSString *t in terms) {
        if ([low containsString:t]) {
            return YES;
        }
    }
    return NO;
}

/// Returns a short readable string for a value, or nil if unrepresentable / noise.
static NSString *YTMUQueueScalar(id value) {
    if (!value || value == [NSNull null]) {
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0) {
            return nil;
        }
        // Skip NSObject -description dumps (protobuf noise).
        if ([s hasPrefix:@"<YT"] && [s rangeOfString:@">: {"].location != NSNotFound) {
            return nil;
        }
        if ([s rangeOfString:@"response_context {"].location != NSNotFound) {
            return nil;
        }
        return s.length > 300 ? [[s substringToIndex:300] stringByAppendingString:@"…"] : s;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    if ([value isKindOfClass:[NSDate class]]) {
        return [(NSDate *)value description];
    }
    // Try common YT formatted-string shapes.
    for (NSString *nk in @[@"simpleText", @"text", @"runs", @"content", @"label"]) {
        id inner = nil;
        @try { inner = [value valueForKey:nk]; } @catch (__unused NSException *e) {}
        if ([inner isKindOfClass:[NSString class]]) {
            return YTMUQueueScalar(inner);
        }
        if ([inner isKindOfClass:[NSArray class]]) {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (id el in (NSArray *)inner) {
                NSString *ps = YTMUQueueScalar(el);
                if (ps.length > 0) { [parts addObject:ps]; }
            }
            if (parts.count > 0) {
                return [parts componentsJoinedByString:@" "];
            }
        }
    }
    return nil;
}

static void YTMUQueueWalkObject(id obj, NSString *prefix, NSUInteger depth,
                                 NSMutableArray<NSString *> *lines, NSMutableSet<NSString *> *seen) {
    if (!obj || depth == 0 || lines.count >= 80) {
        return;
    }
    NSString *ptr = [NSString stringWithFormat:@"%p", (void *)obj];
    if ([seen containsObject:ptr]) {
        return;
    }
    [seen addObject:ptr];

    // Collect interesting property and ivar names from the class hierarchy.
    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    Class cls = [obj class];
    while (cls && cls != [NSObject class]) {
        unsigned int n = 0;
        objc_property_t *props = class_copyPropertyList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
            if (YTMUQueueTermLooksInteresting(name)) {
                [keys addObject:name];
            }
        }
        free(props);
        unsigned int iv = 0;
        Ivar *ivars = class_copyIvarList(cls, &iv);
        for (unsigned int i = 0; i < iv; i++) {
            const char *raw = ivar_getName(ivars[i]);
            if (!raw) { continue; }
            NSString *name = [NSString stringWithUTF8String:raw];
            // Strip leading underscore for KVC access.
            if ([name hasPrefix:@"_"]) {
                name = [name substringFromIndex:1];
            }
            if (YTMUQueueTermLooksInteresting(name)) {
                [keys addObject:name];
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }

    for (NSString *key in keys) {
        if (lines.count >= 80) { break; }
        id val = nil;
        @try { val = [obj valueForKey:key]; } @catch (__unused NSException *e) { continue; }
        if (!val || val == [NSNull null]) { continue; }

        NSString *scalar = YTMUQueueScalar(val);
        if (scalar.length > 0) {
            [lines addObject:[NSString stringWithFormat:@"%@.%@ -> %@", prefix, key, scalar]];
            continue;
        }
        // Array: walk first 2 elements.
        if ([val isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)val;
            for (NSUInteger i = 0; i < MIN(arr.count, 2); i++) {
                YTMUQueueWalkObject(arr[i],
                                    [NSString stringWithFormat:@"%@.%@[%lu]", prefix, key, (unsigned long)i],
                                    depth - 1, lines, seen);
            }
            continue;
        }
        // Recurse into object.
        YTMUQueueWalkObject(val, [NSString stringWithFormat:@"%@.%@", prefix, key], depth - 1, lines, seen);
    }
}

void YTMUMetadataProbeOnVideoActivated(id playerVC, id video, id playbackData) {
    if (!playerVC) {
        return;
    }
    NSString *vid = nil;
    @try { vid = [playerVC valueForKey:@"contentVideoID"]; } @catch (__unused NSException *e) {}
    if (![vid isKindOfClass:[NSString class]] || vid.length == 0) {
        vid = @"<unknown>";
    }

    NSString *videoClass    = video       ? NSStringFromClass([video class])       : @"<nil>";
    NSString *dataClass     = playbackData ? NSStringFromClass([playbackData class]) : @"<nil>";
    NSString *playerVCClass = NSStringFromClass([playerVC class]);

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"hook: didActivateVideo (queue probe)"]];
    [lines addObject:[NSString stringWithFormat:@"video_id: %@", vid]];
    [lines addObject:[NSString stringWithFormat:@"playerVC_class: %@", playerVCClass]];
    [lines addObject:[NSString stringWithFormat:@"video_class: %@", videoClass]];
    [lines addObject:[NSString stringWithFormat:@"data_class: %@", dataClass]];

    // --- Walk the `video` arg ---
    if (video) {
        [lines addObject:@""];
        [lines addObject:@"--- video arg ---"];
        NSMutableSet *seen = [NSMutableSet set];
        YTMUQueueWalkObject(video, @"video", 4, lines, seen);
        if (lines.lastObject && [lines.lastObject isEqualToString:@"--- video arg ---"]) {
            [lines addObject:@"(no interesting properties found)"];
        }
    }

    // --- Walk the `playbackData` arg ---
    if (playbackData) {
        [lines addObject:@""];
        [lines addObject:@"--- playbackData arg ---"];
        NSMutableSet *seen = [NSMutableSet set];
        YTMUQueueWalkObject(playbackData, @"data", 4, lines, seen);
        if (lines.lastObject && [lines.lastObject isEqualToString:@"--- playbackData arg ---"]) {
            [lines addObject:@"(no interesting properties found)"];
        }
    }

    // --- Key paths on playerVC: queue / current item candidates ---
    [lines addObject:@""];
    [lines addObject:@"--- playerVC queue key paths ---"];
    NSArray<NSString *> *vcPaths = @[
        @"currentQueueItem", @"queueItem", @"currentItem", @"mediaItem",
        @"musicItem", @"videoData", @"currentVideoData", @"videoInfo",
        @"playbackQueue", @"queue", @"currentQueueVideo",
        @"currentlyPlayingVideo", @"activeVideoData",
        @"playerData", @"currentVideoMetadata",
    ];
    NSMutableSet *vcSeen = [NSMutableSet set];
    BOOL foundAny = NO;
    for (NSString *kp in vcPaths) {
        id val = nil;
        @try { val = [playerVC valueForKey:kp]; } @catch (__unused NSException *e) { continue; }
        if (!val || val == [NSNull null]) { continue; }
        foundAny = YES;
        NSString *scalar = YTMUQueueScalar(val);
        if (scalar.length > 0) {
            [lines addObject:[NSString stringWithFormat:@"playerVC.%@ -> %@", kp, scalar]];
        } else {
            [lines addObject:[NSString stringWithFormat:@"playerVC.%@ = <%@>", kp, NSStringFromClass([val class])]];
            YTMUQueueWalkObject(val, [NSString stringWithFormat:@"playerVC.%@", kp], 3, lines, vcSeen);
        }
    }
    if (!foundAny) {
        [lines addObject:@"(all nil)"];
    }

    NSString *body = [lines componentsJoinedByString:@"\n"];
    if (body.length > 8000) {
        body = [[body substringToIndex:8000] stringByAppendingString:@"\n…(truncated)"];
    }
    NSLog(@"[YTMU] queue probe video_id=%@\n%@", vid, body);
    YTMUProbePostNtfy(@"YTMU probe: queue-item", body);
}

// ---------------------------------------------------------------------------
// MARK: - YTMUFetchAlbumMetadataForVideoId  (WEB_REMIX next-API lookup)
// ---------------------------------------------------------------------------

/// Recursively searches a deserialized JSON tree for a playlistPanelVideoRenderer whose
/// "videoId" matches `target`, then returns the concatenated runs text from "longBylineText".
static NSString *YTMUFindBylineInJSON(id json, NSString *target) {
    if (!json || target.length == 0) {
        return nil;
    }
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)json;
        id vid = dict[@"videoId"];
        if ([vid isKindOfClass:[NSString class]] && [vid isEqualToString:target]) {
            // Found the renderer for our track. Extract longBylineText runs.
            id longByline = dict[@"longBylineText"];
            if ([longByline isKindOfClass:[NSDictionary class]]) {
                id runs = longByline[@"runs"];
                if ([runs isKindOfClass:[NSArray class]]) {
                    NSMutableString *text = [NSMutableString string];
                    for (id run in (NSArray *)runs) {
                        if ([run isKindOfClass:[NSDictionary class]]) {
                            id t = run[@"text"];
                            if ([t isKindOfClass:[NSString class]]) {
                                [text appendString:(NSString *)t];
                            }
                        }
                    }
                    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmed.length > 0) {
                        return trimmed;
                    }
                }
            }
        }
        // Recurse into all values.
        for (id value in dict.allValues) {
            NSString *found = YTMUFindBylineInJSON(value, target);
            if (found) {
                return found;
            }
        }
    } else if ([json isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)json) {
            NSString *found = YTMUFindBylineInJSON(item, target);
            if (found) {
                return found;
            }
        }
    }
    return nil;
}

/// Deduplication: skip a fetch if one is already in-flight for this videoId.
static NSMutableSet<NSString *> *YTMUInFlightVideoIds(void) {
    static NSMutableSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}

void YTMUFetchAlbumMetadataForVideoId(NSString *videoId) {
    if (videoId.length == 0) {
        return;
    }
    // Skip if we already have album in cache for this videoId.
    [YTMUProbeCacheLock() lock];
    NSString *cached = YTMUProbeCache()[videoId][@"album"];
    [YTMUProbeCacheLock() unlock];
    if (cached.length > 0) {
        return;
    }
    // Dedup concurrent fetches for the same video.
    @synchronized (YTMUInFlightVideoIds()) {
        if ([YTMUInFlightVideoIds() containsObject:videoId]) {
            return;
        }
        [YTMUInFlightVideoIds() addObject:videoId];
    }

    NSURL *url = [NSURL URLWithString:@"https://music.youtube.com/youtubei/v1/next?prettyPrint=false"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://music.youtube.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://music.youtube.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];

    NSDictionary *body = @{
        @"context": @{
            @"client": @{
                @"clientName": @"WEB_REMIX",
                @"clientVersion": @"1.20241101.01.00",
                @"hl": @"en",
                @"gl": @"US"
            }
        },
        @"videoId": videoId,
        @"isAudioOnly": @YES
    };
    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (!bodyData || jsonErr) {
        @synchronized (YTMUInFlightVideoIds()) { [YTMUInFlightVideoIds() removeObject:videoId]; }
        return;
    }
    request.HTTPBody = bodyData;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        @synchronized (YTMUInFlightVideoIds()) { [YTMUInFlightVideoIds() removeObject:videoId]; }

        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (error || !data || statusCode < 200 || statusCode >= 300) {
            NSLog(@"[YTMU] nextAPI fetch failed for %@: HTTP %ld %@", videoId, (long)statusCode, error.localizedDescription ?: @"");
            YTMUProbePostNtfy(@"YTMU probe: nextAPI error",
                              [NSString stringWithFormat:@"video_id: %@\nstatus: %ld\nerror: %@",
                               videoId, (long)statusCode, error.localizedDescription ?: @"<none>"]);
            return;
        }

        NSError *parseErr = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr || !json) {
            NSLog(@"[YTMU] nextAPI JSON parse failed for %@: %@", videoId, parseErr.localizedDescription);
            return;
        }

        NSString *byline = YTMUFindBylineInJSON(json, videoId);
        if (byline.length == 0) {
            NSLog(@"[YTMU] nextAPI: no byline found for videoId=%@", videoId);
            YTMUProbePostNtfy(@"YTMU probe: nextAPI no-byline",
                              [NSString stringWithFormat:@"video_id: %@\nstatus: %ld\nnote: renderer found but longBylineText missing or empty", videoId, (long)statusCode]);
            return;
        }

        NSDictionary *parsed = YTMUProbeParseMusicByline(byline);
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        if (parsed[@"album"]) { fields[@"album"] = parsed[@"album"]; }
        if (parsed[@"date"])  { fields[@"date"]  = parsed[@"date"];  }

        if (fields.count > 0) {
            YTMUProbeMergeFieldsIntoCache(videoId, @"nextAPI", fields);
        }

        NSLog(@"[YTMU] nextAPI: videoId=%@ byline=%@ album=%@ date=%@",
              videoId, byline, parsed[@"album"] ?: @"", parsed[@"date"] ?: @"");
        YTMUProbePostNtfy(@"YTMU probe: nextAPI",
                          [NSString stringWithFormat:@"video_id: %@\nbyline: %@\nalbum: %@\ndate: %@",
                           videoId, byline,
                           parsed[@"album"] ?: @"<none>",
                           parsed[@"date"]  ?: @"<none>"]);
    }] resume];
}
