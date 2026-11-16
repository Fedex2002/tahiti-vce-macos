// vtenc: test the VideoToolbox hardware H.264 encoder (VCE via AppleGVA + AMDRadeonVADriver).
// Generates N NV12 frames with a moving test pattern, encodes them REQUIRING a hardware encoder, and writes
// the result as an Annex-B elementary stream plus an .mp4 (passthrough) that you can open in QuickTime.
//
//   clang -fobjc-arc -O2 -o vtenc vtenc.m -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
//         -framework Foundation -framework AVFoundation
//   ./vtenc [width height frames fps bitrate out.h264] [rt]
//
// "rt" as a 7th argument sets kVTCompressionPropertyKey_RealTime. FAST=1 in the environment feeds flat frames
// (no per-pixel pattern generation on the CPU), to measure the encoder alone.
//
// What to look for:
//   create rc=0 + "using hardware: YES"   the hardware encoder was selected
//   frame 0: ~30 KB, nal: 5               an IDR slice with a sane size
//   frame N: nal: 1                       P slices
// A broken setup shows create rc=-12903 (no hardware encoder) or frames the size of the whole
// bitstream buffer filled with zeros ("nal: BAD(0)").
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>

static FILE *out;
static AVAssetWriter *mw; static AVAssetWriterInput *mi;
static int nOut = 0, nErr = 0;
static double tSubmit[100000], latSum = 0, latMax = 0;   // per-frame latency (submit -> callback)
static long totalBytes = 0;

static void writeParamSets(CMFormatDescriptionRef fmt) {
    size_t count = 0; int nalLen = 0;
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &count, &nalLen);
    for (size_t i = 0; i < count; i++) {
        const uint8_t *ps; size_t sz;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &sz, NULL, NULL) == noErr) {
            fwrite("\0\0\0\1", 1, 4, out); fwrite(ps, 1, sz, out);
            printf("  parameter set %zu: %zu bytes, nal type %d\n", i, sz, ps[0] & 0x1f);
        }
    }
}

static void cb(void *refcon, void *frameRefcon, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    long idx = (long)frameRefcon;
    double lat = (CFAbsoluteTimeGetCurrent() - tSubmit[idx]) * 1000; latSum += lat; if (lat > latMax) latMax = lat;
    if (status != noErr || !sb) { nErr++; printf("frame %ld: status=%d\n", idx, (int)status); return; }
    if (!mw) {
        [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/vtenc.mp4" error:nil];
        mw = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:@"/tmp/vtenc.mp4"] fileType:AVFileTypeMPEG4 error:nil];
        mi = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil
                                              sourceFormatHint:CMSampleBufferGetFormatDescription(sb)];
        [mw addInput:mi]; [mw startWriting]; [mw startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sb)];
    }
    for (int t = 0; t < 200 && !mi.readyForMoreMediaData; t++) usleep(5000);
    if (![mi appendSampleBuffer:sb]) printf("mp4 append failed: %s\n", mw.error.description.UTF8String);

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    if (nOut == 0) writeParamSets(CMSampleBufferGetFormatDescription(sb));
    uint8_t *buf = malloc(len ? len : 1);
    if (len) CMBlockBufferCopyDataBytes(bb, 0, len, buf);
    // AVCC (4-byte length prefix) -> Annex-B
    size_t p = 0; char types[128] = "";
    while (p + 4 <= len) {
        uint32_t n = (buf[p] << 24) | (buf[p + 1] << 16) | (buf[p + 2] << 8) | buf[p + 3];
        if (n == 0 || p + 4 + n > len) { snprintf(types + strlen(types), 16, " BAD(%u)", n); break; }
        fwrite("\0\0\0\1", 1, 4, out); fwrite(buf + p + 4, 1, n, out);
        snprintf(types + strlen(types), 16, " %d", buf[p + 4] & 0x1f);
        p += 4 + n;
    }
    if (idx < 8 || len == 0) printf("frame %ld: %zu bytes, nal:%s\n", idx, len, types);
    free(buf);
    nOut++; totalBytes += len;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int w = argc > 1 ? atoi(argv[1]) : 1280, h = argc > 2 ? atoi(argv[2]) : 720, n = argc > 3 ? atoi(argv[3]) : 60;
        int fps = argc > 4 ? atoi(argv[4]) : 30, br = argc > 5 ? atoi(argv[5]) : 4000000;
        const char *path = argc > 6 ? argv[6] : "/tmp/vtenc.h264";
        BOOL rt = argc > 7, fast = getenv("FAST") != NULL;
        if (n > 100000) n = 100000;
        out = fopen(path, "wb");
        NSDictionary *spec = @{ (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES };
        VTCompressionSessionRef s = NULL;
        OSStatus rc = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_H264, (__bridge CFDictionaryRef)spec,
                                                 NULL, NULL, cb, NULL, &s);
        printf("create rc=%d\n", (int)rc);
        if (rc) return 1;
        CFBooleanRef hw = NULL;
        VTSessionCopyProperty(s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, NULL, &hw);
        printf("using hardware: %s\n", hw == kCFBooleanTrue ? "YES" : "no");
        VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel);
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(br));
        VTSessionSetProperty(s, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@(fps));
        VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@(fps * 2));
        VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        if (rt) VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        rc = VTCompressionSessionPrepareToEncodeFrames(s);
        printf("prepare rc=%d\n", (int)rc);

        NSDictionary *pbAttrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        for (long i = 0; i < n; i++) {
            CVPixelBufferRef pb = NULL;
            CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                (__bridge CFDictionaryRef)pbAttrs, &pb);
            CVPixelBufferLockBaseAddress(pb, 0);
            uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0); size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
            uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1); size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
            if (fast) {
                memset(y, 60 + (i % 64), ys * h); memset(uv, 128, uvs * (h / 2));
            } else {
                // scrolling luma ramp over a checkerboard, with a chroma gradient
                for (int r = 0; r < h; r++) for (int c = 0; c < w; c++)
                    y[r * ys + c] = (uint8_t)(16 + ((c + i * 8) % 200) / 2 + ((r / 32 + c / 32) % 2) * 60);
                for (int r = 0; r < h / 2; r++) for (int c = 0; c < w / 2; c++) {
                    uv[r * uvs + 2 * c] = (uint8_t)(64 + (r * 128) / (h / 2));
                    uv[r * uvs + 2 * c + 1] = (uint8_t)(64 + (c * 128) / (w / 2));
                }
            }
            // moving white square
            int bx = (int)((i * 16) % (w - 96)), by = h / 2 - 48;
            for (int r = 0; r < 96; r++) memset(y + (by + r) * ys + bx, 235, 96);
            CVPixelBufferUnlockBaseAddress(pb, 0);
            tSubmit[i] = CFAbsoluteTimeGetCurrent();
            rc = VTCompressionSessionEncodeFrame(s, pb, CMTimeMake(i, fps), CMTimeMake(1, fps), NULL, (void *)i, NULL);
            if (rc) printf("encode %ld rc=%d\n", i, (int)rc);
            CVPixelBufferRelease(pb);
        }
        rc = VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
        double dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("latency: mean %.1f ms, max %.1f ms\n", nOut ? latSum / nOut : 0, latMax);
        printf("complete rc=%d | in=%d out=%d err=%d | %ld bytes | %.1f fps | %s\n", (int)rc, n, nOut, nErr, totalBytes, n / dt, path);
        if (mw) {
            [mi markAsFinished];
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [mw finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
            printf("mp4: %s (/tmp/vtenc.mp4)\n", mw.status == AVAssetWriterStatusCompleted ? "ok" : mw.error.description.UTF8String);
        }
        VTCompressionSessionInvalidate(s); CFRelease(s); fclose(out);
    }
    return 0;
}
