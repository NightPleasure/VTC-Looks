#include "VTC_FrameMap_AdobePF.h"

namespace vtc {
namespace pf {

namespace {

FrameFormat PixelFormatToFrameFormat(PF_PixelFormat pf) {
    switch (pf) {
        case PF_PixelFormat_ARGB32:
            return FrameFormat::kRGBA_8u;
        case PF_PixelFormat_ARGB64:
            return FrameFormat::kRGBA_16u;
        case PF_PixelFormat_ARGB128:
            return FrameFormat::kRGBA_32f;
        default:
            return FrameFormat::kRGBA_8u;
    }
}

PF_PixelFormat GetWorldPixelFormat(PF_InData* in_data, const PF_EffectWorld* world) {
    if (!in_data || !in_data->pica_basicP || !world) {
        return PF_PixelFormat_INVALID;
    }

    const PF_WorldSuite2* worldSuite = nullptr;
    PF_PixelFormat pf = PF_PixelFormat_INVALID;
    if (in_data->pica_basicP->AcquireSuite(kPFWorldSuite, kPFWorldSuiteVersion2, reinterpret_cast<const void**>(&worldSuite)) == PF_Err_NONE &&
        worldSuite) {
        if (worldSuite->PF_GetPixelFormat(world, &pf) != PF_Err_NONE) {
            pf = PF_PixelFormat_INVALID;
        }
        in_data->pica_basicP->ReleaseSuite(kPFWorldSuite, kPFWorldSuiteVersion2);
    }
    return pf;
}

}  // namespace

PF_Err MapWorldToFrame(PF_InData* in_data, const PF_EffectWorld* world, FrameDesc* out) {
    if (!world || !out) {
        return PF_Err_BAD_CALLBACK_PARAM;
    }

    out->data = world->data;
    out->width = static_cast<int>(world->width);
    out->height = static_cast<int>(world->height);
    out->rowBytes = static_cast<int>(world->rowbytes);

    const PF_PixelFormat pf = GetWorldPixelFormat(in_data, world);
    if (pf != PF_PixelFormat_INVALID) {
        out->format = PixelFormatToFrameFormat(pf);
    } else {
        out->format = PF_WORLD_IS_DEEP(world) ? FrameFormat::kRGBA_16u : FrameFormat::kRGBA_8u;
    }

    return PF_Err_NONE;
}

}  // namespace pf
}  // namespace vtc
