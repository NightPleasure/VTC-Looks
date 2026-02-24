#include "VTC_FrameMap_AdobePF.h"

namespace vtc {
namespace pf {

PF_Err MapWorldToFrame(const PF_EffectWorld* world, FrameDesc* out) {
    if (!world || !out) return PF_Err_BAD_CALLBACK_PARAM;
    out->data     = world->data;
    out->width    = static_cast<int>(world->width);
    out->height   = static_cast<int>(world->height);
    out->rowBytes = static_cast<int>(world->rowbytes);

    if (PF_WORLD_IS_DEEP(world)) {
        out->format = FrameFormat::kRGBA_16u;
    } else if (world->width > 0 && world->rowbytes / world->width >= 16) {
        out->format = FrameFormat::kRGBA_32f;
    } else {
        out->format = FrameFormat::kRGBA_8u;
    }
    return PF_Err_NONE;
}

}  // namespace pf
}  // namespace vtc
