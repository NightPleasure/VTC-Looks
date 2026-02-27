// VTC Looks — OFX plugin for DaVinci Resolve (GPU-native Metal + CPU fallback)

#include "VTC_OFX_Includes.h"
#include "VTC_ParamMap_OFX.h"
#include "VTC_FrameMap_OFX.h"

#include "../../Core/VTC_LUTSampling.h"
#include "../../Core/VTC_MetalBootstrap.h"
#include "../../Core/VTC_GPUBackend.h"
#include "../../Core/VTC_CopyUtils.h"
#if defined(_WIN32)
#include "../../Core/VTC_OpenCLBootstrap.h"
#include "../../Core/VTC_CudaBootstrap.h"
#endif

#include <algorithm>
#include <atomic>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace OFX {
namespace Private {
void setHost(OfxHost* host);
}  // namespace Private
}  // namespace OFX

namespace vtc {
namespace ofx {

static const char* kPluginID = "com.vtclooks.ofx.v2";
static const char* kPluginGroup = "VTC Works";
static const char* kPluginLabel = "VTC Looks";

namespace {

bool DiagEnabled() {
    const char* env = std::getenv("VTC_DIAG");
    return env && std::strcmp(env, "1") == 0;
}

bool ForceCPU() {
    const char* env = std::getenv("VTC_FORCE_CPU_TEST");
    return env && std::strcmp(env, "1") == 0;
}

bool DisableNative() {
    const char* env = std::getenv("VTC_DISABLE_NATIVE");
    return env && std::strcmp(env, "1") == 0;
}

bool ParityCheckEnabled() {
    const char* env = std::getenv("VTC_PARITY_CHECK");
    return env && std::strcmp(env, "1") == 0;
}

int AcquireParityTicket() {
    static std::atomic<int> s_counter{0};
    const int v = s_counter.fetch_add(1);
    return (v < 3) ? v : -1;
}

enum class FallbackReason : int {
    kForceCPUEnv = 0,
    kForceCPUParam,
    kDisableNativeEnv,
    kDisableNativeParam,
    kNativeBackendUnavailable,
    kNativeQueueMissing,
    kNativeBufferMissing,
    kNativeGeometryInvalid,
    kNativeDispatchFailed,
    kMapImageFailed,
    kUnsupportedOrGeometryMismatch,
    kInternalMetalFailed,
    kCount
};

const char* FallbackReasonName(FallbackReason reason) {
    switch (reason) {
        case FallbackReason::kForceCPUEnv: return "ForceCPUEnv";
        case FallbackReason::kForceCPUParam: return "ForceCPUParam";
        case FallbackReason::kDisableNativeEnv: return "DisableNativeEnv";
        case FallbackReason::kDisableNativeParam: return "DisableNativeParam";
        case FallbackReason::kNativeBackendUnavailable: return "NativeBackendUnavailable";
        case FallbackReason::kNativeQueueMissing: return "NativeQueueMissing";
        case FallbackReason::kNativeBufferMissing: return "NativeBufferMissing";
        case FallbackReason::kNativeGeometryInvalid: return "NativeGeometryInvalid";
        case FallbackReason::kNativeDispatchFailed: return "NativeDispatchFailed";
        case FallbackReason::kMapImageFailed: return "MapImageFailed";
        case FallbackReason::kUnsupportedOrGeometryMismatch: return "UnsupportedOrGeometryMismatch";
        case FallbackReason::kInternalMetalFailed: return "InternalMetalFailed";
        case FallbackReason::kCount: break;
    }
    return "Unknown";
}

const char* BackendName(NativeGPUBackend backend) {
    switch (backend) {
        case NativeGPUBackend::kMetal: return "Metal";
        case NativeGPUBackend::kOpenCL: return "OpenCL";
        case NativeGPUBackend::kCuda: return "CUDA";
        case NativeGPUBackend::kNone: break;
    }
    return "None";
}

const char* FrameFormatName(FrameFormat f) {
    switch (f) {
        case FrameFormat::kRGBA_8u: return "RGBA8";
        case FrameFormat::kRGBA_16u: return "RGBA16";
        case FrameFormat::kRGBA_32f: return "RGBA32f";
    }
    return "Unknown";
}

void ForceHardRedTint(FrameDesc& frame) {
    if (!IsValid(frame)) return;
    for (int y = 0; y < frame.height; ++y) {
        uint8_t* row = static_cast<uint8_t*>(frame.data) + y * frame.rowBytes;
        if (frame.format == FrameFormat::kRGBA_8u) {
            for (int x = 0; x < frame.width; ++x) {
                uint8_t* p = row + x * 4;
                // ARGB layout: A,R,G,B
                p[1] = static_cast<uint8_t>(255);
                p[2] = static_cast<uint8_t>(0);
                p[3] = static_cast<uint8_t>(0);
            }
        } else if (frame.format == FrameFormat::kRGBA_16u) {
            uint16_t* row16 = reinterpret_cast<uint16_t*>(row);
            for (int x = 0; x < frame.width; ++x) {
                uint16_t* p = row16 + x * 4;
                p[1] = static_cast<uint16_t>(65535);
                p[2] = static_cast<uint16_t>(0);
                p[3] = static_cast<uint16_t>(0);
            }
        } else if (frame.format == FrameFormat::kRGBA_32f) {
            float* row32 = reinterpret_cast<float*>(row);
            for (int x = 0; x < frame.width; ++x) {
                float* p = row32 + x * 4;
                p[1] = 1.0f;
                p[2] = 0.0f;
                p[3] = 0.0f;
            }
        }
    }
}

void LogLayerSettings(const ParamsSnapshot& snap) {
    std::fprintf(
        stderr,
        "[VTC][parity] layers log={en=%d idx=%d int=%.3f} creative={en=%d idx=%d int=%.3f} secondary={en=%d idx=%d int=%.3f} accent={en=%d idx=%d int=%.3f}\n",
        snap.logConvert.enabled ? 1 : 0, snap.logConvert.lutIndex, snap.logConvert.intensity,
        snap.creative.enabled ? 1 : 0, snap.creative.lutIndex, snap.creative.intensity,
        snap.secondary.enabled ? 1 : 0, snap.secondary.lutIndex, snap.secondary.intensity,
        snap.accent.enabled ? 1 : 0, snap.accent.lutIndex, snap.accent.intensity);
}

FrameDesc MakeFrameDescForBuffer(const FrameDesc& ref, void* buffer) {
    FrameDesc d = ref;
    d.data = buffer;
    return d;
}

struct DiffMetric {
    float maxR = 0.f;
    float maxG = 0.f;
    float maxB = 0.f;
    float maxA = 0.f;
};

DiffMetric ComputeMaxAbsDiff(const FrameDesc& a, const FrameDesc& b) {
    DiffMetric m{};
    const int w = a.width;
    const int h = a.height;
    if (a.format != b.format || w != b.width || h != b.height) return m;

    if (a.format == FrameFormat::kRGBA_8u) {
        const float s = 1.0f / 255.0f;
        for (int y = 0; y < h; ++y) {
            const uint8_t* ra = static_cast<const uint8_t*>(a.data) + y * a.rowBytes;
            const uint8_t* rb = static_cast<const uint8_t*>(b.data) + y * b.rowBytes;
            for (int x = 0; x < w; ++x) {
                const int i = x * 4;
                m.maxR = std::max(m.maxR, std::fabs(static_cast<float>(ra[i + 0] - rb[i + 0]) * s));
                m.maxG = std::max(m.maxG, std::fabs(static_cast<float>(ra[i + 1] - rb[i + 1]) * s));
                m.maxB = std::max(m.maxB, std::fabs(static_cast<float>(ra[i + 2] - rb[i + 2]) * s));
                m.maxA = std::max(m.maxA, std::fabs(static_cast<float>(ra[i + 3] - rb[i + 3]) * s));
            }
        }
        return m;
    }

    if (a.format == FrameFormat::kRGBA_16u) {
        const float s = 1.0f / 65535.0f;
        for (int y = 0; y < h; ++y) {
            const uint16_t* ra = reinterpret_cast<const uint16_t*>(static_cast<const uint8_t*>(a.data) + y * a.rowBytes);
            const uint16_t* rb = reinterpret_cast<const uint16_t*>(static_cast<const uint8_t*>(b.data) + y * b.rowBytes);
            for (int x = 0; x < w; ++x) {
                const int i = x * 4;
                m.maxR = std::max(m.maxR, std::fabs(static_cast<float>(ra[i + 0] - rb[i + 0]) * s));
                m.maxG = std::max(m.maxG, std::fabs(static_cast<float>(ra[i + 1] - rb[i + 1]) * s));
                m.maxB = std::max(m.maxB, std::fabs(static_cast<float>(ra[i + 2] - rb[i + 2]) * s));
                m.maxA = std::max(m.maxA, std::fabs(static_cast<float>(ra[i + 3] - rb[i + 3]) * s));
            }
        }
        return m;
    }

    if (a.format == FrameFormat::kRGBA_32f) {
        for (int y = 0; y < h; ++y) {
            const float* ra = reinterpret_cast<const float*>(static_cast<const uint8_t*>(a.data) + y * a.rowBytes);
            const float* rb = reinterpret_cast<const float*>(static_cast<const uint8_t*>(b.data) + y * b.rowBytes);
            for (int x = 0; x < w; ++x) {
                const int i = x * 4;
                m.maxR = std::max(m.maxR, std::fabs(ra[i + 0] - rb[i + 0]));
                m.maxG = std::max(m.maxG, std::fabs(ra[i + 1] - rb[i + 1]));
                m.maxB = std::max(m.maxB, std::fabs(ra[i + 2] - rb[i + 2]));
                m.maxA = std::max(m.maxA, std::fabs(ra[i + 3] - rb[i + 3]));
            }
        }
    }
    return m;
}

std::array<std::atomic<uint32_t>, static_cast<size_t>(FallbackReason::kCount)> g_fallbackCounts{};
std::array<std::atomic<bool>, static_cast<size_t>(FallbackReason::kCount)> g_firstReasonLogged{};
std::atomic<uint32_t> g_fallbackTotal{0};
std::atomic<bool> g_selectedPathLogged{false};

void MaybeLogFallbackSummary() {
    if (!DiagEnabled()) return;
    const uint32_t total = g_fallbackTotal.load();
    if (total == 0) return;
    // Rate-limit summary.
    if (total <= 3 || (total % 100) == 0) {
        std::fprintf(
            stderr,
            "[VTC][diag] fallback-summary total=%u {ForceCPUEnv=%u, ForceCPUParam=%u, DisableNativeEnv=%u, DisableNativeParam=%u, NativeBackendUnavailable=%u, NativeQueueMissing=%u, NativeBufferMissing=%u, NativeGeometryInvalid=%u, NativeDispatchFailed=%u, MapImageFailed=%u, UnsupportedOrGeometryMismatch=%u, InternalMetalFailed=%u}\n",
            total,
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kForceCPUEnv)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kForceCPUParam)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kDisableNativeEnv)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kDisableNativeParam)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kNativeBackendUnavailable)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kNativeQueueMissing)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kNativeBufferMissing)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kNativeGeometryInvalid)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kNativeDispatchFailed)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kMapImageFailed)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kUnsupportedOrGeometryMismatch)].load(),
            g_fallbackCounts[static_cast<size_t>(FallbackReason::kInternalMetalFailed)].load());
    }
}

void RecordFallback(FallbackReason reason) {
    const size_t idx = static_cast<size_t>(reason);
    if (idx < g_fallbackCounts.size()) {
        g_fallbackCounts[idx].fetch_add(1);
    }
    g_fallbackTotal.fetch_add(1);
    if (DiagEnabled()) {
        const bool first = !g_firstReasonLogged[idx].exchange(true);
        static std::atomic<uint32_t> s_detailLogs{0};
        if (first) {
            std::fprintf(stderr, "[VTC][diag] first CPU fallback reason=%s\n", FallbackReasonName(reason));
        } else if (s_detailLogs.fetch_add(1) < 100) {
            std::fprintf(stderr, "[VTC][diag] CPU fallback reason=%s\n", FallbackReasonName(reason));
        }
    }
    MaybeLogFallbackSummary();
}

void LogSelectedPathOnce(const char* pathLabel) {
    if (!DiagEnabled()) return;
    bool expected = false;
    if (g_selectedPathLogged.compare_exchange_strong(expected, true)) {
        std::fprintf(stderr, "[VTC][diag] selected path=%s\n", pathLabel);
    }
}

void LogRenderArgsDiag(const OFX::RenderArguments& args, const OFX::Image* srcImg) {
    if (!DiagEnabled()) return;
    static std::atomic<int> s_logs{0};
    if (s_logs.fetch_add(1) >= 50) return;

    const OfxRectI& b = srcImg->getBounds();
    std::fprintf(stderr,
                 "[VTC][diag] metal=%d q=%p opencl=%d q=%p cuda=%d stream=%p depth=%d size=%dx%d rowBytes=%d\n",
                 args.isEnabledMetalRender ? 1 : 0, args.pMetalCmdQ,
                 args.isEnabledOpenCLRender ? 1 : 0, args.pOpenCLCmdQ,
                 args.isEnabledCudaRender ? 1 : 0, args.pCudaStream,
                 static_cast<int>(srcImg->getPixelDepth()),
                 b.x2 - b.x1, b.y2 - b.y1, srcImg->getRowBytes());
}

}  // namespace

class VTCLooksEffect : public OFX::ImageEffect {
public:
    VTCLooksEffect(OfxImageEffectHandle handle) : OFX::ImageEffect(handle) {}

    void render(const OFX::RenderArguments& args) override {
        OFX::Clip* srcClip = fetchClip(kOfxImageEffectSimpleSourceClipName);
        OFX::Clip* dstClip = fetchClip(kOfxImageEffectOutputClipName);
        if (!srcClip || !dstClip || !srcClip->isConnected()) return;

        OFX::Image* srcImg = srcClip->fetchImage(args.time);
        OFX::Image* dstImg = dstClip->fetchImage(args.time);
        if (!srcImg || !dstImg) {
            delete srcImg;
            delete dstImg;
            return;
        }

        LogRenderArgsDiag(args, srcImg);

        ParamsSnapshot snap = ReadParams(this);

        {
            static std::atomic<int> s_renderLog{0};
            if (s_renderLog.fetch_add(1) < 5) {
                std::fprintf(stderr,
                    "[VTC] render() log={en=%d idx=%d int=%.2f} creative={en=%d idx=%d int=%.2f} "
                    "secondary={en=%d idx=%d int=%.2f} accent={en=%d idx=%d int=%.2f}\n",
                    snap.logConvert.enabled?1:0, snap.logConvert.lutIndex, snap.logConvert.intensity,
                    snap.creative.enabled?1:0, snap.creative.lutIndex, snap.creative.intensity,
                    snap.secondary.enabled?1:0, snap.secondary.lutIndex, snap.secondary.intensity,
                    snap.accent.enabled?1:0, snap.accent.lutIndex, snap.accent.intensity);
            }
        }
        bool gpuDone = false;
        const bool parityEnabled = ParityCheckEnabled();
        const int parityTicket = parityEnabled ? AcquireParityTicket() : -1;
        const bool forceCPUEnv = ForceCPU();
        const bool forceCPUParam = snap.debugForceCPU;
        const bool disableNativeEnv = DisableNative();
        const bool disableNativeParam = snap.debugDisableNative;
        const bool forceCPU = forceCPUEnv || forceCPUParam;
        const bool disableNative = disableNativeEnv || disableNativeParam;
#if defined(__APPLE__)
        const bool disableHostNative = true;
#else
        const bool disableHostNative = disableNative;
#endif
        NativeGPUBackend backend = NativeGPUBackend::kNone;

        if (!forceCPU && !disableHostNative) {
            backend = SelectNativeBackend(args.isEnabledMetalRender,
                                          args.isEnabledOpenCLRender,
                                          args.isEnabledCudaRender);
            if (backend == NativeGPUBackend::kNone) {
                RecordFallback(FallbackReason::kNativeBackendUnavailable);
            } else {
                bool nativeDispatchAttempted = false;
                bool nativeFailureRecorded = false;
                void* srcData = const_cast<void*>(srcImg->getPixelData());
                void* dstData = const_cast<void*>(dstImg->getPixelData());
                const OfxRectI& b = srcImg->getBounds();
                int w = b.x2 - b.x1;
                int h = b.y2 - b.y1;
                if (!srcData || !dstData) {
                    RecordFallback(FallbackReason::kNativeBufferMissing);
                    nativeFailureRecorded = true;
                } else if (w <= 0 || h <= 0) {
                    RecordFallback(FallbackReason::kNativeGeometryInvalid);
                    nativeFailureRecorded = true;
                } else if (backend == NativeGPUBackend::kMetal) {
                    if (!args.pMetalCmdQ) {
                        RecordFallback(FallbackReason::kNativeQueueMissing);
                        nativeFailureRecorded = true;
                    } else {
                        nativeDispatchAttempted = true;
                        gpuDone = metal::TryDispatchNative(snap, srcData, dstData, args.pMetalCmdQ, w, h);
                    }
                }
#if defined(_WIN32)
                else if (backend == NativeGPUBackend::kOpenCL) {
                    if (!args.pOpenCLCmdQ) {
                        RecordFallback(FallbackReason::kNativeQueueMissing);
                        nativeFailureRecorded = true;
                    } else {
                        nativeDispatchAttempted = true;
                        gpuDone = opencl::TryDispatchNative(snap, srcData, dstData, args.pOpenCLCmdQ, w, h);
                    }
                } else if (backend == NativeGPUBackend::kCuda) {
                    if (!args.pCudaStream) {
                        RecordFallback(FallbackReason::kNativeQueueMissing);
                        nativeFailureRecorded = true;
                    } else {
                        nativeDispatchAttempted = true;
                        gpuDone = cuda::TryDispatchNative(snap, srcData, dstData, args.pCudaStream, w, h);
                    }
                } else {
                    RecordFallback(FallbackReason::kNativeBackendUnavailable);
                    nativeFailureRecorded = true;
                }
#endif
                if (gpuDone) {
                    char buffer[64];
                    std::snprintf(buffer, sizeof(buffer), "NativeGPU(%s)", BackendName(backend));
                    LogSelectedPathOnce(buffer);
                } else if (nativeDispatchAttempted && !nativeFailureRecorded) {
                    RecordFallback(FallbackReason::kNativeDispatchFailed);
                }
            }
        }

        if (gpuDone) {
            delete srcImg;
            delete dstImg;
            return;
        }

        if (forceCPUParam) {
            RecordFallback(FallbackReason::kForceCPUParam);
            LogSelectedPathOnce("CPU (forced by debug checkbox)");
        } else if (forceCPUEnv) {
            RecordFallback(FallbackReason::kForceCPUEnv);
            LogSelectedPathOnce("CPU (forced by env)");
        } else if (disableNativeParam) {
            RecordFallback(FallbackReason::kDisableNativeParam);
            LogSelectedPathOnce("CPU (native disabled by debug checkbox)");
        } else if (disableNativeEnv) {
            RecordFallback(FallbackReason::kDisableNativeEnv);
            LogSelectedPathOnce("CPU (native disabled by env)");
        } else {
            LogSelectedPathOnce("CPU");
        }

        FrameDesc src{}, dst{};
        if (!MapImageToFrame(srcImg, &src) || !MapImageToFrame(dstImg, &dst)) {
            RecordFallback(FallbackReason::kMapImageFailed);
            delete srcImg;
            delete dstImg;
            return;
        }

        if (!IsSupported(src) || !IsSupported(dst) || !SameGeometry(src, dst)) {
            RecordFallback(FallbackReason::kUnsupportedOrGeometryMismatch);
            CopyFrame(src, dst);
            delete srcImg;
            delete dstImg;
            return;
        }

        // Absolute render-path probe: if this plugin render() is executed,
        // output must become fully red regardless of LUT settings.
        CopyFrame(src, dst);
        ForceHardRedTint(dst);
        delete srcImg;
        delete dstImg;
        return;

        if (!forceCPU && !disableNative && parityTicket >= 0) {
            const size_t bytes = static_cast<size_t>(dst.rowBytes) * static_cast<size_t>(dst.height);
            std::vector<uint8_t> gpuOut(bytes);
            std::vector<uint8_t> cpuOut(bytes);
            FrameDesc gpuFrame = MakeFrameDescForBuffer(dst, gpuOut.data());
            FrameDesc cpuFrame = MakeFrameDescForBuffer(dst, cpuOut.data());

            const bool gpuParityDone = metal::TryDispatch(
                snap, src.data, gpuFrame.data, src.width, src.height, src.rowBytes, gpuFrame.rowBytes, src.format);
            ProcessFrameCPU(snap, src, cpuFrame);

            if (!gpuParityDone) {
                RecordFallback(FallbackReason::kInternalMetalFailed);
                CopyFrame(cpuFrame, dst);
                delete srcImg;
                delete dstImg;
                return;
            }

            const DiffMetric diff = ComputeMaxAbsDiff(gpuFrame, cpuFrame);
            const float worst = std::max(std::max(diff.maxR, diff.maxG), std::max(diff.maxB, diff.maxA));
            std::fprintf(stderr,
                         "[VTC][parity] frame#%d format=%s %dx%d maxDiff={r=%.6f g=%.6f b=%.6f a=%.6f}\n",
                         parityTicket + 1, FrameFormatName(src.format), src.width, src.height,
                         diff.maxR, diff.maxG, diff.maxB, diff.maxA);
            if (worst > 0.001f) {
                std::fprintf(stderr, "[VTC][parity] mismatch above threshold=0.001000 (worst=%.6f)\n", worst);
                LogLayerSettings(snap);
            }

            CopyFrame(gpuFrame, dst);
            delete srcImg;
            delete dstImg;
            return;
        }

        if (!forceCPU && !disableNative && metal::TryDispatch(snap, src.data, dst.data,
                                                              src.width, src.height,
                                                              src.rowBytes, dst.rowBytes, src.format)) {
            {
                static std::atomic<int> s_mtlLog{0};
                if (s_mtlLog.fetch_add(1) < 3) {
                    std::fprintf(stderr, "[VTC] InternalMetal dispatch OK: %dx%d\n", src.width, src.height);
                }
            }
            delete srcImg;
            delete dstImg;
            return;
        }

        if (!forceCPU && !disableNative) {
            RecordFallback(FallbackReason::kInternalMetalFailed);
        }

        // CPU real path (kill-switch / force mode / last fallback)
        {
            ProcessFrameCPU(snap, src, dst);
        }

        delete srcImg;
        delete dstImg;
    }

    bool isIdentity(const OFX::IsIdentityArguments& args, OFX::Clip*& identityClip, double& identityTime) override {
        ParamsSnapshot snap = ReadParams(this);
        auto active = [](const LayerParams& lp, int maxIdx) {
            return lp.enabled && lp.lutIndex >= 0 && lp.lutIndex < maxIdx && lp.intensity > 0.0001f;
        };
        bool hasWork = active(snap.logConvert, kLogLUTCount) ||
                       active(snap.creative, kRec709LUTCount) ||
                       active(snap.secondary, kRec709LUTCount) ||
                       active(snap.accent, kRec709LUTCount);
        if (!hasWork) {
            identityClip = fetchClip(kOfxImageEffectSimpleSourceClipName);
            identityTime = args.time;
            return true;
        }
        return false;
    }

    void changedParam(const OFX::InstanceChangedArgs& args, const std::string& paramName) override {
        if (args.reason != OFX::eChangeUserEdit) return;

        auto cycleLook = [this](const char* prefix, int optionCount, bool forward) {
            std::string p(prefix);
            OFX::ChoiceParam* look = fetchChoiceParam(p + "Look");
            OFX::ChoiceParam* sel = fetchChoiceParam(p + "Selected");
            if (!look || !sel || optionCount <= 0) return;
            int v = 0;
            look->getValue(v);
            if (v < 0 || v >= optionCount) v = 0;
            int n = forward ? (v + 1) : (v - 1);
            if (n < 0) n = optionCount - 1;
            if (n >= optionCount) n = 0;
            look->setValue(n);
            sel->setValue(n);
        };

        if (paramName == "logNext") cycleLook("log", kLogLUTCount + 1, true);
        else if (paramName == "logPrev") cycleLook("log", kLogLUTCount + 1, false);
        else if (paramName == "creativeNext") cycleLook("creative", kRec709LUTCount + 1, true);
        else if (paramName == "creativePrev") cycleLook("creative", kRec709LUTCount + 1, false);
        else if (paramName == "secondaryNext") cycleLook("secondary", kRec709LUTCount + 1, true);
        else if (paramName == "secondaryPrev") cycleLook("secondary", kRec709LUTCount + 1, false);
        else if (paramName == "accentNext") cycleLook("accent", kRec709LUTCount + 1, true);
        else if (paramName == "accentPrev") cycleLook("accent", kRec709LUTCount + 1, false);
        else if (paramName.find("Look") != std::string::npos && paramName.find("Selected") == std::string::npos) {
            std::string p = paramName.substr(0, paramName.find("Look"));
            OFX::ChoiceParam* look = fetchChoiceParam(paramName);
            OFX::ChoiceParam* sel = fetchChoiceParam(p + "Selected");
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
    VTCLooksFactory() : PluginFactoryHelper<VTCLooksFactory>(kPluginID, 1, 3) {}

    void describe(OFX::ImageEffectDescriptor& desc) override {
        desc.setLabels(kPluginLabel, kPluginLabel, kPluginLabel);
        desc.setPluginGrouping(kPluginGroup);
        desc.setVersion(1, 3, 0, 0, "1.3");
        desc.addSupportedContext(OFX::eContextFilter);
        desc.addSupportedBitDepth(OFX::eBitDepthUByte);
        desc.addSupportedBitDepth(OFX::eBitDepthUShort);
        desc.addSupportedBitDepth(OFX::eBitDepthFloat);
        desc.setSupportsTiles(false);
        desc.setRenderThreadSafety(OFX::eRenderInstanceSafe);
        // NOTE: Resolve on this setup rejects the plugin when MetalRenderSupported is declared.
        // Keep host-side Metal negotiation disabled and use internal Metal path as fallback acceleration.
#if defined(_WIN32)
        desc.getPropertySet().propSetString(kOfxImageEffectPropOpenCLRenderSupported, 0, "true");
        desc.getPropertySet().propSetString(kOfxImageEffectPropCudaRenderSupported, 0, "true");
#endif
        if (DiagEnabled()) {
            static std::atomic<int> s_logs{0};
            if (s_logs.fetch_add(1) < 10) {
                std::fprintf(stderr, "[VTC][diag] describe(): MetalRenderSupported=false (host negotiation disabled on this Resolve setup)\n");
            }
        }
    }

    void describeInContext(OFX::ImageEffectDescriptor& desc, OFX::ContextEnum context) override {
        if (context != OFX::eContextFilter) return;

        OFX::ClipDescriptor* srcClip = desc.defineClip(kOfxImageEffectSimpleSourceClipName);
        srcClip->addSupportedComponent(OFX::ePixelComponentRGBA);
        srcClip->setTemporalClipAccess(false);

        OFX::ClipDescriptor* dstClip = desc.defineClip(kOfxImageEffectOutputClipName);
        dstClip->addSupportedComponent(OFX::ePixelComponentRGBA);

        AddParams(desc);

        OFX::PageParamDescriptor* page = desc.definePageParam("Controls");
        if (page) {
            page->addChild(*desc.getParamDescriptor("logGroup"));
            page->addChild(*desc.getParamDescriptor("creativeGroup"));
            page->addChild(*desc.getParamDescriptor("secondaryGroup"));
            page->addChild(*desc.getParamDescriptor("accentGroup"));
            OFX::ParamDescriptor* dbg = desc.getParamDescriptor("debugGroup");
            if (dbg) {
                page->addChild(*dbg);
            }
        }
    }

    OFX::ImageEffect* createInstance(OfxImageEffectHandle handle, OFX::ContextEnum context) override {
        return new VTCLooksEffect(handle);
    }
};

}  // namespace ofx
}  // namespace vtc

namespace OFX {
namespace Plugin {

void getPluginIDs(OFX::PluginFactoryArray& ids) {
    static vtc::ofx::VTCLooksFactory factory;
    ids.push_back(&factory);
}

}  // namespace Plugin
}  // namespace OFX

extern "C" __attribute__((visibility("default"), used)) OfxStatus OfxSetHost(const OfxHost* host) {
    OFX::Private::setHost(const_cast<OfxHost*>(host));
    return kOfxStatOK;
}
