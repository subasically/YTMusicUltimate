#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class FFMpegDownloader;

/// On-device metadata cache + ntfy probes for exploring which hooks expose usable fields (videoId-keyed).
void YTMUMetadataProbeOnTrackActivated(NSString *videoId, id playerResponse, NSString *source);
void YTMUMetadataProbeOnWatchViewController(id watchVC);
void YTMUMetadataProbeOnNowPlayingViewController(id nowPlayingVC);

/// Walks a view subtree (e.g. watch / now playing / window) for labels matching `Artist • Album • Year` and merges into the probe cache.
void YTMUMetadataProbeScanRootViewForByline(NSString *videoId, UIView *rootView);

/// Fills empty FFMpegDownloader fields from the per–video-id probe cache.
void YTMUMetadataProbeMergeIntoDownloader(FFMpegDownloader *ffmpeg, NSString *videoId);

/// Formatted block for the YTMU discovery ntfy body (hook-derived cache for this video id).
NSString *YTMUMetadataProbeDiscoveryAppendixForVideoId(NSString *videoId);

/// Runtime-walks the `video` and `playbackData` args from playbackController:didActivateVideo:withPlaybackData:
/// plus selected key paths on playerVC itself, looking for album / year in queue-item objects.
void YTMUMetadataProbeOnVideoActivated(id playerVC, id video, id playbackData);

/// Fires a WEB_REMIX /next API call for the given videoId, parses album + year from the
/// playlistPanelVideoRenderer byline, and merges the result into the probe cache asynchronously.
/// Safe to call from any thread; completion happens on a background URLSession queue.
void YTMUFetchAlbumMetadataForVideoId(NSString *videoId);
