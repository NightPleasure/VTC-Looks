#pragma once

#include <algorithm>
#include <cstring>
#include <cstdint>
#include "../Shared/VTC_Frame.h"

namespace vtc {

inline void CopyFrame(const FrameDesc& src, FrameDesc& dst) {
    if (!IsValid(src) || !IsValid(dst)) {
        return;
    }
    const int height = std::min(src.height, dst.height);
    const int bytesPerRow = std::min(src.rowBytes, dst.rowBytes);
    const auto* srcBytes = static_cast<const std::uint8_t*>(src.data);
    auto* dstBytes = static_cast<std::uint8_t*>(dst.data);
    for (int y = 0; y < height; ++y) {
        std::memcpy(dstBytes + y * dst.rowBytes, srcBytes + y * src.rowBytes, bytesPerRow);
    }
}

inline bool IsSupported(const FrameDesc& f) {
    return IsValid(f) && (f.format == FrameFormat::kRGBA_8u || f.format == FrameFormat::kRGBA_16u || f.format == FrameFormat::kRGBA_32f);
}

}  // namespace vtc
