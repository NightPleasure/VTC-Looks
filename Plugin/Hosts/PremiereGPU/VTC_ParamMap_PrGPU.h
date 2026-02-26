#pragma once

#include "VTC_PrGPU_Params.h"

struct PrParam;

namespace vtc {
namespace prgpu {

/// Reads Enable and Intensity from PrParam (from GetParam) into snapshot.
PrGPUParamsSnapshot ReadParamsFromPrParam(const struct PrParam& enableParam,
                                          const struct PrParam& intensityParam);

}  // namespace prgpu
}  // namespace vtc
