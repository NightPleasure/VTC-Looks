#include "VTC_OFX_ImageMap.h"

#include "ofxsImageEffect.h"

namespace vtc {
namespace ofx {

bool MapImageToFrame(const OFX::Image* img, FrameDesc* out) {
    if (!img || !out) {
        return false;
    }

    out->data = const_cast<void*>(img->getPixelData());
    const OfxRectI& b = img->getBounds();
    out->width = b.x2 - b.x1;
    out->height = b.y2 - b.y1;
    out->rowBytes = img->getRowBytes();
    if (out->rowBytes < 0) {
        out->rowBytes = -out->rowBytes;
    }

    switch (img->getPixelDepth()) {
        case OFX::eBitDepthUByte:
            out->format = FrameFormat::kRGBA_8u;
            break;
        case OFX::eBitDepthUShort:
            out->format = FrameFormat::kRGBA_16u;
            break;
        case OFX::eBitDepthFloat:
            out->format = FrameFormat::kRGBA_32f;
            break;
        default:
            out->format = FrameFormat::kRGBA_8u;
            return false;
    }

    return IsValid(*out);
}

}  // namespace ofx
}  // namespace vtc
