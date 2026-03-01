#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "VTC_MetalBackend.h"

#include "../../Core/VTC_CopyUtils.h"
#include "../../Shared/VTC_LUTData.h"

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

id<MTLDevice> gDevice = nil;
id<MTLLibrary> gLib = nil;
id<MTLComputePipelineState> gPass = nil;
id<MTLComputePipelineState> gApply = nil;
std::once_flag gInit;
std::mutex gMutex;

bool envEnabled(const char *name) {
  const char *v = std::getenv(name);
  return v && (std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 ||
               std::strcmp(v, "TRUE") == 0);
}

// Inline Metal shader source — compiled at runtime because OFX plugins
// can't use [device newDefaultLibrary] (only searches main app bundle).
static NSString *const kShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

struct MetalParams {
    uint layerCount;
};

struct LayerInfo {
    uint offset;
    uint dim;
    float scale;
    float intensity;
};

inline float3 sampleLUT3D(device const float* lut, int dim, float r, float g, float b) {
    float s = float(dim - 1);
    r = clamp(r, 0.0f, 1.0f) * s;
    g = clamp(g, 0.0f, 1.0f) * s;
    b = clamp(b, 0.0f, 1.0f) * s;
    int x0 = int(r), y0 = int(g), z0 = int(b);
    int x1 = min(x0+1, dim-1), y1 = min(y0+1, dim-1), z1 = min(z0+1, dim-1);
    float fx = r-x0, fy = g-y0, fz = b-z0;
    int d2 = dim*dim;
    int i000=(z0*d2+y0*dim+x0)*3, i100=(z0*d2+y0*dim+x1)*3;
    int i010=(z0*d2+y1*dim+x0)*3, i110=(z0*d2+y1*dim+x1)*3;
    int i001=(z1*d2+y0*dim+x0)*3, i101=(z1*d2+y0*dim+x1)*3;
    int i011=(z1*d2+y1*dim+x0)*3, i111=(z1*d2+y1*dim+x1)*3;
    float3 c000={lut[i000],lut[i000+1],lut[i000+2]};
    float3 c100={lut[i100],lut[i100+1],lut[i100+2]};
    float3 c010={lut[i010],lut[i010+1],lut[i010+2]};
    float3 c110={lut[i110],lut[i110+1],lut[i110+2]};
    float3 c001={lut[i001],lut[i001+1],lut[i001+2]};
    float3 c101={lut[i101],lut[i101+1],lut[i101+2]};
    float3 c011={lut[i011],lut[i011+1],lut[i011+2]};
    float3 c111={lut[i111],lut[i111+1],lut[i111+2]};
    float3 c00=mix(c000,c100,fx), c10=mix(c010,c110,fx);
    float3 c01=mix(c001,c101,fx), c11=mix(c011,c111,fx);
    float3 c0=mix(c00,c10,fy), c1=mix(c01,c11,fy);
    return mix(c0,c1,fz);
}

kernel void vtc_passthrough_32f(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(src.read(gid), gid);
}

kernel void vtc_apply_32f(
    texture2d<float, access::read>  src    [[texture(0)]],
    texture2d<float, access::write> dst    [[texture(1)]],
    constant MetalParams&           p      [[buffer(0)]],
    constant LayerInfo*             layers [[buffer(1)]],
    device const float*             lutBuf [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = src.read(gid);
    float r = c.x, g = c.y, b = c.z;
    for (uint i = 0; i < p.layerCount && i < 4; ++i) {
        float3 lutRGB = sampleLUT3D(lutBuf + layers[i].offset,
                                     int(layers[i].dim), r, g, b);
        r = mix(r, lutRGB.x, layers[i].intensity);
        g = mix(g, lutRGB.y, layers[i].intensity);
        b = mix(b, lutRGB.z, layers[i].intensity);
    }
    dst.write(float4(r, g, b, c.w), gid);
}
)";

static void metalDiagLog(const char *fmt, ...) {
  FILE *f = fopen("/tmp/vtc_ofx_diag.log", "a");
  if (f) {
    va_list args;
    va_start(args, fmt);
    fprintf(f, "[METAL] ");
    vfprintf(f, fmt, args);
    fprintf(f, "\n");
    va_end(args);
    fclose(f);
  }
}

void initPipeline(id<MTLCommandQueue> q) {
  std::call_once(gInit, [&]() {
    gDevice = q.device;
    if (!gDevice) {
      metalDiagLog("q.device is null");
      return;
    }
    // Compile shaders from source at runtime (OFX plugins can't use
    // newDefaultLibrary — it only searches the main app bundle).
    NSError *e = nil;
    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.languageVersion = MTLLanguageVersion2_0;
    gLib = [gDevice newLibraryWithSource:kShaderSource options:opts error:&e];
    if (!gLib) {
      metalDiagLog("shader compile failed: %s",
                   e ? [[e localizedDescription] UTF8String] : "unknown");
      return;
    }
    e = nil;
    id<MTLFunction> passFn = [gLib newFunctionWithName:@"vtc_passthrough_32f"];
    id<MTLFunction> applyFn = [gLib newFunctionWithName:@"vtc_apply_32f"];
    if (!passFn || !applyFn) {
      metalDiagLog("kernel functions not found");
      return;
    }
    gPass = [gDevice newComputePipelineStateWithFunction:passFn error:&e];
    if (!gPass || e) {
      metalDiagLog("pass pipeline failed: %s",
                   e ? [[e localizedDescription] UTF8String] : "unknown");
      return;
    }
    e = nil;
    gApply = [gDevice newComputePipelineStateWithFunction:applyFn error:&e];
    if (!gApply || e) {
      metalDiagLog("apply pipeline failed: %s",
                   e ? [[e localizedDescription] UTF8String] : "unknown");
      return;
    }
    metalDiagLog("pipeline initialized OK");
  });
}

// Blit fallback: copy src texture to dst texture when compute pipeline is
// unavailable. Ensures video passes through without white screen.
bool blitCopy(id<MTLCommandQueue> q, id<MTLTexture> srcTex,
              id<MTLTexture> dstTex) {
  if (!q || !srcTex || !dstTex)
    return false;
  id<MTLCommandBuffer> cb = [q commandBuffer];
  if (!cb)
    return false;
  id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
  if (!blit)
    return false;

  MTLSize size = MTLSizeMake(std::min(srcTex.width, dstTex.width),
                             std::min(srcTex.height, dstTex.height), 1);
  [blit copyFromTexture:srcTex
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:size
              toTexture:dstTex
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];

  [blit endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  return cb.status == MTLCommandBufferStatusCompleted;
}

void buildLayers(const ParamsSnapshot &p, std::array<LayerInfo, 4> &layers,
                 std::vector<float> &lutData, uint32_t &count) {
  count = 0;
  lutData.clear();
  auto add = [&](const LayerParams &lp, const LUT3D *table, int n) {
    if (!lp.enabled || lp.lutIndex < 0 || lp.lutIndex >= n ||
        lp.intensity <= 0.0001f) {
      return;
    }
    const LUT3D &lut = table[lp.lutIndex];
    LayerInfo info{};
    info.offset = static_cast<uint32_t>(lutData.size());
    info.dim = static_cast<uint32_t>(lut.dimension);
    info.scale = static_cast<float>(lut.dimension - 1);
    info.intensity =
        lp.intensity < 0.f ? 0.f : (lp.intensity > 1.f ? 1.f : lp.intensity);
    const int lutValues = lut.dimension * lut.dimension * lut.dimension * 3;
    lutData.insert(lutData.end(), lut.data, lut.data + lutValues);
    layers[count++] = info;
  };
  add(p.logConvert, kLogLUTs, kLogLUTCount);
  add(p.creative, kRec709LUTs, kRec709LUTCount);
  add(p.secondary, kRec709LUTs, kRec709LUTCount);
  add(p.accent, kRec709LUTs, kRec709LUTCount);
}

} // namespace

bool TryDispatchNative(const ParamsSnapshot &params, const FrameDesc &src,
                       FrameDesc &dst, void *nativeCommandQueue, bool *usedGPU,
                       const char **reason, bool forceStaging) {
  if (usedGPU) {
    *usedGPU = false;
  }
  if (reason) {
    *reason = "not_attempted";
  }
  if (!forceStaging && !envEnabled("VTC_ENABLE_GPU")) {
    if (reason) {
      *reason = "gpu_disabled_default";
    }
    return false;
  }

  try {
    @try {
      if (!nativeCommandQueue) {
        if (reason)
          *reason = "queue_missing";
        return false;
      }
      if (!IsSupported(src) || !IsSupported(dst) || !SameGeometry(src, dst)) {
        if (reason)
          *reason = "unsupported_or_geometry";
        return false;
      }
      if (src.format != FrameFormat::kRGBA_32f ||
          dst.format != FrameFormat::kRGBA_32f) {
        if (reason)
          *reason = "format_not_32f";
        return false;
      }

      id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)nativeCommandQueue;
      if (!q) {
        if (reason)
          *reason = "queue_bridge_failed";
        return false;
      }

      std::lock_guard<std::mutex> lock(gMutex);
      initPipeline(q);
      if (!gDevice || !gPass || !gApply) {
        if (reason)
          *reason = "pipeline_unavailable";
        return false;
      }

      const size_t srcBytes =
          static_cast<size_t>(src.rowBytes) * static_cast<size_t>(src.height);
      const size_t dstBytes =
          static_cast<size_t>(dst.rowBytes) * static_cast<size_t>(dst.height);

      // Use staging buffers to avoid host-pointer lifetime/alignment issues.
      id<MTLBuffer> srcBuf =
          [gDevice newBufferWithLength:srcBytes
                               options:MTLResourceStorageModeShared];
      id<MTLBuffer> dstBuf =
          [gDevice newBufferWithLength:dstBytes
                               options:MTLResourceStorageModeShared];
      if (!srcBuf || !dstBuf) {
        if (reason)
          *reason = "buffer_alloc_failed";
        return false;
      }
      std::memcpy([srcBuf contents], src.data, srcBytes);

      std::array<LayerInfo, 4> layers{};
      std::vector<float> lutData;
      uint32_t layerCount = 0;
      buildLayers(params, layers, lutData, layerCount);

      const MetalParams p{static_cast<uint32_t>(src.width),
                          static_cast<uint32_t>(src.height),
                          static_cast<uint32_t>(src.rowBytes),
                          static_cast<uint32_t>(dst.rowBytes), layerCount};

      id<MTLBuffer> pbuf =
          [gDevice newBufferWithBytes:&p
                               length:sizeof(MetalParams)
                              options:MTLResourceStorageModeShared];
      if (!pbuf) {
        if (reason)
          *reason = "params_buffer_failed";
        return false;
      }

      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
      id<MTLComputePipelineState> pso = (layerCount == 0) ? gPass : gApply;
      [enc setComputePipelineState:pso];
      [enc setBuffer:srcBuf offset:0 atIndex:0];
      [enc setBuffer:dstBuf offset:0 atIndex:1];
      [enc setBuffer:pbuf offset:0 atIndex:2];

      if (layerCount > 0) {
        id<MTLBuffer> lbuf =
            [gDevice newBufferWithBytes:layers.data()
                                 length:sizeof(LayerInfo) * layerCount
                                options:MTLResourceStorageModeShared];
        id<MTLBuffer> tbuf =
            [gDevice newBufferWithBytes:lutData.data()
                                 length:sizeof(float) * lutData.size()
                                options:MTLResourceStorageModeShared];
        if (!lbuf || !tbuf) {
          if (reason)
            *reason = "lut_buffer_failed";
          return false;
        }
        [enc setBuffer:lbuf offset:0 atIndex:3];
        [enc setBuffer:tbuf offset:0 atIndex:4];
      }

      MTLSize grid = MTLSizeMake(p.width, p.height, 1);
      NSUInteger tw = pso.threadExecutionWidth;
      if (!tw)
        tw = 8;
      NSUInteger th = pso.maxTotalThreadsPerThreadgroup / tw;
      if (!th)
        th = 8;
      MTLSize tg = MTLSizeMake(tw, th, 1);
      [enc dispatchThreads:grid threadsPerThreadgroup:tg];
      [enc endEncoding];
      [cb commit];
      [cb waitUntilCompleted];

      if (cb.status != MTLCommandBufferStatusCompleted) {
        if (reason)
          *reason = "metal_dispatch_failed";
        return false;
      }

      std::memcpy(dst.data, [dstBuf contents], dstBytes);

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
          std::fprintf(stderr, "[VTC][diag] Native Metal path active (%s)\n",
                       (layerCount == 0 ? "passthrough" : "lut_apply"));
        }
      }
      return true;
    } @catch (NSException *e) {
      (void)e;
      if (reason) {
        *reason = "objc_exception";
      }
      return false;
    }
  } catch (...) {
    if (reason) {
      *reason = "cpp_exception";
    }
    return false;
  }
}

bool TryDispatchNativeBuffers(const ParamsSnapshot &params,
                              void *srcMetalBuffer, void *dstMetalBuffer,
                              FrameFormat format, int width, int height,
                              int srcRowBytes, int dstRowBytes,
                              void *nativeCommandQueue, bool *usedGPU,
                              const char **reason) {
  if (usedGPU) {
    *usedGPU = false;
  }
  if (reason) {
    *reason = "not_attempted";
  }

  if (!nativeCommandQueue || !srcMetalBuffer || !dstMetalBuffer) {
    if (reason)
      *reason = "buffer_or_queue_null";
    return false;
  }
  if (format != FrameFormat::kRGBA_32f) {
    if (reason)
      *reason = "format_not_32f";
    return false;
  }

  id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)nativeCommandQueue;
  id<MTLTexture> srcTex = (__bridge id<MTLTexture>)srcMetalBuffer;
  id<MTLTexture> dstTex = (__bridge id<MTLTexture>)dstMetalBuffer;
  if (!q || !srcTex || !dstTex) {
    if (reason)
      *reason = "texture_bridge_failed";
    return false;
  }

  try {
    @try {
      std::lock_guard<std::mutex> lock(gMutex);
      initPipeline(q);
      if (!gDevice || !gPass || !gApply) {
        // Pipeline unavailable — fall back to blit copy to avoid white screen.
        if (blitCopy(q, srcTex, dstTex)) {
          if (usedGPU)
            *usedGPU = true;
          if (reason)
            *reason = "blit_passthrough";
          return true;
        }
        if (reason)
          *reason = "pipeline_unavailable";
        return false;
      }

      std::array<LayerInfo, 4> layers{};
      std::vector<float> lutData;
      uint32_t layerCount = 0;
      buildLayers(params, layers, lutData, layerCount);

      const MetalParams p{layerCount};

      id<MTLBuffer> pbuf =
          [gDevice newBufferWithBytes:&p
                               length:sizeof(MetalParams)
                              options:MTLResourceStorageModeShared];
      if (!pbuf) {
        if (reason)
          *reason = "params_buffer_failed";
        return false;
      }

      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
      id<MTLComputePipelineState> pso = (layerCount == 0) ? gPass : gApply;
      [enc setComputePipelineState:pso];

      [enc setTexture:srcTex atIndex:0];
      [enc setTexture:dstTex atIndex:1];
      [enc setBuffer:pbuf offset:0 atIndex:0];

      if (layerCount > 0) {
        id<MTLBuffer> lbuf =
            [gDevice newBufferWithBytes:layers.data()
                                 length:sizeof(LayerInfo) * layerCount
                                options:MTLResourceStorageModeShared];
        id<MTLBuffer> tbuf =
            [gDevice newBufferWithBytes:lutData.data()
                                 length:sizeof(float) * lutData.size()
                                options:MTLResourceStorageModeShared];
        if (!lbuf || !tbuf) {
          if (reason)
            *reason = "lut_buffer_failed";
          return false;
        }
        [enc setBuffer:lbuf offset:0 atIndex:1];
        [enc setBuffer:tbuf offset:0 atIndex:2];
      }

      MTLSize grid = MTLSizeMake(dstTex.width, dstTex.height, 1);
      NSUInteger tw = pso.threadExecutionWidth;
      if (!tw)
        tw = 8;
      NSUInteger th = pso.maxTotalThreadsPerThreadgroup / tw;
      if (!th)
        th = 8;
      MTLSize tg = MTLSizeMake(tw, th, 1);
      [enc dispatchThreads:grid threadsPerThreadgroup:tg];
      [enc endEncoding];
      [cb commit];
      [cb waitUntilCompleted];

      if (cb.status != MTLCommandBufferStatusCompleted) {
        if (reason)
          *reason = "metal_dispatch_failed";
        return false;
      }

      if (usedGPU)
        *usedGPU = true;
      if (reason)
        *reason = (layerCount == 0) ? "metal_passthrough" : "metal_apply";

      if (envEnabled("VTC_DIAG")) {
        static std::atomic<bool> once{false};
        bool expected = false;
        if (once.compare_exchange_strong(expected, true)) {
          std::fprintf(
              stderr,
              "[VTC][diag] Native Metal path (host buffers) active (%s)\n",
              (layerCount == 0 ? "passthrough" : "lut_apply"));
        }
      }
      return true;
    } @catch (NSException *e) {
      (void)e;
      if (reason)
        *reason = "objc_exception";
      return false;
    }
  } catch (...) {
    if (reason)
      *reason = "cpp_exception";
    return false;
  }
}

} // namespace metal
} // namespace vtc
