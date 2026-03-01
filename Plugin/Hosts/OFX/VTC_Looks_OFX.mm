#include "VTC_OFX_ImageMap.h"
#include "VTC_OFX_Includes.h"
#include "VTC_ParamMap_OFX.h"

#include "../../Core/VTC_CopyUtils.h"
#include "../../Core/VTC_LUTSampling.h"
#include "../../GPU/Metal/VTC_MetalBackend.h"

#import <Metal/Metal.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace OFX {
namespace Private {
void setHost(OfxHost *host);
} // namespace Private
} // namespace OFX

namespace vtc {
namespace ofx {

namespace {
constexpr const char *kPluginID = "com.vtclooks.ofx.v2";
constexpr const char *kPluginGroup = "VTC";
constexpr const char *kPluginLabel = "VTC Looks";
constexpr bool kMetalPathEnabled = true; // allow Metal path (guarded)
constexpr const char *kDiagPath = "/tmp/vtc_ofx_diag.log";

bool layerActive(const LayerParams &lp, int maxCount) {
  return lp.enabled && lp.lutIndex >= 0 && lp.lutIndex < maxCount &&
         lp.intensity > 0.0001f;
}

void logParamsOncePerFrame(const ParamsSnapshot &snap, const char *path,
                           const char *reason) {
  static std::atomic<int> count{0};
  const int n = count.fetch_add(1);
  if (n >= 120) {
    return;
  }
  FILE *f = std::fopen("/tmp/vtc_ofx_diag.log", "a");
  if (!f) {
    return;
  }
  if (n == 0) {
    std::fprintf(f, "[VTC] first render from this plugin build\n");
  }
  std::fprintf(f,
               "[VTC][diag] path=%s reason=%s log={en=%d idx=%d int=%.3f} "
               "creative={en=%d idx=%d int=%.3f} secondary={en=%d idx=%d "
               "int=%.3f} accent={en=%d idx=%d int=%.3f}\n",
               path ? path : "unknown", reason ? reason : "unknown",
               snap.logConvert.enabled ? 1 : 0, snap.logConvert.lutIndex,
               snap.logConvert.intensity, snap.creative.enabled ? 1 : 0,
               snap.creative.lutIndex, snap.creative.intensity,
               snap.secondary.enabled ? 1 : 0, snap.secondary.lutIndex,
               snap.secondary.intensity, snap.accent.enabled ? 1 : 0,
               snap.accent.lutIndex, snap.accent.intensity);
  std::fclose(f);
}

bool envEnabled(const char *name) {
  const char *v = std::getenv(name);
  return v && (std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 ||
               std::strcmp(v, "TRUE") == 0);
}

const char *formatToStr(FrameFormat fmt) {
  switch (fmt) {
  case FrameFormat::kRGBA_8u:
    return "RGBA_8u";
  case FrameFormat::kRGBA_16u:
    return "RGBA_16u";
  case FrameFormat::kRGBA_32f:
    return "RGBA_32f";
  }
  return "unknown";
}

void logFrameOnce(const ParamsSnapshot &snap, const FrameDesc &frame,
                  const OFX::RenderArguments &args, const char *path,
                  const char *reason) {
  static std::atomic<int> count{0};
  const int n = count.fetch_add(1);
  if (n >= 200) {
    return;
  }

  FILE *f = std::fopen("/tmp/vtc_ofx_diag.log", "a");
  if (!f)
    return;

  if (n == 0) {
    std::fprintf(f, "[VTC] first render from this plugin build\n");
  }

  std::fprintf(f,
               "[VTC][diag] path=%s reason=%s fmt=%s %dx%d rb=%d hostMetal=%d "
               "hasQueue=%d renderScale=%.2fx%.2f seq=%d interactive=%d\n",
               path ? path : "unknown", reason ? reason : "unknown",
               formatToStr(frame.format), frame.width, frame.height,
               frame.rowBytes, args.isEnabledMetalRender ? 1 : 0,
               args.pMetalCmdQ ? 1 : 0, args.renderScale.x, args.renderScale.y,
               args.sequentialRenderStatus ? 1 : 0,
               args.interactiveRenderStatus ? 1 : 0);

  if (n < 50) {
    std::fprintf(f,
                 "        params log={en=%d idx=%d int=%.3f} creative={en=%d "
                 "idx=%d int=%.3f} secondary={en=%d idx=%d int=%.3f} "
                 "accent={en=%d idx=%d int=%.3f}\n",
                 snap.logConvert.enabled ? 1 : 0, snap.logConvert.lutIndex,
                 snap.logConvert.intensity, snap.creative.enabled ? 1 : 0,
                 snap.creative.lutIndex, snap.creative.intensity,
                 snap.secondary.enabled ? 1 : 0, snap.secondary.lutIndex,
                 snap.secondary.intensity, snap.accent.enabled ? 1 : 0,
                 snap.accent.lutIndex, snap.accent.intensity);
  }

  std::fclose(f);
}

void logLifecycle(const char *stage, const char *detail = nullptr) {
  FILE *f = std::fopen(kDiagPath, "a");
  if (!f)
    return;
  std::fprintf(f, "[VTC][life] stage=%s detail=%s\n", stage ? stage : "unknown",
               detail ? detail : "");
  std::fclose(f);
}
} // namespace

class VTCLooksEffect : public OFX::ImageEffect {
public:
  explicit VTCLooksEffect(OfxImageEffectHandle handle)
      : OFX::ImageEffect(handle) {}
  ~VTCLooksEffect() override { logLifecycle("destroyInstance", "dtor"); }

  void render(const OFX::RenderArguments &args) override {
    @autoreleasepool {
      logLifecycle("render_enter", "starting");
      try {
        @try {
          OFX::Clip *srcClip = fetchClip(kOfxImageEffectSimpleSourceClipName);
          OFX::Clip *dstClip = fetchClip(kOfxImageEffectOutputClipName);
          logLifecycle("render_clips", (srcClip && dstClip) ? "ok" : "missing");
          if (!srcClip || !dstClip || !srcClip->isConnected()) {
            logLifecycle("render_skip", "missing_clips");
            return;
          }

          OFX::Image *srcImg = srcClip->fetchImage(args.time);
          OFX::Image *dstImg = dstClip->fetchImage(args.time);
          logLifecycle("render_images", (srcImg && dstImg) ? "ok" : "missing");
          if (!srcImg || !dstImg) {
            logLifecycle("render_skip", "missing_images");
            delete srcImg;
            delete dstImg;
            return;
          }

          logLifecycle("render_params", "reading");
          const ParamsSnapshot snap = ReadParams(this);
          logLifecycle("render_params", "done");

          const bool hostMetalAvailable =
              args.isEnabledMetalRender && args.pMetalCmdQ != nullptr;
          const bool gpuEnvOn = envEnabled("VTC_ENABLE_GPU");
          const bool forceCPU = envEnabled("VTC_FORCE_CPU");
          const bool allowHostBuffers = envEnabled("VTC_HOST_METAL_BUFFERS");
          // When host provides Metal rendering, pixel data is Metal-backed
          // and NOT safe for raw CPU access (SIGBUS). We MUST use the
          // Metal buffer path regardless of env var settings.
          const bool tryMetal = kMetalPathEnabled && hostMetalAvailable;
          {
            char flagsBuf[256];
            std::snprintf(
                flagsBuf, sizeof(flagsBuf),
                "hostMetal=%d gpuEnv=%d forceCPU=%d tryMetal=%d hostQ=%p",
                hostMetalAvailable ? 1 : 0, gpuEnvOn ? 1 : 0, forceCPU ? 1 : 0,
                tryMetal ? 1 : 0, args.pMetalCmdQ);
            logLifecycle("render_flags", flagsBuf);
          }
          const char *reason = nullptr;
          bool usedGPU = false;
          FrameDesc src{};
          FrameDesc dst{};

          // CPU-mapping is only safe when the host is NOT using Metal
          // rendering. When isEnabledMetalRender is true, getPixelData() may
          // return a Metal resource handle that SIGBUS on CPU read.
          const bool cpuMappingSafe = !args.isEnabledMetalRender;

          auto mapCpuImage = [&](const OFX::Image *img,
                                 FrameDesc *out) -> bool {
            if (!img || !out)
              return false;
            return MapImageToFrame(img, out);
          };

          bool cpuMapped = false;
          auto ensureCpuMapped = [&]() -> bool {
            if (!cpuMappingSafe)
              return false; // Metal-backed, not safe
            if (!cpuMapped) {
              cpuMapped = mapCpuImage(srcImg, &src) &&
                          mapCpuImage(dstImg, &dst) && SameGeometry(src, dst);
            }
            return cpuMapped;
          };

          if (tryMetal) {
            // When host provides Metal rendering, getPixelData() returns
            // Metal buffer handles. We MUST bridge them as id<MTLBuffer>
            // and use TryDispatchNativeBuffers — the only safe path.
            // CPU-side access (memcpy, ProcessFrameCPU) would SIGBUS.
            id<MTLBuffer> srcBuf = (__bridge id<MTLBuffer>)(const_cast<void *>(
                srcImg->getPixelData()));
            id<MTLBuffer> dstBuf = (__bridge id<MTLBuffer>)(const_cast<void *>(
                dstImg->getPixelData()));
            const OfxRectI &b = srcImg->getBounds();
            const int width = b.x2 - b.x1;
            const int height = b.y2 - b.y1;
            const int srcRB = std::abs(srcImg->getRowBytes());
            const int dstRB = std::abs(dstImg->getRowBytes());
            FrameFormat fmt = FrameFormat::kRGBA_8u;
            switch (srcImg->getPixelDepth()) {
            case OFX::eBitDepthUByte:
              fmt = FrameFormat::kRGBA_8u;
              break;
            case OFX::eBitDepthUShort:
              fmt = FrameFormat::kRGBA_16u;
              break;
            case OFX::eBitDepthFloat:
              fmt = FrameFormat::kRGBA_32f;
              break;
            default:
              fmt = FrameFormat::kRGBA_8u;
              break;
            }

            logLifecycle("render_metal_buffers", "bridging");
            if (srcBuf && dstBuf && width > 0 && height > 0 && srcRB > 0 &&
                dstRB > 0) {
              if (!vtc::metal::TryDispatchNativeBuffers(
                      snap, (__bridge void *)srcBuf, (__bridge void *)dstBuf,
                      fmt, width, height, srcRB, dstRB, args.pMetalCmdQ,
                      &usedGPU, &reason)) {
                usedGPU = false;
              }
            } else {
              reason = "metal_buffer_null";
            }
          } else {
            if (!kMetalPathEnabled) {
              reason = "metal_disabled_build";
            } else if (!hostMetalAvailable) {
              reason = args.isEnabledMetalRender ? "metal_queue_missing"
                                                 : "metal_disabled_host";
            }
          }

          if (!usedGPU) {
            // Fallback CPU path requires valid CPU pointers.
            // ONLY safe when host is NOT using Metal for pixel storage.
            if (!ensureCpuMapped()) {
              delete srcImg;
              delete dstImg;
              logFrameOnce(snap, src, args, "cpu",
                           reason ? reason : "no_frame_data");
              logLifecycle("render_skip", reason ? reason : "no_cpu_map");
              return;
            }
            if (!reason) {
              reason = hostMetalAvailable ? "metal_fallback"
                                          : "stability_forced_cpu";
            }
            logLifecycle("render_cpu_start", reason);
            ProcessFrameCPU(snap, src, dst);
            logLifecycle("render_cpu_done", "ok");
            logFrameOnce(snap, src, args, "cpu", reason);
          } else {
            // For host buffer path, we already wrote into dstBuf; still map
            // once for logging geometry — only if safe.
            if (cpuMappingSafe && mapCpuImage(dstImg, &dst)) {
              logFrameOnce(snap, dst, args, "metal", reason);
            } else {
              FrameDesc dummy{};
              dummy.format = FrameFormat::kRGBA_32f;
              dummy.width = dummy.height = 0;
              logFrameOnce(snap, dummy, args, "metal",
                           reason ? reason : "metal_no_cpu_map");
            }
          }

          logLifecycle("render_cleanup", "deleting_images");
          delete srcImg;
          delete dstImg;
          logLifecycle("render_exit", "done");
        } @catch (NSException *e) {
          logLifecycle("render_objc_exc", [[e reason] UTF8String]);
        }
      } catch (const std::exception &e) {
        logLifecycle("render_cpp_exc", e.what());
      } catch (...) {
        logLifecycle("render_unknown_exc", "");
      }
    } // @autoreleasepool
  }

  bool isIdentity(const OFX::IsIdentityArguments &args,
                  OFX::Clip *&identityClip, double &identityTime) override {
    (void)args;
    (void)identityClip;
    (void)identityTime;
    return false;
  }

  void changedParam(const OFX::InstanceChangedArgs &args,
                    const std::string &paramName) override {
    if (args.reason != OFX::eChangeUserEdit)
      return;

    auto cycleLook = [this](const char *prefix, int optionCount, bool forward) {
      std::string p(prefix);
      OFX::ChoiceParam *look = fetchChoiceParam(p + "Look");
      OFX::ChoiceParam *sel = fetchChoiceParam(p + "Selected");
      if (!look || !sel || optionCount <= 0)
        return;

      int current = 0;
      look->getValue(current);
      if (current < 0 || current >= optionCount)
        current = 0;

      int next = forward ? (current + 1) : (current - 1);
      if (next < 0)
        next = optionCount - 1;
      if (next >= optionCount)
        next = 0;

      look->setValue(next);
      sel->setValue(next);
    };

    if (paramName == "logNext")
      cycleLook("log", kLogLUTCount + 1, true);
    else if (paramName == "logPrev")
      cycleLook("log", kLogLUTCount + 1, false);
    else if (paramName == "creativeNext")
      cycleLook("creative", kRec709LUTCount + 1, true);
    else if (paramName == "creativePrev")
      cycleLook("creative", kRec709LUTCount + 1, false);
    else if (paramName == "secondaryNext")
      cycleLook("secondary", kRec709LUTCount + 1, true);
    else if (paramName == "secondaryPrev")
      cycleLook("secondary", kRec709LUTCount + 1, false);
    else if (paramName == "accentNext")
      cycleLook("accent", kRec709LUTCount + 1, true);
    else if (paramName == "accentPrev")
      cycleLook("accent", kRec709LUTCount + 1, false);
    else if (paramName.find("Look") != std::string::npos &&
             paramName.find("Selected") == std::string::npos) {
      std::string p = paramName.substr(0, paramName.find("Look"));
      OFX::ChoiceParam *look = fetchChoiceParam(paramName);
      OFX::ChoiceParam *sel = fetchChoiceParam(p + "Selected");
      if (look && sel) {
        int value = 0;
        look->getValue(value);
        sel->setValue(value);
      }
    }
  }
};

class VTCLooksFactory : public OFX::PluginFactoryHelper<VTCLooksFactory> {
public:
  VTCLooksFactory() : PluginFactoryHelper<VTCLooksFactory>(kPluginID, 1, 0) {}

  void describe(OFX::ImageEffectDescriptor &desc) override {
    logLifecycle("describe", kPluginID);
    desc.setLabels(kPluginLabel, kPluginLabel, kPluginLabel);
    desc.setPluginGrouping(kPluginGroup);
    desc.addSupportedContext(OFX::eContextFilter);
    desc.addSupportedBitDepth(OFX::eBitDepthUByte);
    desc.addSupportedBitDepth(OFX::eBitDepthUShort);
    desc.addSupportedBitDepth(OFX::eBitDepthFloat);
    desc.setSupportsMetalRender(true);
    desc.setSupportsTiles(false);
    // Resolve appears to enable Metal queues only for fully thread-safe
    // effects.
    desc.setRenderThreadSafety(OFX::eRenderFullySafe);
  }

  void describeInContext(OFX::ImageEffectDescriptor &desc,
                         OFX::ContextEnum context) override {
    logLifecycle("describeInContext",
                 context == OFX::eContextFilter ? "filter" : "other");
    if (context != OFX::eContextFilter) {
      return;
    }

    OFX::ClipDescriptor *srcClip =
        desc.defineClip(kOfxImageEffectSimpleSourceClipName);
    srcClip->addSupportedComponent(OFX::ePixelComponentRGBA);
    srcClip->setTemporalClipAccess(false);

    OFX::ClipDescriptor *dstClip =
        desc.defineClip(kOfxImageEffectOutputClipName);
    dstClip->addSupportedComponent(OFX::ePixelComponentRGBA);

    AddParams(desc);

    OFX::PageParamDescriptor *page = desc.definePageParam("Controls");
    if (page) {
      page->addChild(*desc.getParamDescriptor("logGroup"));
      page->addChild(*desc.getParamDescriptor("creativeGroup"));
      page->addChild(*desc.getParamDescriptor("secondaryGroup"));
      page->addChild(*desc.getParamDescriptor("accentGroup"));
    }
  }

  OFX::ImageEffect *createInstance(OfxImageEffectHandle handle,
                                   OFX::ContextEnum context) override {
    @autoreleasepool {
      (void)context;
      logLifecycle("createInstance", "filter");
      return new VTCLooksEffect(handle);
    }
  }
};

} // namespace ofx
} // namespace vtc

namespace OFX {
namespace Plugin {

void getPluginIDs(OFX::PluginFactoryArray &ids) {
  vtc::ofx::logLifecycle("OfxGetPluginIDs", "com.vtclooks.ofx.v2");
  static vtc::ofx::VTCLooksFactory factory;
  ids.push_back(&factory);
}

} // namespace Plugin
} // namespace OFX

extern "C" __attribute__((visibility("default"), used)) OfxStatus
OfxSetHost(const OfxHost *host) {
  OFX::Private::setHost(const_cast<OfxHost *>(host));
  return kOfxStatOK;
}
