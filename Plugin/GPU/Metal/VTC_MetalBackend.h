#pragma once

#include "../VTC_GPUBackend.h"

namespace vtc {
namespace metal {

bool TryDispatchNative(const ParamsSnapshot &params, const FrameDesc &src,
                       FrameDesc &dst, void *nativeCommandQueue, bool *usedGPU,
                       const char **reason, bool forceStaging = false);

// Dispatch using host-provided Metal buffers directly (no CPU pointer needed).
bool TryDispatchNativeBuffers(const ParamsSnapshot &params,
                              void *srcMetalBuffer, void *dstMetalBuffer,
                              FrameFormat format, int width, int height,
                              int srcRowBytes, int dstRowBytes,
                              void *nativeCommandQueue, bool *usedGPU,
                              const char **reason);

} // namespace metal
} // namespace vtc
