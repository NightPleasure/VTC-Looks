#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "VTC_RenderBackend.h"
#include <dispatch/dispatch.h>
#include <cstring>

// Define VTC_METAL_LOG=1 at compile time to enable stderr trace.
// Default off -- zero overhead in release builds.
#ifndef VTC_METAL_LOG
#define VTC_METAL_LOG 0
#endif

#if VTC_METAL_LOG
#include <cstdio>
#define MLOG(fmt, ...) std::fprintf(stderr, "[VTC Metal] " fmt "\n", ##__VA_ARGS__)
#else
#define MLOG(fmt, ...)
#endif

namespace vtc {
namespace metal {

namespace {

id<MTLDevice>               g_device   = nil;
id<MTLCommandQueue>         g_queue    = nil;
id<MTLComputePipelineState> g_smokePSO = nil;
bool                        g_available   = false;
bool                        g_pipelineOK  = false;
dispatch_once_t             g_ctxOnce;
dispatch_once_t             g_psoOnce;

// Minimal passthrough compute kernel for 8bpc ARGB.
// Reads each pixel as a uint (4 bytes), writes it unchanged to dst.
// Uses separate src/dst row strides to handle AE row padding.
NSString* const kSmokeSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

kernel void smoke_passthrough(
    device const uint* src  [[buffer(0)]],
    device       uint* dst  [[buffer(1)]],
    constant     uint4& p   [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    // p.x = width, p.y = height, p.z = srcRowUints, p.w = dstRowUints
    if (gid.x >= p.x || gid.y >= p.y) return;
    dst[gid.y * p.w + gid.x] = src[gid.y * p.z + gid.x];
}
)MSL";

void InitPipeline() {
    dispatch_once(&g_psoOnce, ^{
        if (!g_device) {
            MLOG("pipeline skip: no device");
            return;
        }
        NSError* err = nil;
        id<MTLLibrary> lib = [g_device newLibraryWithSource:kSmokeSource
                                                    options:nil
                                                      error:&err];
        if (!lib) {
            MLOG("shader compile failed: %s",
                 err ? [[err localizedDescription] UTF8String] : "unknown");
            return;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"smoke_passthrough"];
        if (!fn) {
            MLOG("function lookup failed");
            return;
        }
        g_smokePSO = [g_device newComputePipelineStateWithFunction:fn error:&err];
        if (!g_smokePSO) {
            MLOG("pipeline creation failed: %s",
                 err ? [[err localizedDescription] UTF8String] : "unknown");
            return;
        }
        g_pipelineOK = true;
        MLOG("smoke pipeline ready  threadExecWidth=%lu  maxThreads=%lu",
             (unsigned long)g_smokePSO.threadExecutionWidth,
             (unsigned long)g_smokePSO.maxTotalThreadsPerThreadgroup);
    });
}

}  // anon namespace

// ── Public API ───────────────────────────────────────────────────────

bool InitContext() {
    dispatch_once(&g_ctxOnce, ^{
        g_device = MTLCreateSystemDefaultDevice();
        if (g_device) {
            g_queue = [g_device newCommandQueue];
            g_available = (g_queue != nil);
            MLOG("context init: device=%s  queue=%s",
                 g_device ? [[g_device name] UTF8String] : "nil",
                 g_queue  ? "ok" : "FAIL");
        } else {
            MLOG("context init: no Metal device");
        }
    });
    return g_available;
}

bool IsAvailable() {
    InitContext();
    return g_available;
}

bool TryDispatch(const GPUDispatchDesc& desc,
                 const void* srcData, void* dstData,
                 int srcRowBytes, int dstRowBytes) {
    // ── Gate: context ──
    if (!g_available) {
        MLOG("dispatch skip: context unavailable");
        return false;
    }

    // ── Gate: format (Phase 4 supports 8bpc only) ──
    if (desc.bytesPerPixel != 4) {
        MLOG("dispatch skip: unsupported bpp=%d (only 8bpc/4 in Phase 4)",
             desc.bytesPerPixel);
        return false;
    }

    // ── Gate: pipeline ──
    InitPipeline();
    if (!g_pipelineOK) {
        MLOG("dispatch skip: pipeline not ready");
        return false;
    }

    const int w = desc.frameWidth;
    const int h = desc.frameHeight;
    if (w <= 0 || h <= 0) return false;

    const NSUInteger srcSize = (NSUInteger)h * (NSUInteger)srcRowBytes;
    const NSUInteger dstSize = (NSUInteger)h * (NSUInteger)dstRowBytes;

    // ── Create buffers ──
    @autoreleasepool {
        id<MTLBuffer> srcBuf = [g_device newBufferWithBytes:srcData
                                                     length:srcSize
                                                    options:MTLResourceStorageModeShared];
        if (!srcBuf) { MLOG("dispatch fail: srcBuf alloc"); return false; }

        id<MTLBuffer> dstBuf = [g_device newBufferWithLength:dstSize
                                                     options:MTLResourceStorageModeShared];
        if (!dstBuf) { MLOG("dispatch fail: dstBuf alloc"); return false; }

        // Kernel params: {width, height, srcRowUints, dstRowUints}
        uint32_t params[4] = {
            (uint32_t)w,
            (uint32_t)h,
            (uint32_t)(srcRowBytes / 4),
            (uint32_t)(dstRowBytes / 4)
        };

        // ── Encode ──
        id<MTLCommandBuffer> cmdBuf = [g_queue commandBuffer];
        if (!cmdBuf) { MLOG("dispatch fail: cmdBuf"); return false; }

        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        if (!enc) { MLOG("dispatch fail: encoder"); return false; }

        [enc setComputePipelineState:g_smokePSO];
        [enc setBuffer:srcBuf offset:0 atIndex:0];
        [enc setBuffer:dstBuf offset:0 atIndex:1];
        [enc setBytes:params length:sizeof(params) atIndex:2];

        // Threadgroup size derived from pipeline for portability
        NSUInteger tw = g_smokePSO.threadExecutionWidth;
        NSUInteger th = g_smokePSO.maxTotalThreadsPerThreadgroup / tw;
        MTLSize tgSize   = MTLSizeMake(tw, th, 1);
        MTLSize gridSize = MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1);

        [enc dispatchThreads:gridSize threadsPerThreadgroup:tgSize];
        [enc endEncoding];

        // ── Execute (synchronous for Phase 4) ──
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if (cmdBuf.status == MTLCommandBufferStatusError) {
            MLOG("dispatch fail: GPU error: %s",
                 cmdBuf.error ? [[cmdBuf.error localizedDescription] UTF8String] : "unknown");
            return false;
        }

        // ── Copy result back to host ──
        std::memcpy(dstData, dstBuf.contents, dstSize);

        MLOG("dispatch OK: %dx%d  8bpc passthrough", w, h);
        return true;
    }
}

}  // namespace metal
}  // namespace vtc
