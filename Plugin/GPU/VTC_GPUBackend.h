#pragma once

#include "../Shared/VTC_Params.h"
#include "../Shared/VTC_Frame.h"

namespace vtc {

class GPUBackend {
public:
    virtual ~GPUBackend() = default;
    virtual bool IsAvailable(void* nativeQueue) = 0;
    virtual bool Dispatch(const ParamsSnapshot& params, const FrameDesc& src, FrameDesc& dst, void* nativeQueue) = 0;
};

}  // namespace vtc
