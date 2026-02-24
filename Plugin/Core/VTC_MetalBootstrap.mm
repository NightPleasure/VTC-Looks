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

id<MTLDevice>               g_device      = nil;
id<MTLCommandQueue>         g_queue       = nil;
id<MTLComputePipelineState> g_lutPSO_8    = nil;
id<MTLComputePipelineState> g_lutPSO_32f  = nil;
bool                        g_available   = false;
bool                        g_pipeline8OK = false;
bool                        g_pipeline32OK = false;
dispatch_once_t             g_ctxOnce;
dispatch_once_t             g_psoOnce;

// ── GPU LUT kernels ──────────────────────────────────────────────────
// Both kernels share the sampleLUT helper and struct definitions.
// lut_apply_8bpc:  8bpc ARGB8 pixels (uchar4), 1..4 layers
// lut_apply_32bpc: 32bpc ARGB float pixels (float4), 1 layer only
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
    uint  srcStride;   // row stride in pixel units (uchar4 for 8bpc, float4 for 32bpc)
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

// ── 8bpc kernel (1..4 layers) ────────────────────────────────────────

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

    float3 q = clamp(color, 0.0f, 1.0f) * 255.0f + 0.5f;
    q = min(q, 255.0f);

    dst[gid.y * p.dstStride + gid.x] = uchar4(
        pixel.x, uchar(q.x), uchar(q.y), uchar(q.z));
}

// ── 32bpc kernel (single layer) ──────────────────────────────────────
// AE 32bpc pixel layout: float4(A, R, G, B)
// CPU reference: toFloat32 extracts (r, g, b) directly,
//   fromFloat32 writes (a, clamp01(r), clamp01(g), clamp01(b)).

kernel void lut_apply_32bpc(
    device const float4* src [[buffer(0)]],
    device       float4* dst [[buffer(1)]],
    device const float*  lut [[buffer(2)]],
    constant LUTParams&  p   [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;

    float4 pixel = src[gid.y * p.srcStride + gid.x];
    float3 color = float3(pixel.y, pixel.z, pixel.w);  // R, G, B

    LayerDesc ld = p.layers[0];
    int dim   = int(ld.dim);
    int dimM1 = dim - 1;
    float3 lutColor = sampleLUT(lut, ld.lutOffset, dim, dimM1, ld.scale, color);
    color = mix(color, lutColor, ld.intensity);

    dst[gid.y * p.dstStride + gid.x] = float4(
        pixel.x,                    // preserve alpha
        clamp(color.x, 0.0f, 1.0f),
        clamp(color.y, 0.0f, 1.0f),
        clamp(color.z, 0.0f, 1.0f));
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

        // 8bpc pipeline
        id<MTLFunction> fn8 = [lib newFunctionWithName:@"lut_apply_8bpc"];
        if (fn8) {
            g_lutPSO_8 = [g_device newComputePipelineStateWithFunction:fn8 error:&err];
            if (g_lutPSO_8) {
                g_pipeline8OK = true;
                MLOG("8bpc pipeline ready  tw=%lu  maxT=%lu",
                     (unsigned long)g_lutPSO_8.threadExecutionWidth,
                     (unsigned long)g_lutPSO_8.maxTotalThreadsPerThreadgroup);
            } else {
                MLOG("8bpc pipeline creation failed: %s",
                     err ? [[err localizedDescription] UTF8String] : "unknown");
            }
        } else {
            MLOG("8bpc function lookup failed");
        }

        // 32bpc pipeline
        id<MTLFunction> fn32 = [lib newFunctionWithName:@"lut_apply_32bpc"];
        if (fn32) {
            g_lutPSO_32f = [g_device newComputePipelineStateWithFunction:fn32 error:&err];
            if (g_lutPSO_32f) {
                g_pipeline32OK = true;
                MLOG("32bpc pipeline ready  tw=%lu  maxT=%lu",
                     (unsigned long)g_lutPSO_32f.threadExecutionWidth,
                     (unsigned long)g_lutPSO_32f.maxTotalThreadsPerThreadgroup);
            } else {
                MLOG("32bpc pipeline creation failed: %s",
                     err ? [[err localizedDescription] UTF8String] : "unknown");
            }
        } else {
            MLOG("32bpc function lookup failed");
        }
    });
}

// ── Shared dispatch helper ───────────────────────────────────────────

static bool dispatchKernel(id<MTLComputePipelineState> pso,
                           const GPUParams& params,
                           const void* srcData, void* dstData,
                           int srcRowBytes, int dstRowBytes,
                           int frameW, int frameH,
                           const float* lutPacked, NSUInteger lutBytes)
{
    const NSUInteger srcSize = (NSUInteger)frameH * (NSUInteger)srcRowBytes;
    const NSUInteger dstSize = (NSUInteger)frameH * (NSUInteger)dstRowBytes;

    id<MTLBuffer> srcBuf = [g_device newBufferWithBytes:srcData
                                                 length:srcSize
                                                options:MTLResourceStorageModeShared];
    id<MTLBuffer> dstBuf = [g_device newBufferWithLength:dstSize
                                                 options:MTLResourceStorageModeShared];
    id<MTLBuffer> lutBuf = [g_device newBufferWithBytes:lutPacked
                                                 length:lutBytes
                                                options:MTLResourceStorageModeShared];
    if (!srcBuf || !dstBuf || !lutBuf) {
        MLOG("dispatch fail: buffer alloc");
        return false;
    }

    id<MTLCommandBuffer> cmdBuf = [g_queue commandBuffer];
    if (!cmdBuf) { MLOG("dispatch fail: cmdBuf"); return false; }

    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
    if (!enc) { MLOG("dispatch fail: encoder"); return false; }

    [enc setComputePipelineState:pso];
    [enc setBuffer:srcBuf offset:0 atIndex:0];
    [enc setBuffer:dstBuf offset:0 atIndex:1];
    [enc setBuffer:lutBuf offset:0 atIndex:2];
    [enc setBytes:&params length:sizeof(params) atIndex:3];

    NSUInteger tw = pso.threadExecutionWidth;
    NSUInteger th = pso.maxTotalThreadsPerThreadgroup / tw;
    MTLSize tgSize   = MTLSizeMake(tw, th, 1);
    MTLSize gridSize = MTLSizeMake((NSUInteger)frameW, (NSUInteger)frameH, 1);

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
    return true;
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

    if (desc.layerCount < 1 || desc.layerCount > GPUDispatchDesc::kMaxLayers) {
        MLOG("dispatch skip: layerCount=%d out of range", desc.layerCount);
        return false;
    }

    // ── Route by pixel format ──
    const bool is8bpc  = (desc.bytesPerPixel == 4);
    const bool is32bpc = (desc.bytesPerPixel == 16);

    if (!is8bpc && !is32bpc) {
        MLOG("dispatch skip: unsupported bpp=%d (16bpc stays on CPU)", desc.bytesPerPixel);
        return false;
    }

    if (is32bpc && desc.layerCount != 1) {
        MLOG("dispatch skip: 32bpc multi-layer not yet supported (layers=%d)", desc.layerCount);
        return false;
    }

    // Validate all active layers
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

    id<MTLComputePipelineState> pso = nil;
    if (is8bpc) {
        if (!g_pipeline8OK) { MLOG("dispatch skip: 8bpc pipeline not ready"); return false; }
        pso = g_lutPSO_8;
    } else {
        if (!g_pipeline32OK) { MLOG("dispatch skip: 32bpc pipeline not ready"); return false; }
        pso = g_lutPSO_32f;
    }

    const int w = desc.frameWidth;
    const int h = desc.frameHeight;
    if (w <= 0 || h <= 0) return false;

    const NSUInteger lutBytes = totalLutFloats * sizeof(float);

    @autoreleasepool {
        // Pack LUT data
        float* lutPacked = (float*)std::malloc(lutBytes);
        if (!lutPacked) { MLOG("dispatch fail: lutPacked malloc"); return false; }

        GPUParams params = {};
        params.width      = (uint32_t)w;
        params.height     = (uint32_t)h;
        params.layerCount = (uint32_t)desc.layerCount;

        // Stride: pixels per row (rowBytes / bytesPerPixel)
        params.srcStride = (uint32_t)(srcRowBytes / desc.bytesPerPixel);
        params.dstStride = (uint32_t)(dstRowBytes / desc.bytesPerPixel);

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

        bool ok = dispatchKernel(pso, params, srcData, dstData,
                                 srcRowBytes, dstRowBytes, w, h,
                                 lutPacked, lutBytes);
        std::free(lutPacked);

        if (ok) {
            MLOG("dispatch OK: %dx%d  %dbpc  layers=%d",
                 w, h, is8bpc ? 8 : 32, desc.layerCount);
        }
        return ok;
    }
}

}  // namespace metal
}  // namespace vtc
