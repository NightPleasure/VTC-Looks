#pragma once

#include <cstdint>

namespace vtc {

enum class FrameFormat {
    kRGBA_8u,
    kRGBA_16u,
    kRGBA_32f
};

struct FrameDesc {
    void* data = nullptr;
    int width = 0;
    int height = 0;
    int rowBytes = 0;
    FrameFormat format = FrameFormat::kRGBA_8u;
};

inline bool IsValid(const FrameDesc& f) {
    return f.data != nullptr && f.width > 0 && f.height > 0 && f.rowBytes > 0;
}

inline bool SameGeometry(const FrameDesc& a, const FrameDesc& b) {
    return a.width == b.width && a.height == b.height && a.format == b.format;
}

}  // namespace vtc
