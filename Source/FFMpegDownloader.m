#import "FFMpegDownloader.h"
#import "YTMUMetadataProbe.h"

@implementation FFMpegDownloader {

    Statistics *statistics;

}

- (NSDictionary *)ytmuSettings {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [settings isKindOfClass:[NSDictionary class]] ? settings : @{};
}

- (BOOL)metadataLoggingEnabled {
    id configuredValue = [self ytmuSettings][@"ntfyMetadataLogging"];
    if ([configuredValue respondsToSelector:@selector(boolValue)]) {
        return [configuredValue boolValue];
    }

    return YES;
}

- (NSString *)trimmedStringValue:(id)value {
    if (![value isKindOfClass:[NSString class]]) return nil;

    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

- (NSString *)lyricsPreview {
    NSString *lyrics = [self trimmedStringValue:self.lyrics];
    if (lyrics.length == 0) return @"<none>";

    if (lyrics.length <= 200) return lyrics;
    return [[lyrics substringToIndex:200] stringByAppendingString:@"..."];
}

- (NSString *)commentPreviewForLog {
    NSString *c = [self trimmedStringValue:self.comment];
    if (c.length == 0) return @"<none>";
    if (c.length <= 120) return c;
    return [[c substringToIndex:120] stringByAppendingString:@"..."];
}

- (NSString *)uploadEndpointString {
    NSDictionary *settings = [self ytmuSettings];
    return [self trimmedStringValue:settings[@"uploadEndpoint"]] ?: @"https://radio-v2.subasically.me/api/upload";
}

- (BOOL)shouldPostNtfyForTitle:(NSString *)title body:(NSString *)body {
    NSString *normalized = (title ?: @"").lowercaseString;
    return [normalized rangeOfString:@"error"].location != NSNotFound || [normalized rangeOfString:@"warn"].location != NSNotFound;
}

- (NSString *)uploadResponsePreviewFromData:(NSData *)data {
    if (data.length == 0) return nil;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *trimmed = [self trimmedStringValue:text];
    if (trimmed.length == 0) return nil;

    if (trimmed.length > 1000) {
        return [[trimmed substringToIndex:1000] stringByAppendingString:@"..."];
    }
    return trimmed;
}

- (void)logUploadErrorWithEndpoint:(NSString *)endpoint
                           fileURL:(NSURL *)fileURL
                          fileSize:(NSUInteger)fileSize
                        statusCode:(NSInteger)statusCode
                             detail:(NSString *)detail
                       errorMessage:(NSString *)errorMessage
                       responseData:(NSData *)responseData {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:@"phase: upload-error"];
    [lines addObject:[NSString stringWithFormat:@"endpoint: %@", endpoint ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"file: %@", fileURL.lastPathComponent ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"file_bytes: %lu", (unsigned long)fileSize]];
    [lines addObject:[NSString stringWithFormat:@"title: %@", [self trimmedStringValue:self.title] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"artist: %@", [self trimmedStringValue:self.artist] ?: @"<none>"]];
    if (statusCode > 0) {
        [lines addObject:[NSString stringWithFormat:@"status_code: %ld", (long)statusCode]];
    }
    if (detail.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"detail: %@", detail]];
    }
    if (errorMessage.length > 0) {
        [lines addObject:[NSString stringWithFormat:@"error: %@", errorMessage]];
    }
    NSString *responsePreview = [self uploadResponsePreviewFromData:responseData];
    if (responsePreview.length > 0) {
        [lines addObject:@"response:"];
        [lines addObject:responsePreview];
    }

    NSString *body = [lines componentsJoinedByString:@"\n"];
    NSLog(@"[YTMU] Upload error\n%@", body);
    [self postMetadataLogToNtfyWithTitle:@"YTMU upload-error" body:body];
}

- (NSString *)metadataLogBodyForPhase:(NSString *)phase hasCover:(BOOL)hasCover outputURL:(NSURL *)outputURL {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"phase: %@", phase ?: @"unknown"]];
    [lines addObject:[NSString stringWithFormat:@"file: %@", outputURL.lastPathComponent ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"title: %@", [self trimmedStringValue:self.title] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"artist: %@", [self trimmedStringValue:self.artist] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"album: %@", [self trimmedStringValue:self.album] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"album_artist: %@", [self trimmedStringValue:self.albumArtist] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"composer: %@", [self trimmedStringValue:self.composer] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"track: %@", [self trimmedStringValue:self.track] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"disc: %@", [self trimmedStringValue:self.disc] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"genre: %@", [self trimmedStringValue:self.genre] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"date: %@", [self trimmedStringValue:self.date] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"lyrics: %@", [self lyricsPreview]]];
    [lines addObject:[NSString stringWithFormat:@"comment: %@", [self commentPreviewForLog]]];
    [lines addObject:[NSString stringWithFormat:@"copyright: %@", [self trimmedStringValue:self.copyright] ?: @"<none>"]];
    [lines addObject:[NSString stringWithFormat:@"cover_embedded: %@", hasCover ? @"yes" : @"no"]];
    [lines addObject:[NSString stringWithFormat:@"duration_seconds: %ld", (long)self.duration]];
    [lines addObject:[NSString stringWithFormat:@"format: %@", outputURL.pathExtension.lowercaseString ?: @"<unknown>"]];
    if ([phase isEqualToString:@"discovery"]) {
        if (self.metadataDiscoveryReport.length > 0) {
            [lines addObject:@""];
            [lines addObject:@"candidate_paths:"];
            [lines addObject:self.metadataDiscoveryReport];
        }
        NSString *probeAppendix = YTMUMetadataProbeDiscoveryAppendixForVideoId(self.tempName);
        if (probeAppendix.length > 0) {
            [lines addObject:@""];
            [lines addObject:probeAppendix];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (void)postMetadataLogToNtfyWithTitle:(NSString *)title body:(NSString *)body {
    NSDictionary *settings = [self ytmuSettings];
    if (![self metadataLoggingEnabled]) return;
    if (![self shouldPostNtfyForTitle:title body:body]) return;

    NSString *topic = [self trimmedStringValue:settings[@"ntfyTopic"]] ?: @"ytmusicultimate";

    NSString *server = [self trimmedStringValue:settings[@"ntfyServer"]] ?: @"https://ntfy.subasically.me";
    NSString *baseURL = [server hasSuffix:@"/"] ? [server substringToIndex:server.length - 1] : server;
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", baseURL, topic];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 10;
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:title forHTTPHeaderField:@"Title"];

    NSString *token = [self trimmedStringValue:settings[@"ntfyToken"]];
    if (token.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[YTMU] ntfy metadata log failed: %@", error.localizedDescription);
            return;
        }

        NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
        if (statusCode < 200 || statusCode >= 300) {
            NSLog(@"[YTMU] ntfy metadata log returned HTTP %ld", (long)statusCode);
        }
    }] resume];
}

- (void)logMetadataPhase:(NSString *)phase hasCover:(BOOL)hasCover outputURL:(NSURL *)outputURL {
    NSString *body = [self metadataLogBodyForPhase:phase hasCover:hasCover outputURL:outputURL];
    NSLog(@"[YTMU] Metadata %@\n%@", phase, body);
    [self postMetadataLogToNtfyWithTitle:[NSString stringWithFormat:@"YTMU %@", phase] body:body];
}

- (NSString *)escapedMetadataValue:(NSString *)value {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return @"";

    if (value.length > 8192) {
        value = [value substringToIndex:8192];
    }

    NSString *escaped = [[value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                         stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [[escaped stringByReplacingOccurrencesOfString:@"\r\n" withString:@" "]
               stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\r" withString:@" "];

    return [escaped stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)appendMetadataIfPresent:(NSMutableString *)cmd key:(NSString *)key value:(NSString *)value {
    NSString *escaped = [self escapedMetadataValue:value];
    if (escaped.length == 0) {
        return;
    }
    [cmd appendFormat:@" -metadata %@=\"%@\"", key, escaped];
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

    // Use readable filename for upload: "Artist - Title.m4a"
    NSString *safeMediaName = [[[self.mediaName stringByReplacingOccurrencesOfString:@":" withString:@"-"]
                               stringByReplacingOccurrencesOfString:@"\"" withString:@""]
                               stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    NSURL *outputURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", safeMediaName]];

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
        NSString *downloadCmd = [NSString stringWithFormat:@"-i \"%@\" -c copy \"%@\"", audioURL, tempAudioURL.path];
        NSLog(@"[YTMU] Download command: %@", downloadCmd);
        int returnCode = [MobileFFmpeg execute:downloadCmd];
        NSLog(@"[YTMU] Download return code: %d", returnCode);

        if (returnCode != RETURN_CODE_SUCCESS) {
            NSString *output = [MobileFFmpegConfig getLastCommandOutput];
            NSLog(@"[YTMU] Download failed output: %@", output);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showErrorHUD:@"Download failed"];
                [[NSFileManager defaultManager] removeItemAtURL:tempAudioURL error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:tempCoverURL error:nil];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.hud.label.text = @"Processing...";
        });

        // Build FFmpeg command - keep AAC audio, embed metadata, and attach artwork when available.
        NSMutableString *ffmpegCmd = [NSMutableString string];

        // Input audio
        [ffmpegCmd appendFormat:@"-i \"%@\"", tempAudioURL.path];

        // Input cover if exists
        BOOL hasCover = [[NSFileManager defaultManager] fileExistsAtPath:tempCoverURL.path];
        if (hasCover) {
            [ffmpegCmd appendFormat:@" -i \"%@\"", tempCoverURL.path];
        }

        // Map streams
        [ffmpegCmd appendString:@" -map 0:a"];
        if (hasCover) {
            [ffmpegCmd appendString:@" -map 1:0"];
        }

        // Keep the original AAC stream and attach cover art when available.
        [ffmpegCmd appendString:@" -c:a copy"];
        if (hasCover) {
            [ffmpegCmd appendString:@" -c:v mjpeg -disposition:v attached_pic"];
        }

        // Metadata (MP4/M4A atoms via FFmpeg; omit empty tags)
        NSString *escapedTitle = [self escapedMetadataValue:self.title];
        NSString *escapedArtist = [self escapedMetadataValue:self.artist];
        NSString *escapedAlbum = [self escapedMetadataValue:self.album];
        NSString *escapedGenre = [self escapedMetadataValue:self.genre];
        NSString *escapedDate = [self escapedMetadataValue:self.date];
        NSString *escapedLyrics = [self escapedMetadataValue:self.lyrics];

        [ffmpegCmd appendFormat:@" -metadata title=\"%@\"", escapedTitle];
        [ffmpegCmd appendFormat:@" -metadata artist=\"%@\"", escapedArtist];
        if (escapedAlbum.length > 0) {
            [ffmpegCmd appendFormat:@" -metadata album=\"%@\"", escapedAlbum];
        }
        [self appendMetadataIfPresent:ffmpegCmd key:@"album_artist" value:self.albumArtist];
        [self appendMetadataIfPresent:ffmpegCmd key:@"composer" value:self.composer];
        [self appendMetadataIfPresent:ffmpegCmd key:@"track" value:self.track];
        [self appendMetadataIfPresent:ffmpegCmd key:@"disc" value:self.disc];
        if (escapedGenre.length > 0) {
            [ffmpegCmd appendFormat:@" -metadata genre=\"%@\"", escapedGenre];
        }
        if (escapedDate.length > 0) {
            [ffmpegCmd appendFormat:@" -metadata date=\"%@\" -metadata year=\"%@\"", escapedDate, escapedDate];
        }
        if (escapedLyrics.length > 0) {
            [ffmpegCmd appendFormat:@" -metadata lyrics=\"%@\"", escapedLyrics];
        }
        [self appendMetadataIfPresent:ffmpegCmd key:@"comment" value:self.comment];
        [self appendMetadataIfPresent:ffmpegCmd key:@"copyright" value:self.copyright];

        // Output file (discovery / fetched logs run when the track activates; see YTMULogFetchedMetadataSnapshotForPlayer)
        [ffmpegCmd appendFormat:@" -y \"%@\"", outputURL.path];

        NSLog(@"[YTMU] Convert command: %@", ffmpegCmd);
        returnCode = [MobileFFmpeg execute:ffmpegCmd];
        NSLog(@"[YTMU] Convert return code: %d", returnCode);

        // Clean up temp files
        [[NSFileManager defaultManager] removeItemAtURL:tempAudioURL error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:tempCoverURL error:nil];

        if (returnCode != RETURN_CODE_SUCCESS) {
            NSString *output = [MobileFFmpegConfig getLastCommandOutput];
            NSLog(@"[YTMU] Convert failed output: %@", output);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showErrorHUD:@"Processing failed"];
                [UIPasteboard generalPasteboard].string = output;
                [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
            });
            return;
        }

        [self logMetadataPhase:@"embedded" hasCover:hasCover outputURL:outputURL];

        // Upload to server
        dispatch_async(dispatch_get_main_queue(), ^{
            self.hud.mode = MBProgressHUDModeIndeterminate;
            self.hud.label.text = @"Uploading...";
        });

        [self uploadFileToServer:outputURL completion:^(BOOL success, NSString *message) {
            // Clean up the output file after upload
            [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self.hud hideAnimated:YES];

                self.hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
                self.hud.mode = MBProgressHUDModeCustomView;

                if (success) {
                    self.hud.label.text = message ?: @"Uploaded!";
                    UIImageView *checkmarkImageView = [[UIImageView alloc] initWithImage:[self imageWithSystemIconNamed:@"checkmark"]];
                    checkmarkImageView.contentMode = UIViewContentModeScaleAspectFit;
                    self.hud.customView = checkmarkImageView;

                    // Refresh library cache and update indicator after successful upload
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        // Force refresh the cache by clearing it
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"ServerLibraryRefreshNeeded" object:nil];
                    });
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
    NSString *uploadURLString = [self uploadEndpointString];
    NSString *apiKey = @"4CBpvrymhCyzJ/+XgD3DzBtZKTlCvFoqCRiEZBwe238=";

    NSData *fileData = [NSData dataWithContentsOfURL:fileURL];
    if (!fileData) {
        NSLog(@"[YTMU] Failed to read file at: %@", fileURL.path);
        [self logUploadErrorWithEndpoint:uploadURLString
                                 fileURL:fileURL
                                fileSize:0
                              statusCode:0
                                  detail:@"failed to read file before upload"
                            errorMessage:nil
                            responseData:nil];
        completion(NO, @"Failed to read file");
        return;
    }

    NSLog(@"[YTMU] Uploading file: %@ (%lu bytes)", fileURL.lastPathComponent, (unsigned long)fileData.length);
    NSLog(@"[YTMU] Upload endpoint: %@", uploadURLString);

    NSString *filename = [fileURL lastPathComponent];
    NSString *boundary = [NSString stringWithFormat:@"----FormBoundary%@", [[NSUUID UUID] UUIDString]];

    // Determine content type based on file extension
    NSString *contentType = @"audio/mp4";
    if ([filename.pathExtension.lowercaseString isEqualToString:@"mp3"]) {
        contentType = @"audio/mpeg";
    }

    NSMutableData *body = [NSMutableData data];
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", filename] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", contentType] dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:fileData];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    NSURL *uploadURL = [NSURL URLWithString:uploadURLString];
    if (!uploadURL) {
        [self logUploadErrorWithEndpoint:uploadURLString
                                 fileURL:fileURL
                                fileSize:fileData.length
                              statusCode:0
                                  detail:@"invalid upload endpoint"
                            errorMessage:nil
                            responseData:nil];
        completion(NO, @"Invalid upload endpoint");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:uploadURL];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 120;
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    [request setValue:apiKey forHTTPHeaderField:@"X-API-Key"];
    request.HTTPBody = body;

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 120;
    configuration.timeoutIntervalForResource = 600;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];

        if (error) {
            [self logUploadErrorWithEndpoint:uploadURLString
                                     fileURL:fileURL
                                    fileSize:fileData.length
                                  statusCode:[(NSHTTPURLResponse *)response statusCode]
                                      detail:@"upload request failed"
                                errorMessage:error.localizedDescription
                                responseData:data];
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
                    [self logUploadErrorWithEndpoint:uploadURLString
                                             fileURL:fileURL
                                            fileSize:fileData.length
                                          statusCode:httpResponse.statusCode
                                              detail:@"upload API returned success=false"
                                        errorMessage:message
                                        responseData:data];
                    completion(NO, message);
                    return;
                }
            }
        }

        if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
            completion(YES, nil);
        } else {
            [self logUploadErrorWithEndpoint:uploadURLString
                                     fileURL:fileURL
                                    fileSize:fileData.length
                                  statusCode:httpResponse.statusCode
                                      detail:@"upload API returned non-2xx status"
                                errorMessage:nil
                                responseData:data];
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
