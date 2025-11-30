#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTMNowPlayingView.h"
#import "Headers/YTMWatchViewController.h"
#import "Headers/YTPlayerViewController.h"
#import "Headers/YTPlayerResponse.h"
#import "Headers/YTIPlayerResponse.h"
#import "Headers/YTIVideoDetails.h"

static NSArray *cachedTracks = nil;
static NSDate *lastFetchTime = nil;
static const NSTimeInterval CACHE_DURATION = 300; // 5 minutes

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

@interface YTMNowPlayingViewController (ServerCheck)
- (void)updateServerCheckIndicator;
- (void)refreshLibraryAndUpdate;
- (void)showCheckingIndicator;
@end

@interface ServerLibraryChecker : NSObject
+ (void)fetchTracksWithCompletion:(void (^)(NSArray *tracks))completion;
+ (void)forceRefreshWithCompletion:(void (^)(NSArray *tracks))completion;
+ (BOOL)isTrackInLibrary:(NSString *)title artist:(NSString *)artist;
+ (NSString *)cleanTitle:(NSString *)title;
+ (BOOL)hasCachedTracks;
@end

@implementation ServerLibraryChecker

+ (void)fetchTracksWithCompletion:(void (^)(NSArray *tracks))completion {
    // Return cached tracks if still valid
    if (cachedTracks && lastFetchTime && [[NSDate date] timeIntervalSinceDate:lastFetchTime] < CACHE_DURATION) {
        NSLog(@"[YTMU] Using cached tracks: %lu items", (unsigned long)cachedTracks.count);
        if (completion) completion(cachedTracks);
        return;
    }
    
    NSLog(@"[YTMU] Fetching tracks from server...");
    NSURL *url = [NSURL URLWithString:@"http://62.146.177.62:8080/api/tracks?sort=title&order=asc"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[YTMU] Fetch tracks error: %@", error.localizedDescription);
            if (completion) completion(cachedTracks ?: @[]);
            return;
        }
        
        if (!data) {
            NSLog(@"[YTMU] Fetch tracks: no data");
            if (completion) completion(cachedTracks ?: @[]);
            return;
        }
        
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        
        if (jsonError) {
            NSLog(@"[YTMU] JSON parse error: %@", jsonError.localizedDescription);
            if (completion) completion(cachedTracks ?: @[]);
            return;
        }
        
        if (!json[@"tracks"]) {
            NSLog(@"[YTMU] No tracks key in response: %@", json);
            if (completion) completion(cachedTracks ?: @[]);
            return;
        }
        
        cachedTracks = json[@"tracks"];
        lastFetchTime = [NSDate date];
        NSLog(@"[YTMU] Fetched %lu tracks from server", (unsigned long)cachedTracks.count);
        
        if (completion) completion(cachedTracks);
    }];
    
    [task resume];
}

+ (NSString *)cleanTitle:(NSString *)title {
    if (!title) return @"";
    
    NSString *cleaned = title;
    
    // Remove common YouTube suffixes
    NSArray *patterns = @[
        @"\\s*\\(Official.*?\\)",
        @"\\s*\\[Official.*?\\]",
        @"\\s*\\(Lyric.*?\\)",
        @"\\s*\\[Lyric.*?\\]",
        @"\\s*\\(Audio.*?\\)",
        @"\\s*\\[Audio.*?\\]",
        @"\\s*\\(Music Video\\)",
        @"\\s*\\(HD\\)",
        @"\\s*\\(HQ\\)",
        @"\\s*-\\s*\\(audio\\s*\\d*\\)",  // - (audio 2004)
        @"\\s*\\(audio\\s*\\d*\\)"         // (audio 2004)
    ];
    
    for (NSString *pattern in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        cleaned = [regex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@""];
    }
    
    return [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

+ (NSString *)cleanArtist:(NSString *)artist {
    if (!artist) return @"";
    
    NSString *cleaned = artist;
    
    // Remove "Official" suffix variations
    NSArray *patterns = @[
        @"\\s+Official$",
        @"\\s+official$",
        @"\\s+OFFICIAL$",
        @"\\s+-\\s*Official$",
        @"\\s+VEVO$",
        @"\\s+vevo$"
    ];
    
    for (NSString *pattern in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        cleaned = [regex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@""];
    }
    
    return [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

+ (NSString *)extractTitleFromCombined:(NSString *)title artist:(NSString *)artist {
    // Handle titles like "Artist - Song Title" by extracting just the song title
    if (!title) return @"";
    
    NSString *cleanedArtist = [[self cleanArtist:artist] lowercaseString];
    NSString *lowerTitle = [title lowercaseString];
    
    // Check if title starts with artist name followed by separator
    NSArray *separators = @[@" - ", @" – ", @" — ", @": "];
    for (NSString *sep in separators) {
        if ([lowerTitle hasPrefix:[cleanedArtist stringByAppendingString:sep]]) {
            NSRange range = [title rangeOfString:sep];
            if (range.location != NSNotFound) {
                return [[title substringFromIndex:range.location + range.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }
    }
    
    return title;
}

+ (NSString *)removeDiacritics:(NSString *)string {
    if (!string || string.length == 0) return @"";
    // Use Unicode decomposition to separate base characters from combining marks
    // Then remove the combining marks (diacritics)
    NSMutableString *result = [NSMutableString stringWithString:[string decomposedStringWithCanonicalMapping]];
    // Remove all combining diacritical marks (Unicode range 0x0300-0x036F)
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[\u0300-\u036F]" options:0 error:nil];
    [regex replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@""];
    return result;
}

+ (BOOL)isTrackInLibrary:(NSString *)title artist:(NSString *)artist {
    if (!cachedTracks || cachedTracks.count == 0) return YES; // Assume exists if no cache
    
    // Clean and normalize the input
    NSString *cleanedArtist = [self cleanArtist:artist];
    NSString *cleanedTitle = [self cleanTitle:title];
    
    // Also try extracting song title if format is "Artist - Song Title"
    NSString *extractedTitle = [self extractTitleFromCombined:cleanedTitle artist:cleanedArtist];
    
    NSString *normalizedTitle = [self removeDiacritics:[cleanedTitle lowercaseString]];
    NSString *normalizedExtractedTitle = [self removeDiacritics:[extractedTitle lowercaseString]];
    NSString *normalizedArtist = [self removeDiacritics:[cleanedArtist lowercaseString]] ?: @"";
    
    for (NSDictionary *track in cachedTracks) {
        NSString *trackTitle = [self removeDiacritics:[[track[@"title"] ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        NSString *trackArtist = [self removeDiacritics:[[self cleanArtist:track[@"artist"] ?: @""] lowercaseString]];
        
        // Check artist match (flexible)
        BOOL artistMatch = (normalizedArtist.length == 0 || trackArtist.length == 0 ||
                           [trackArtist containsString:normalizedArtist] || 
                           [normalizedArtist containsString:trackArtist]);
        
        if (!artistMatch) continue;
        
        // Exact title match
        if ([trackTitle isEqualToString:normalizedTitle] || 
            [trackTitle isEqualToString:normalizedExtractedTitle]) {
            return YES;
        }
        
        // Title contains match with length check
        if (trackTitle.length > 0) {
            // Try with full cleaned title
            if (normalizedTitle.length > 0) {
                NSUInteger shorter = MIN(trackTitle.length, normalizedTitle.length);
                NSUInteger longer = MAX(trackTitle.length, normalizedTitle.length);
                
                if ((float)shorter / longer >= 0.5) {
                    if ([trackTitle containsString:normalizedTitle] || [normalizedTitle containsString:trackTitle]) {
                        return YES;
                    }
                }
            }
            
            // Try with extracted title (from "Artist - Song" format)
            if (normalizedExtractedTitle.length > 0 && ![normalizedExtractedTitle isEqualToString:normalizedTitle]) {
                NSUInteger shorter = MIN(trackTitle.length, normalizedExtractedTitle.length);
                NSUInteger longer = MAX(trackTitle.length, normalizedExtractedTitle.length);
                
                if ((float)shorter / longer >= 0.5) {
                    if ([trackTitle containsString:normalizedExtractedTitle] || [normalizedExtractedTitle containsString:trackTitle]) {
                        return YES;
                    }
                }
            }
        }
    }
    
    return NO;
}

+ (BOOL)hasCachedTracks {
    return cachedTracks != nil && cachedTracks.count > 0;
}

+ (void)forceRefreshWithCompletion:(void (^)(NSArray *tracks))completion {
    NSLog(@"[YTMU] Force refreshing library cache");
    // Clear the cache to force a new fetch
    cachedTracks = nil;
    lastFetchTime = nil;
    [self fetchTracksWithCompletion:completion];
}

@end

%hook YTMNowPlayingViewController

- (void)viewDidLoad {
    %orig;
    
    if (!YTMU(@"YTMUltimateIsEnabled")) return;
    
    // Fetch tracks on load
    [ServerLibraryChecker fetchTracksWithCompletion:nil];
    
    // Register for track change notifications
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(updateServerCheckIndicator) 
                                                 name:@"ServerLibraryCheckUpdate" 
                                               object:nil];
    
    // Register for library refresh after upload
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(refreshLibraryAndUpdate) 
                                                 name:@"ServerLibraryRefreshNeeded" 
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    
    if (!YTMU(@"YTMUltimateIsEnabled")) return;
    
    NSLog(@"[YTMU] YTMNowPlayingViewController viewWillAppear");
    
    // Delay 1 second to ensure playerResponse is ready
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
    
    NSString *title = playerResponse.playerData.videoDetails.title;
    NSString *artist = playerResponse.playerData.videoDetails.author;
    
    NSLog(@"[YTMU] Checking track: %@ - %@", artist, title);
    
    if (!title || title.length == 0) {
        NSLog(@"[YTMU] No title");
        return;
    }
    
    UIView *nowPlayingView = self.view;
    if (!nowPlayingView) {
        NSLog(@"[YTMU] No nowPlayingView");
        return;
    }
    
    // Use same tag as Downloading.x
    static NSInteger const INDICATOR_TAG = 7777;
    
    // Show "Checking..." first
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
    
    // Track when we started checking
    NSDate *checkStartTime = [NSDate date];
    
    [ServerLibraryChecker fetchTracksWithCompletion:^(NSArray *tracks) {
        BOOL inLibrary = [ServerLibraryChecker isTrackInLibrary:title artist:artist];
        NSLog(@"[YTMU] Track in library: %@", inLibrary ? @"YES" : @"NO");
        
        // Calculate how long the check took
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:checkStartTime];
        NSTimeInterval minDisplayTime = 1.0; // Minimum 1 second
        NSTimeInterval delay = MAX(0, minDisplayTime - elapsed);
        
        // Wait at least 1 second total before showing result
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Remove checking indicator
            UIView *existing = [nowPlayingView viewWithTag:INDICATOR_TAG];
            [existing removeFromSuperview];
            
            // Create final indicator
            UILabel *indicator = [[UILabel alloc] init];
            indicator.tag = INDICATOR_TAG;
            indicator.textAlignment = NSTextAlignmentCenter;
            indicator.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
            indicator.translatesAutoresizingMaskIntoConstraints = NO;
            indicator.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
            indicator.layer.cornerRadius = 10;
            indicator.clipsToBounds = YES;
            
            if (inLibrary) {
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
    NSLog(@"[YTMU] refreshLibraryAndUpdate called - forcing cache refresh");
    
    UIView *nowPlayingView = self.view;
    if (!nowPlayingView) return;
    
    // Use same tag
    static NSInteger const INDICATOR_TAG = 7777;
    
    // Show "Checking..." while refreshing
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
    
    // Force refresh by clearing cache and fetching again
    [ServerLibraryChecker forceRefreshWithCompletion:^(NSArray *tracks) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateServerCheckIndicator];
        });
    }];
}

%end

// Update indicator when song changes
%hook YTPlayerViewController

- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)data {
    %orig;
    
    if (!YTMU(@"YTMUltimateIsEnabled")) return;
    
    NSLog(@"[YTMU] didActivateVideo called - song changed!");
    
    // Delay 1 second to ensure playerResponse is updated
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"[YTMU] Posting ServerLibraryCheckUpdate notification");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ServerLibraryCheckUpdate" object:nil];
    });
}

%end
