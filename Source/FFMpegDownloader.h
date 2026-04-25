#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import "Utils/MobileFFmpeg/MobileFFmpegConfig.h"
#import "Utils/MobileFFmpeg/MobileFFmpeg.h"
#import "Utils/MobileFFmpeg/MobileFFprobe.h"
#import "Utils/MBProgressHUD/MBProgressHUD.h"
#import "Headers/Localization.h"

@interface FFMpegDownloader : NSObject <LogDelegate, StatisticsDelegate>
@property (nonatomic, strong) MBProgressHUD *hud;
@property (nonatomic, strong) NSString *tempName;
@property (nonatomic, strong) NSString *mediaName;
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSString *artist;
@property (nonatomic, strong) NSString *album;
@property (nonatomic, strong) NSString *albumArtist;
@property (nonatomic, strong) NSString *composer;
@property (nonatomic, strong) NSString *track;
@property (nonatomic, strong) NSString *disc;
@property (nonatomic, strong) NSString *genre;
@property (nonatomic, strong) NSString *date;
@property (nonatomic, strong) NSString *lyrics;
@property (nonatomic, strong) NSString *comment;
@property (nonatomic, strong) NSString *copyright;
@property (nonatomic, strong) NSString *metadataDiscoveryReport;
@property (nonatomic, strong) NSString *coverURL;
@property (nonatomic) NSInteger duration;
- (void)downloadAudio:(NSString *)audioURL;
- (void)downloadAudioAndUpload:(NSString *)audioURL;
- (void)downloadImage:(NSURL *)link;
- (void)shareMedia:(NSURL *)mediaURL;
/// Snapshot log (e.g. ntfy "YTMU discovery" / "YTMU fetched") — used when a track starts and after mux.
- (void)logMetadataPhase:(NSString *)phase hasCover:(BOOL)hasCover outputURL:(NSURL *)outputURL;
@end
