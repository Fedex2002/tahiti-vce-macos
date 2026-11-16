// vdisplay: create a virtual display for a headless Mac (no monitor attached to the GPU).
// Without a display macOS falls back to a 1280x1024 phantom screen; remote-desktop tools then stream that.
// Uses the private CGVirtualDisplay API of CoreGraphics (the one BetterDisplay / DeskPad use) and offers modes
// up to 1920x1080@60, the maximum the VCE 1.0 encoder handles. It must keep running inside the user's GUI
// session (see README for a LaunchAgent).
//   clang -fobjc-arc -o vdisplay vdisplay.m -framework Cocoa -framework CoreGraphics
#import <Cocoa/Cocoa.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.queue = dispatch_get_main_queue();
        d.name = @"Virtual 1080p";
        d.maxPixelsWide = 1920; d.maxPixelsHigh = 1080;
        d.sizeInMillimeters = CGSizeMake(527, 296);   // ~24 inch: 92 dpi, no scaling
        d.productID = 0x1080; d.vendorID = 0x3456; d.serialNum = 1;
        CGVirtualDisplay *vd = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.hiDPI = 0;
        s.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:1920 height:1080 refreshRate:60],
                     [[CGVirtualDisplayMode alloc] initWithWidth:1600 height:900 refreshRate:60],
                     [[CGVirtualDisplayMode alloc] initWithWidth:1440 height:810 refreshRate:60],
                     [[CGVirtualDisplayMode alloc] initWithWidth:1280 height:720 refreshRate:60] ];
        BOOL ok = [vd applySettings:s];
        NSLog(@"vdisplay: id=%u applySettings=%d", vd.displayID, ok);
        if (!vd || !ok) return 1;
        [NSApp run];
    }
    return 0;
}
