#pragma once

#include "../Shared/VTC_Params.h"
#include "../Shared/VTC_Frame.h"
#include "../Shared/VTC_LookRegistry.h"
#include "VTC_EmbeddedLUTs.h"
#include "VTC_CopyUtils.h"

namespace vtc {

struct RGB {
    float r;
    float g;
    float b;
};

// Core CPU processing entry point. Safe to call with identical src/dst pointers.
void ProcessFrameCPU(const ParamsSnapshot& params, const FrameDesc& src, FrameDesc& dst);

}  // namespace vtc
