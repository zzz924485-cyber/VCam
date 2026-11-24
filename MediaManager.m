#import "MediaManager.h"
#import <CoreImage/CoreImage.h>

@interface MediaManager ()
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) int64_t frameIndex;
@property (nonatomic, strong) NSLock *readerLock;
@end

@implementation MediaManager

+ (instancetype)sharedManager {
    static MediaManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MediaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = VCamModeBlack;
        _loopPlayback = YES;
        _isRunning = NO;
        _videoSize = CGSizeMake(1080, 1920);
        _decodeQueue = dispatch_queue_create("com.vcam.decode", DISPATCH_QUEUE_SERIAL);
        _readerLock = [[NSLock alloc] init];
        _startTime = kCMTimeZero;
        _frameIndex = 0;
    }
    return self;
}

#pragma mark - Media Loading

- (void)loadMediaFromURL:(NSURL *)url {
    if (!url) return;
    [_readerLock lock];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    if (!asset) {
        [_readerLock unlock];
        return;
    }
    
    self.currentAsset = asset;
    self.videoDuration = asset.duration;
    
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count > 0) {
        AVAssetTrack *track = tracks.firstObject;
        CGSize size = track.naturalSize;
        CGAffineTransform t = track.preferredTransform;
        size = CGSizeApplyAffineTransform(size, t);
        size.width = fabs(size.width);
        size.height = fabs(size.height);
        if (size.width > 0 && size.height > 0) {
            self.videoSize = size;
        }
    }
    
    [self resetReadersInternal];
    self.mode = VCamModeVideo;
    [_readerLock unlock];
}

- (void)resetReaders {
    [_readerLock lock];
    [self resetReadersInternal];
    [_readerLock unlock];
}

- (void)resetReadersInternal {
    NSError *error = nil;
    if (self.videoReader) {
        [self.videoReader cancelReading];
        self.videoReader = nil;
        self.videoOutput = nil;
    }
    if (self.currentAsset) {
        self.videoReader = [AVAssetReader assetReaderWithAsset:self.currentAsset error:&error];
        NSArray<AVAssetTrack *> *videoTracks = [self.currentAsset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count > 0) {
            // 使用 iOS 相机标准 VideoRange (420v) 格式，完美兼容微信与 Telegram 管线
            NSDictionary *settings = @{
                (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };
            self.videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTracks.firstObject
                                                                          outputSettings:settings];
            self.videoOutput.alwaysCopiesSampleData = NO;
            if ([self.videoReader canAddOutput:self.videoOutput]) {
                [self.videoReader addOutput:self.videoOutput];
            }
        }
        [self.videoReader startReading];
    }
}

#pragma mark - Frame Generation

- (CMSampleBufferRef)nextVideoFrame {
    [_readerLock lock];
    if (self.mode != VCamModeVideo || !self.videoOutput) {
        [_readerLock unlock];
        return NULL;
    }
    
    CMSampleBufferRef sample = NULL;
    if (self.videoReader.status == AVAssetReaderStatusReading) {
        sample = [self.videoOutput copyNextSampleBuffer];
    }
    
    if (!sample) {
        if (self.loopPlayback) {
            [self resetReadersInternal];
            if (self.videoReader.status == AVAssetReaderStatusReading) {
                sample = [self.videoOutput copyNextSampleBuffer];
            }
        }
        if (!sample) {
            [_readerLock unlock];
            return NULL;
        }
    }
    
    CMTime now = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
    CMSampleBufferRef copy = NULL;
    CMSampleBufferCreateCopy(kCFAllocatorDefault, sample, &copy);
    if (copy) {
        CMSampleBufferSetOutputPresentationTimeStamp(copy, now);
    }
    CFRelease(sample);
    [_readerLock unlock];
    
    return copy;
}

- (CMSampleBufferRef)nextAudioFrame {
    return NULL;
}

- (CMSampleBufferRef)generateBlackFrameWithSize:(CGSize)size presentationTime:(CMTime)pts {
    return NULL;
}

#pragma mark - Lifecycle

- (void)start {
    self.isRunning = YES;
    self.startTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
}

- (void)stop {
    self.isRunning = NO;
}

@end
