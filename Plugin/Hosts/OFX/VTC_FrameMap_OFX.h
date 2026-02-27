#pragma once

#include "../../Shared/VTC_Frame.h"

namespace OFX {
class Image;
}

namespace vtc {
namespace ofx {

bool MapImageToFrame(const OFX::Image* img, FrameDesc* out);

}  // namespace ofx
}  // namespace vtc
