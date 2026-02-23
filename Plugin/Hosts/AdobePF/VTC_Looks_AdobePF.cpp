#include "VTC_AdobePF_Includes.h"

#include "../../Core/VTC_LUTSampling.h"
#include "VTC_FrameMap_AdobePF.h"
#include "VTC_ParamMap_AdobePF.h"

namespace vtc {
namespace pf {

static PF_Err GlobalSetup(PF_InData* in_data, PF_OutData* out_data) {
    out_data->my_version = PF_VERSION(1, 0, 0, 0, 0);

    out_data->out_flags = PF_OutFlag_DEEP_COLOR_AWARE | PF_OutFlag_PIX_INDEPENDENT | PF_OutFlag_USE_OUTPUT_EXTENT | PF_OutFlag_WIDE_TIME_INPUT;
    out_data->out_flags2 = PF_OutFlag2_FLOAT_COLOR_AWARE;

    return PF_Err_NONE;
}

static PF_Err Render(PF_InData* in_data, PF_OutData* out_data, PF_ParamDef* params[], PF_LayerDef* output) {
    (void)out_data;
    FrameDesc src{};
    FrameDesc dst{};

    PF_Err err = MapWorldToFrame(in_data, &params[kParam_Input]->u.ld, &src);
    err = (err == PF_Err_NONE) ? MapWorldToFrame(in_data, output, &dst) : err;

    if (err != PF_Err_NONE) {
        return err;
    }

    const ParamsSnapshot snap = ReadParams(const_cast<const PF_ParamDef* const*>(params));

    ProcessFrameCPU(snap, src, dst);

    return PF_Err_NONE;
}

}  // namespace pf
}  // namespace vtc

extern "C" DllExport PF_Err EffectMain(PF_Cmd cmd, PF_InData* in_data, PF_OutData* out_data, PF_ParamDef* params[], PF_LayerDef* output, void* extra) {
    using namespace vtc::pf;
    PF_Err err = PF_Err_NONE;

    switch (cmd) {
        case PF_Cmd_GLOBAL_SETUP:
            err = GlobalSetup(in_data, out_data);
            break;
        case PF_Cmd_PARAMS_SETUP:
            err = AddParams(in_data, out_data);
            break;
        case PF_Cmd_RENDER:
            err = Render(in_data, out_data, params, output);
            break;
        default:
            break;
    }

    return err;
}
