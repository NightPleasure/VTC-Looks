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

struct Pixel8  { std::uint8_t  a, r, g, b; };
struct Pixel16 { std::uint16_t a, r, g, b; };
struct Pixel32f { float a, r, g, b; };

inline RGB sampleLUT(const LUT3D& lut, float r, float g, float b) {
    const int   dim   = lut.dimension;
    const int   dimM1 = dim - 1;
    const float scale = static_cast<float>(dimM1);
    const float* lutData = lut.data;

    const float x = clamp01(r) * scale;
    const float y = clamp01(g) * scale;
    const float z = clamp01(b) * scale;

    const int x0 = static_cast<int>(x);
    const int y0 = static_cast<int>(y);
    const int z0 = static_cast<int>(z);
    const int x1 = std::min(x0 + 1, dimM1);
    const int y1 = std::min(y0 + 1, dimM1);
    const int z1 = std::min(z0 + 1, dimM1);

    const float fx = x - x0, fy = y - y0, fz = z - z0;

    auto at = [dim, lutData](int xi, int yi, int zi) -> RGB {
        const int idx = ((zi * dim + yi) * dim + xi) * 3;
        return {lutData[idx], lutData[idx + 1], lutData[idx + 2]};
    };

    const RGB c000 = at(x0, y0, z0), c100 = at(x1, y0, z0);
    const RGB c010 = at(x0, y1, z0), c110 = at(x1, y1, z0);
    const RGB c001 = at(x0, y0, z1), c101 = at(x1, y0, z1);
    const RGB c011 = at(x0, y1, z1), c111 = at(x1, y1, z1);

    RGB c00{lerp(c000.r,c100.r,fx), lerp(c000.g,c100.g,fx), lerp(c000.b,c100.b,fx)};
    RGB c10{lerp(c010.r,c110.r,fx), lerp(c010.g,c110.g,fx), lerp(c010.b,c110.b,fx)};
    RGB c01{lerp(c001.r,c101.r,fx), lerp(c001.g,c101.g,fx), lerp(c001.b,c101.b,fx)};
    RGB c11{lerp(c011.r,c111.r,fx), lerp(c011.g,c111.g,fx), lerp(c011.b,c111.b,fx)};

    RGB c0{lerp(c00.r,c10.r,fy), lerp(c00.g,c10.g,fy), lerp(c00.b,c10.b,fy)};
    RGB c1{lerp(c01.r,c11.r,fy), lerp(c01.g,c11.g,fy), lerp(c01.b,c11.b,fy)};

    return {lerp(c0.r,c1.r,fz), lerp(c0.g,c1.g,fz), lerp(c0.b,c1.b,fz)};
}

inline RGB applyLayer(const LUT3D& lut, float intensity, RGB color) {
    const RGB lutRGB = sampleLUT(lut, color.r, color.g, color.b);
    if (intensity >= 0.9999f) return lutRGB;
    return {lerp(color.r, lutRGB.r, intensity),
            lerp(color.g, lutRGB.g, intensity),
            lerp(color.b, lutRGB.b, intensity)};
}

inline const LUT3D* resolveLayer(const LayerParams& lp, const LUT3D* table, int count) {
    if (!lp.enabled || lp.lutIndex < 0 || lp.lutIndex >= count || lp.intensity <= 0.0001f)
        return nullptr;
    return &table[lp.lutIndex];
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
    auto toU8 = [](float v) -> std::uint8_t {
        const float cl = clamp01(v) * 255.0f + 0.5f;
        return static_cast<std::uint8_t>(cl > 255.0f ? 255.0f : cl);
    };
    return {a, toU8(c.r), toU8(c.g), toU8(c.b)};
}
inline Pixel16 fromFloat16(const RGB& c, std::uint16_t a) {
    auto toU16 = [](float v) -> std::uint16_t {
        const float cl = clamp01(v) * 32768.0f + 0.5f;
        return static_cast<std::uint16_t>(cl > 32768.0f ? 32768.0f : cl);
    };
    return {a, toU16(c.r), toU16(c.g), toU16(c.b)};
}
inline Pixel32f fromFloat32(const RGB& c, float a) {
    return {a, clamp01(c.r), clamp01(c.g), clamp01(c.b)};
}

// Per-frame resolved state. The 4 null checks in processPixel are constant
// for every pixel in the frame -- branch prediction handles them at zero cost.
// TODO [GPU]: Replace with a compact array of active layers and dispatch count
// to match Metal compute shader uniform layout.
struct ActiveLayers {
    const LUT3D* log      = nullptr; float logI      = 0.f;
    const LUT3D* creative = nullptr; float creativeI = 0.f;
    const LUT3D* secondary= nullptr; float secondaryI= 0.f;
    const LUT3D* accent   = nullptr; float accentI   = 0.f;
    bool any() const { return log || creative || secondary || accent; }
};

inline RGB processPixel(RGB color, const ActiveLayers& al) {
    if (al.log)       color = applyLayer(*al.log,       al.logI,       color);
    if (al.creative)  color = applyLayer(*al.creative,  al.creativeI,  color);
    if (al.secondary) color = applyLayer(*al.secondary, al.secondaryI, color);
    if (al.accent)    color = applyLayer(*al.accent,    al.accentI,    color);
    return color;
}

template <typename PixelType, typename ToFloatFn, typename FromFloatFn>
void processTyped(const ActiveLayers& al, const FrameDesc& src, FrameDesc& dst,
                  ToFloatFn toFloat, FromFloatFn fromFloat) {
    auto* srcBytes = static_cast<const std::uint8_t*>(src.data);
    auto* dstBytes = static_cast<std::uint8_t*>(dst.data);
    for (int y = 0; y < src.height; ++y) {
        const auto* srcRow = reinterpret_cast<const PixelType*>(srcBytes + y * src.rowBytes);
        auto*       dstRow = reinterpret_cast<PixelType*>(dstBytes + y * dst.rowBytes);
        for (int x = 0; x < src.width; ++x) {
            const PixelType& s = srcRow[x];
            RGB color = toFloat(s);
            color = processPixel(color, al);
            dstRow[x] = fromFloat(color, s.a);
        }
    }
}

}  // namespace

// TODO [GPU]: This function is the CPU fallback entry point.
// Metal path will share ActiveLayers resolution but dispatch to a compute shader
// instead of processTyped. LUT data will be uploaded as MTLBuffer once per
// param change, not per frame.
void ProcessFrameCPU(const ParamsSnapshot& params, const FrameDesc& src, FrameDesc& dst) {
    if (!IsSupported(src) || !IsSupported(dst) || !SameGeometry(src, dst)) {
        CopyFrame(src, dst); return;
    }

    ActiveLayers al;
    al.log       = resolveLayer(params.logConvert, kLogLUTs, kLogLUTCount);
    al.logI      = clamp01(params.logConvert.intensity);
    al.creative  = resolveLayer(params.creative,  kRec709LUTs, kRec709LUTCount);
    al.creativeI = clamp01(params.creative.intensity);
    al.secondary = resolveLayer(params.secondary, kRec709LUTs, kRec709LUTCount);
    al.secondaryI= clamp01(params.secondary.intensity);
    al.accent    = resolveLayer(params.accent,    kRec709LUTs, kRec709LUTCount);
    al.accentI   = clamp01(params.accent.intensity);

    if (!al.any()) { CopyFrame(src, dst); return; }

    switch (src.format) {
        case FrameFormat::kRGBA_8u:
            processTyped<Pixel8>(al, src, dst, toFloat8, fromFloat8); break;
        case FrameFormat::kRGBA_16u:
            processTyped<Pixel16>(al, src, dst, toFloat16, fromFloat16); break;
        case FrameFormat::kRGBA_32f:
            processTyped<Pixel32f>(al, src, dst, toFloat32, fromFloat32); break;
    }
}

}  // namespace vtc
