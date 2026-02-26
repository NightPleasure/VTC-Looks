#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "VTC_RenderBackend.h"
#include <dispatch/dispatch.h>
#include <unordered_map>
#include <mutex>
#include <cstring>
#include <cstdlib>

#ifndef VTC_METAL_LOG
#define VTC_METAL_LOG 0
#endif

#if VTC_METAL_LOG
#include <cstdio>
#include <mach/mach_time.h>
#define MLOG(fmt, ...) std::fprintf(stderr, "[VTC Metal] " fmt "\n", ##__VA_ARGS__)

static double g_tickToMs = 0.0;
static void ensureTickScale() {
    if (g_tickToMs == 0.0) {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        g_tickToMs = (double)info.numer / (double)info.denom / 1e6;
    }
}
#define MTIMER_BEGIN  uint64_t _mt0 = mach_absolute_time()
#define MTIMER_ELAPSED_MS  ((double)(mach_absolute_time() - _mt0) * g_tickToMs)
#else
#define MLOG(fmt, ...)
#define MTIMER_BEGIN       ((void)0)
#define MTIMER_ELAPSED_MS  (0.0)
static inline void ensureTickScale() {}
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
// I/O buffer cache (shared, thread-safe). ARC is off; cache holds one retain.
static std::mutex   g_ioBufMutex;
static id<MTLBuffer> g_cachedSrcBuf = nil;
static NSUInteger    g_cachedSrcCap = 0;
static id<MTLBuffer> g_cachedDstBuf = nil;
static NSUInteger    g_cachedDstCap = 0;
// ── Debug: GPU path selection override ───────────────────────────────
// Controls which GPU LUT path is attempted when Metal is enabled.
// Auto (default): try texture3d first, fall back to buffer, then CPU.
// ForceTexture:   skip buffer attempt, texture only (still falls back
//                 to CPU on failure -- never crashes).
// ForceBuffer:    skip texture attempt, buffer only.
enum class GPUPathMode { kAuto, kForceTexture, kForceBuffer };
GPUPathMode g_gpuPathMode = GPUPathMode::kAuto;


// ── Per-dispatch resources (MFR baseline) ───────────────────────────
// For MFR safety, buffers/textures are allocated per dispatch; no
// shared mutable caches remain in the render path. Pipeline/device
// objects stay shared and init-once.
// ── Texture LUT path (optional, additive) ────────────────────────────
// Uses Metal 3D textures with hardware trilinear interpolation for
// LUT sampling. Falls back to buffer path if texture creation fails.

id<MTLComputePipelineState> g_texPSO_8   = nil;
id<MTLComputePipelineState> g_texPSO_16  = nil;
id<MTLComputePipelineState> g_texPSO_32f = nil;
bool            g_texPipelineOK = false;
dispatch_once_t g_texPsoOnce;

id<MTLTexture>  g_dummyTex = nil;


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

// ── Texture-based LUT kernels (optional optimization) ───────────────
// Hardware trilinear interpolation via Metal 3D textures. Same pixel
// I/O as buffer kernels; only the LUT lookup path changes.
// Bindings: buffer(0)=src, buffer(1)=dst, buffer(2)=params
//           texture(0..3) = per-layer 3D LUT textures (RGBA32Float)
NSString* const kTexShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct TexLayerDesc {
    float coordScale;   // (dim-1) / dim
    float coordBias;    // 0.5 / dim
    float intensity;
    float _pad;
};

struct LUTTexParams {
    uint width; uint height; uint srcStride; uint dstStride;
    uint layerCount; uint _pad0; uint _pad1; uint _pad2;
    TexLayerDesc layers[4];
};

constexpr sampler lutSampler(filter::linear, address::clamp_to_edge);

kernel void lut_apply_tex_8bpc(
    device const uchar4* src [[buffer(0)]],
    device       uchar4* dst [[buffer(1)]],
    constant LUTTexParams& p [[buffer(2)]],
    texture3d<float> lut0 [[texture(0)]],
    texture3d<float> lut1 [[texture(1)]],
    texture3d<float> lut2 [[texture(2)]],
    texture3d<float> lut3 [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    uchar4 pixel = src[gid.y * p.srcStride + gid.x];
    float3 color = float3(float(pixel.y), float(pixel.z), float(pixel.w)) / 255.0f;

    if (p.layerCount > 0) {
        TexLayerDesc ld = p.layers[0];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut0.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 1) {
        TexLayerDesc ld = p.layers[1];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut1.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 2) {
        TexLayerDesc ld = p.layers[2];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut2.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 3) {
        TexLayerDesc ld = p.layers[3];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut3.sample(lutSampler, tc).xyz, ld.intensity);
    }

    float3 q = clamp(color, 0.0f, 1.0f) * 255.0f + 0.5f;
    q = min(q, 255.0f);
    dst[gid.y * p.dstStride + gid.x] = uchar4(
        pixel.x, uchar(q.x), uchar(q.y), uchar(q.z));
}

kernel void lut_apply_tex_16bpc(
    device const ushort4* src [[buffer(0)]],
    device       ushort4* dst [[buffer(1)]],
    constant LUTTexParams& p  [[buffer(2)]],
    texture3d<float> lut0 [[texture(0)]],
    texture3d<float> lut1 [[texture(1)]],
    texture3d<float> lut2 [[texture(2)]],
    texture3d<float> lut3 [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    ushort4 pixel = src[gid.y * p.srcStride + gid.x];
    float3 color = float3(float(pixel.y), float(pixel.z), float(pixel.w)) / 32768.0f;

    if (p.layerCount > 0) {
        TexLayerDesc ld = p.layers[0];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut0.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 1) {
        TexLayerDesc ld = p.layers[1];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut1.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 2) {
        TexLayerDesc ld = p.layers[2];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut2.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 3) {
        TexLayerDesc ld = p.layers[3];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut3.sample(lutSampler, tc).xyz, ld.intensity);
    }

    float3 q = clamp(color, 0.0f, 1.0f) * 32768.0f + 0.5f;
    q = min(q, 32768.0f);
    dst[gid.y * p.dstStride + gid.x] = ushort4(
        pixel.x, ushort(q.x), ushort(q.y), ushort(q.z));
}

kernel void lut_apply_tex_32bpc(
    device const float4* src [[buffer(0)]],
    device       float4* dst [[buffer(1)]],
    constant LUTTexParams& p [[buffer(2)]],
    texture3d<float> lut0 [[texture(0)]],
    texture3d<float> lut1 [[texture(1)]],
    texture3d<float> lut2 [[texture(2)]],
    texture3d<float> lut3 [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    float4 pixel = src[gid.y * p.srcStride + gid.x];
    float3 color = float3(pixel.y, pixel.z, pixel.w);

    if (p.layerCount > 0) {
        TexLayerDesc ld = p.layers[0];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut0.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 1) {
        TexLayerDesc ld = p.layers[1];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut1.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 2) {
        TexLayerDesc ld = p.layers[2];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut2.sample(lutSampler, tc).xyz, ld.intensity);
    }
    if (p.layerCount > 3) {
        TexLayerDesc ld = p.layers[3];
        float3 tc = clamp(color, 0.0f, 1.0f) * ld.coordScale + ld.coordBias;
        color = mix(color, lut3.sample(lutSampler, tc).xyz, ld.intensity);
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

struct GPUTexLayerInfo {
    float coordScale;   // (dim-1) / dim
    float coordBias;    // 0.5 / dim
    float intensity;
    float _pad;
};

struct GPUTexParams {
    uint32_t width;
    uint32_t height;
    uint32_t srcStride;
    uint32_t dstStride;
    uint32_t layerCount;
    uint32_t _pad0, _pad1, _pad2;
    GPUTexLayerInfo layers[4];
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

// ── 3D Texture LUT helpers ──────────────────────────────────────────

static id<MTLTexture> createLUTTexture(const float* rgbData, int dim) {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.textureType = MTLTextureType3D;
    desc.pixelFormat = MTLPixelFormatRGBA32Float;
    desc.width  = (NSUInteger)dim;
    desc.height = (NSUInteger)dim;
    desc.depth  = (NSUInteger)dim;
    desc.usage  = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    id<MTLTexture> tex = [g_device newTextureWithDescriptor:desc];
    [desc release];
    if (!tex) return nil;

    size_t n = (size_t)dim * dim * dim;
    float* rgba = (float*)std::malloc(n * 4 * sizeof(float));
    if (!rgba) return nil;

    for (size_t i = 0; i < n; i++) {
        rgba[i*4 + 0] = rgbData[i*3 + 0];
        rgba[i*4 + 1] = rgbData[i*3 + 1];
        rgba[i*4 + 2] = rgbData[i*3 + 2];
        rgba[i*4 + 3] = 0.0f;
    }

    [tex replaceRegion:MTLRegionMake3D(0, 0, 0, dim, dim, dim)
           mipmapLevel:0
                 slice:0
             withBytes:rgba
           bytesPerRow:(NSUInteger)dim * 4 * sizeof(float)
         bytesPerImage:(NSUInteger)dim * dim * 4 * sizeof(float)];

    std::free(rgba);
    return tex;
}

static id<MTLTexture> createDummyTexture() {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.textureType = MTLTextureType3D;
    desc.pixelFormat = MTLPixelFormatRGBA32Float;
    desc.width = 1; desc.height = 1; desc.depth = 1;
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [g_device newTextureWithDescriptor:desc];
    [desc release];
    if (tex) {
        float rgba[4] = {0, 0, 0, 0};
        [tex replaceRegion:MTLRegionMake3D(0,0,0,1,1,1) mipmapLevel:0 slice:0
                 withBytes:rgba bytesPerRow:16 bytesPerImage:16];
    }
    return tex;
}

void InitTexturePipeline() {
    dispatch_once(&g_texPsoOnce, ^{
        if (!g_device) return;
        NSError* err = nil;
        id<MTLLibrary> lib = [g_device newLibraryWithSource:kTexShaderSource
                                                    options:nil error:&err];
        if (!lib) {
            MLOG("tex shader compile FAILED: %s",
                 err ? [[err localizedDescription] UTF8String] : "unknown");
            return;
        }

        id<MTLFunction> fn8  = [lib newFunctionWithName:@"lut_apply_tex_8bpc"];
        if (fn8)  g_texPSO_8  = [g_device newComputePipelineStateWithFunction:fn8  error:&err];

        id<MTLFunction> fn16 = [lib newFunctionWithName:@"lut_apply_tex_16bpc"];
        if (fn16) g_texPSO_16 = [g_device newComputePipelineStateWithFunction:fn16 error:&err];

        id<MTLFunction> fn32 = [lib newFunctionWithName:@"lut_apply_tex_32bpc"];
        if (fn32) g_texPSO_32f = [g_device newComputePipelineStateWithFunction:fn32 error:&err];

        g_texPipelineOK = (g_texPSO_8 && g_texPSO_16 && g_texPSO_32f);

        if (g_texPipelineOK) {
            g_dummyTex = createDummyTexture();
            if (!g_dummyTex) g_texPipelineOK = false;
        }

        MLOG("tex pipeline: %s", g_texPipelineOK ? "OK" : "FAILED");
    });
}

static bool dispatchTextureKernel(id<MTLComputePipelineState> pso,
                                   const GPUTexParams& params,
                                   id<MTLBuffer> srcBuf,
                                   id<MTLBuffer> dstBuf,
                                   id<MTLTexture> textures[4],
                                   int frameW, int frameH,
                                   NSUInteger dstReadbackBytes,
                                   void* dstData)
{
    id<MTLCommandBuffer> cmdBuf = [g_queue commandBuffer];
    if (!cmdBuf) return false;

    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
    if (!enc) return false;

    [enc setComputePipelineState:pso];
    [enc setBuffer:srcBuf offset:0 atIndex:0];
    [enc setBuffer:dstBuf offset:0 atIndex:1];
    [enc setBytes:&params length:sizeof(params) atIndex:2];

    for (int i = 0; i < 4; i++)
        [enc setTexture:textures[i] atIndex:i];

    NSUInteger tw = pso.threadExecutionWidth;
    NSUInteger th = pso.maxTotalThreadsPerThreadgroup / tw;
    [enc dispatchThreads:MTLSizeMake((NSUInteger)frameW, (NSUInteger)frameH, 1)
       threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
    [enc endEncoding];

    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    if (cmdBuf.status == MTLCommandBufferStatusError) return false;

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

    // ── Validation guards (debug-only sanity checks) ──
    if (srcRowBytes < w * desc.bytesPerPixel) {
        MLOG("dispatch skip: srcRowBytes=%d too small for %dx%dbpp", srcRowBytes, w, desc.bytesPerPixel);
        return false;
    }
    if (dstRowBytes < w * desc.bytesPerPixel) {
        MLOG("dispatch skip: dstRowBytes=%d too small for %dx%dbpp", dstRowBytes, w, desc.bytesPerPixel);
        return false;
    }
    if (srcRowBytes % desc.bytesPerPixel != 0 || dstRowBytes % desc.bytesPerPixel != 0) {
        MLOG("dispatch skip: rowBytes not aligned to bpp (src=%d dst=%d bpp=%d)",
             srcRowBytes, dstRowBytes, desc.bytesPerPixel);
        return false;
    }

    const NSUInteger srcSize  = (NSUInteger)h * (NSUInteger)srcRowBytes;
    const NSUInteger dstSize  = (NSUInteger)h * (NSUInteger)dstRowBytes;
    const NSUInteger lutBytes = totalLutFloats * sizeof(float);

    // ── LUT cache (process lifetime; thread-safe with mutex) ──
    enum class LUTPathMode : uint8_t { kBuffer = 0, kTexture = 1 };
    struct LUTCacheKey {
        const float* ptr;
        uint16_t     dim;
        uint8_t      path;
        uint8_t      pixelFmt; // only used for texture
        bool operator==(const LUTCacheKey& o) const {
            return ptr == o.ptr && dim == o.dim && path == o.path && pixelFmt == o.pixelFmt;
        }
    };
    struct LUTKeyHash {
        std::size_t operator()(const LUTCacheKey& k) const noexcept {
            return (std::hash<const float*>()(k.ptr) ^ (std::hash<uint16_t>()(k.dim) << 1)) ^
                   (std::hash<uint8_t>()(k.path) << 2) ^ (std::hash<uint8_t>()(k.pixelFmt) << 3);
        }
    };

    static std::unordered_map<LUTCacheKey, id<MTLTexture>, LUTKeyHash> g_texLUTCache;
    static std::unordered_map<LUTCacheKey, id<MTLBuffer>,  LUTKeyHash> g_bufLUTCache;
    static std::mutex g_lutCacheMutex;

    auto getOrCreateLUTTexture = [&](const GPUDispatchDesc::Layer& L) -> id<MTLTexture> {
        LUTCacheKey key{L.lutData, (uint16_t)L.dimension, (uint8_t)LUTPathMode::kTexture,
                        (uint8_t)MTLPixelFormatRGBA32Float};
        {
            std::lock_guard<std::mutex> lock(g_lutCacheMutex);
            auto it = g_texLUTCache.find(key);
            if (it != g_texLUTCache.end()) {
                return [it->second retain]; // caller releases; cache keeps its own retain
            }
        }

        id<MTLTexture> tex = nil;
        MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
        desc.textureType = MTLTextureType3D;
        desc.pixelFormat = MTLPixelFormatRGBA32Float;
        desc.width  = (NSUInteger)L.dimension;
        desc.height = (NSUInteger)L.dimension;
        desc.depth  = (NSUInteger)L.dimension;
        desc.usage  = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        tex = [g_device newTextureWithDescriptor:desc];
        [desc release];
        if (!tex) return nil;

        const NSUInteger n = (NSUInteger)L.dimension * L.dimension * L.dimension;
        float* rgba = (float*)std::malloc(n * 4 * sizeof(float));
        if (!rgba) { [tex release]; return nil; }
        for (NSUInteger i = 0; i < n; i++) {
            rgba[i*4 + 0] = L.lutData[i*3 + 0];
            rgba[i*4 + 1] = L.lutData[i*3 + 1];
            rgba[i*4 + 2] = L.lutData[i*3 + 2];
            rgba[i*4 + 3] = 0.0f;
        }
        [tex replaceRegion:MTLRegionMake3D(0,0,0,L.dimension,L.dimension,L.dimension)
               mipmapLevel:0 slice:0
                 withBytes:rgba
               bytesPerRow:(NSUInteger)L.dimension * 4 * sizeof(float)
             bytesPerImage:(NSUInteger)L.dimension * L.dimension * 4 * sizeof(float)];
        std::free(rgba);

        {
            std::lock_guard<std::mutex> lock(g_lutCacheMutex);
            g_texLUTCache[key] = [tex retain]; // cache owns one retain
        }
        return tex; // caller owns this retain and must release
    };

    auto getOrCreateLUTBuffer = [&](const GPUDispatchDesc::Layer& L) -> id<MTLBuffer> {
        LUTCacheKey key{L.lutData, (uint16_t)L.dimension, (uint8_t)LUTPathMode::kBuffer, 0};
        {
            std::lock_guard<std::mutex> lock(g_lutCacheMutex);
            auto it = g_bufLUTCache.find(key);
            if (it != g_bufLUTCache.end()) {
                return [it->second retain]; // caller releases; cache retains
            }
        }

        const NSUInteger layerFloats = (NSUInteger)L.dimension * L.dimension * L.dimension * 3;
        id<MTLBuffer> buf = [g_device newBufferWithLength:layerFloats * sizeof(float)
                                                  options:MTLResourceStorageModeShared];
        if (!buf) return nil;
        std::memcpy(buf.contents, L.lutData, layerFloats * sizeof(float));

        {
            std::lock_guard<std::mutex> lock(g_lutCacheMutex);
            g_bufLUTCache[key] = [buf retain]; // cache owns
        }
        return buf; // caller owns this retain and must release
    };

    // Combined LUT buffer reused (single shared, grows as needed), guarded by mutex.
    static id<MTLBuffer> g_combinedLutBuf = nil;
    static NSUInteger    g_combinedLutCap = 0;
    static std::mutex    g_combinedBufMutex;

    auto AcquireSharedBuffer = [&](id<MTLBuffer>& cached,
                                   NSUInteger& cap,
                                   NSUInteger neededBytes,
                                   const char* tag) -> id<MTLBuffer> {
        std::lock_guard<std::mutex> lock(g_ioBufMutex);
        if (!cached || cap < neededBytes) {
            if (cached) { [cached release]; cached = nil; }
            cached = [g_device newBufferWithLength:neededBytes
                                           options:MTLResourceStorageModeShared];
            cap = cached ? neededBytes : 0;
#if VTC_METAL_LOG
            MLOG("IOBUF ALLOC %s %lu bytes", tag, (unsigned long)neededBytes);
#endif
        } else {
#if VTC_METAL_LOG
            MLOG("IOBUF REUSE %s req=%lu cap=%lu", tag,
                 (unsigned long)neededBytes, (unsigned long)cap);
#endif
        }
        return cached ? [cached retain] : nil;  // caller releases; cache keeps own retain
    };

    @autoreleasepool {
        ensureTickScale();

        // Per-dispatch Metal resources (owned via Create Rule). ARC is OFF.
        id<MTLBuffer> srcBuf = nil;
        id<MTLBuffer> dstBuf = nil;
        id<MTLBuffer> lutBuf = nil;
        id<MTLTexture> lutTex[4] = { nil, nil, nil, nil };
        bool success = false;

        @try {
            do {
                srcBuf = AcquireSharedBuffer(g_cachedSrcBuf, g_cachedSrcCap, srcSize, "src");
                if (!srcBuf) { MLOG("dispatch fail: srcBuf alloc"); break; }
                std::memcpy(srcBuf.contents, srcData, srcSize);

                dstBuf = AcquireSharedBuffer(g_cachedDstBuf, g_cachedDstCap, dstSize, "dst");
                if (!dstBuf) { MLOG("dispatch fail: dstBuf alloc"); break; }

                lutBuf = [g_device newBufferWithLength:lutBytes
                                               options:MTLResourceStorageModeShared];
                if (!lutBuf) { MLOG("dispatch fail: lutBuf alloc"); break; }

                float* lutDst = (float*)lutBuf.contents;
                uint32_t floatOff = 0;
                for (int i = 0; i < desc.layerCount; i++) {
                    const auto& L = desc.layers[i];
                    NSUInteger layerFloats = (NSUInteger)L.dimension * L.dimension * L.dimension * 3;
                    std::memcpy(lutDst + floatOff, L.lutData, layerFloats * sizeof(float));
                    floatOff += (uint32_t)layerFloats;
                }

                const bool tryTexture = (g_gpuPathMode != GPUPathMode::kForceBuffer);
                const bool tryBuffer  = (g_gpuPathMode != GPUPathMode::kForceTexture);

                MLOG("path mode: %s  tryTex=%d tryBuf=%d",
                     g_gpuPathMode == GPUPathMode::kAuto ? "Auto" :
                     g_gpuPathMode == GPUPathMode::kForceTexture ? "ForceTexture" : "ForceBuffer",
                     tryTexture, tryBuffer);

                // ── Try 3D texture path ──
                if (tryTexture) {
                    InitTexturePipeline();
                    if (g_texPipelineOK && g_dummyTex) {
                        id<MTLComputePipelineState> texPso = nil;
                        if (is8bpc)       texPso = g_texPSO_8;
                        else if (is16bpc) texPso = g_texPSO_16;
                        else              texPso = g_texPSO_32f;

                        bool texturesReady = true;
                        id<MTLTexture> texArr[4] = {g_dummyTex, g_dummyTex, g_dummyTex, g_dummyTex};
                        for (int i = 0; i < desc.layerCount; i++) {
                            texArr[i] = getOrCreateLUTTexture(desc.layers[i]);
                            lutTex[i] = texArr[i]; // owned; release in finally
                            if (!texArr[i]) { texturesReady = false; break; }
                        }

                        if (texturesReady && texPso) {
                            GPUTexParams texParams = {};
                            texParams.width      = (uint32_t)w;
                            texParams.height     = (uint32_t)h;
                            texParams.srcStride  = (uint32_t)(srcRowBytes / desc.bytesPerPixel);
                            texParams.dstStride  = (uint32_t)(dstRowBytes / desc.bytesPerPixel);
                            texParams.layerCount = (uint32_t)desc.layerCount;
                            for (int i = 0; i < desc.layerCount; i++) {
                                float d = (float)desc.layers[i].dimension;
                                texParams.layers[i].coordScale = (d - 1.0f) / d;
                                texParams.layers[i].coordBias  = 0.5f / d;
                                texParams.layers[i].intensity  = desc.layers[i].intensity;
                            }

                            MTIMER_BEGIN;
                            bool texOK = dispatchTextureKernel(texPso, texParams,
                                srcBuf, dstBuf, texArr,
                                w, h, dstSize, dstData);
                            if (texOK) {
                                MLOG("RENDERED via TEXTURE: %dx%d %dbpc layers=%d  %.3fms",
                                     w, h, bpcLabel, desc.layerCount, MTIMER_ELAPSED_MS);
                                success = true;
                                break;
                            }
                            MLOG("tex dispatch FAILED (%.3fms)", MTIMER_ELAPSED_MS);
                        } else {
                            MLOG("tex path skipped: pipeline=%d texturesReady=%d",
                                 (texPso != nil), texturesReady);
                        }
                    } else {
                        MLOG("tex pipeline not available");
                    }

                    if (!tryBuffer) {
                        MLOG("ForceTexture mode: texture failed, falling back to CPU");
                        break;
                    }
                    MLOG("texture path failed -> trying buffer path");
                }

                // ── Buffer-based GPU LUT path ──
                GPUParams params = {};
                params.width      = (uint32_t)w;
                params.height     = (uint32_t)h;
                params.layerCount = (uint32_t)desc.layerCount;
                params.srcStride  = (uint32_t)(srcRowBytes / desc.bytesPerPixel);
                params.dstStride  = (uint32_t)(dstRowBytes / desc.bytesPerPixel);

                floatOff = 0;
                for (int i = 0; i < desc.layerCount; i++) {
                    const auto& L = desc.layers[i];
                    NSUInteger layerFloats = (NSUInteger)L.dimension * L.dimension * L.dimension * 3;
                    params.layers[i].lutOffset  = floatOff;
                    params.layers[i].dimension  = (uint32_t)L.dimension;
                    params.layers[i].scale      = L.scale;
                    params.layers[i].intensity  = L.intensity;
                    floatOff += (uint32_t)layerFloats;
                }

                // Build/resize combined LUT buffer once; copy LUTs into it (no per-frame allocation).
                {
                    std::lock_guard<std::mutex> lock(g_combinedBufMutex);
                    if (!g_combinedLutBuf || g_combinedLutCap < lutBytes) {
                        if (g_combinedLutBuf) [g_combinedLutBuf release];
                        g_combinedLutBuf = [g_device newBufferWithLength:lutBytes
                                                                 options:MTLResourceStorageModeShared];
                        g_combinedLutCap = g_combinedLutBuf ? lutBytes : 0;
                    }
                    if (!g_combinedLutBuf) { MLOG("dispatch fail: combined lutBuf alloc"); break; }
                    float* dstLut = (float*)g_combinedLutBuf.contents;
                    uint32_t off = 0;
                    for (int i = 0; i < desc.layerCount; i++) {
                        const auto& L = desc.layers[i];
                        NSUInteger layerFloats = (NSUInteger)L.dimension * L.dimension * L.dimension * 3;
                        std::memcpy(dstLut + off, L.lutData, layerFloats * sizeof(float));
                        off += (uint32_t)layerFloats;
                    }
                    lutBuf = [g_combinedLutBuf retain]; // use shared buffer this frame
                }

                MTIMER_BEGIN;
                bool ok = dispatchKernel(pso, params,
                                         srcBuf, dstBuf, lutBuf,
                                         w, h, dstSize, dstData);
                if (ok) {
                    MLOG("RENDERED via BUFFER: %dx%d %dbpc layers=%d  %.3fms",
                         w, h, bpcLabel, desc.layerCount, MTIMER_ELAPSED_MS);
                } else {
                    MLOG("buffer dispatch FAILED -> CPU fallback  (%.3fms)",
                         MTIMER_ELAPSED_MS);
                }
                success = ok;
            } while (false);
        } @finally {
            // Create Rule: new/alloc/copy ⇒ we own; release to avoid leaks. ARC is OFF.
            for (int i = 0; i < 4; i++) {
                if (lutTex[i] && lutTex[i] != g_dummyTex) {
                    [lutTex[i] release];
                    lutTex[i] = nil;
                }
            }
            if (lutBuf) { [lutBuf release]; lutBuf = nil; }
            if (dstBuf) { [dstBuf release]; dstBuf = nil; }
            if (srcBuf) { [srcBuf release]; srcBuf = nil; }
            // commandBuffer/encoder are autoreleased (per Metal API); do not release.
        }

        return success;
    }
}

}  // namespace metal
}  // namespace vtc
