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

id<MTLDevice>               g_device       = nil;
id<MTLCommandQueue>         g_queue        = nil;
id<MTLComputePipelineState> g_lutPSO_8     = nil;
id<MTLComputePipelineState> g_lutPSO_16    = nil;
id<MTLComputePipelineState> g_lutPSO_32f   = nil;
bool                        g_available    = false;
bool                        g_pipeline8OK  = false;
bool                        g_pipeline16OK = false;
bool                        g_pipeline32OK = false;
dispatch_once_t             g_ctxOnce;
dispatch_once_t             g_psoOnce;

// ── Resource cache ──────────────────────────────────────────────────
// Reuses MTLBuffers across dispatches to avoid per-frame allocation
// overhead. Thread safety: safe because TryDispatch blocks on
// waitUntilCompleted before returning, so cached buffers are never
// in-flight when the next dispatch accesses them.
//
// Invalidation conditions:
//   srcBuf/dstBuf: reallocated when required byte size exceeds capacity
//   lutBuf:        rebuilt when layer count, LUT data pointers, or
//                  dimensions change (intensity is in GPUParams, not
//                  baked into the LUT buffer)

struct LUTCacheKey {
    int          layerCount = 0;
    const float* ptrs[GPUDispatchDesc::kMaxLayers] = {};
    int          dims[GPUDispatchDesc::kMaxLayers] = {};

    bool matches(const GPUDispatchDesc& desc) const {
        if (layerCount != desc.layerCount) return false;
        for (int i = 0; i < desc.layerCount; i++) {
            if (ptrs[i] != desc.layers[i].lutData)   return false;
            if (dims[i] != desc.layers[i].dimension)  return false;
        }
        return true;
    }

    void update(const GPUDispatchDesc& desc) {
        layerCount = desc.layerCount;
        for (int i = 0; i < GPUDispatchDesc::kMaxLayers; i++) {
            if (i < desc.layerCount) {
                ptrs[i] = desc.layers[i].lutData;
                dims[i] = desc.layers[i].dimension;
            } else {
                ptrs[i] = nullptr;
                dims[i] = 0;
            }
        }
    }
};

id<MTLBuffer> g_cachedSrcBuf = nil;
NSUInteger    g_cachedSrcCap = 0;
id<MTLBuffer> g_cachedDstBuf = nil;
NSUInteger    g_cachedDstCap = 0;
id<MTLBuffer> g_cachedLutBuf = nil;
LUTCacheKey   g_lutCacheKey;

// ── GPU LUT kernels ──────────────────────────────────────────────────
// All kernels share the sampleLUT helper and LUTParams struct.
// lut_apply_8bpc:  8bpc  ARGB8 pixels (uchar4),  1..4 layers
// lut_apply_16bpc: 16bpc ARGB16 pixels (ushort4), 1..4 layers
// lut_apply_32bpc: 32bpc ARGB float pixels (float4), 1..4 layers
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
    uint  srcStride;   // row stride in pixel units
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

// ── 16bpc kernel (1..4 layers) ───────────────────────────────────────
// AE 16bpc pixel layout: ushort4(A, R, G, B), range [0, 32768]
// CPU reference: toFloat16 divides by 32768.0,
//   fromFloat16 writes clamp01(v) * 32768.0 + 0.5, clamped to max 32768.

kernel void lut_apply_16bpc(
    device const ushort4* src [[buffer(0)]],
    device       ushort4* dst [[buffer(1)]],
    device const float*   lut [[buffer(2)]],
    constant LUTParams&   p   [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;

    ushort4 pixel = src[gid.y * p.srcStride + gid.x];
    float3 color = float3(float(pixel.y), float(pixel.z), float(pixel.w)) / 32768.0f;

    for (uint i = 0; i < p.layerCount; i++) {
        LayerDesc ld = p.layers[i];
        int dim   = int(ld.dim);
        int dimM1 = dim - 1;
        float3 lutColor = sampleLUT(lut, ld.lutOffset, dim, dimM1, ld.scale, color);
        color = mix(color, lutColor, ld.intensity);
    }

    float3 q = clamp(color, 0.0f, 1.0f) * 32768.0f + 0.5f;
    q = min(q, 32768.0f);

    dst[gid.y * p.dstStride + gid.x] = ushort4(
        pixel.x, ushort(q.x), ushort(q.y), ushort(q.z));
}

// ── 32bpc kernel (1..4 layers) ───────────────────────────────────────

kernel void lut_apply_32bpc(
    device const float4* src [[buffer(0)]],
    device       float4* dst [[buffer(1)]],
    device const float*  lut [[buffer(2)]],
    constant LUTParams&  p   [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;

    float4 pixel = src[gid.y * p.srcStride + gid.x];
    float3 color = float3(pixel.y, pixel.z, pixel.w);

    for (uint i = 0; i < p.layerCount; i++) {
        LayerDesc ld = p.layers[i];
        int dim   = int(ld.dim);
        int dimM1 = dim - 1;
        float3 lutColor = sampleLUT(lut, ld.lutOffset, dim, dimM1, ld.scale, color);
        color = mix(color, lutColor, ld.intensity);
    }

    dst[gid.y * p.dstStride + gid.x] = float4(
        pixel.x,
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
                MLOG("8bpc pipeline failed: %s",
                     err ? [[err localizedDescription] UTF8String] : "unknown");
            }
        }

        // 16bpc pipeline
        id<MTLFunction> fn16 = [lib newFunctionWithName:@"lut_apply_16bpc"];
        if (fn16) {
            g_lutPSO_16 = [g_device newComputePipelineStateWithFunction:fn16 error:&err];
            if (g_lutPSO_16) {
                g_pipeline16OK = true;
                MLOG("16bpc pipeline ready  tw=%lu  maxT=%lu",
                     (unsigned long)g_lutPSO_16.threadExecutionWidth,
                     (unsigned long)g_lutPSO_16.maxTotalThreadsPerThreadgroup);
            } else {
                MLOG("16bpc pipeline failed: %s",
                     err ? [[err localizedDescription] UTF8String] : "unknown");
            }
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
                MLOG("32bpc pipeline failed: %s",
                     err ? [[err localizedDescription] UTF8String] : "unknown");
            }
        }
    });
}

// ── Shared dispatch helper (uses pre-created buffers) ────────────────

static bool dispatchKernel(id<MTLComputePipelineState> pso,
                           const GPUParams& params,
                           id<MTLBuffer> srcBuf,
                           id<MTLBuffer> dstBuf,
                           id<MTLBuffer> lutBuf,
                           int frameW, int frameH,
                           NSUInteger dstReadbackBytes,
                           void* dstData)
{
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

    std::memcpy(dstData, dstBuf.contents, dstReadbackBytes);
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
    const bool is16bpc = (desc.bytesPerPixel == 8);
    const bool is32bpc = (desc.bytesPerPixel == 16);

    if (!is8bpc && !is16bpc && !is32bpc) {
        MLOG("dispatch skip: unsupported bpp=%d", desc.bytesPerPixel);
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
    int bpcLabel = 0;
    if (is8bpc) {
        if (!g_pipeline8OK) { MLOG("dispatch skip: 8bpc pipeline not ready"); return false; }
        pso = g_lutPSO_8;  bpcLabel = 8;
    } else if (is16bpc) {
        if (!g_pipeline16OK) { MLOG("dispatch skip: 16bpc pipeline not ready"); return false; }
        pso = g_lutPSO_16; bpcLabel = 16;
    } else {
        if (!g_pipeline32OK) { MLOG("dispatch skip: 32bpc pipeline not ready"); return false; }
        pso = g_lutPSO_32f; bpcLabel = 32;
    }

    const int w = desc.frameWidth;
    const int h = desc.frameHeight;
    if (w <= 0 || h <= 0) return false;

    const NSUInteger srcSize  = (NSUInteger)h * (NSUInteger)srcRowBytes;
    const NSUInteger dstSize  = (NSUInteger)h * (NSUInteger)dstRowBytes;
    const NSUInteger lutBytes = totalLutFloats * sizeof(float);

    @autoreleasepool {
        // ── Source buffer: reuse if capacity sufficient, else reallocate ──
        if (!g_cachedSrcBuf || g_cachedSrcCap < srcSize) {
            g_cachedSrcBuf = [g_device newBufferWithBytes:srcData
                                                   length:srcSize
                                                  options:MTLResourceStorageModeShared];
            g_cachedSrcCap = g_cachedSrcBuf ? srcSize : 0;
            MLOG("cache: srcBuf ALLOC %lu bytes", (unsigned long)srcSize);
            if (!g_cachedSrcBuf) {
                MLOG("dispatch fail: srcBuf alloc"); return false;
            }
        } else {
            std::memcpy(g_cachedSrcBuf.contents, srcData, srcSize);
            MLOG("cache: srcBuf REUSE (%lu <= %lu)",
                 (unsigned long)srcSize, (unsigned long)g_cachedSrcCap);
        }

        // ── Destination buffer: reuse if capacity sufficient ──
        if (!g_cachedDstBuf || g_cachedDstCap < dstSize) {
            g_cachedDstBuf = [g_device newBufferWithLength:dstSize
                                                   options:MTLResourceStorageModeShared];
            g_cachedDstCap = g_cachedDstBuf ? dstSize : 0;
            MLOG("cache: dstBuf ALLOC %lu bytes", (unsigned long)dstSize);
            if (!g_cachedDstBuf) {
                MLOG("dispatch fail: dstBuf alloc"); return false;
            }
        } else {
            MLOG("cache: dstBuf REUSE (%lu <= %lu)",
                 (unsigned long)dstSize, (unsigned long)g_cachedDstCap);
        }

        // ── LUT buffer: reuse if layer pointers + dimensions unchanged ──
        if (g_cachedLutBuf && g_lutCacheKey.matches(desc)) {
            MLOG("cache: lutBuf HIT (layers=%d)", desc.layerCount);
        } else {
            float* lutPacked = (float*)std::malloc(lutBytes);
            if (!lutPacked) { MLOG("dispatch fail: lutPacked malloc"); return false; }

            uint32_t floatOff = 0;
            for (int i = 0; i < desc.layerCount; i++) {
                const auto& L = desc.layers[i];
                NSUInteger layerFloats = (NSUInteger)L.dimension * L.dimension * L.dimension * 3;
                std::memcpy(lutPacked + floatOff, L.lutData, layerFloats * sizeof(float));
                floatOff += (uint32_t)layerFloats;
            }

            g_cachedLutBuf = [g_device newBufferWithBytes:lutPacked
                                                   length:lutBytes
                                                  options:MTLResourceStorageModeShared];
            std::free(lutPacked);

            if (!g_cachedLutBuf) {
                MLOG("dispatch fail: lutBuf alloc"); return false;
            }
            g_lutCacheKey.update(desc);
            MLOG("cache: lutBuf MISS -> rebuilt (layers=%d, %lu bytes)",
                 desc.layerCount, (unsigned long)lutBytes);
        }

        // ── Build params (per-dispatch, cheap struct copy) ──
        GPUParams params = {};
        params.width      = (uint32_t)w;
        params.height     = (uint32_t)h;
        params.layerCount = (uint32_t)desc.layerCount;
        params.srcStride  = (uint32_t)(srcRowBytes / desc.bytesPerPixel);
        params.dstStride  = (uint32_t)(dstRowBytes / desc.bytesPerPixel);

        uint32_t floatOffset = 0;
        for (int i = 0; i < desc.layerCount; i++) {
            const auto& L = desc.layers[i];
            NSUInteger layerFloats = (NSUInteger)L.dimension * L.dimension * L.dimension * 3;
            params.layers[i].lutOffset  = floatOffset;
            params.layers[i].dimension  = (uint32_t)L.dimension;
            params.layers[i].scale      = L.scale;
            params.layers[i].intensity  = L.intensity;
            floatOffset += (uint32_t)layerFloats;
        }

        bool ok = dispatchKernel(pso, params,
                                 g_cachedSrcBuf, g_cachedDstBuf, g_cachedLutBuf,
                                 w, h, dstSize, dstData);
        if (ok) {
            MLOG("dispatch OK: %dx%d  %dbpc  layers=%d", w, h, bpcLabel, desc.layerCount);
        }
        return ok;
    }
}

}  // namespace metal
}  // namespace vtc
