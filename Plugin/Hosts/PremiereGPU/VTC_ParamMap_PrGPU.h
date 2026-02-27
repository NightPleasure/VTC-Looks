#pragma once

#include "VTC_PrGPU_Params.h"

struct PrParam;

namespace vtc {
namespace prgpu {

void ReadLayerFromPrParam(LayerParams& out,
                          const PrParam& enableParam,
                          const PrParam& lookParam,
                          const PrParam& intensityParam);

PrGPUParamsSnapshot ReadParamsFromPrParam(
    const PrParam& logEnable, const PrParam& logLook, const PrParam& logIntensity,
    const PrParam& creativeEnable, const PrParam& creativeLook, const PrParam& creativeIntensity,
    const PrParam& secondaryEnable, const PrParam& secondaryLook, const PrParam& secondaryIntensity,
    const PrParam& accentEnable, const PrParam& accentLook, const PrParam& accentIntensity);

}  // namespace prgpu
}  // namespace vtc
