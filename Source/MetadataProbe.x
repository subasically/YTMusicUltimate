#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import "YTMUMetadataProbe.h"
#import "Headers/YTMWatchViewController.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerViewController.h"

%hook YTMWatchViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTMUMetadataProbeOnWatchViewController(weakSelf);
    });
}

%end

%hook YTMWatchViewController

/// Also re-probe when the queue item changes (track skipped while already in the watch screen).
- (void)queueController:(id)controller didActivateMusicQueueItem:(id)item atIndex:(NSInteger)index {
    %orig;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTMUMetadataProbeOnWatchViewController(weakSelf);
    });
}

%end

%hook YTMNowPlayingViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTMUMetadataProbeOnNowPlayingViewController(weakSelf);
    });
}

%end

%hook YTPlayerViewController

/// Fires when a new track starts. We capture the `video` and `playbackData` args
/// — these come from the queue layer and may carry album / year that the playerResponse never exposes.
- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)data {
    %orig;
    __weak typeof(self) weakSelf = self;
    // Retain args across the dispatch; ARC keeps them alive as long as the block exists.
    id videoCopy = video;
    id dataCopy  = data;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTMUMetadataProbeOnVideoActivated(weakSelf, videoCopy, dataCopy);
    });
}

%end
