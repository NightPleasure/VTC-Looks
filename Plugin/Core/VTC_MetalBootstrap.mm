#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "VTC_RenderBackend.h"
#include <dispatch/dispatch.h>
#include <cstring>

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

id<MTLDevice>               g_device     = nil;
id<MTLCommandQueue>         g_queue      = nil;
id<MTLComputePipelineState> g_lutPSO     = nil;
bool                        g_available  = false;
bool                        g_pipelineOK = false;
dispatch_once_t             g_ctxOnce;
dispatch_once_t             g_psoOnce;

// ── GPU LUT kernel (8bpc, single layer) ──────────────────────────────
// Direct port of CPU trilinear interpolation + intensity blend.
// AE 8bpc pixel layout: [A, R, G, B] = uchar4(a, r, g, b)
// LUT layout: flat float[dim*dim*dim*3], indexed ((z*dim+y)*dim+x)*3 → R,G,B
NSString* const kLUTShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct LUTParams {
    uint  width;
    uint  height;
    uint  srcStride;   // row stride in pixel (uchar4) units = rowBytes / 4
    uint  dstStride;
    uint  lutDim;
    float lutScale;    // (float)(lutDim - 1)
    float intensity;   // 0..1
};

inline float3 lutFetch(device const float* d, int xi, int yi, int zi, int dim) {
    int idx = ((zi * dim + yi) * dim + xi) * 3;
    return float3(d[idx], d[idx + 1], d[idx + 2]);
}

kernel void lut_apply_8bpc(
    device const uchar4* src [[buffer(0)]],
    device       uchar4* dst [[buffer(1)]],
    device const float*  lut [[buffer(2)]],
    constant LUTParams&  p   [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;

    uchar4 pixel = src[gid.y * p.srcStride + gid.x];
    float r = float(pixel.y) / 255.0f;
    float g = float(pixel.z) / 255.0f;
    float b = float(pixel.w) / 255.0f;

    float s = p.lutScale;
    int dim = int(p.lutDim);
    int dimM1 = dim - 1;

    float fx = clamp(r, 0.0f, 1.0f) * s;
    float fy = clamp(g, 0.0f, 1.0f) * s;
    float fz = clamp(b, 0.0f, 1.0f) * s;

    int x0 = int(fx);  int x1 = min(x0 + 1, dimM1);
    int y0 = int(fy);  int y1 = min(y0 + 1, dimM1);
    int z0 = int(fz);  int z1 = min(z0 + 1, dimM1);

    float dx = fx - float(x0);
    float dy = fy - float(y0);
    float dz = fz - float(z0);

    float3 c000 = lutFetch(lut, x0, y0, z0, dim);
    float3 c100 = lutFetch(lut, x1, y0, z0, dim);
    float3 c010 = lutFetch(lut, x0, y1, z0, dim);
    float3 c110 = lutFetch(lut, x1, y1, z0, dim);
    float3 c001 = lutFetch(lut, x0, y0, z1, dim);
    float3 c101 = lutFetch(lut, x1, y0, z1, dim);
    float3 c011 = lutFetch(lut, x0, y1, z1, dim);
    float3 c111 = lutFetch(lut, x1, y1, z1, dim);

    float3 c00 = mix(c000, c100, dx);
    float3 c10 = mix(c010, c110, dx);
    float3 c01 = mix(c001, c101, dx);
    float3 c11 = mix(c011, c111, dx);

    float3 c0 = mix(c00, c10, dy);
    float3 c1 = mix(c01, c11, dy);

    float3 lutColor = mix(c0, c1, dz);

    // Intensity blend (mix with t=1 is a no-op on the original, correct for full intensity)
    float3 original = float3(r, g, b);
    float3 result = mix(original, lutColor, p.intensity);

    // Quantize to 8-bit, matching CPU: clamp01 * 255 + 0.5, min with 255, truncate
    result = clamp(result, 0.0f, 1.0f) * 255.0f + 0.5f;
    result = min(result, 255.0f);

    dst[gid.y * p.dstStride + gid.x] = uchar4(
        pixel.x,          // preserve alpha
        uchar(result.x),  // R
        uchar(result.y),  // G
        uchar(result.z)   // B
    );
}
)MSL";

struct GPUParams {
    uint32_t width;
    uint32_t height;
    uint32_t srcStride;
    uint32_t dstStride;
    uint32_t lutDim;
    float    lutScale;
    float    intensity;
};

void InitPipeline() {
    dispatch_once(&g_psoOnce, ^{
        if (!g_device) {
            MLOG("pipeline skip: no device");
            return;
        }
        NSError* err = nil;
        id<MTLLibrary> lib = [g_device newLibraryWithSource:kLUTShaderSource
                                                    options:nil
                                                      error:&err];
        if (!lib) {
            MLOG("shader compile failed: %s",
                 err ? [[err localizedDescription] UTF8String] : "unknown");
            return;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"lut_apply_8bpc"];
        if (!fn) {
            MLOG("function lookup failed");
            return;
        }
        g_lutPSO = [g_device newComputePipelineStateWithFunction:fn error:&err];
        if (!g_lutPSO) {
            MLOG("pipeline creation failed: %s",
                 err ? [[err localizedDescription] UTF8String] : "unknown");
            return;
        }
        g_pipelineOK = true;
        MLOG("LUT pipeline ready  threadExecWidth=%lu  maxThreads=%lu",
             (unsigned long)g_lutPSO.threadExecutionWidth,
             (unsigned long)g_lutPSO.maxTotalThreadsPerThreadgroup);
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

    // ── Gate: format (8bpc only) ──
    if (desc.bytesPerPixel != 4) {
        MLOG("dispatch skip: unsupported bpp=%d", desc.bytesPerPixel);
        return false;
    }

    // ── Gate: single layer only in Phase 5 ──
    if (desc.layerCount != 1) {
        MLOG("dispatch skip: layerCount=%d (Phase 5 supports 1 only)", desc.layerCount);
        return false;
    }

    const auto& layer = desc.layers[0];
    if (!layer.lutData || layer.dimension < 2) {
        MLOG("dispatch skip: invalid LUT data or dimension");
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
    const NSUInteger lutSize = (NSUInteger)layer.dimension * layer.dimension
                             * layer.dimension * 3 * sizeof(float);

    @autoreleasepool {
        // ── Create buffers ──
        id<MTLBuffer> srcBuf = [g_device newBufferWithBytes:srcData
                                                     length:srcSize
                                                    options:MTLResourceStorageModeShared];
        if (!srcBuf) { MLOG("dispatch fail: srcBuf alloc"); return false; }

        id<MTLBuffer> dstBuf = [g_device newBufferWithLength:dstSize
                                                     options:MTLResourceStorageModeShared];
        if (!dstBuf) { MLOG("dispatch fail: dstBuf alloc"); return false; }

        id<MTLBuffer> lutBuf = [g_device newBufferWithBytes:layer.lutData
                                                     length:lutSize
                                                    options:MTLResourceStorageModeShared];
        if (!lutBuf) { MLOG("dispatch fail: lutBuf alloc"); return false; }

        GPUParams params = {
            (uint32_t)w,
            (uint32_t)h,
            (uint32_t)(srcRowBytes / 4),
            (uint32_t)(dstRowBytes / 4),
            (uint32_t)layer.dimension,
            layer.scale,
            layer.intensity
        };

        // ── Encode ──
        id<MTLCommandBuffer> cmdBuf = [g_queue commandBuffer];
        if (!cmdBuf) { MLOG("dispatch fail: cmdBuf"); return false; }

        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        if (!enc) { MLOG("dispatch fail: encoder"); return false; }

        [enc setComputePipelineState:g_lutPSO];
        [enc setBuffer:srcBuf offset:0 atIndex:0];
        [enc setBuffer:dstBuf offset:0 atIndex:1];
        [enc setBuffer:lutBuf offset:0 atIndex:2];
        [enc setBytes:&params length:sizeof(params) atIndex:3];

        NSUInteger tw = g_lutPSO.threadExecutionWidth;
        NSUInteger th = g_lutPSO.maxTotalThreadsPerThreadgroup / tw;
        MTLSize tgSize   = MTLSizeMake(tw, th, 1);
        MTLSize gridSize = MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1);

        [enc dispatchThreads:gridSize threadsPerThreadgroup:tgSize];
        [enc endEncoding];

        // ── Execute (synchronous) ──
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if (cmdBuf.status == MTLCommandBufferStatusError) {
            MLOG("dispatch fail: GPU error: %s",
                 cmdBuf.error ? [[cmdBuf.error localizedDescription] UTF8String] : "unknown");
            return false;
        }

        // ── Copy result back to host ──
        std::memcpy(dstData, dstBuf.contents, dstSize);

        MLOG("dispatch OK: %dx%d  8bpc  LUT dim=%d  intensity=%.3f",
             w, h, layer.dimension, layer.intensity);
        return true;
    }
}

}  // namespace metal
}  // namespace vtc
