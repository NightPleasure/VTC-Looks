#pragma once

#include "../Shared/VTC_Params.h"

namespace vtc {

enum class NativeGPUBackend {
    kNone = 0,
    kMetal,
    kOpenCL,
    kCuda
};

inline NativeGPUBackend SelectNativeBackend(bool metalEnabled,
                                            bool openclEnabled,
                                            bool cudaEnabled) {
    if (metalEnabled) return NativeGPUBackend::kMetal;
    if (openclEnabled) return NativeGPUBackend::kOpenCL;
    if (cudaEnabled) return NativeGPUBackend::kCuda;
    return NativeGPUBackend::kNone;
}

}  // namespace vtc

