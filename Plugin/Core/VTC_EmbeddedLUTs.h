#pragma once

#include "../Shared/VTC_LookRegistry.h"
#include "../Shared/VTC_Frame.h"

namespace vtc {

struct LUT3D {
    const float* data;
    int dimension;
};

// Returns nullptr if not found.
const LUT3D* GetLUTById(int lutId);

}  // namespace vtc
