#import "FFMpegDownloader.h"

@implementation FFMpegDownloader {

    Statistics *statistics;

}

- (void)statisticsCallback:(Statistics *)newStatistics {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->statistics = newStatistics;
        [self updateProgressDialog];
    });
}

- (void)downloadAudio:(NSString *)audioURL {
    statistics = nil;
    [MobileFFmpegConfig resetStatistics];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setActive];
    });

    self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    self.hud.mode = MBProgressHUDModeAnnularDeterminate;
    self.hud.label.text = LOC(@"DOWNLOADING");

    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *destinationURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", self.tempName]];
    NSURL *outputURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@.m4a", self.mediaName]];
    NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
    [[NSFileManager defaultManager] createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];

    [MobileFFmpegConfig setLogDelegate:self];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int returnCode = [MobileFFmpeg execute:[NSString stringWithFormat:@"-i %@ -c copy %@", audioURL, destinationURL]];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (returnCode == RETURN_CODE_SUCCESS) {
                [self.hud hideAnimated:YES];
                BOOL isMoved = [[NSFileManager defaultManager] moveItemAtURL:destinationURL toURL:outputURL error:nil];

                if (isMoved) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadDataNotification" object:nil];
                    self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
                    self.hud.mode = MBProgressHUDModeCustomView;
                    self.hud.label.text = LOC(@"DONE");
                    self.hud.label.numberOfLines = 0;

                    UIImageView *checkmarkImageView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:@"checkmark"]];
                    checkmarkImageView.contentMode = UIViewContentModeScaleAspectFit;
                    self.hud.customView = checkmarkImageView;

                    [self.hud hideAnimated:YES afterDelay:3.0];
                }
            } else if (returnCode == RETURN_CODE_CANCEL) {
                [self.hud hideAnimated:YES];

                [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
            } else {
                if (self.hud && self.hud.mode == MBProgressHUDModeAnnularDeterminate) {
                    self.hud.mode = MBProgressHUDModeCustomView;
                    self.hud.label.text = LOC(@"OOPS");
                    self.hud.label.numberOfLines = 0;

                    UIImageView *checkmarkImageView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:@"xmark"]];
                    checkmarkImageView.contentMode = UIViewContentModeScaleAspectFit;
                    self.hud.customView = checkmarkImageView;

                    [self.hud hideAnimated:YES afterDelay:3.0];
                    [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"Command execution failed with rc=%d and output=%@.\n", returnCode, [MobileFFmpegConfig getLastCommandOutput]];
                }

                [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
            }
        });
    });
}

- (void)downloadAudioAndUpload:(NSString *)audioURL {
    statistics = nil;
    [MobileFFmpegConfig resetStatistics];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setActive];
    });

    self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    self.hud.mode = MBProgressHUDModeAnnularDeterminate;
    self.hud.label.text = LOC(@"DOWNLOADING");

    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *tempAudioURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@_temp.m4a", self.tempName]];
    NSURL *tempCoverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@_cover.jpg", self.tempName]];
    
    // Use readable filename for upload: "Artist - Title.mp3"
    NSString *safeMediaName = [[self.mediaName stringByReplacingOccurrencesOfString:@":" withString:@"-"] 
                               stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    NSURL *outputURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp3", safeMediaName]];
    
    [[NSFileManager defaultManager] removeItemAtURL:tempAudioURL error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:tempCoverURL error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    // Download cover image first
    if (self.coverURL) {
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:self.coverURL]];
        if (imageData) {
            // Convert to JPEG for better FFmpeg compatibility
            UIImage *image = [UIImage imageWithData:imageData];
            NSData *jpegData = UIImageJPEGRepresentation(image, 0.9);
            [jpegData writeToURL:tempCoverURL atomically:YES];
        }
    }

    [MobileFFmpegConfig setLogDelegate:self];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // First download the audio stream
        int returnCode = [MobileFFmpeg execute:[NSString stringWithFormat:@"-i %@ -c copy %@", audioURL, tempAudioURL]];
        
        if (returnCode != RETURN_CODE_SUCCESS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showErrorHUD:@"Download failed"];
                [[NSFileManager defaultManager] removeItemAtURL:tempAudioURL error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:tempCoverURL error:nil];
            });
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.hud.label.text = @"Converting...";
        });
        
        // Build FFmpeg command for MP3 conversion with metadata
        NSMutableString *ffmpegCmd = [NSMutableString string];
        
        // Input audio
        [ffmpegCmd appendFormat:@"-i %@", tempAudioURL.path];
        
        // Input cover if exists
        BOOL hasCover = [[NSFileManager defaultManager] fileExistsAtPath:tempCoverURL.path];
        if (hasCover) {
            [ffmpegCmd appendFormat:@" -i %@", tempCoverURL.path];
        }
        
        // Map streams
        [ffmpegCmd appendString:@" -map 0:a"];
        if (hasCover) {
            [ffmpegCmd appendString:@" -map 1:0"];
        }
        
        // Audio codec: 128kbps MP3
        [ffmpegCmd appendString:@" -c:a libmp3lame -b:a 128k"];
        
        // Cover image settings
        if (hasCover) {
            [ffmpegCmd appendString:@" -c:v mjpeg -disposition:v attached_pic"];
        }
        
        // Metadata - escape special characters
        NSString *escapedTitle = [self.title stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        NSString *escapedArtist = [self.artist stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        
        [ffmpegCmd appendFormat:@" -metadata title='%@'", escapedTitle ?: @""];
        [ffmpegCmd appendFormat:@" -metadata artist='%@'", escapedArtist ?: @""];
        
        // ID3v2 version for better compatibility
        [ffmpegCmd appendString:@" -id3v2_version 3"];
        
        // Output file
        [ffmpegCmd appendFormat:@" -y %@", outputURL.path];
        
        returnCode = [MobileFFmpeg execute:ffmpegCmd];
        
        // Clean up temp files
        [[NSFileManager defaultManager] removeItemAtURL:tempAudioURL error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:tempCoverURL error:nil];
        
        if (returnCode != RETURN_CODE_SUCCESS) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showErrorHUD:@"Conversion failed"];
                [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
            });
            return;
        }
        
        // Upload to server
        dispatch_async(dispatch_get_main_queue(), ^{
            self.hud.mode = MBProgressHUDModeIndeterminate;
            self.hud.label.text = @"Uploading...";
        });
        
        [self uploadFileToServer:outputURL completion:^(BOOL success, NSString *message) {
            // Clean up the MP3 file after upload
            [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.hud hideAnimated:YES];
                
                self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
                self.hud.mode = MBProgressHUDModeCustomView;
                
                if (success) {
                    self.hud.label.text = @"Uploaded!";
                    UIImageView *checkmarkImageView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:@"checkmark"]];
                    checkmarkImageView.contentMode = UIViewContentModeScaleAspectFit;
                    self.hud.customView = checkmarkImageView;
                } else {
                    self.hud.label.text = message ?: @"Upload failed";
                    self.hud.label.numberOfLines = 0;
                    UIImageView *xmarkImageView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:@"xmark"]];
                    xmarkImageView.contentMode = UIViewContentModeScaleAspectFit;
                    self.hud.customView = xmarkImageView;
                }
                
                [self.hud hideAnimated:YES afterDelay:3.0];
            });
        }];
    });
}

- (void)uploadFileToServer:(NSURL *)fileURL completion:(void (^)(BOOL success, NSString *message))completion {
    NSString *uploadURLString = @"http://62.146.177.62:8080/api/upload";
    NSString *apiKey = @"4CBpvrymhCyzJ/+XgD3DzBtZKTlCvFoqCRiEZBwe238=";
    
    NSData *fileData = [NSData dataWithContentsOfURL:fileURL];
    if (!fileData) {
        completion(NO, @"Failed to read file");
        return;
    }
    
    NSString *filename = [fileURL lastPathComponent];
    NSString *boundary = [NSString stringWithFormat:@"----FormBoundary%@", [[NSUUID UUID] UUIDString]];
    
    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/mpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:uploadURLString]];
    request.HTTPMethod = @"POST";
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    [request setValue:apiKey forHTTPHeaderField:@"X-API-Key"];
    request.HTTPBody = body;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(NO, error.localizedDescription);
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        
        if (data) {
            NSError *jsonError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            
            if (json) {
                // Check for "File already exists" message
                NSString *message = json[@"message"];
                if ([message isEqualToString:@"File already exists"]) {
                    completion(YES, @"Already exists");
                    return;
                }
                
                if ([json[@"success"] boolValue] == NO && message) {
                    completion(NO, message);
                    return;
                }
            }
        }
        
        if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
            completion(YES, nil);
        } else {
            completion(NO, [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]);
        }
    }];
    
    [task resume];
}

- (void)showErrorHUD:(NSString *)message {
    [self.hud hideAnimated:YES];
    self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    self.hud.mode = MBProgressHUDModeCustomView;
    self.hud.label.text = message;
    self.hud.label.numberOfLines = 0;
    
    UIImageView *xmarkImageView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:@"xmark"]];
    xmarkImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.hud.customView = xmarkImageView;
    
    [self.hud hideAnimated:YES afterDelay:3.0];
}

- (void)logCallback:(long)executionId :(int)level :(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"%@", message);
    });
}

- (void)setActive {
    [MobileFFmpegConfig setLogDelegate:self];
    [MobileFFmpegConfig setStatisticsDelegate:self];
}

- (void)updateProgressDialog {
    if (statistics == nil) {
        return;
    }

    int timeInMilliseconds = [statistics getTime];
    if (timeInMilliseconds > 0) {
        double totalVideoDuration = self.duration;
        double timeInSeconds = timeInMilliseconds / 1000.0;
        double percentage = timeInSeconds / totalVideoDuration;

        if (self.hud && self.hud.mode == MBProgressHUDModeAnnularDeterminate) {
            self.hud.progress = percentage;
            self.hud.detailsLabel.text = [NSString stringWithFormat:@"%d%%", (int)(percentage * 100)];
            [self.hud.button setTitle:LOC(@"CANCEL") forState:UIControlStateNormal];
            [self.hud.button addTarget:self action:@selector(cancelDownloading:) forControlEvents:UIControlEventTouchUpInside];

            UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
            [cancelButton setTag:998];
            UIImage *cancelImage = [[UIImage systemImageNamed:@"x.circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            [cancelButton setImage:cancelImage forState:UIControlStateNormal];
            [cancelButton setTintColor:[[UIColor labelColor] colorWithAlphaComponent:0.7]];
            [cancelButton addTarget:self action:@selector(cancelHUD:) forControlEvents:UIControlEventTouchUpInside];

            UIView *buttonSuperview = self.hud.button.superview;
            if (![buttonSuperview viewWithTag:998]) {
                [buttonSuperview addSubview:cancelButton];

                cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
                [NSLayoutConstraint activateConstraints:@[
                    [cancelButton.topAnchor constraintEqualToAnchor:buttonSuperview.topAnchor constant:5.0],
                    [cancelButton.leadingAnchor constraintEqualToAnchor:buttonSuperview.leadingAnchor constant:5.0],
                    [cancelButton.widthAnchor constraintEqualToConstant:17.0],
                    [cancelButton.heightAnchor constraintEqualToConstant:17.0]
                ]];
            }
        }
    }
}

- (void)cancelDownloading:(UIButton *)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [MobileFFmpeg cancel];
    });
}

- (void)cancelHUD:(UIButton *)sender {
    [self.hud hideAnimated:YES];
}

- (void)downloadImage:(NSURL *)link {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData *imageData = [NSData dataWithContentsOfURL:link];
        UIImage *image = [UIImage imageWithData:imageData];

        if (image) UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
        self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
        self.hud.mode = MBProgressHUDModeCustomView;
        self.hud.label.text = LOC(@"SAVED_TO_PHOTOS");

        UIImageView *checkmarkImageView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:@"checkmark"]];
        checkmarkImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.hud.customView = checkmarkImageView;

        [self.hud hideAnimated:YES afterDelay:2.0];
    });
}

- (UIImage *)imageWithSystemIconNamed:(NSString *)iconName {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(36, 36)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
        UIImage *iconImage = [UIImage systemImageNamed:iconName];
        UIView *imageView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
        UIImageView *iconImageView = [[UIImageView alloc] initWithImage:iconImage];
        iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        iconImageView.clipsToBounds = YES;
        iconImageView.tintColor = [[UIColor labelColor] colorWithAlphaComponent:0.7f];
        iconImageView.frame = imageView.bounds;

        [imageView addSubview:iconImageView];
        [imageView.layer renderInContext:rendererContext.CGContext];
    }];
    return image;
}

- (void)shareMedia:(NSURL *)mediaURL {
    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[mediaURL] applicationActivities:nil];
    activityViewController.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    [activityViewController setCompletionWithItemsHandler:^(NSString *activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
        [[NSFileManager defaultManager] removeItemAtURL:mediaURL error:nil];
    }];

    UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
    [rootViewController presentViewController:activityViewController animated:YES completion:nil];
}

@end