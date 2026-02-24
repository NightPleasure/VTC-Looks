#include "VTC_AdobePF_Includes.h"

#include "../../Core/VTC_LUTSampling.h"
#include "../../Shared/VTC_LUTData.h"
#include "VTC_FrameMap_AdobePF.h"
#include "VTC_ParamMap_AdobePF.h"

namespace vtc {
namespace pf {

// ── Next/Prev/Selected sync ──

struct GroupIDs {
    ParamID look, next, prev, selected;
    int lutCount;
};

static const GroupIDs kGroups[] = {
    { kParam_LogLook,       kParam_LogNext,       kParam_LogPrev,       kParam_LogSelected,       kLogLUTCount },
    { kParam_CreativeLook,  kParam_CreativeNext,  kParam_CreativePrev,  kParam_CreativeSelected,  kRec709LUTCount },
    { kParam_SecondaryLook, kParam_SecondaryNext, kParam_SecondaryPrev, kParam_SecondarySelected, kRec709LUTCount },
    { kParam_AccentLook,    kParam_AccentNext,    kParam_AccentPrev,    kParam_AccentSelected,    kRec709LUTCount },
};
constexpr int kGroupCount = 4;

static PF_Err HandleParamChange(PF_InData* in_data, PF_OutData* out_data,
                                PF_ParamDef* params[],
                                PF_UserChangedParamExtra* ucp) {
    (void)in_data; (void)out_data;
    PF_Err err = PF_Err_NONE;
    const int changed = ucp->param_index;

    for (int g = 0; g < kGroupCount; ++g) {
        const GroupIDs& gid = kGroups[g];
        const int maxVal = gid.lutCount + 1;

        if (changed == gid.next) {
            int cur = params[gid.look]->u.pd.value;
            int nxt = (cur < maxVal) ? cur + 1 : 1;
            params[gid.look]->u.pd.value = nxt;
            params[gid.look]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            params[gid.selected]->u.pd.value = nxt;
            params[gid.selected]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            return err;
        }
        if (changed == gid.prev) {
            int cur = params[gid.look]->u.pd.value;
            int prv = (cur > 1) ? cur - 1 : maxVal;
            params[gid.look]->u.pd.value = prv;
            params[gid.look]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            params[gid.selected]->u.pd.value = prv;
            params[gid.selected]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            return err;
        }
        if (changed == gid.look) {
            params[gid.selected]->u.pd.value = params[gid.look]->u.pd.value;
            params[gid.selected]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            return err;
        }

    }
    return err;
}

// ── Render paths ──

static PF_Err Render(PF_InData* in_data, PF_OutData* out_data,
                     PF_ParamDef* params[], PF_LayerDef* output) {
    (void)out_data;
    FrameDesc src{}, dst{};
    PF_Err err = MapWorldToFrame(&params[kParam_Input]->u.ld, &src);
    err = (err == PF_Err_NONE) ? MapWorldToFrame(output, &dst) : err;
    if (err != PF_Err_NONE) return err;
    const ParamsSnapshot snap = ReadParams(const_cast<const PF_ParamDef* const*>(params));
    ProcessFrameCPU(snap, src, dst);
    return PF_Err_NONE;
}

static LayerParams CheckoutLayer(PF_InData* in_data,
                                 ParamID enableId, ParamID lookId, ParamID intensityId) {
    LayerParams lp;
    PF_ParamDef def;

    AEFX_CLR_STRUCT(def);
    if (PF_CHECKOUT_PARAM(in_data, enableId, in_data->current_time,
                          in_data->time_step, in_data->time_scale, &def) == PF_Err_NONE)
        lp.enabled = def.u.bd.value != 0;

    AEFX_CLR_STRUCT(def);
    if (PF_CHECKOUT_PARAM(in_data, lookId, in_data->current_time,
                          in_data->time_step, in_data->time_scale, &def) == PF_Err_NONE) {
        const int pv = def.u.pd.value;
        lp.lutIndex = (pv > 1) ? (pv - 2) : -1;
    }

    AEFX_CLR_STRUCT(def);
    if (PF_CHECKOUT_PARAM(in_data, intensityId, in_data->current_time,
                          in_data->time_step, in_data->time_scale, &def) == PF_Err_NONE)
        lp.intensity = static_cast<float>(def.u.fs_d.value) / 100.0f;

    return lp;
}

static PF_Err ReadParamsForCurrentFrame(PF_InData* in_data, ParamsSnapshot& out_snap) {
    out_snap.logConvert = CheckoutLayer(in_data, kParam_LogEnable,      kParam_LogLook,       kParam_LogIntensity);
    out_snap.creative   = CheckoutLayer(in_data, kParam_CreativeEnable,  kParam_CreativeLook,  kParam_CreativeIntensity);
    out_snap.secondary  = CheckoutLayer(in_data, kParam_SecondaryEnable, kParam_SecondaryLook, kParam_SecondaryIntensity);
    out_snap.accent     = CheckoutLayer(in_data, kParam_AccentEnable,    kParam_AccentLook,    kParam_AccentIntensity);
    return PF_Err_NONE;
}

static PF_Err SmartPreRender(PF_InData* in_data, PF_OutData* out_data,
                             PF_PreRenderExtra* extra) {
    (void)out_data;
    PF_Err err = PF_Err_NONE;
    PF_RenderRequest req = extra->input->output_request;
    PF_CheckoutResult in_result{};
    err = extra->cb->checkout_layer(in_data->effect_ref,
                                    kParam_Input, kParam_Input,
                                    &req, in_data->current_time,
                                    in_data->time_step, in_data->time_scale,
                                    &in_result);
    if (!err) {
        UnionLRect(&in_result.result_rect,     &extra->output->result_rect);
        UnionLRect(&in_result.max_result_rect, &extra->output->max_result_rect);
    }
    return err;
}

static PF_Err SmartRender(PF_InData* in_data, PF_OutData* out_data,
                          PF_SmartRenderExtra* extra) {
    (void)out_data;
    PF_Err err = PF_Err_NONE;
    PF_EffectWorld *input_worldP = nullptr, *output_worldP = nullptr;

    if (!err) err = extra->cb->checkout_layer_pixels(in_data->effect_ref, kParam_Input, &input_worldP);
    if (!err) err = extra->cb->checkout_output(in_data->effect_ref, &output_worldP);

    if (!err && input_worldP && output_worldP) {
        FrameDesc src{}, dst{};
        if (!err) err = MapWorldToFrame(input_worldP,  &src);
        if (!err) err = MapWorldToFrame(output_worldP, &dst);
        if (!err) {
            ParamsSnapshot snap{};
            (void)ReadParamsForCurrentFrame(in_data, snap);
            ProcessFrameCPU(snap, src, dst);
        }
    }
    if (extra && extra->cb && input_worldP)
        extra->cb->checkin_layer_pixels(in_data->effect_ref, kParam_Input);
    return err;
}

}  // namespace pf
}  // namespace vtc

extern "C" __attribute__((visibility("default")))
PF_Err EffectMain(PF_Cmd cmd, PF_InData* in_data, PF_OutData* out_data,
                  PF_ParamDef* params[], PF_LayerDef* output, void* extra) {
    using namespace vtc::pf;
    PF_Err err = PF_Err_NONE;
    switch (cmd) {
        case PF_Cmd_GLOBAL_SETUP:
            out_data->my_version = PF_VERSION(1, 0, 0, 0, 0);
            out_data->out_flags  = PF_OutFlag_DEEP_COLOR_AWARE
                                 | PF_OutFlag_SEND_UPDATE_PARAMS_UI;
            out_data->out_flags2 = PF_OutFlag2_FLOAT_COLOR_AWARE
                                 | PF_OutFlag2_SUPPORTS_SMART_RENDER
                                 | PF_OutFlag2_PARAM_GROUP_START_COLLAPSED_FLAG;
            break;
        case PF_Cmd_PARAMS_SETUP:
            err = AddParams(in_data, out_data);
            break;
        case PF_Cmd_RENDER:
            err = Render(in_data, out_data, params, output);
            break;
        case PF_Cmd_SMART_PRE_RENDER:
            err = SmartPreRender(in_data, out_data,
                                reinterpret_cast<PF_PreRenderExtra*>(extra));
            break;
        case PF_Cmd_SMART_RENDER:
            err = SmartRender(in_data, out_data,
                              reinterpret_cast<PF_SmartRenderExtra*>(extra));
            break;
        case PF_Cmd_USER_CHANGED_PARAM:
            err = HandleParamChange(in_data, out_data, params,
                                    reinterpret_cast<PF_UserChangedParamExtra*>(extra));
            break;
        default:
            break;
    }
    return err;
}
