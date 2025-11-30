#import <Foundation/Foundation.h>

@interface ServerLibraryChecker : NSObject
+ (void)fetchTracksWithCompletion:(void (^)(NSArray *tracks))completion;
+ (BOOL)isTrackInLibrary:(NSString *)title artist:(NSString *)artist;
+ (NSString *)cleanTitle:(NSString *)title;
+ (BOOL)hasCachedTracks;
@end
