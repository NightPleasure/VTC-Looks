// VTC Looks — PrGPU parameter mapping (M3: 4-layer)
// Reads Log, Creative, Secondary, Accent from PrParam.

#include "VTC_ParamMap_PrGPU.h"
#include "PrSDKTypes.h"

namespace vtc {
namespace prgpu {

void ReadLayerFromPrParam(LayerParams& out,
                          const PrParam& enableParam,
                          const PrParam& lookParam,
                          const PrParam& intensityParam) {
    out.enabled = (enableParam.mType == kPrParamType_Bool && enableParam.mBool != 0);
    if (lookParam.mType == kPrParamType_Int32 || lookParam.mType == kPrParamType_Int64) {
        const int pv = (lookParam.mType == kPrParamType_Int64)
            ? static_cast<int>(lookParam.mInt64) : lookParam.mInt32;
        // PrGPU popup values are 0-based here: None=0, first LUT=1, second LUT=2, ...
        out.lutIndex = (pv > 0) ? (pv - 1) : -1;
    } else {
        out.lutIndex = -1;
    }
    if (intensityParam.mType == kPrParamType_Float32)
        out.intensity = intensityParam.mFloat32 / 100.0f;
    else if (intensityParam.mType == kPrParamType_Float64)
        out.intensity = static_cast<float>(intensityParam.mFloat64) / 100.0f;
    else
        out.intensity = 1.0f;
}

PrGPUParamsSnapshot ReadParamsFromPrParam(
    const PrParam& logEnable, const PrParam& logLook, const PrParam& logIntensity,
    const PrParam& creativeEnable, const PrParam& creativeLook, const PrParam& creativeIntensity,
    const PrParam& secondaryEnable, const PrParam& secondaryLook, const PrParam& secondaryIntensity,
    const PrParam& accentEnable, const PrParam& accentLook, const PrParam& accentIntensity) {
    PrGPUParamsSnapshot snap{};
    ReadLayerFromPrParam(snap.logConvert, logEnable, logLook, logIntensity);
    ReadLayerFromPrParam(snap.creative, creativeEnable, creativeLook, creativeIntensity);
    ReadLayerFromPrParam(snap.secondary, secondaryEnable, secondaryLook, secondaryIntensity);
    ReadLayerFromPrParam(snap.accent, accentEnable, accentLook, accentIntensity);
    return snap;
}

}  // namespace prgpu
}  // namespace vtc
