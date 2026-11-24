#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "MediaManager.h"

static BOOL g_vcamEnabled = NO;
static UIWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;
static NSHashTable *g_previewLayers = nil;
static dispatch_source_t g_previewTimer = nil;
static CIContext *g_ciContext = nil;

// ============================================================================
// MARK: - 同步刷新屏幕取景框预览层 (AVCaptureVideoPreviewLayer)
// ============================================================================

static void updatePreviewLayersWithSample(CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer || !g_previewLayers) return;
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;
    
    if (!g_ciContext) {
        g_ciContext = [CIContext contextWithOptions:nil];
    }
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CGImageRef cgImage = [g_ciContext createCGImage:ciImage fromRect:ciImage.extent];
    if (!cgImage) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        for (AVCaptureVideoPreviewLayer *layer in [g_previewLayers allObjects]) {
            CALayer *fakeSub = [layer viewWithTag:998877] ? nil : nil;
            CALayer *overlay = nil;
            for (CALayer *sub in layer.sublayers) {
                if ([sub.name isEqualToString:@"VCamPreviewOverlay"]) {
                    overlay = sub;
                    break;
                }
            }
            if (!overlay) {
                overlay = [CALayer layer];
                overlay.name = @"VCamPreviewOverlay";
                overlay.contentsGravity = kCAGravityResizeAspectFill;
                overlay.masksToBounds = YES;
                [layer addSublayer:overlay];
            }
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            overlay.frame = layer.bounds;
            overlay.hidden = !g_vcamEnabled;
            overlay.contents = (__bridge id)cgImage;
            [CATransaction commit];
        }
        CGImageRelease(cgImage);
    });
}

static void clearPreviewOverlays(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (AVCaptureVideoPreviewLayer *layer in [g_previewLayers allObjects]) {
            for (CALayer *sub in layer.sublayers) {
                if ([sub.name isEqualToString:@"VCamPreviewOverlay"]) {
                    sub.hidden = YES;
                    sub.contents = nil;
                }
            }
        }
    });
}

// ============================================================================
// MARK: - 点击穿透窗口 & 悬浮按钮 UI
// ============================================================================

@interface VCamPassThroughWindow : UIWindow
@end

@implementation VCamPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }
    return hitView;
}
@end

@interface VCamFloatButton : UIButton
@end

@implementation VCamFloatButton
@end

static void handlePanGesture(UIPanGestureRecognizer *gesture) {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
    
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat x = btn.center.x < screen.size.width / 2 ? 35 : screen.size.width - 35;
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(x, btn.center.y);
        }];
    }
}

@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker 
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (url) {
        // 同步拷贝到持久目录，防止相册选择器关闭后临时文件被系统清理
        NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSURL *savedURL = [NSURL fileURLWithPath:[docDir stringByAppendingPathComponent:@"vcam_active.mp4"]];
        [[NSFileManager defaultManager] removeItemAtURL:savedURL error:nil];
        NSError *copyErr = nil;
        [[NSFileManager defaultManager] copyItemAtURL:url toURL:savedURL error:&copyErr];
        
        NSURL *finalURL = copyErr ? url : savedURL;
        [[MediaManager sharedManager] loadMediaFromURL:finalURL];
        g_vcamEnabled = YES;
        [[MediaManager sharedManager] start];
        if (g_floatButton) {
            g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
        }
    }
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

@interface VCamActionHandler : NSObject
@end

@implementation VCamActionHandler
- (void)onPan:(UIPanGestureRecognizer *)gesture {
    handlePanGesture(gesture);
}

- (void)onTap:(id)sender {
    UIViewController *hostVC = g_overlayWindow.rootViewController;
    if (!hostVC) return;

    [g_overlayWindow makeKeyAndVisible];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"VCam 虚拟相机"
        message:g_vcamEnabled ? @"当前状态: 已开启 (全局替换)" : @"当前状态: 已关闭"
        preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"选择视频"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) {
            return;
        }
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
        picker.mediaTypes = @[@"public.movie"];
        picker.videoExportPreset = AVAssetExportPresetPassthrough;
        picker.delegate = g_pickerDelegate;
        [hostVC presentViewController:picker animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"关闭虚拟相机" : @"开启虚拟相机"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        g_vcamEnabled = !g_vcamEnabled;
        if (g_floatButton) {
            g_floatButton.backgroundColor = g_vcamEnabled
                ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
                : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        }
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] start];
        } else {
            [[MediaManager sharedManager] stop];
            clearPreviewOverlays();
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (alert.popoverPresentationController && g_floatButton) {
        alert.popoverPresentationController.sourceView = g_floatButton;
        alert.popoverPresentationController.sourceRect = g_floatButton.bounds;
    }

    [hostVC presentViewController:alert animated:YES completion:nil];
}
@end

static VCamActionHandler *g_actionHandler = nil;

static void setupFloatButton(void) {
    if (g_floatButton) return;
    g_actionHandler = [[VCamActionHandler alloc] init];

    CGFloat btnSize = 50;
    CGRect screen = [UIScreen mainScreen].bounds;

    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeCustom];
    g_floatButton.frame = CGRectMake(screen.size.width - btnSize - 15, 100, btnSize, btnSize);
    g_floatButton.layer.cornerRadius = btnSize / 2.0;
    g_floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;
    g_floatButton.backgroundColor = g_vcamEnabled
        ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
        : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];

    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];

    [g_floatButton addTarget:g_actionHandler action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:g_actionHandler action:@selector(onPan:)];
    [g_floatButton addGestureRecognizer:pan];

    UIWindowScene *activeScene = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
            activeScene = scene;
            break;
        }
    }

    if (activeScene) {
        g_overlayWindow = [[VCamPassThroughWindow alloc] initWithWindowScene:activeScene];
        g_overlayWindow.frame = screen;
    } else {
        g_overlayWindow = [[VCamPassThroughWindow alloc] initWithFrame:screen];
    }
    g_overlayWindow.windowLevel = UIWindowLevelStatusBar + 1000;
    g_overlayWindow.backgroundColor = [UIColor clearColor];

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    [rootVC.view addSubview:g_floatButton];
    g_overlayWindow.rootViewController = rootVC;
    g_overlayWindow.hidden = NO;
}

