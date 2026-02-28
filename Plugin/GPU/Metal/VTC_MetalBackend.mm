#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "VTC_MetalBackend.h"

#include "../../Shared/VTC_LUTData.h"
#include "../../Core/VTC_CopyUtils.h"

#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

namespace vtc {
namespace metal {

namespace {

struct MetalParams {
    uint32_t width;
    uint32_t height;
    uint32_t srcRowBytes;
    uint32_t dstRowBytes;
    uint32_t layerCount;
};

struct LayerInfo {
    uint32_t offset;
    uint32_t dim;
    float scale;
    float intensity;
};

static const char* kShaderSrc = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct LayerInfo { uint offset; uint dim; float scale; float intensity; };
struct Params { uint width; uint height; uint srcRowBytes; uint dstRowBytes; uint layerCount; };

inline uint lutIndex(uint d, uint xi, uint yi, uint zi) {
    return ((zi * d + yi) * d + xi) * 3;
}

inline float3 sampleLUT(device const float* lutData, constant LayerInfo& l, float3 rgb) {
    uint d = l.dim;
    uint dm = d - 1;

    float x = clamp(rgb.r, 0.0f, 1.0f) * l.scale;
    float y = clamp(rgb.g, 0.0f, 1.0f) * l.scale;
    float z = clamp(rgb.b, 0.0f, 1.0f) * l.scale;

    uint x0 = (uint)x, y0 = (uint)y, z0 = (uint)z;
    uint x1 = min(x0 + 1, dm), y1 = min(y0 + 1, dm), z1 = min(z0 + 1, dm);

    float fx = x - (float)x0;
    float fy = y - (float)y0;
    float fz = z - (float)z0;

    device const float* base = lutData + l.offset;

    float3 c000 = float3(base[lutIndex(d, x0, y0, z0)], base[lutIndex(d, x0, y0, z0) + 1], base[lutIndex(d, x0, y0, z0) + 2]);
    float3 c100 = float3(base[lutIndex(d, x1, y0, z0)], base[lutIndex(d, x1, y0, z0) + 1], base[lutIndex(d, x1, y0, z0) + 2]);
    float3 c010 = float3(base[lutIndex(d, x0, y1, z0)], base[lutIndex(d, x0, y1, z0) + 1], base[lutIndex(d, x0, y1, z0) + 2]);
    float3 c110 = float3(base[lutIndex(d, x1, y1, z0)], base[lutIndex(d, x1, y1, z0) + 1], base[lutIndex(d, x1, y1, z0) + 2]);
    float3 c001 = float3(base[lutIndex(d, x0, y0, z1)], base[lutIndex(d, x0, y0, z1) + 1], base[lutIndex(d, x0, y0, z1) + 2]);
    float3 c101 = float3(base[lutIndex(d, x1, y0, z1)], base[lutIndex(d, x1, y0, z1) + 1], base[lutIndex(d, x1, y0, z1) + 2]);
    float3 c011 = float3(base[lutIndex(d, x0, y1, z1)], base[lutIndex(d, x0, y1, z1) + 1], base[lutIndex(d, x0, y1, z1) + 2]);
    float3 c111 = float3(base[lutIndex(d, x1, y1, z1)], base[lutIndex(d, x1, y1, z1) + 1], base[lutIndex(d, x1, y1, z1) + 2]);

    float3 c00 = mix(c000, c100, fx);
    float3 c10 = mix(c010, c110, fx);
    float3 c01 = mix(c001, c101, fx);
    float3 c11 = mix(c011, c111, fx);
    float3 c0 = mix(c00, c10, fy);
    float3 c1 = mix(c01, c11, fy);

    return mix(c0, c1, fz);
}

kernel void vtc_passthrough_8u(device const uchar4* src [[buffer(0)]],
                               device uchar4* dst [[buffer(1)]],
                               constant Params& p [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint srow = p.srcRowBytes / sizeof(uchar4);
    uint drow = p.dstRowBytes / sizeof(uchar4);
    uint si = gid.y * srow + gid.x;
    uint di = gid.y * drow + gid.x;
    dst[di] = src[si];
}

kernel void vtc_apply_8u(device const uchar4* src [[buffer(0)]],
                         device uchar4* dst [[buffer(1)]],
                         constant Params& p [[buffer(2)]],
                         constant LayerInfo* layers [[buffer(3)]],
                         device const float* lutData [[buffer(4)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint srow = p.srcRowBytes / sizeof(uchar4);
    uint drow = p.dstRowBytes / sizeof(uchar4);
    uint si = gid.y * srow + gid.x;
    uint di = gid.y * drow + gid.x;

    uchar4 inPx = src[si];
    float3 c = float3((float)inPx.r, (float)inPx.g, (float)inPx.b) / 255.0f;

    for (uint i = 0; i < p.layerCount; ++i) {
        float3 lut = sampleLUT(lutData, layers[i], c);
        c = mix(c, lut, layers[i].intensity);
    }

    float3 outC = clamp(c, 0.0f, 1.0f) * 255.0f + 0.5f;
    dst[di] = uchar4((uchar)min(outC.r, 255.0f),
                     (uchar)min(outC.g, 255.0f),
                     (uchar)min(outC.b, 255.0f),
                     inPx.a);
}

kernel void vtc_passthrough_16u(device const ushort4* src [[buffer(0)]],
                                device ushort4* dst [[buffer(1)]],
                                constant Params& p [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint srow = p.srcRowBytes / sizeof(ushort4);
    uint drow = p.dstRowBytes / sizeof(ushort4);
    uint si = gid.y * srow + gid.x;
    uint di = gid.y * drow + gid.x;
    dst[di] = src[si];
}

kernel void vtc_apply_16u(device const ushort4* src [[buffer(0)]],
                          device ushort4* dst [[buffer(1)]],
                          constant Params& p [[buffer(2)]],
                          constant LayerInfo* layers [[buffer(3)]],
                          device const float* lutData [[buffer(4)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint srow = p.srcRowBytes / sizeof(ushort4);
    uint drow = p.dstRowBytes / sizeof(ushort4);
    uint si = gid.y * srow + gid.x;
    uint di = gid.y * drow + gid.x;

    ushort4 inPx = src[si];
    float3 c = float3((float)inPx.r, (float)inPx.g, (float)inPx.b) / 32768.0f;

    for (uint i = 0; i < p.layerCount; ++i) {
        float3 lut = sampleLUT(lutData, layers[i], c);
        c = mix(c, lut, layers[i].intensity);
    }

    float3 outC = clamp(c, 0.0f, 1.0f) * 32768.0f + 0.5f;
    dst[di] = ushort4((ushort)min(outC.r, 32768.0f),
                      (ushort)min(outC.g, 32768.0f),
                      (ushort)min(outC.b, 32768.0f),
                      inPx.a);
}

kernel void vtc_passthrough_32f(device const float4* src [[buffer(0)]],
                                device float4* dst [[buffer(1)]],
                                constant Params& p [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint srow = p.srcRowBytes / sizeof(float4);
    uint drow = p.dstRowBytes / sizeof(float4);
    uint si = gid.y * srow + gid.x;
    uint di = gid.y * drow + gid.x;
    dst[di] = src[si];
}

kernel void vtc_apply_32f(device const float4* src [[buffer(0)]],
                          device float4* dst [[buffer(1)]],
                          constant Params& p [[buffer(2)]],
                          constant LayerInfo* layers [[buffer(3)]],
                          device const float* lutData [[buffer(4)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint srow = p.srcRowBytes / sizeof(float4);
    uint drow = p.dstRowBytes / sizeof(float4);
    uint si = gid.y * srow + gid.x;
    uint di = gid.y * drow + gid.x;

    float4 inPx = src[si];
    float3 c = inPx.rgb;

    for (uint i = 0; i < p.layerCount; ++i) {
        float3 lut = sampleLUT(lutData, layers[i], c);
        c = mix(c, lut, layers[i].intensity);
    }

    dst[di] = float4(clamp(c, 0.0f, 1.0f), inPx.a);
}
)METAL";

id<MTLDevice> gDevice = nil;
id<MTLLibrary> gLib = nil;
id<MTLComputePipelineState> gPass8 = nil;
id<MTLComputePipelineState> gApply8 = nil;
id<MTLComputePipelineState> gPass16 = nil;
id<MTLComputePipelineState> gApply16 = nil;
id<MTLComputePipelineState> gPass32 = nil;
id<MTLComputePipelineState> gApply32 = nil;
std::once_flag gInit;
std::mutex gMutex;

bool envEnabled(const char* name) {
    const char* v = std::getenv(name);
    return v && (std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 || std::strcmp(v, "TRUE") == 0);
}

bool initPipeline(id<MTLDevice> device, id<MTLLibrary> lib, const char* fnName, id<MTLComputePipelineState>* outPso) {
    NSError* err = nil;
    NSString* name = [NSString stringWithUTF8String:fnName];
    id<MTLFunction> fn = [lib newFunctionWithName:name];
    if (!fn) {
        return false;
    }
    *outPso = [device newComputePipelineStateWithFunction:fn error:&err];
    return *outPso != nil && err == nil;
}

void init(id<MTLCommandQueue> q) {
    std::call_once(gInit, [&]() {
        gDevice = q.device;
        if (!gDevice) {
            return;
        }

        NSError* err = nil;
        NSString* src = [NSString stringWithUTF8String:kShaderSrc];
        gLib = [gDevice newLibraryWithSource:src options:nil error:&err];
        if (!gLib || err) {
            return;
        }

        if (!initPipeline(gDevice, gLib, "vtc_passthrough_8u", &gPass8)) return;
        if (!initPipeline(gDevice, gLib, "vtc_apply_8u", &gApply8)) return;
        if (!initPipeline(gDevice, gLib, "vtc_passthrough_16u", &gPass16)) return;
        if (!initPipeline(gDevice, gLib, "vtc_apply_16u", &gApply16)) return;
        if (!initPipeline(gDevice, gLib, "vtc_passthrough_32f", &gPass32)) return;
        if (!initPipeline(gDevice, gLib, "vtc_apply_32f", &gApply32)) return;
    });
}

void buildLayers(const ParamsSnapshot& p, std::array<LayerInfo, 4>& outLayers, std::vector<float>& outLUT, uint32_t& outCount) {
    outCount = 0;
    outLUT.clear();

    auto add = [&](const LayerParams& lp, const LUT3D* table, int count) {
        if (!lp.enabled || lp.lutIndex < 0 || lp.lutIndex >= count || lp.intensity <= 0.0001f) {
            return;
        }
        const LUT3D& L = table[lp.lutIndex];
        LayerInfo info{};
        info.offset = static_cast<uint32_t>(outLUT.size());
        info.dim = static_cast<uint32_t>(L.dimension);
        info.scale = static_cast<float>(L.dimension - 1);
        info.intensity = lp.intensity < 0.f ? 0.f : (lp.intensity > 1.f ? 1.f : lp.intensity);
        const int n = L.dimension * L.dimension * L.dimension * 3;
        outLUT.insert(outLUT.end(), L.data, L.data + n);
        outLayers[outCount++] = info;
    };

    add(p.logConvert, kLogLUTs, kLogLUTCount);
    add(p.creative, kRec709LUTs, kRec709LUTCount);
    add(p.secondary, kRec709LUTs, kRec709LUTCount);
    add(p.accent, kRec709LUTs, kRec709LUTCount);
}

bool selectPipelines(FrameFormat format, uint32_t layerCount, id<MTLComputePipelineState>* outPso) {
    if (format == FrameFormat::kRGBA_8u) {
        *outPso = (layerCount == 0) ? gPass8 : gApply8;
        return *outPso != nil;
    }
    if (format == FrameFormat::kRGBA_16u) {
        *outPso = (layerCount == 0) ? gPass16 : gApply16;
        return *outPso != nil;
    }
    if (format == FrameFormat::kRGBA_32f) {
        *outPso = (layerCount == 0) ? gPass32 : gApply32;
        return *outPso != nil;
    }
    return false;
}

const char* formatName(FrameFormat format) {
    switch (format) {
        case FrameFormat::kRGBA_8u: return "8u";
        case FrameFormat::kRGBA_16u: return "16u";
        case FrameFormat::kRGBA_32f: return "32f";
    }
    return "unknown";
}

}  // namespace

bool TryDispatchNative(const ParamsSnapshot& params,
                       const FrameDesc& src,
                       FrameDesc& dst,
                       void* nativeCommandQueue,
                       bool* usedGPU,
                       const char** reason) {
    if (usedGPU) {
        *usedGPU = false;
    }
    if (reason) {
        *reason = "not_attempted";
    }

    if (!nativeCommandQueue) {
        if (reason) *reason = "queue_missing";
        return false;
    }
    if (!IsSupported(src) || !IsSupported(dst) || !SameGeometry(src, dst)) {
        if (reason) *reason = "unsupported_or_geometry";
        return false;
    }

    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)nativeCommandQueue;
    if (!q) {
        if (reason) *reason = "queue_bridge_failed";
        return false;
    }

    std::lock_guard<std::mutex> lock(gMutex);
    init(q);
    if (!gDevice || !gLib) {
        if (reason) *reason = "pipeline_unavailable";
        return false;
    }

    std::array<LayerInfo, 4> layers{};
    std::vector<float> lut;
    uint32_t layerCount = 0;
    buildLayers(params, layers, lut, layerCount);

    id<MTLComputePipelineState> pso = nil;
    if (!selectPipelines(src.format, layerCount, &pso)) {
        if (reason) *reason = "pipeline_unavailable";
        return false;
    }

    const size_t srcBytes = static_cast<size_t>(src.rowBytes) * static_cast<size_t>(src.height);
    const size_t dstBytes = static_cast<size_t>(dst.rowBytes) * static_cast<size_t>(dst.height);
    id<MTLBuffer> srcBuf = [gDevice newBufferWithBytesNoCopy:src.data length:srcBytes options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> dstBuf = [gDevice newBufferWithBytesNoCopy:dst.data length:dstBytes options:MTLResourceStorageModeShared deallocator:nil];
    if (!srcBuf || !dstBuf) {
        if (reason) *reason = "buffer_wrap_failed";
        return false;
    }

    MetalParams p{static_cast<uint32_t>(src.width), static_cast<uint32_t>(src.height),
                  static_cast<uint32_t>(src.rowBytes), static_cast<uint32_t>(dst.rowBytes), layerCount};

    id<MTLBuffer> pbuf = [gDevice newBufferWithBytes:&p length:sizeof(MetalParams) options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

    [enc setComputePipelineState:pso];
    [enc setBuffer:srcBuf offset:0 atIndex:0];
    [enc setBuffer:dstBuf offset:0 atIndex:1];
    [enc setBuffer:pbuf offset:0 atIndex:2];

    if (layerCount > 0) {
        id<MTLBuffer> lbuf = [gDevice newBufferWithBytes:layers.data() length:sizeof(LayerInfo) * layerCount options:MTLResourceStorageModeShared];
        id<MTLBuffer> tbuf = [gDevice newBufferWithBytes:lut.data() length:sizeof(float) * lut.size() options:MTLResourceStorageModeShared];
        [enc setBuffer:lbuf offset:0 atIndex:3];
        [enc setBuffer:tbuf offset:0 atIndex:4];
    }

    MTLSize grid = MTLSizeMake(p.width, p.height, 1);
    NSUInteger tw = pso.threadExecutionWidth;
    if (!tw) tw = 8;
    NSUInteger th = pso.maxTotalThreadsPerThreadgroup / tw;
    if (!th) th = 8;
    MTLSize tg = MTLSizeMake(tw, th, 1);

    [enc dispatchThreads:grid threadsPerThreadgroup:tg];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    if (cb.status != MTLCommandBufferStatusCompleted) {
        if (reason) *reason = "metal_dispatch_failed";
        return false;
    }

    if (usedGPU) {
        *usedGPU = true;
    }
    if (reason) {
        *reason = (layerCount == 0) ? "metal_passthrough" : "metal_apply";
    }

    if (envEnabled("VTC_DIAG")) {
        static std::atomic<bool> once{false};
        bool expected = false;
        if (once.compare_exchange_strong(expected, true)) {
            std::fprintf(stderr, "[VTC][diag] Native Metal path active (%s, fmt=%s)\\n",
                         (layerCount == 0) ? "passthrough" : "lut_apply",
                         formatName(src.format));
        }
    }

    return true;
}

}  // namespace metal
}  // namespace vtc
