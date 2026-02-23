#include "VTC_LUTSampling.h"

#include <algorithm>
#include <cstdint>

namespace vtc {

namespace {

inline float clamp01(float v) {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

inline float lerp(float a, float b, float t) {
    return a + (b - a) * t;
}

struct Pixel8 {
    std::uint8_t a, r, g, b;
};

struct Pixel16 {
    std::uint16_t a, r, g, b;
};

struct Pixel32f {
    float a, r, g, b;
};

inline int lutIndex(int dim, int ri, int gi, int bi) {
    return ((ri * dim + gi) * dim + bi) * 3;
}

inline RGB sampleLUT(const LUT3D& lut, float r, float g, float b) {
    const float x = clamp01(r) * (lut.dimension - 1);
    const float y = clamp01(g) * (lut.dimension - 1);
    const float z = clamp01(b) * (lut.dimension - 1);

    const int x0 = static_cast<int>(x);
    const int y0 = static_cast<int>(y);
    const int z0 = static_cast<int>(z);
    const int x1 = std::min(x0 + 1, lut.dimension - 1);
    const int y1 = std::min(y0 + 1, lut.dimension - 1);
    const int z1 = std::min(z0 + 1, lut.dimension - 1);

    const float fx = x - x0;
    const float fy = y - y0;
    const float fz = z - z0;

    auto at = [&](int xi, int yi, int zi) -> RGB {
        const int idx = lutIndex(lut.dimension, xi, yi, zi);
        return {lut.data[idx + 0], lut.data[idx + 1], lut.data[idx + 2]};
    };

    const RGB c000 = at(x0, y0, z0);
    const RGB c100 = at(x1, y0, z0);
    const RGB c010 = at(x0, y1, z0);
    const RGB c110 = at(x1, y1, z0);
    const RGB c001 = at(x0, y0, z1);
    const RGB c101 = at(x1, y0, z1);
    const RGB c011 = at(x0, y1, z1);
    const RGB c111 = at(x1, y1, z1);

    RGB c00{lerp(c000.r, c100.r, fx), lerp(c000.g, c100.g, fx), lerp(c000.b, c100.b, fx)};
    RGB c10{lerp(c010.r, c110.r, fx), lerp(c010.g, c110.g, fx), lerp(c010.b, c110.b, fx)};
    RGB c01{lerp(c001.r, c101.r, fx), lerp(c001.g, c101.g, fx), lerp(c001.b, c101.b, fx)};
    RGB c11{lerp(c011.r, c111.r, fx), lerp(c011.g, c111.g, fx), lerp(c011.b, c111.b, fx)};

    RGB c0{lerp(c00.r, c10.r, fy), lerp(c00.g, c10.g, fy), lerp(c00.b, c10.b, fy)};
    RGB c1{lerp(c01.r, c11.r, fy), lerp(c01.g, c11.g, fy), lerp(c01.b, c11.b, fy)};

    return {lerp(c0.r, c1.r, fz), lerp(c0.g, c1.g, fz), lerp(c0.b, c1.b, fz)};
}

template <typename PixelType, typename ToFloatFn, typename FromFloatFn>
void processTyped(const LUT3D& lut, float intensity, const FrameDesc& src, FrameDesc& dst, ToFloatFn toFloat, FromFloatFn fromFloat) {
    auto* srcBytes = static_cast<const std::uint8_t*>(src.data);
    auto* dstBytes = static_cast<std::uint8_t*>(dst.data);
    const int width = src.width;
    const int height = src.height;

    for (int y = 0; y < height; ++y) {
        const auto* srcRow = reinterpret_cast<const PixelType*>(srcBytes + y * src.rowBytes);
        auto* dstRow = reinterpret_cast<PixelType*>(dstBytes + y * dst.rowBytes);
        for (int x = 0; x < width; ++x) {
            const PixelType& s = srcRow[x];
            RGB color = toFloat(s);
            const RGB lutRGB = sampleLUT(lut, color.r, color.g, color.b);
            const float t = intensity;
            RGB out{
                lerp(color.r, lutRGB.r, t),
                lerp(color.g, lutRGB.g, t),
                lerp(color.b, lutRGB.b, t),
            };
            dstRow[x] = fromFloat(out, s.a);
        }
    }
}

inline RGB toFloat8(const Pixel8& p) {
    constexpr float k = 1.0f / 255.0f;
    return {p.r * k, p.g * k, p.b * k};
}

inline RGB toFloat16(const Pixel16& p) {
    constexpr float k = 1.0f / 32768.0f;
    return {p.r * k, p.g * k, p.b * k};
}

inline RGB toFloat32(const Pixel32f& p) {
    return {p.r, p.g, p.b};
}

inline Pixel8 fromFloat8(const RGB& c, std::uint8_t a) {
    constexpr float k = 255.0f;
    auto toU8 = [](float v) -> std::uint8_t {
        const float clamped = clamp01(v) * k + 0.5f;
        return static_cast<std::uint8_t>(clamped > 255.0f ? 255.0f : clamped);
    };
    return Pixel8{a, toU8(c.r), toU8(c.g), toU8(c.b)};
}

inline Pixel16 fromFloat16(const RGB& c, std::uint16_t a) {
    constexpr float k = 32768.0f;
    auto toU16 = [](float v) -> std::uint16_t {
        const float clamped = clamp01(v) * k + 0.5f;
        const float capped = clamped > 32768.0f ? 32768.0f : clamped;
        return static_cast<std::uint16_t>(capped);
    };
    return Pixel16{a, toU16(c.r), toU16(c.g), toU16(c.b)};
}

inline Pixel32f fromFloat32(const RGB& c, float a) {
    return Pixel32f{a, clamp01(c.r), clamp01(c.g), clamp01(c.b)};
}

}  // namespace

void ProcessFrameCPU(const ParamsSnapshot& params, const FrameDesc& src, FrameDesc& dst) {
    if (!IsSupported(src) || !IsSupported(dst) || !SameGeometry(src, dst)) {
        CopyFrame(src, dst);
        return;
    }

    if (!params.enabled || params.primaryIntensity <= 0.0001f) {
        CopyFrame(src, dst);
        return;
    }

    const LookEntry& look = GetLook(params.primaryCategory, params.primaryLook);
    const LUT3D* lut = GetLUTById(look.lutId);
    if (!lut || !lut->data || lut->dimension <= 1) {
        CopyFrame(src, dst);
        return;
    }

    const float intensity = clamp01(params.primaryIntensity);

    switch (src.format) {
        case FrameFormat::kRGBA_8u:
            processTyped<Pixel8>(*lut, intensity, src, dst, toFloat8, fromFloat8);
            break;
        case FrameFormat::kRGBA_16u:
            processTyped<Pixel16>(*lut, intensity, src, dst, toFloat16, fromFloat16);
            break;
        case FrameFormat::kRGBA_32f:
            processTyped<Pixel32f>(*lut, intensity, src, dst, toFloat32, fromFloat32);
            break;
    }
}

}  // namespace vtc
