// VTC Looks — PrGPU parameter mapping (M1)
// Reads Enable + Intensity from PrParam (from GPU filter GetParam).

#include "VTC_ParamMap_PrGPU.h"
#include "PrSDKTypes.h"

namespace vtc {
namespace prgpu {

PrGPUParamsSnapshot ReadParamsFromPrParam(const PrParam& enableParam,
                                          const PrParam& intensityParam) {
    PrGPUParamsSnapshot snap{};
    snap.enable = (enableParam.mType == kPrParamType_Bool && enableParam.mBool != 0);
    if (intensityParam.mType == kPrParamType_Float32)
        snap.intensity = intensityParam.mFloat32 / 100.0f;
    else if (intensityParam.mType == kPrParamType_Float64)
        snap.intensity = static_cast<float>(intensityParam.mFloat64) / 100.0f;
    else
        snap.intensity = 1.0f;
    return snap;
}

}  // namespace prgpu
}  // namespace vtc
