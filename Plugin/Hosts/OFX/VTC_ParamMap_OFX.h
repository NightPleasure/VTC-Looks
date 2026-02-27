#pragma once

#include "../../Shared/VTC_Params.h"

namespace OFX {
class ParamSetDescriptor;
class ParamSet;
}

namespace vtc {
namespace ofx {

void AddParams(OFX::ParamSetDescriptor& desc);
ParamsSnapshot ReadParams(const OFX::ParamSet* params);

}  // namespace ofx
}  // namespace vtc
