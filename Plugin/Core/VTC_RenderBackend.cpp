#include "VTC_RenderBackend.h"
#include "VTC_MetalBootstrap.h"
#include <cstdlib>
#include <cstring>

namespace vtc {

static BackendPolicy ReadBackendPolicyImpl() {
    const char* v = std::getenv("VTC_BACKEND");
    if (v && std::strcmp(v, "cpu") == 0) return BackendPolicy::kCPU;
    return BackendPolicy::kAuto;
}

BackendPolicy ReadBackendPolicy() {
    static BackendPolicy cached = ReadBackendPolicyImpl();
    return cached;
}

bool TryDispatchGPU(const ParamsSnapshot& params,
                    const void* srcData, void* dstData,
                    int width, int height,
                    int srcRowBytes, int dstRowBytes,
                    FrameFormat format) {
    if (ReadBackendPolicy() == BackendPolicy::kCPU) return false;
    return metal::TryDispatch(params, srcData, dstData,
                              width, height, srcRowBytes, dstRowBytes, format);
}

}  // namespace vtc
