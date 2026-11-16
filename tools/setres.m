// setres: change the resolution of the main display (e.g. the virtual display). No arguments: list modes.
//   clang -fobjc-arc -o setres setres.m -framework CoreGraphics -framework Foundation
//   setres 1600 900
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        CGDirectDisplayID d = CGMainDisplayID();
        NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(d, NULL));
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
        if (argc < 3) {
            for (id m in modes) { CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
                printf("%zux%zu @%.0f%s\n", CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode), CGDisplayModeGetRefreshRate(mode),
                       (CGDisplayModeGetWidth(mode) == CGDisplayModeGetWidth(cur) && CGDisplayModeGetHeight(mode) == CGDisplayModeGetHeight(cur)) ? "  <- current" : ""); }
            return 0;
        }
        size_t w = atoi(argv[1]), h = atoi(argv[2]);
        for (id m in modes) { CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
            if (CGDisplayModeGetWidth(mode) == w && CGDisplayModeGetHeight(mode) == h) {
                CGDisplayConfigRef cfg; CGBeginDisplayConfiguration(&cfg);
                CGConfigureDisplayWithDisplayMode(cfg, d, mode, NULL);
                CGError e = CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently);
                printf("%zux%zu: %s\n", w, h, e == kCGErrorSuccess ? "ok" : "error");
                return e != kCGErrorSuccess;
            } }
        printf("no hay modo %zux%zu\n", w, h);
        return 1;
    }
}
