#pragma once

#include "VTC_AdobePF_Includes.h"
#include "../../Shared/VTC_Params.h"

namespace vtc {
namespace pf {

PF_Err AddParams(PF_InData* in_data, PF_OutData* out_data);
ParamsSnapshot ReadParams(const PF_ParamDef* const params[]);

}  // namespace pf
}  // namespace vtc
