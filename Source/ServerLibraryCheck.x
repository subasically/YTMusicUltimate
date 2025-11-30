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
static const NSInteger SERVER_CHECK_INDICATOR_TAG = 9999;

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

@interface YTMNowPlayingViewController (ServerCheck)
- (void)updateServerCheckIndicator;
@end

@interface ServerLibraryChecker : NSObject
+ (void)fetchTracksWithCompletion:(void (^)(NSArray *tracks))completion;
+ (BOOL)isTrackInLibrary:(NSString *)title artist:(NSString *)artist;
+ (NSString *)cleanTitle:(NSString *)title;
@end

@implementation ServerLibraryChecker

+ (void)fetchTracksWithCompletion:(void (^)(NSArray *tracks))completion {
    // Return cached tracks if still valid
    if (cachedTracks && lastFetchTime && [[NSDate date] timeIntervalSinceDate:lastFetchTime] < CACHE_DURATION) {
        if (completion) completion(cachedTracks);
        return;
    }
    
    NSURL *url = [NSURL URLWithString:@"http://62.146.177.62:8080/api/tracks?sort=title&order=asc"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 10;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            if (completion) completion(cachedTracks ?: @[]);
            return;
        }
        
        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        
        if (jsonError || !json[@"tracks"]) {
            if (completion) completion(cachedTracks ?: @[]);
            return;
        }
        
        cachedTracks = json[@"tracks"];
        lastFetchTime = [NSDate date];
        
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
        @"\\s*\\(HQ\\)"
    ];
    
    for (NSString *pattern in patterns) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
        cleaned = [regex stringByReplacingMatchesInString:cleaned options:0 range:NSMakeRange(0, cleaned.length) withTemplate:@""];
    }
    
    return [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

+ (BOOL)isTrackInLibrary:(NSString *)title artist:(NSString *)artist {
    if (!cachedTracks || cachedTracks.count == 0) return YES; // Assume exists if no cache
    
    NSString *cleanedTitle = [[self cleanTitle:title] lowercaseString];
    NSString *normalizedArtist = [artist lowercaseString] ?: @"";
    
    for (NSDictionary *track in cachedTracks) {
        NSString *trackTitle = [[track[@"title"] ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *trackArtist = [[track[@"artist"] ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        // Exact title + artist match
        if ([trackTitle isEqualToString:cleanedTitle]) {
            if (normalizedArtist.length > 0 && trackArtist.length > 0) {
                if ([trackArtist containsString:normalizedArtist] || [normalizedArtist containsString:trackArtist]) {
                    return YES;
                }
            }
        }
        
        // Title contains match with length check
        if (trackTitle.length > 0 && cleanedTitle.length > 0) {
            NSUInteger shorter = MIN(trackTitle.length, cleanedTitle.length);
            NSUInteger longer = MAX(trackTitle.length, cleanedTitle.length);
            
            if ((float)shorter / longer >= 0.5) {
                if ([trackTitle containsString:cleanedTitle] || [cleanedTitle containsString:trackTitle]) {
                    if (normalizedArtist.length == 0 || trackArtist.length == 0 ||
                        [trackArtist containsString:normalizedArtist] || [normalizedArtist containsString:trackArtist]) {
                        return YES;
                    }
                }
            }
        }
    }
    
    return NO;
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
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    
    if (!YTMU(@"YTMUltimateIsEnabled")) return;
    
    // Delay to ensure player data is available
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateServerCheckIndicator];
    });
}

%new
- (void)updateServerCheckIndicator {
    YTMWatchViewController *watchVC = (YTMWatchViewController *)self.parentViewController;
    if (!watchVC) return;
    
    YTPlayerViewController *playerVC = watchVC.playerViewController;
    if (!playerVC) return;
    
    YTPlayerResponse *playerResponse = playerVC.playerResponse;
    if (!playerResponse) return;
    
    NSString *title = playerResponse.playerData.videoDetails.title;
    NSString *artist = playerResponse.playerData.videoDetails.author;
    
    if (!title || title.length == 0) return;
    
    UIView *nowPlayingView = self.view;
    if (!nowPlayingView) return;
    
    // Remove existing indicator
    UIView *existingIndicator = [nowPlayingView viewWithTag:SERVER_CHECK_INDICATOR_TAG];
    [existingIndicator removeFromSuperview];
    
    [ServerLibraryChecker fetchTracksWithCompletion:^(NSArray *tracks) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL inLibrary = [ServerLibraryChecker isTrackInLibrary:title artist:artist];
            
            if (!inLibrary) {
                // Create indicator - small red circle with cloud icon
                UIView *indicator = [[UIView alloc] init];
                indicator.tag = SERVER_CHECK_INDICATOR_TAG;
                indicator.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
                indicator.layer.cornerRadius = 14;
                indicator.translatesAutoresizingMaskIntoConstraints = NO;
                
                UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"icloud.slash"]];
                iconView.tintColor = [UIColor whiteColor];
                iconView.contentMode = UIViewContentModeScaleAspectFit;
                iconView.translatesAutoresizingMaskIntoConstraints = NO;
                [indicator addSubview:iconView];
                
                [nowPlayingView addSubview:indicator];
                
                [NSLayoutConstraint activateConstraints:@[
                    [indicator.topAnchor constraintEqualToAnchor:nowPlayingView.safeAreaLayoutGuide.topAnchor constant:60],
                    [indicator.leadingAnchor constraintEqualToAnchor:nowPlayingView.leadingAnchor constant:16],
                    [indicator.widthAnchor constraintEqualToConstant:28],
                    [indicator.heightAnchor constraintEqualToConstant:28],
                    
                    [iconView.centerXAnchor constraintEqualToAnchor:indicator.centerXAnchor],
                    [iconView.centerYAnchor constraintEqualToAnchor:indicator.centerYAnchor],
                    [iconView.widthAnchor constraintEqualToConstant:16],
                    [iconView.heightAnchor constraintEqualToConstant:16]
                ]];
            }
        });
    }];
}

%end

// Update indicator when song changes
%hook YTMWatchViewController

- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)data {
    %orig;
    
    if (!YTMU(@"YTMUltimateIsEnabled")) return;
    
    // Delay slightly to ensure playerResponse is updated
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ServerLibraryCheckUpdate" object:nil];
    });
}

%end
