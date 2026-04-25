#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "FFMpegDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"
#import "Headers/ServerLibraryChecker.h"
#import "Headers/YTPlayerViewController.h"
#import "YTMUMetadataProbe.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

static id YTMUSafeValueForKeyPath(id object, NSString *keyPath) {
    if (!object || keyPath.length == 0) return nil;

    @try {
        return [object valueForKeyPath:keyPath];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// `valueForKey:@"description"` on YT protobuf objects returns -[NSObject description] (protobuf dump), not a description field.
static BOOL YTMUStringLooksLikeProtobufDebugDump(NSString *s) {
    if (s.length < 24) {
        return NO;
    }
    if ([s hasPrefix:@"<YT"] && [s rangeOfString:@">: {"].location != NSNotFound) {
        return YES;
    }
    if ([s hasPrefix:@"<YTI"] && [s rangeOfString:@">: {"].location != NSNotFound) {
        return YES;
    }
    if ([s rangeOfString:@"video_id:"].location != NSNotFound && [s rangeOfString:@"length_seconds:"].location != NSNotFound) {
        return YES;
    }
    if ([s rangeOfString:@"response_context {"].location != NSNotFound) {
        return YES;
    }
    return NO;
}

static NSString *YTMUMetadataStringFromValue(id value) {
    if (!value || value == [NSNull null]) return nil;

    if ([value isKindOfClass:[NSString class]]) {
        NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            return nil;
        }
        if (YTMUStringLooksLikeProtobufDebugDump(trimmed)) {
            return nil;
        }
        return trimmed;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            NSString *itemString = YTMUMetadataStringFromValue(item);
            if (itemString.length > 0) {
                [parts addObject:itemString];
            }
        }

        if (parts.count == 0) return nil;
        return [parts componentsJoinedByString:@" "];
    }

    id simpleText = YTMUSafeValueForKeyPath(value, @"simpleText");
    NSString *simpleTextString = YTMUMetadataStringFromValue(simpleText);
    if (simpleTextString.length > 0) return simpleTextString;

    id text = YTMUSafeValueForKeyPath(value, @"text");
    NSString *textString = YTMUMetadataStringFromValue(text);
    if (textString.length > 0) return textString;

    id runs = YTMUSafeValueForKeyPath(value, @"runs");
    NSString *runsString = YTMUMetadataStringFromValue(runs);
    if (runsString.length > 0) return runsString;

    return nil;
}

/// NSObject KVC traps: `description`, `debugDescription`, and often `longDescription` map to NSObject methods, not proto text.
static BOOL YTMUKeyPathIsForbiddenForKVCMetadata(NSString *keyPath) {
    if (keyPath.length == 0) {
        return YES;
    }
    if ([keyPath hasSuffix:@".description"]) {
        return YES;
    }
    if ([keyPath hasSuffix:@".debugDescription"]) {
        return YES;
    }
    if ([keyPath hasSuffix:@".longDescription"]) {
        return YES;
    }
    return NO;
}

/// Runtime discovery walks NSObject properties; block NSObject dumps and non-music subtrees.
static BOOL YTMUKeyPathIsForbiddenForRuntimeDiscovery(NSString *fullKey) {
    if (fullKey.length == 0) {
        return YES;
    }
    NSString *low = fullKey.lowercaseString;
    if ([low containsString:@"miniplayerbyline"]) {
        return YES;
    }
    if ([low containsString:@"playeroverlaylayer"]) {
        return YES;
    }
    if ([low containsString:@"endscreen"]) {
        return YES;
    }
    if ([low containsString:@".debugdescription"]) {
        return YES;
    }
    if ([low hasSuffix:@".description"] && ![low hasSuffix:@"shortdescription"]) {
        return YES;
    }
    if ([low hasSuffix:@".longdescription"]) {
        return YES;
    }
    return NO;
}

static NSString *YTMUFirstMetadataString(id object, NSArray<NSString *> *keyPaths) {
    for (NSString *keyPath in keyPaths) {
        if (YTMUKeyPathIsForbiddenForKVCMetadata(keyPath)) {
            continue;
        }
        NSString *value = YTMUMetadataStringFromValue(YTMUSafeValueForKeyPath(object, keyPath));
        if (value.length > 0) {
            return value;
        }
    }

    return nil;
}

static NSArray<NSString *> *YTMUAlbumMetadataKeyPaths(void) {
    static NSArray<NSString *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = @[
            @"playerData.videoDetails.album",
            @"playerData.videoDetails.albumTitle",
            @"playerData.videoDetails.musicTrack.album",
            @"playerData.videoDetails.musicTrack.albumTitle",
            @"playerData.videoDetails.musicTrack.albumName",
            @"playerData.videoDetails.musicMetadata.album",
            @"playerData.videoDetails.musicMetadata.albumName",
            @"playerData.videoDetails.musicVideoDetails.album",
            @"playerData.videoDetails.musicArtistAndTrackDetails.album",
            @"playerData.album",
            @"playerData.microformat.playerMicroformatRenderer.album",
        ];
    });
    return paths;
}

/// Fallback when album lives on a nested music* message under videoDetails (protobuf shape varies by client/version).
static NSString *YTMUAlbumStringByNestedScan(YTPlayerResponse *playerResponse) {
    static NSArray<NSString *> *bases;
    static NSArray<NSString *> *leaves;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bases = @[
            @"playerData.videoDetails",
            @"playerData.videoDetails.musicTrack",
            @"playerData.videoDetails.musicMetadata",
            @"playerData.videoDetails.musicVideoDetails",
            @"playerData.videoDetails.musicArtistAndTrackDetails",
            @"playerData.videoDetails.musicDisplay",
            @"playerData.microformat.playerMicroformatRenderer",
        ];
        leaves = @[ @"album", @"albumTitle", @"albumName", @"musicAlbumTitle", @"musicAlbumName" ];
    });
    for (NSString *base in bases) {
        for (NSString *leaf in leaves) {
            NSString *path = [NSString stringWithFormat:@"%@.%@", base, leaf];
            NSString *value = YTMUMetadataStringFromValue(YTMUSafeValueForKeyPath(playerResponse, path));
            if (value.length > 0) {
                return value;
            }
        }
    }
    return nil;
}

static NSString *YTMUAlbumStringFromPlayerResponse(YTPlayerResponse *playerResponse) {
    NSString *album = YTMUFirstMetadataString(playerResponse, YTMUAlbumMetadataKeyPaths());
    if (album.length > 0) {
        return album;
    }
    return YTMUAlbumStringByNestedScan(playerResponse);
}

static NSNumber *YTMUFirstMetadataNumber(id object, NSArray<NSString *> *keyPaths) {
    for (NSString *keyPath in keyPaths) {
        id v = YTMUSafeValueForKeyPath(object, keyPath);
        if ([v isKindOfClass:[NSNumber class]]) {
            return v;
        }
        if ([v isKindOfClass:[NSString class]]) {
            NSString *s = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (s.length == 0) {
                continue;
            }
            NSInteger d = [s integerValue];
            if (d > 0) {
                return @(d);
            }
        }
    }
    return nil;
}

static NSString *YTMUFormattedTrackNumber(YTPlayerResponse *playerResponse) {
    NSArray<NSString *> *numPaths = @[
        @"playerData.videoDetails.musicTrack.trackNumber",
        @"playerData.videoDetails.musicTrack.albumTrackIndex",
        @"playerData.videoDetails.musicMetadata.trackNumber",
        @"playerData.videoDetails.musicTrack.index",
    ];
    NSArray<NSString *> *totPaths = @[
        @"playerData.videoDetails.musicTrack.trackCount",
        @"playerData.videoDetails.musicTrack.albumTrackCount",
        @"playerData.videoDetails.musicMetadata.trackCount",
        @"playerData.videoDetails.musicMetadata.albumTrackCount",
    ];
    NSNumber *n = YTMUFirstMetadataNumber(playerResponse, numPaths);
    NSNumber *m = YTMUFirstMetadataNumber(playerResponse, totPaths);
    if (n && m) {
        return [NSString stringWithFormat:@"%@/%@", n, m];
    }
    if (n) {
        return n.stringValue;
    }
    return nil;
}

static NSString *YTMUFormattedDiscNumber(YTPlayerResponse *playerResponse) {
    NSArray<NSString *> *numPaths = @[
        @"playerData.videoDetails.musicTrack.discNumber",
        @"playerData.videoDetails.musicTrack.volumeNumber",
        @"playerData.videoDetails.musicMetadata.discNumber",
    ];
    NSArray<NSString *> *totPaths = @[
        @"playerData.videoDetails.musicTrack.discCount",
        @"playerData.videoDetails.musicMetadata.discCount",
    ];
    NSNumber *n = YTMUFirstMetadataNumber(playerResponse, numPaths);
    NSNumber *m = YTMUFirstMetadataNumber(playerResponse, totPaths);
    if (n && m) {
        return [NSString stringWithFormat:@"%@/%@", n, m];
    }
    if (n) {
        return n.stringValue;
    }
    return nil;
}

/// youtubei MusicVideoType (ordinal). Raw NSNumber string was showing as genre "1".
static NSString *YTMUHumanizedMusicVideoTypeFromValue(id value) {
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

static NSArray<NSString *> *YTMUInterestingDiscoveryTerms(void) {
    static NSArray<NSString *> *terms;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Omit "description" — it matches cps_privacyPreservingDescription and NSObject description noise.
        terms = @[@"album", @"genre", @"date", @"year", @"lyric", @"subtitle", @"byline", @"microformat", @"renderer", @"music"];
    });
    return terms;
}

static BOOL YTMUKeyLooksInteresting(NSString *key) {
    if ([key isEqualToString:@"description"] || [key isEqualToString:@"debugDescription"]) {
        return NO;
    }
    NSString *lowercaseKey = key.lowercaseString;
    for (NSString *term in YTMUInterestingDiscoveryTerms()) {
        if ([lowercaseKey containsString:term]) {
            return YES;
        }
    }

    return NO;
}

static NSString *YTMUDiscoveryStringFromValue(id value) {
    NSString *metadataString = YTMUMetadataStringFromValue(value);
    if (metadataString.length > 0) {
        return metadataString;
    }

    if ([value isKindOfClass:[NSAttributedString class]]) {
        NSString *string = [(NSAttributedString *)value string];
        return YTMUMetadataStringFromValue(string);
    }

    if ([value isKindOfClass:[NSDate class]]) {
        return [(NSDate *)value description];
    }

    return nil;
}

static NSArray<NSString *> *YTMUDiscoveryKeysForObject(id object) {
    if (!object) return @[];

    NSMutableOrderedSet<NSString *> *keys = [NSMutableOrderedSet orderedSet];
    Class cls = [object class];

    while (cls && cls != [NSObject class]) {
        unsigned int propertyCount = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &propertyCount);
        for (unsigned int i = 0; i < propertyCount; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(properties[i])];
            if (name.length > 0 && YTMUKeyLooksInteresting(name)) {
                [keys addObject:name];
            }
        }
        free(properties);

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
            if (name.length > 0 && YTMUKeyLooksInteresting(name)) {
                [keys addObject:name];
            }
        }
        free(ivars);

        cls = class_getSuperclass(cls);
    }

    return keys.array;
}

static void YTMUAppendRuntimeDiscoveryLines(id object, NSString *prefix, NSUInteger depth, NSMutableArray<NSString *> *lines, NSMutableSet<NSString *> *visited) {
    if (!object || depth == 0 || lines.count >= 40) return;

    NSString *visitKey = [NSString stringWithFormat:@"%p", object];
    if ([visited containsObject:visitKey]) return;
    [visited addObject:visitKey];

    for (NSString *key in YTMUDiscoveryKeysForObject(object)) {
        if (lines.count >= 40) break;

        NSString *fullKey = [NSString stringWithFormat:@"%@.%@", prefix, key];
        if (YTMUKeyPathIsForbiddenForRuntimeDiscovery(fullKey)) {
            continue;
        }

        id value = YTMUSafeValueForKeyPath(object, key);
        if (!value || value == [NSNull null]) continue;

        NSString *scalarValue = YTMUDiscoveryStringFromValue(value);
        if (scalarValue.length > 0) {
            if (scalarValue.length > 200) {
                scalarValue = [[scalarValue substringToIndex:200] stringByAppendingString:@"..."];
            }
            [lines addObject:[NSString stringWithFormat:@"%@ -> %@", fullKey, scalarValue]];
            continue;
        }

        if ([value isKindOfClass:[NSArray class]]) {
            NSUInteger index = 0;
            for (id item in (NSArray *)value) {
                if (index >= 3 || lines.count >= 40) break;
                YTMUAppendRuntimeDiscoveryLines(item, [NSString stringWithFormat:@"%@[%lu]", fullKey, (unsigned long)index], depth - 1, lines, visited);
                index++;
            }
            continue;
        }

        YTMUAppendRuntimeDiscoveryLines(value, fullKey, depth - 1, lines, visited);
    }
}

static NSString *YTMURuntimeMetadataDiscoveryReport(__unused YTPlayerViewController *playerVC, YTPlayerResponse *playerResponse) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];

    if (playerResponse.playerData.videoDetails) {
        YTMUAppendRuntimeDiscoveryLines(playerResponse.playerData.videoDetails, @"playerResponse.playerData.videoDetails", 4, lines, visited);
    }
    id microformat = YTMUSafeValueForKeyPath(playerResponse, @"playerData.microformat");
    if (microformat) {
        [visited removeAllObjects];
        YTMUAppendRuntimeDiscoveryLines(microformat, @"playerResponse.playerData.microformat", 3, lines, visited);
    }

    if (lines.count == 0) {
        return @"<no candidate metadata values found>";
    }

    return [lines componentsJoinedByString:@"\n"];
}

static NSString *YTMUMetadataDebugReport(id object, NSDictionary<NSString *, NSArray<NSString *> *> *metadataPaths) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    for (NSString *group in @[@"album", @"albumArtist", @"composer", @"genre", @"date", @"lyrics", @"comment", @"copyright", @"track", @"disc"]) {
        NSArray<NSString *> *paths = metadataPaths[group] ?: @[];
        for (NSString *keyPath in paths) {
            if (YTMUKeyPathIsForbiddenForKVCMetadata(keyPath)) {
                continue;
            }
            NSString *value = YTMUMetadataStringFromValue(YTMUSafeValueForKeyPath(object, keyPath));
            if (value.length > 0) {
                if ([group isEqualToString:@"lyrics"] && value.length > 200) {
                    value = [[value substringToIndex:200] stringByAppendingString:@"..."];
                }
                [lines addObject:[NSString stringWithFormat:@"%@ -> %@", keyPath, value]];
            }
        }
    }

    if (lines.count == 0) {
        return @"<no candidate metadata values found>";
    }

    return [lines componentsJoinedByString:@"\n"];
}

static NSDictionary<NSString *, NSArray<NSString *> *> *YTMUMetadataPathsDictionary(void) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paths = @{
            @"album": YTMUAlbumMetadataKeyPaths(),
            @"albumArtist": @[
                @"playerData.videoDetails.musicTrack.albumArtist",
                @"playerData.videoDetails.musicMetadata.albumArtist",
                @"playerData.videoDetails.albumArtist",
                @"playerData.videoDetails.musicArtistAndTrackDetails.albumArtist",
                @"playerData.microformat.playerMicroformatRenderer.albumArtist",
            ],
            @"composer": @[
                @"playerData.videoDetails.musicTrack.composer",
                @"playerData.videoDetails.musicMetadata.composer",
                @"playerData.videoDetails.musicMetadata.composerName",
                @"playerData.videoDetails.musicArtistAndTrackDetails.composer",
            ],
            @"genre": @[
                @"playerData.videoDetails.genre",
                @"playerData.videoDetails.musicGenre",
                @"playerData.videoDetails.musicVideoType",
                @"playerData.videoDetails.music_video_type",
                @"playerData.microformat.playerMicroformatRenderer.genre",
                @"playerData.microformat.playerMicroformatRenderer.category",
            ],
            @"date": @[
                @"playerData.videoDetails.releaseDate",
                @"playerData.videoDetails.publishDate",
                @"playerData.microformat.playerMicroformatRenderer.releaseDate",
                @"playerData.microformat.playerMicroformatRenderer.publishDate",
                @"playerData.microformat.playerMicroformatRenderer.uploadDate",
            ],
            @"lyrics": @[
                @"playerData.videoDetails.lyrics",
                @"playerData.lyrics",
                @"playerData.musicLyrics",
                @"playerData.microformat.playerMicroformatRenderer.lyrics",
            ],
            @"comment": @[
                @"playerData.videoDetails.shortDescription",
                @"playerData.videoDetails.musicTrack.shortDescription",
                @"playerData.videoDetails.musicMetadata.shortDescription",
                @"playerData.videoDetails.keywords",
            ],
            @"copyright": @[
                @"playerData.videoDetails.musicTrack.copyright",
                @"playerData.videoDetails.musicMetadata.copyright",
            ],
            @"track": @[
                @"playerData.videoDetails.musicTrack.trackNumber",
                @"playerData.videoDetails.musicTrack.albumTrackIndex",
                @"playerData.videoDetails.musicMetadata.trackNumber",
            ],
            @"disc": @[
                @"playerData.videoDetails.musicTrack.discNumber",
                @"playerData.videoDetails.musicTrack.volumeNumber",
                @"playerData.videoDetails.musicMetadata.discNumber",
            ],
        };
    });
    return paths;
}

static void YTMUPopulateFFmpegMetadataFromPlayer(FFMpegDownloader *ffmpeg, YTPlayerViewController *playerVC) {
    YTPlayerResponse *playerResponse = playerVC.playerResponse;
    if (!playerResponse) {
        return;
    }
    NSString *title = [playerResponse.playerData.videoDetails.title stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *author = [playerResponse.playerData.videoDetails.author stringByReplacingOccurrencesOfString:@"/" withString:@""];
    ffmpeg.tempName = playerVC.contentVideoID;
    ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
    ffmpeg.title = title;
    ffmpeg.artist = author;
    NSDictionary<NSString *, NSArray<NSString *> *> *metadataPaths = YTMUMetadataPathsDictionary();
    ffmpeg.album = YTMUAlbumStringFromPlayerResponse(playerResponse);
    ffmpeg.albumArtist = YTMUFirstMetadataString(playerResponse, metadataPaths[@"albumArtist"]);
    ffmpeg.composer = YTMUFirstMetadataString(playerResponse, metadataPaths[@"composer"]);
    ffmpeg.track = YTMUFormattedTrackNumber(playerResponse);
    ffmpeg.disc = YTMUFormattedDiscNumber(playerResponse);
    NSString *genreFromPaths = YTMUFirstMetadataString(playerResponse, metadataPaths[@"genre"]);
    id mvtObj = YTMUSafeValueForKeyPath(playerResponse, @"playerData.videoDetails.musicVideoType");
    if (!mvtObj) {
        mvtObj = YTMUSafeValueForKeyPath(playerResponse, @"playerData.videoDetails.music_video_type");
    }
    NSString *humanMvt = YTMUHumanizedMusicVideoTypeFromValue(mvtObj);
    BOOL genreIsRawEnumDigits = (genreFromPaths.length > 0 && [genreFromPaths rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound);
    if (genreFromPaths.length > 0 && !genreIsRawEnumDigits) {
        ffmpeg.genre = genreFromPaths;
    } else if (humanMvt.length > 0) {
        ffmpeg.genre = humanMvt;
    } else {
        ffmpeg.genre = genreFromPaths;
    }
    ffmpeg.date = YTMUFirstMetadataString(playerResponse, metadataPaths[@"date"]);
    ffmpeg.lyrics = YTMUFirstMetadataString(playerResponse, metadataPaths[@"lyrics"]);
    ffmpeg.comment = YTMUFirstMetadataString(playerResponse, metadataPaths[@"comment"]);
    ffmpeg.copyright = YTMUFirstMetadataString(playerResponse, metadataPaths[@"copyright"]);
    YTMUMetadataProbeMergeIntoDownloader(ffmpeg, playerVC.contentVideoID);
    // Fallback: when album is known but album artist is still missing, use track artist.
    // This is correct for the vast majority of tracks; album compilations are rare here.
    if (ffmpeg.album.length > 0 && ffmpeg.albumArtist.length == 0 && ffmpeg.artist.length > 0) {
        ffmpeg.albumArtist = ffmpeg.artist;
    }
    // Source URL in the comment field so the file carries a link back to YouTube Music.
    if (ffmpeg.comment.length == 0 && playerVC.contentVideoID.length > 0) {
        ffmpeg.comment = [NSString stringWithFormat:@"https://music.youtube.com/watch?v=%@", playerVC.contentVideoID];
    }
    NSString *pathReport = YTMUMetadataDebugReport(playerResponse, metadataPaths);
    NSString *runtimeReport = YTMURuntimeMetadataDiscoveryReport(playerVC, playerResponse);
    if ([runtimeReport isEqualToString:@"<no candidate metadata values found>"]) {
        ffmpeg.metadataDiscoveryReport = pathReport;
    } else if ([pathReport isEqualToString:@"<no candidate metadata values found>"]) {
        ffmpeg.metadataDiscoveryReport = runtimeReport;
    } else {
        ffmpeg.metadataDiscoveryReport = [NSString stringWithFormat:@"%@\n%@", pathReport, runtimeReport];
    }
    ffmpeg.duration = round(playerVC.currentVideoTotalMediaTime);
}

/// Called when a track activates (see ServerLibraryCheck). Logs ntfy "YTMU discovery" / "YTMU fetched" from current player state.
void YTMULogFetchedMetadataSnapshotForPlayer(YTPlayerViewController *playerVC) {
    if (!playerVC || !playerVC.playerResponse) {
        return;
    }
    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    YTMUPopulateFFmpegMetadataFromPlayer(ffmpeg, playerVC);
    BOOL hasCover = NO;
    if (playerVC.playerResponse.playerData.videoDetails.thumbnail.thumbnailsArray.count > 0) {
        hasCover = YES;
    }
    NSString *safe = [[[ffmpeg.mediaName stringByReplacingOccurrencesOfString:@":" withString:@"-"]
                       stringByReplacingOccurrencesOfString:@"\"" withString:@""]
                      stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", safe]];
    NSURL *placeholder = [NSURL fileURLWithPath:path];
    NSString *vid = playerVC.contentVideoID;
    BOOL hasProbeAppendix = YTMUMetadataProbeDiscoveryAppendixForVideoId(vid).length > 0;
    if (ffmpeg.metadataDiscoveryReport.length > 0 || hasProbeAppendix) {
        [ffmpeg logMetadataPhase:@"discovery" hasCover:hasCover outputURL:placeholder];
    }
    [ffmpeg logMetadataPhase:@"fetched" hasCover:hasCover outputURL:placeholder];
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(YTPlayerViewController *)playerResponse;
- (void)downloadCoverImage:(YTPlayerViewController *)playerResponse;
- (void)saveToServer:(YTPlayerViewController *)playerVC;
- (NSString *)getURLFromManifest:(NSURL *)manifest;
- (void)updateServerIndicatorOnView:(UIView *)view withTitle:(NSString *)title artist:(NSString *)artist;
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {

    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }


    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    if (![node.key isEqualToString:@"music_download_badge_1"]) {
        return %orig;
    }

    if (![tapRecognizer.view._viewControllerForAncestor isKindOfClass:%c(YTMNowPlayingViewController)]) {
        return %orig;
    }

    YTMNowPlayingViewController *playingVC = (YTMNowPlayingViewController *)tapRecognizer.view._viewControllerForAncestor;
    YTMWatchViewController *watchVC = (YTMWatchViewController *)playingVC.parentViewController;
    YTPlayerViewController *playerVC = watchVC.playerViewController;
    YTPlayerResponse *playerResponse = playerVC.playerResponse;

    if (playerResponse) {
        // Preserve the playback-driven library indicator when opening the sheet.
        // Recomputing here can briefly disagree with the async check path and
        // makes the badge appear to "reset" on tap.
        if (![playingVC.view viewWithTag:7777]) {
            [self updateServerIndicatorOnView:playingVC.view withTitle:playerResponse.playerData.videoDetails.title artist:playerResponse.playerData.videoDetails.author];
        }

        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapRecognizer.view;

        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self downloadAudio:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:@"Save to Server" iconImage:[UIImage systemImageNamed:@"icloud.and.arrow.up"] style:0 handler:^ {
            [self saveToServer:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self downloadCoverImage:playerVC];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
            [sheetController presentFromViewController:playingVC animated:YES completion:nil];
        } else if (YTMU(@"downloadAudio")) {
            [self downloadAudio:playerVC];
        } else if (YTMU(@"downloadCoverImage")) {
            [self downloadCoverImage:playerVC];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    YTPlayerResponse *playerResponse = playerVC.playerResponse;
    NSString *urlStr = playerResponse.playerData.streamingData.hlsManifestURL;

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    // Populate all metadata fields (title, artist, album, date, genre, …) from playerResponse
    // and the probe cache — which includes album + year fetched from the WEB_REMIX next API.
    YTMUPopulateFFmpegMetadataFromPlayer(ffmpeg, playerVC);

    NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];

    if (extractedURL.length > 0) {
        [ffmpeg downloadAudio:extractedURL];

        NSMutableArray *thumbnailsArray = playerResponse.playerData.videoDetails.thumbnail.thumbnailsArray;
        YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnail.URL]];

        if (imageData) {
            NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@.png", ffmpeg.mediaName]];
            [imageData writeToURL:coverURL atomically:YES];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
    }
}

%new
- (NSString *)getURLFromManifest:(NSURL *)manifest {
    NSData *manifestData = [NSData dataWithContentsOfURL:manifest];
    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];

    NSArray *groupIDS = @[@"234", @"233"]; // Our priority to find group id 234
    for (NSString *groupID in groupIDS) {
        for (NSString *line in manifestLines) {
            NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
            if ([line containsString:searchString]) {
                NSRange startRange = [line rangeOfString:@"https://"];
                NSRange endRange = [line rangeOfString:@"index.m3u8"];

                if (startRange.location != NSNotFound && endRange.location != NSNotFound) {
                    NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                    return [line substringWithRange:targetRange];
                }
            }
        }
    }

    return nil;
}

%new
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC {
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        hud.mode = MBProgressHUDModeIndeterminate;
    });

    YTPlayerResponse *playerResponse = playerVC.playerResponse;

    NSMutableArray *thumbnailsArray = playerResponse.playerData.videoDetails.thumbnail.thumbnailsArray;
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    NSString *thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];

    dispatch_async(dispatch_get_main_queue(), ^{
        [hud hideAnimated:YES];
    });
}

%new
- (void)saveToServer:(YTPlayerViewController *)playerVC {
    YTPlayerResponse *playerResponse = playerVC.playerResponse;
    NSString *urlStr = playerResponse.playerData.streamingData.hlsManifestURL;

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    YTMUPopulateFFmpegMetadataFromPlayer(ffmpeg, playerVC);

    NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];

    if (extractedURL.length > 0) {
        // Get cover URL for embedding
        NSMutableArray *thumbnailsArray = playerResponse.playerData.videoDetails.thumbnail.thumbnailsArray;
        YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
        if (thumbnail) {
            ffmpeg.coverURL = thumbnail.URL;
        }

        [ffmpeg downloadAudioAndUpload:extractedURL];
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"OOPS");
        alertView.subtitle = LOC(@"LINK_NOT_FOUND");
        [alertView show];
    }
}

%new
- (void)updateServerIndicatorOnView:(UIView *)view withTitle:(NSString *)title artist:(NSString *)artist {
    static NSInteger const INDICATOR_TAG = 7777;

    // Remove existing indicator
    UIView *existing = [view viewWithTag:INDICATOR_TAG];
    [existing removeFromSuperview];

    if (!title || title.length == 0) return;

    // Create label indicator
    UILabel *indicator = [[UILabel alloc] init];
    indicator.tag = INDICATOR_TAG;
    indicator.textAlignment = NSTextAlignmentCenter;
    indicator.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    indicator.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
    indicator.layer.cornerRadius = 10;
    indicator.clipsToBounds = YES;
    indicator.text = @"  Checking...  ";
    indicator.textColor = [UIColor labelColor];

    [view addSubview:indicator];

    // Position higher up
    [NSLayoutConstraint activateConstraints:@[
        [indicator.topAnchor constraintEqualToAnchor:view.topAnchor constant:50],
        [indicator.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [indicator.heightAnchor constraintEqualToConstant:20]
    ]];

    [ServerLibraryChecker checkTrackWithTitle:title artist:artist completion:^(NSDictionary *result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UILabel *currentIndicator = (UILabel *)[view viewWithTag:INDICATOR_TAG];
            if (![currentIndicator isKindOfClass:[UILabel class]]) {
                return;
            }

            NSString *state = [result[@"state"] isKindOfClass:[NSString class]] ? result[@"state"] : @"";
            BOOL requestSucceeded = [[state lowercaseString] isEqualToString:@"success"];
            BOOL inLibrary = [result[@"exists"] boolValue];

            if (!requestSucceeded) {
                currentIndicator.text = @"  Check failed  ";
                currentIndicator.textColor = [UIColor systemRedColor];
            } else if (inLibrary) {
                currentIndicator.text = @"  ✓ In library  ";
                currentIndicator.textColor = [UIColor systemGreenColor];
            } else {
                currentIndicator.text = @"  ⚠ Not in library  ";
                currentIndicator.textColor = [UIColor systemOrangeColor];
            }
        });
    }];
}

%end
