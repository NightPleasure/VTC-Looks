#pragma once

#include "../Shared/VTC_Params.h"
#include "../Shared/VTC_Frame.h"
#include "../Shared/VTC_LUTData.h"
#include "VTC_CopyUtils.h"

namespace vtc {

struct RGB {
    float r, g, b;
};

void ProcessFrameCPU(const ParamsSnapshot& params, const FrameDesc& src, FrameDesc& dst);

}  // namespace vtc
