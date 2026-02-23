#pragma once

#include "VTC_AdobePF_Includes.h"
#include "../../Shared/VTC_Frame.h"

namespace vtc {
namespace pf {

PF_Err MapWorldToFrame(const PF_EffectWorld* world, FrameDesc* out);

}  // namespace pf
}  // namespace vtc
