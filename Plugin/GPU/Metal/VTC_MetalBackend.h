#pragma once

#include "../VTC_GPUBackend.h"

namespace vtc {
namespace metal {

bool TryDispatchNative(const ParamsSnapshot& params,
                       const FrameDesc& src,
                       FrameDesc& dst,
                       void* nativeCommandQueue,
                       bool* usedGPU,
                       const char** reason);

}  // namespace metal
}  // namespace vtc
