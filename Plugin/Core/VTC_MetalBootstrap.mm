#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "VTC_RenderBackend.h"
#include <dispatch/dispatch.h>
#include <cstring>
#include <cstdlib>

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

// ── GPU LUT kernel (8bpc, 1..4 layers) ───────────────────────────────
// Matches CPU: sequential trilinear LUT sampling + per-layer intensity blend.
// All layers' data packed into one buffer; per-layer offset/dim/scale/intensity
// passed via the params struct.
// Layer application order is preserved: Log → Creative → Secondary → Accent.
NSString* const kLUTShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct LayerDesc {
    uint  lutOffset;  // offset in float units into combined LUT buffer
    uint  dim;
    float scale;      // (float)(dim - 1)
    float intensity;  // 0..1
};

struct LUTParams {
    uint  width;
    uint  height;
    uint  srcStride;   // row stride in uchar4 (pixel) units
    uint  dstStride;
    uint  layerCount;  // 1..4
    uint  _pad0;
    uint  _pad1;
    uint  _pad2;
    LayerDesc layers[4];
};

inline float3 sampleLUT(device const float* lut, uint baseOff,
                         int dim, int dimM1, float scale, float3 color)
{
    float fx = clamp(color.x, 0.0f, 1.0f) * scale;
    float fy = clamp(color.y, 0.0f, 1.0f) * scale;
    float fz = clamp(color.z, 0.0f, 1.0f) * scale;

    int x0 = int(fx);  int x1 = min(x0 + 1, dimM1);
    int y0 = int(fy);  int y1 = min(y0 + 1, dimM1);
    int z0 = int(fz);  int z1 = min(z0 + 1, dimM1);

    float dx = fx - float(x0);
    float dy = fy - float(y0);
    float dz = fz - float(z0);

    // ((z*dim+y)*dim+x)*3 → R,G,B
    #define LF(xi,yi,zi) ({ \
        int _i = baseOff + ((zi * dim + yi) * dim + xi) * 3; \
        float3(lut[_i], lut[_i+1], lut[_i+2]); })

    float3 c000 = LF(x0,y0,z0); float3 c100 = LF(x1,y0,z0);
    float3 c010 = LF(x0,y1,z0); float3 c110 = LF(x1,y1,z0);
    float3 c001 = LF(x0,y0,z1); float3 c101 = LF(x1,y0,z1);
    float3 c011 = LF(x0,y1,z1); float3 c111 = LF(x1,y1,z1);
    #undef LF

    float3 c00 = mix(c000, c100, dx);
    float3 c10 = mix(c010, c110, dx);
    float3 c01 = mix(c001, c101, dx);
    float3 c11 = mix(c011, c111, dx);

    float3 c0 = mix(c00, c10, dy);
    float3 c1 = mix(c01, c11, dy);

    return mix(c0, c1, dz);
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
    float3 color = float3(float(pixel.y), float(pixel.z), float(pixel.w)) / 255.0f;

    for (uint i = 0; i < p.layerCount; i++) {
        LayerDesc ld = p.layers[i];
        int dim   = int(ld.dim);
        int dimM1 = dim - 1;
        float3 lutColor = sampleLUT(lut, ld.lutOffset, dim, dimM1, ld.scale, color);
        color = mix(color, lutColor, ld.intensity);
    }

    // Quantize to 8-bit (matches CPU: clamp01 * 255 + 0.5, min 255, truncate)
    float3 q = clamp(color, 0.0f, 1.0f) * 255.0f + 0.5f;
    q = min(q, 255.0f);

    dst[gid.y * p.dstStride + gid.x] = uchar4(
        pixel.x, uchar(q.x), uchar(q.y), uchar(q.z));
}
)MSL";

// ── Host-side params struct (must match Metal layout exactly) ────────

struct GPULayerInfo {
    uint32_t lutOffset;
    uint32_t dimension;
    float    scale;
    float    intensity;
};

struct GPUParams {
    uint32_t width;
    uint32_t height;
    uint32_t srcStride;
    uint32_t dstStride;
    uint32_t layerCount;
    uint32_t _pad0, _pad1, _pad2;
    GPULayerInfo layers[4];
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
    if (!g_available) {
        MLOG("dispatch skip: context unavailable");
        return false;
    }

    if (desc.bytesPerPixel != 4) {
        MLOG("dispatch skip: unsupported bpp=%d", desc.bytesPerPixel);
        return false;
    }

    if (desc.layerCount < 1 || desc.layerCount > GPUDispatchDesc::kMaxLayers) {
        MLOG("dispatch skip: layerCount=%d out of range", desc.layerCount);
        return false;
    }

    // Validate all layers before allocating anything
    NSUInteger totalLutFloats = 0;
    for (int i = 0; i < desc.layerCount; i++) {
        const auto& L = desc.layers[i];
        if (!L.lutData || L.dimension < 2) {
            MLOG("dispatch skip: layer %d invalid (data=%p dim=%d)", i, L.lutData, L.dimension);
            return false;
        }
        totalLutFloats += (NSUInteger)L.dimension * L.dimension * L.dimension * 3;
    }

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
    const NSUInteger lutBytes = totalLutFloats * sizeof(float);

    @autoreleasepool {
        // ── Pack all LUT data into one contiguous host buffer ──
        float* lutPacked = (float*)std::malloc(lutBytes);
        if (!lutPacked) { MLOG("dispatch fail: lutPacked malloc"); return false; }

        GPUParams params = {};
        params.width      = (uint32_t)w;
        params.height     = (uint32_t)h;
        params.srcStride  = (uint32_t)(srcRowBytes / 4);
        params.dstStride  = (uint32_t)(dstRowBytes / 4);
        params.layerCount = (uint32_t)desc.layerCount;

        uint32_t floatOffset = 0;
        for (int i = 0; i < desc.layerCount; i++) {
            const auto& L = desc.layers[i];
            NSUInteger layerFloats = (NSUInteger)L.dimension * L.dimension * L.dimension * 3;
            std::memcpy(lutPacked + floatOffset, L.lutData, layerFloats * sizeof(float));

            params.layers[i].lutOffset  = floatOffset;
            params.layers[i].dimension  = (uint32_t)L.dimension;
            params.layers[i].scale      = L.scale;
            params.layers[i].intensity  = L.intensity;
            floatOffset += (uint32_t)layerFloats;
        }

        // ── Create Metal buffers ──
        id<MTLBuffer> srcBuf = [g_device newBufferWithBytes:srcData
                                                     length:srcSize
                                                    options:MTLResourceStorageModeShared];
        id<MTLBuffer> dstBuf = [g_device newBufferWithLength:dstSize
                                                     options:MTLResourceStorageModeShared];
        id<MTLBuffer> lutBuf = [g_device newBufferWithBytes:lutPacked
                                                     length:lutBytes
                                                    options:MTLResourceStorageModeShared];
        std::free(lutPacked);

        if (!srcBuf || !dstBuf || !lutBuf) {
            MLOG("dispatch fail: buffer alloc (src=%p dst=%p lut=%p)",
                 srcBuf, dstBuf, lutBuf);
            return false;
        }

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

        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];

        if (cmdBuf.status == MTLCommandBufferStatusError) {
            MLOG("dispatch fail: GPU error: %s",
                 cmdBuf.error ? [[cmdBuf.error localizedDescription] UTF8String] : "unknown");
            return false;
        }

        std::memcpy(dstData, dstBuf.contents, dstSize);

        MLOG("dispatch OK: %dx%d  8bpc  layers=%d", w, h, desc.layerCount);
        return true;
    }
}

}  // namespace metal
}  // namespace vtc
