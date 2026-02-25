#include "VTC_LUTSampling.h"
#include "VTC_RenderBackend.h"

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

struct ResolvedLayer {
    const float* data;
    int   dimension;
    float scale;
    float intensity;
};

inline RGB sampleLUTFast(const ResolvedLayer& layer, float r, float g, float b) {
    const int dim   = layer.dimension;
    const int dimM1 = dim - 1;

    const float x = clamp01(r) * layer.scale;
    const float y = clamp01(g) * layer.scale;
    const float z = clamp01(b) * layer.scale;

    const int x0 = static_cast<int>(x);
    const int y0 = static_cast<int>(y);
    const int z0 = static_cast<int>(z);
    const int x1 = std::min(x0 + 1, dimM1);
    const int y1 = std::min(y0 + 1, dimM1);
    const int z1 = std::min(z0 + 1, dimM1);

    const float fx = x - x0;
    const float fy = y - y0;
    const float fz = z - z0;

    const int dim2 = dim * dim;
    const float* lut = layer.data;

    const int z0Base = z0 * dim2;
    const int z1Base = z1 * dim2;
    const int z0y0 = (z0Base + y0 * dim) * 3;
    const int z0y1 = (z0Base + y1 * dim) * 3;
    const int z1y0 = (z1Base + y0 * dim) * 3;
    const int z1y1 = (z1Base + y1 * dim) * 3;

    const int i000 = z0y0 + x0 * 3;
    const int i100 = z0y0 + x1 * 3;
    const int i010 = z0y1 + x0 * 3;
    const int i110 = z0y1 + x1 * 3;
    const int i001 = z1y0 + x0 * 3;
    const int i101 = z1y0 + x1 * 3;
    const int i011 = z1y1 + x0 * 3;
    const int i111 = z1y1 + x1 * 3;

    const RGB c000{lut[i000], lut[i000 + 1], lut[i000 + 2]};
    const RGB c100{lut[i100], lut[i100 + 1], lut[i100 + 2]};
    const RGB c010{lut[i010], lut[i010 + 1], lut[i010 + 2]};
    const RGB c110{lut[i110], lut[i110 + 1], lut[i110 + 2]};
    const RGB c001{lut[i001], lut[i001 + 1], lut[i001 + 2]};
    const RGB c101{lut[i101], lut[i101 + 1], lut[i101 + 2]};
    const RGB c011{lut[i011], lut[i011 + 1], lut[i011 + 2]};
    const RGB c111{lut[i111], lut[i111 + 1], lut[i111 + 2]};

    const RGB c00{lerp(c000.r, c100.r, fx), lerp(c000.g, c100.g, fx), lerp(c000.b, c100.b, fx)};
    const RGB c10{lerp(c010.r, c110.r, fx), lerp(c010.g, c110.g, fx), lerp(c010.b, c110.b, fx)};
    const RGB c01{lerp(c001.r, c101.r, fx), lerp(c001.g, c101.g, fx), lerp(c001.b, c101.b, fx)};
    const RGB c11{lerp(c011.r, c111.r, fx), lerp(c011.g, c111.g, fx), lerp(c011.b, c111.b, fx)};

    const RGB c0{lerp(c00.r, c10.r, fy), lerp(c00.g, c10.g, fy), lerp(c00.b, c10.b, fy)};
    const RGB c1{lerp(c01.r, c11.r, fy), lerp(c01.g, c11.g, fy), lerp(c01.b, c11.b, fy)};

    return {lerp(c0.r, c1.r, fz), lerp(c0.g, c1.g, fz), lerp(c0.b, c1.b, fz)};
}

inline RGB sampleLUT(const ResolvedLayer& layer, float r, float g, float b) {
    return sampleLUTFast(layer, r, g, b);
}

inline RGB applyLayer(const ResolvedLayer& layer, RGB color) {
    const RGB lutRGB = sampleLUT(layer, color.r, color.g, color.b);
    if (layer.intensity >= 0.9999f) return lutRGB;
    return {lerp(color.r, lutRGB.r, layer.intensity),
            lerp(color.g, lutRGB.g, layer.intensity),
            lerp(color.b, lutRGB.b, layer.intensity)};
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

struct ActiveLayers {
    ResolvedLayer layers[4];
    int count = 0;

    void tryAdd(const LayerParams& lp, const LUT3D* table, int tableCount) {
        if (!lp.enabled || lp.lutIndex < 0 || lp.lutIndex >= tableCount
            || lp.intensity <= 0.0001f)
            return;
        const LUT3D& lut = table[lp.lutIndex];
        ResolvedLayer& rl = layers[count++];
        rl.data      = lut.data;
        rl.dimension = lut.dimension;
        rl.scale     = static_cast<float>(lut.dimension - 1);
        rl.intensity = clamp01(lp.intensity);
    }

    bool any() const { return count > 0; }
};

GPUDispatchDesc BuildGPUDesc(const ActiveLayers& al, const FrameDesc& src) {
    GPUDispatchDesc desc{};
    desc.layerCount  = al.count;
    desc.frameWidth  = src.width;
    desc.frameHeight = src.height;
    switch (src.format) {
        case FrameFormat::kRGBA_8u:  desc.bytesPerPixel = 4;  break;
        case FrameFormat::kRGBA_16u: desc.bytesPerPixel = 8;  break;
        case FrameFormat::kRGBA_32f: desc.bytesPerPixel = 16; break;
    }
    for (int i = 0; i < al.count; ++i) {
        desc.layers[i].lutData   = al.layers[i].data;
        desc.layers[i].dimension = al.layers[i].dimension;
        desc.layers[i].scale     = al.layers[i].scale;
        desc.layers[i].intensity = al.layers[i].intensity;
    }
    return desc;
}

inline RGB processPixel(RGB color, const ActiveLayers& al) {
    switch (al.count) {
        case 1:
            return applyLayer(al.layers[0], color);
        case 2:
            color = applyLayer(al.layers[0], color);
            return applyLayer(al.layers[1], color);
        case 3:
            color = applyLayer(al.layers[0], color);
            color = applyLayer(al.layers[1], color);
            return applyLayer(al.layers[2], color);
        case 4:
            color = applyLayer(al.layers[0], color);
            color = applyLayer(al.layers[1], color);
            color = applyLayer(al.layers[2], color);
            return applyLayer(al.layers[3], color);
        default:
            return color;
    }
}

template <typename PixelType, typename ToFloatFn, typename FromFloatFn>
void processTyped(const ActiveLayers& al, const FrameDesc& src, FrameDesc& dst,
                  ToFloatFn toFloat, FromFloatFn fromFloat) {
    const auto* srcBytes = static_cast<const std::uint8_t*>(src.data);
    auto* dstBytes = static_cast<std::uint8_t*>(dst.data);
    for (int y = 0; y < src.height; ++y) {
        const auto* __restrict srcRow = reinterpret_cast<const PixelType*>(srcBytes + y * src.rowBytes);
        auto* __restrict dstRow = reinterpret_cast<PixelType*>(dstBytes + y * dst.rowBytes);
        for (int x = 0; x < src.width; ++x) {
            const PixelType& s = srcRow[x];
            RGB color = processPixel(toFloat(s), al);
            dstRow[x] = fromFloat(color, s.a);
        }
    }
}

}  // namespace

void ProcessFrameCPU(const ParamsSnapshot& params, const FrameDesc& src, FrameDesc& dst) {
    if (!IsSupported(src) || !IsSupported(dst) || !SameGeometry(src, dst)) {
        CopyFrame(src, dst); return;
    }

    // Resolve active layers (order: Log -> Creative -> Secondary -> Accent)
    ActiveLayers al;
    al.tryAdd(params.logConvert, kLogLUTs,    kLogLUTCount);
    al.tryAdd(params.creative,   kRec709LUTs, kRec709LUTCount);
    al.tryAdd(params.secondary,  kRec709LUTs, kRec709LUTCount);
    al.tryAdd(params.accent,     kRec709LUTs, kRec709LUTCount);

    if (!al.any()) { CopyFrame(src, dst); return; }

    // Backend dispatch: when kEnableExperimentalMetal == false, the compiler
    // eliminates this entire block via if-constexpr dead-code removal.
    if (SelectBackend() == RenderBackend::kMetalGPU) {
        GPUDispatchDesc desc = BuildGPUDesc(al, src);
        if (metal::TryDispatch(desc, src.data, dst.data, src.rowBytes, dst.rowBytes))
            return;
        // TryDispatch returned false -- fall through to CPU
    }

    // CPU path (default and permanent fallback)
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
