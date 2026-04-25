#import <UIKit/UIKit.h>
#import "YTMUMetadataProbe.h"
#import "Headers/YTMWatchViewController.h"
#import "Headers/YTMNowPlayingViewController.h"

static NSString *YTMUPlayerBarLastVideoId;
static NSTimeInterval YTMUPlayerBarLastScanTime;
static const NSTimeInterval YTMUPlayerBarScanMinInterval = 1.2;

static NSString *YTMUPlayerBarTrimVideoId(id playerVC) {
    if (!playerVC) {
        return nil;
    }
    id v = nil;
    @try {
        v = [playerVC valueForKey:@"contentVideoID"];
    } @catch (__unused NSException *e) {
        v = nil;
    }
    if (![v isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length > 0 ? s : nil;
}

static void YTMUPlayerBarMaybeScan(NSString *videoId, UIView *root) {
    if (videoId.length == 0 || !root) {
        return;
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ([videoId isEqualToString:YTMUPlayerBarLastVideoId] && (now - YTMUPlayerBarLastScanTime) < YTMUPlayerBarScanMinInterval) {
        return;
    }
    YTMUPlayerBarLastVideoId = videoId;
    YTMUPlayerBarLastScanTime = now;
    YTMUMetadataProbeScanRootViewForByline(videoId, root);
}

%hook YTMWatchViewController

- (void)viewDidLayoutSubviews {
    %orig;
    NSString *vid = YTMUPlayerBarTrimVideoId(self.playerViewController);
    if (!vid.length) {
        return;
    }
    YTMUPlayerBarMaybeScan(vid, self.view);
}

%end

%hook YTMNowPlayingViewController

- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *parent = self.parentViewController;
    if (!parent) {
        return;
    }
    id pvc = nil;
    @try {
        pvc = [parent valueForKey:@"playerViewController"];
    } @catch (__unused NSException *e) {
        pvc = nil;
    }
    NSString *vid = YTMUPlayerBarTrimVideoId(pvc);
    if (!vid.length) {
        return;
    }
    YTMUPlayerBarMaybeScan(vid, self.view);
}

%end
