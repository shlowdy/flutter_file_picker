#import "FilePickerPlugin.h"
#import "FileUtils.h"
#import "ImageUtils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#ifdef PICKER_MEDIA
@import DKImagePickerController;

@interface FilePickerPlugin() <DKImageAssetExporterObserver>
#else
@interface FilePickerPlugin()
#endif
@property (nonatomic) FlutterResult result;
@property (nonatomic) FlutterEventSink eventSink;
#ifdef PICKER_MEDIA
@property (nonatomic) UIImagePickerController *galleryPickerController;
#endif
#ifdef PICKER_DOCUMENT
@property (nonatomic) UIDocumentPickerViewController *documentPickerController;
@property (nonatomic) UIDocumentInteractionController *interactionController;
#endif
@property (nonatomic) MPMediaPickerController *audioPickerController;
@property (nonatomic) NSArray<NSString *> * allowedExtensions;
@property (nonatomic) BOOL loadDataToMemory;
@property (nonatomic) BOOL allowCompression;
@property (nonatomic) dispatch_group_t group;
@property (nonatomic) BOOL isDirectory;
@end

@implementation FilePickerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"miguelruivo.flutter.plugins.filepicker"
                                     binaryMessenger:[registrar messenger]];
    
    FlutterEventChannel* eventChannel = [FlutterEventChannel
                                         eventChannelWithName:@"miguelruivo.flutter.plugins.filepickerevent"
                                         binaryMessenger:[registrar messenger]];
    
    FilePickerPlugin* instance = [[FilePickerPlugin alloc] init];
    
    [registrar addMethodCallDelegate:instance channel:channel];
    [eventChannel setStreamHandler:instance];
}

- (instancetype)init {
    self = [super init];
    
    return self;
}

- (UIViewController *)viewControllerWithWindow:(UIWindow *)window {
    UIWindow *windowToUse = window;
    if (windowToUse == nil) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window.isKeyWindow) {
                windowToUse = window;
                break;
            }
        }
    }
    
    UIViewController *topController = windowToUse.rootViewController;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    _eventSink = events;
    return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
    _eventSink = nil;
    return nil;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if (_result) {
        result([FlutterError errorWithCode:@"multiple_request"
                                   message:@"Cancelled by a second request"
                                   details:nil]);
        _result = nil;
        return;
    }
    
    _result = result;
    
    if([call.method isEqualToString:@"clear"]) {
        _result([NSNumber numberWithBool: [FileUtils clearTemporaryFiles]]);
        _result = nil;
        return;
    }
    
    if([call.method isEqualToString:@"dir"]) {
        if (@available(iOS 13, *)) {
#ifdef PICKER_DOCUMENT
            [self resolvePickDocumentWithMultiPick:NO pickDirectory:YES];
#else
            _result([FlutterError errorWithCode:@"Unsupported picker type"
                                        message:@"Support for the Document picker is not compiled in. Remove the Pod::PICKER_DOCUMENT=false statement from your Podfile."
                                        details:nil]);
#endif
        } else {
            _result([self getDocumentDirectory]);
            _result = nil;
        }
        return;
    }
    
    NSDictionary * arguments = call.arguments;
    BOOL isMultiplePick = ((NSNumber*)[arguments valueForKey:@"allowMultipleSelection"]).boolValue;
    
    self.allowCompression = ((NSNumber*)[arguments valueForKey:@"allowCompression"]).boolValue;
    self.loadDataToMemory = ((NSNumber*)[arguments valueForKey:@"withData"]).boolValue;
    
    if([call.method isEqualToString:@"any"] || [call.method containsString:@"custom"]) {
        self.allowedExtensions = [FileUtils resolveType:call.method withAllowedExtensions: [arguments valueForKey:@"allowedExtensions"]];
        if(self.allowedExtensions == nil) {
            _result([FlutterError errorWithCode:@"Unsupported file extension"
                                        message:@"If you are providing extension filters make sure that you are only using FileType.custom and the extension are provided without the dot, (ie., jpg instead of .jpg). This could also have happened because you are using an unsupported file extension. If the problem persists, you may want to consider using FileType.all instead."
                                        details:nil]);
            _result = nil;
        } else if(self.allowedExtensions != nil) {
#ifdef PICKER_DOCUMENT
            [self resolvePickDocumentWithMultiPick:isMultiplePick pickDirectory:NO];
#else
            _result([FlutterError errorWithCode:@"Unsupported picker type"
                                        message:@"Support for the Document picker is not compiled in. Remove the Pod::PICKER_DOCUMENT=false statement from your Podfile."
                                        details:nil]);
#endif
        }
    } else if([call.method isEqualToString:@"video"] || [call.method isEqualToString:@"image"] || [call.method isEqualToString:@"media"]) {
#ifdef PICKER_MEDIA
        [self resolvePickMedia:[FileUtils resolveMediaType:call.method] withMultiPick:isMultiplePick withCompressionAllowed:self.allowCompression];
#else
        _result([FlutterError errorWithCode:@"Unsupported picker type"
                                    message:@"Support for the Media picker is not compiled in. Remove the Pod::PICKER_MEDIA=false statement from your Podfile."
                                    details:nil]);
#endif
    } else if([call.method isEqualToString:@"audio"]) {
 #ifdef PICKER_AUDIO
       [self resolvePickAudioWithMultiPick: isMultiplePick];
 #else
        _result([FlutterError errorWithCode:@"Unsupported picker type"
                                    message:@"Support for the Audio picker is not compiled in. Remove the Pod::PICKER_AUDIO=false statement from your Podfile."
                                    details:nil]);
#endif      
    } else {
        result(FlutterMethodNotImplemented);
        _result = nil;
    }
}

- (NSString*)getDocumentDirectory {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject;
}

#pragma mark - Resolvers

#ifdef PICKER_DOCUMENT
- (void)resolvePickDocumentWithMultiPick:(BOOL)allowsMultipleSelection pickDirectory:(BOOL)isDirectory {
    self.isDirectory = isDirectory;
    @try{
        self.documentPickerController = [[UIDocumentPickerViewController alloc]
                                         initWithDocumentTypes: isDirectory ? @[@"public.folder"] : self.allowedExtensions
                                         inMode: isDirectory ? UIDocumentPickerModeOpen : UIDocumentPickerModeImport];
    } @catch (NSException * e) {
        Log(@"Couldn't launch documents file picker. Probably due to iOS version being below 11.0 and not having the iCloud entitlement. If so, just make sure to enable it for your app in Xcode. Exception was: %@", e);
        _result = nil;
        return;
    }
    
    if (@available(iOS 11.0, *)) {
        self.documentPickerController.allowsMultipleSelection = allowsMultipleSelection;
    } else if(allowsMultipleSelection) {
        Log(@"Multiple file selection is only supported on iOS 11 and above. Single selection will be used.");
    }
    
    self.documentPickerController.delegate = self;
    self.documentPickerController.presentationController.delegate = self;
    
    [[self viewControllerWithWindow:nil] presentViewController:self.documentPickerController animated:YES completion:nil];
}
#endif // PICKER_DOCUMENT

#ifdef PICKER_MEDIA
- (void) resolvePickMedia:(MediaType)type withMultiPick:(BOOL)multiPick withCompressionAllowed:(BOOL)allowCompression  {
    
#ifdef PHPicker
    if (@available(iOS 14, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = type == IMAGE ? [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter livePhotosFilter], [PHPickerFilter imagesFilter]]] : type == VIDEO ? [PHPickerFilter videosFilter] : [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter videosFilter], [PHPickerFilter imagesFilter], [PHPickerFilter livePhotosFilter]]];
        config.preferredAssetRepresentationMode = self.allowCompression ? PHPickerConfigurationAssetRepresentationModeCompatible : PHPickerConfigurationAssetRepresentationModeCurrent;
        
        if(multiPick) {
            config.selectionLimit = 0;
        }
        
        PHPickerViewController *pickerViewController = [[PHPickerViewController alloc] initWithConfiguration:config];
        pickerViewController.delegate = self;
        pickerViewController.presentationController.delegate = self;
        [[self viewControllerWithWindow:nil] presentViewController:pickerViewController animated:YES completion:nil];
        return;
    }
#endif
    
    [self resolveMultiPickFromGallery:type multi:multiPick withCompressionAllowed:allowCompression];
    return;
}

- (void) resolveMultiPickFromGallery:(MediaType)type multi:(BOOL)multiPick withCompressionAllowed:(BOOL)allowCompression {
    DKImagePickerController * dkImagePickerController = [[DKImagePickerController alloc] init];
    
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"" message:@"" preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView* indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    
    UIViewController *currentViewController = [self viewControllerWithWindow:nil];
    if(_eventSink == nil) {
        // Create alert dialog for asset caching
        [alert.view setCenter: currentViewController.view.center];
        [alert.view addConstraint: [NSLayoutConstraint constraintWithItem:alert.view attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:100]];
        
        // Create a default loader if user don't provide a status handler
        indicator.hidesWhenStopped = YES;
        [indicator setCenter: alert.view.center];
        indicator.autoresizingMask = (UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleTopMargin);
        [alert.view addSubview: indicator];
    }
    
    if (@available(iOS 11.0, *)) {
        DKImageAssetExporterConfiguration * exportConfiguration = [[DKImageAssetExporterConfiguration alloc] init];
        exportConfiguration.imageExportPreset = allowCompression ? DKImageExportPresentCompatible : DKImageExportPresentCurrent;
        exportConfiguration.videoExportPreset = allowCompression ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough;
        dkImagePickerController.exporter = [dkImagePickerController.exporter initWithConfiguration:exportConfiguration];
    }
    
    dkImagePickerController.exportsWhenCompleted = YES;
    dkImagePickerController.showsCancelButton = YES;
    dkImagePickerController.sourceType = DKImagePickerControllerSourceTypePhoto;
    dkImagePickerController.assetType = type == VIDEO ? DKImagePickerControllerAssetTypeAllVideos : type == IMAGE ? DKImagePickerControllerAssetTypeAllPhotos : DKImagePickerControllerAssetTypeAllAssets;
    dkImagePickerController.singleSelect = !multiPick;
    
    // Export status changed
    [dkImagePickerController setExportStatusChanged:^(enum DKImagePickerControllerExportStatus status) {
        
        if(status == DKImagePickerControllerExportStatusExporting && dkImagePickerController.selectedAssets.count > 0){
            Log("Exporting assets, this operation may take a while if remote (iCloud) assets are being cached.");
            
            if(self->_eventSink != nil){
                self->_eventSink([NSNumber numberWithBool:YES]);
            } else {
                [indicator startAnimating];
                [currentViewController showViewController:alert sender:nil];
            }
            
        } else {
            if(self->_eventSink != nil) {
                self->_eventSink([NSNumber numberWithBool:NO]);
            } else {
                [indicator stopAnimating];
                [alert dismissViewControllerAnimated:YES completion:nil];
            }
            
        }
    }];
    
    // Did cancel
    [dkImagePickerController setDidCancel:^(){
        self->_result(nil);
        self->_result = nil;
    }];
    
    // Did select
    [dkImagePickerController setDidSelectAssets:^(NSArray<DKAsset*> * __nonnull DKAssets) {
        NSMutableArray<NSURL*>* paths = [[NSMutableArray<NSURL*> alloc] init];
        NSFileManager *manager = NSFileManager.defaultManager;
        for(DKAsset * asset in DKAssets) {
            if(asset.localTemporaryPath.absoluteURL != nil) {
                NSURL *target = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:asset.fileName]];
                if ([manager fileExistsAtPath:target.path]) {
                    [manager removeItemAtURL:target error:nil];
                }
                [manager moveItemAtURL:asset.localTemporaryPath.absoluteURL toURL:target error:nil];
                [paths addObject:target];
            }
        }
        
        [self handleResult: paths];
    }];
    
    [[self viewControllerWithWindow:nil] presentViewController:dkImagePickerController animated:YES completion:nil];
}
#endif // PICKER_MEDIA

#ifdef PICKER_AUDIO
- (void) resolvePickAudioWithMultiPick:(BOOL)isMultiPick {
    
    
    self.audioPickerController = [[MPMediaPickerController alloc] initWithMediaTypes:MPMediaTypeAnyAudio];
    self.audioPickerController.delegate = self;
    self.audioPickerController.presentationController.delegate = self;
    self.audioPickerController.showsCloudItems = YES;
    self.audioPickerController.allowsPickingMultipleItems = isMultiPick;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if([self viewControllerWithWindow:nil].presentedViewController == nil){
            Log("Exporting assets, this operation may take a while if remote (iCloud) assets are being cached.");
        }
    });

    
    [[self viewControllerWithWindow:nil] presentViewController:self.audioPickerController animated:YES completion:nil];
}
#endif // PICKER_AUDIO


- (void) handleResult:(id) files {
    _result([FileUtils resolveFileInfo: [files isKindOfClass: [NSArray class]] ? files : @[files] withData:self.loadDataToMemory]);
    _result = nil;
}

#pragma mark - Delegates

#ifdef PICKER_DOCUMENT

// DocumentPicker delegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls{
    
    if(_result == nil) {
        return;
    }
    
    [self.documentPickerController dismissViewControllerAnimated:YES completion:nil];
    
    if(self.isDirectory) {
        _result([urls objectAtIndex:0].path);
        _result = nil;
        return;
    } else {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSMutableArray *result = [NSMutableArray array];
        for (NSURL *url in urls) {
            NSString *name = url.lastPathComponent;
            NSURL *target = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
            if ([manager fileExistsAtPath:target.path]) {
                [manager removeItemAtURL:target error:nil];
            }
            BOOL moved = [manager moveItemAtURL:url toURL:target error:nil];
            if (moved) {
                [result addObject:target];
            }
        }
        [self handleResult:result];
    }
}
#endif // PICKER_DOCUMENT

#ifdef PICKER_MEDIA
// ImagePicker delegate
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    if(_result == nil) {
        return;
    }
    
    NSURL *pickedVideoUrl = [info objectForKey:UIImagePickerControllerMediaURL];
    NSURL *pickedImageUrl;
    
    if(@available(iOS 13.0, *)) {
        
        if(pickedVideoUrl != nil) {
            NSString * fileName = [pickedVideoUrl lastPathComponent];
            NSURL * destination = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];

            if([[NSFileManager defaultManager] isReadableFileAtPath: [pickedVideoUrl path]]) {
                Log(@"Caching video file for iOS 13 or above...");
                [[NSFileManager defaultManager] moveItemAtURL:pickedVideoUrl toURL:destination error:nil];
                pickedVideoUrl = destination;
            }
        } else {
            pickedImageUrl = [info objectForKey:UIImagePickerControllerImageURL];
        }
        
    } else if (@available(iOS 11.0, *)) {
        pickedImageUrl = [info objectForKey:UIImagePickerControllerImageURL];
    } else {
        UIImage *pickedImage  = [info objectForKey:UIImagePickerControllerEditedImage];
        
        if(pickedImage == nil) {
            pickedImage = [info objectForKey:UIImagePickerControllerOriginalImage];
        }
        pickedImageUrl = [ImageUtils saveTmpImage:pickedImage];
    }
    
    [picker dismissViewControllerAnimated:YES completion:NULL];
    
    if(pickedImageUrl == nil && pickedVideoUrl == nil) {
        _result([FlutterError errorWithCode:@"file_picker_error"
                                    message:@"Temporary file could not be created"
                                    details:nil]);
        _result = nil;
        return;
    }
    
    [self handleResult: pickedVideoUrl != nil ? pickedVideoUrl : pickedImageUrl];
}

#ifdef PHPicker

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14)) {
    if (_result == nil) {
        return;
    }
    if (self.group != nil) {
        return;
    }
    Log(@"Picker:%@ didFinishPicking:%@", picker, results);
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) {
        Log(@"FilePicker canceled");
        _result(nil);
        _result = nil;
        return;
    }
    NSMutableArray<NSURL *> *urls = [[NSMutableArray alloc] initWithCapacity:results.count];
    self.group = dispatch_group_create();
    if (self->_eventSink != nil) {
        self->_eventSink(@YES);
    }
    __block NSError *blockError;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (PHPickerResult *result in results) {
        dispatch_group_enter(_group);
        [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeItem.identifier completionHandler:^(NSURL *url, NSError *error) {
            if (url == nil) {
                blockError = error;
                Log("Could not load the picked given file: %@", blockError);
                dispatch_group_leave(self->_group);
                return;
            }
            NSString *fileName = url.lastPathComponent;
            NSString *extension = fileName.pathExtension;
            NSURL *cachedURL;
            if ([extension isEqualToString:@"pvt"]) {
                NSArray *children = [fileManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
                if (self.allowCompression) {
                    for (NSURL *child in children) {
                        if (UTTypeConformsTo(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, CFBridgingRetain(child.pathExtension), NULL), kUTTypeImage)) {
                            NSData *raw = [NSData dataWithContentsOfURL:child];
                            NSData *jpg = UIImageJPEGRepresentation([UIImage imageWithData:raw], 0.8);
                            NSString *name = fileName.stringByDeletingPathExtension;
                            NSString *target = [NSTemporaryDirectory() stringByAppendingPathComponent:[name stringByAppendingString:@".jpeg"]];
                            cachedURL = [NSURL fileURLWithPath:target];
                            if ([fileManager fileExistsAtPath:target]) {
                                [fileManager removeItemAtPath:target error:nil];
                            }
                            if ([fileManager createFileAtPath:target contents:jpg attributes:nil]) {
                                [urls addObject:cachedURL];
                            }
                        }
                    }
                } else {
                    for (NSURL *child in children) {
                        if (UTTypeConformsTo(UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, CFBridgingRetain(child.pathExtension), NULL), kUTTypeImage)) {
                            NSString *target = [NSTemporaryDirectory() stringByAppendingPathComponent:child.lastPathComponent];
                            if ([fileManager fileExistsAtPath:target]) {
                                [fileManager removeItemAtPath:target error:NULL];
                            }
                            cachedURL = [NSURL fileURLWithPath:target];
                            if ([fileManager moveItemAtURL:child toURL:cachedURL error:nil]) {
                                [urls addObject:cachedURL];
                            }
                        }
                    }
                }
                dispatch_group_leave(self->_group);
            } else {
                NSString *cachedFile = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
                if ([fileManager fileExistsAtPath:cachedFile]) {
                    [fileManager removeItemAtPath:cachedFile error:NULL];
                }
                cachedURL = [NSURL fileURLWithPath:cachedFile];
                if ([fileManager moveItemAtURL:url toURL:cachedURL error:nil]) {
                    [urls addObject:cachedURL];
                }
                dispatch_group_leave(self->_group);
            }
        }];
    }
    dispatch_group_notify(_group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self->_group = nil;
        if (self->_eventSink != nil) {
            self->_eventSink([NSNumber numberWithBool:NO]);
        }
        if (blockError) {
            self->_result([FlutterError errorWithCode:@"file_picker_error"
                                              message:@"Temporary file could not be created"
                                              details:blockError.description]);
            self->_result = nil;
            return;
        }
        [self handleResult:urls];
    });
}

#endif // PHPicker
#endif // PICKER_MEDIA

#ifdef PICKER_AUDIO
// AudioPicker delegate
- (void)mediaPicker: (MPMediaPickerController *)mediaPicker didPickMediaItems:(MPMediaItemCollection *)mediaItemCollection
{
    [mediaPicker dismissViewControllerAnimated:YES completion:NULL];
    int numberOfItems = (int)[mediaItemCollection items].count;
    
    if(numberOfItems == 0) {
        return;
    }
    
    if(_eventSink != nil) {
        _eventSink([NSNumber numberWithBool:YES]);
    }
    
    NSMutableArray<NSURL *> * urls = [[NSMutableArray alloc] initWithCapacity:numberOfItems];
    
    for(MPMediaItemCollection * item in [mediaItemCollection items]) {
        NSURL * cachedAsset = [FileUtils exportMusicAsset: [item valueForKey:MPMediaItemPropertyAssetURL] withName: [item valueForKey:MPMediaItemPropertyTitle]];
        [urls addObject: cachedAsset];
    }
    
    if(_eventSink != nil) {
        _eventSink([NSNumber numberWithBool:NO]);
    }
    
    if(urls.count == 0) {
        Log(@"Couldn't retrieve the audio file path, either is not locally downloaded or the file is DRM protected.");
    }
    [self handleResult:urls];
}
#endif // PICKER_AUDIO

#pragma mark - Actions canceled

#ifdef PICKER_MEDIA
- (void)presentationControllerDidDismiss:(UIPresentationController *)controller {
    Log(@"FilePicker canceled");
    if (self.result != nil) {
        self.result(nil);
        self.result = nil;
    }
}
#endif // PICKER_MEDIA

#ifdef PICKER_AUDIO
- (void)mediaPickerDidCancel:(MPMediaPickerController *)controller {
    Log(@"FilePicker canceled");
    _result(nil);
    _result = nil;
    [controller dismissViewControllerAnimated:YES completion:NULL];
}
#endif // PICKER_AUDIO

#ifdef PICKER_DOCUMENT
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    Log(@"FilePicker canceled");
    _result(nil);
    _result = nil;
    [controller dismissViewControllerAnimated:YES completion:NULL];
}
#endif // PICKER_DOCUMENT

#ifdef PICKER_MEDIA
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    Log(@"FilePicker canceled");
    _result(nil);
    _result = nil;
    [picker dismissViewControllerAnimated:YES completion:NULL];
}
#endif

#pragma mark - Alert dialog


@end
