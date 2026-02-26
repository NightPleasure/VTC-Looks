// VTC Looks PrGPU — minimal PF entry for param definition + CPU fallback
// Defines Enable + Intensity. GPU path uses xGPUFilterEntry.
// CPU fallback: passthrough (copy input->output).

#include "AEConfig.h"
#include "AE_Effect.h"
#include "AE_EffectCB.h"
#include "AE_Macros.h"
#include "Param_Utils.h"
#include "VTC_PrGPU_Params.h"

#include <cstring>

#ifndef DllExport
#  define DllExport __attribute__((visibility("default")))
#endif

static PF_Err AddParams(PF_InData* in_data, PF_OutData* out_data) {
    PF_Err err = PF_Err_NONE;
    PF_ParamDef def;

    // Param 0 (input layer) is implicit -- do NOT add PF_ADD_LAYER.
    // PF params: [0=input(implicit), 1=Enable, 2=Intensity]
    // GPU GetParam subtracts 1: GetParam(1)->Enable, GetParam(2)->Intensity

    AEFX_CLR_STRUCT(def);
    PF_ADD_CHECKBOXX("Enable", TRUE, 0, vtc::prgpu::kParam_Enable);

    AEFX_CLR_STRUCT(def);
    PF_ADD_FLOAT_SLIDERX("Intensity", 0, 100, 0, 100, 100.0, 1, 1, 0, vtc::prgpu::kParam_Intensity);

    out_data->num_params = vtc::prgpu::kParam_Count;
    return err;
}

static PF_Err Render(PF_InData* in_data, PF_OutData* out_data,
                     PF_ParamDef* params[], PF_LayerDef* output) {
    (void)in_data;
    (void)out_data;
    PF_Err err = PF_Err_NONE;
    if (!params || !params[0] || !output) return PF_Err_INVALID_CALLBACK;
    const PF_LayerDef* src = &params[0]->u.ld;
    if (src->width != output->width || src->height != output->height) return PF_Err_INVALID_CALLBACK;

    const int rowbytes = src->rowbytes ? src->rowbytes : src->width * 4;
    const size_t total = (size_t)rowbytes * src->height;
    if (total > 0 && src->data && output->data)
        std::memcpy(output->data, src->data, total);

    return err;
}

extern "C" DllExport PF_Err EffectMain(PF_Cmd cmd, PF_InData* in_data, PF_OutData* out_data,
                                       PF_ParamDef* params[], PF_LayerDef* output, void* extra) {
    (void)extra;
    PF_Err err = PF_Err_NONE;
    switch (cmd) {
        case PF_Cmd_GLOBAL_SETUP:
            out_data->my_version = PF_VERSION(1, 0, 1, 0, 0);
            out_data->out_flags = PF_OutFlag_DEEP_COLOR_AWARE;
            out_data->out_flags2 = PF_OutFlag2_FLOAT_COLOR_AWARE;
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
