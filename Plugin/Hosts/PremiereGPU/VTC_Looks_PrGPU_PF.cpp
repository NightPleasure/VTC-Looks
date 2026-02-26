// VTC Looks PrGPU — PF entry for parameter definition + CPU fallback.
// Mirrors AdobePF parameter UX behavior (Look/Next/Prev/Selected sync).

#include "AEConfig.h"
#include "AE_Effect.h"
#include "AE_EffectCB.h"
#include "AE_Macros.h"
#include "Param_Utils.h"
#include "VTC_PrGPU_Params.h"
#include "../../Core/VTC_CopyUtils.h"
#include "../../Core/VTC_LUTSampling.h"
#include "../../Shared/VTC_LUTData.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifndef DllExport
#  define DllExport __attribute__((visibility("default")))
#endif

namespace {

using vtc::prgpu::PrGPUParamID;

struct GroupIDs {
    PrGPUParamID look;
    PrGPUParamID next;
    PrGPUParamID prev;
    PrGPUParamID selected;
    int lutCount;
};

static const GroupIDs kGroups[] = {
    {vtc::prgpu::kParam_LogLook,       vtc::prgpu::kParam_LogNext,       vtc::prgpu::kParam_LogPrev,       vtc::prgpu::kParam_LogSelected,       vtc::kLogLUTCount},
    {vtc::prgpu::kParam_CreativeLook,  vtc::prgpu::kParam_CreativeNext,  vtc::prgpu::kParam_CreativePrev,  vtc::prgpu::kParam_CreativeSelected,  vtc::kRec709LUTCount},
    {vtc::prgpu::kParam_SecondaryLook, vtc::prgpu::kParam_SecondaryNext, vtc::prgpu::kParam_SecondaryPrev, vtc::prgpu::kParam_SecondarySelected, vtc::kRec709LUTCount},
    {vtc::prgpu::kParam_AccentLook,    vtc::prgpu::kParam_AccentNext,    vtc::prgpu::kParam_AccentPrev,    vtc::prgpu::kParam_AccentSelected,    vtc::kRec709LUTCount},
};

static bool EnvEnabled(const char* name) {
    const char* v = std::getenv(name);
    if (!v) return false;
    return std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 || std::strcmp(v, "TRUE") == 0;
}

static bool DiagEnabled() {
    static const bool enabled = EnvEnabled("VTC_PRGPU_DIAG");
    return enabled;
}

static void DiagLogPathOnce(const char* reason) {
    static bool logged = false;
    if (!DiagEnabled() || logged) return;
    std::fprintf(stderr, "[VTC_PrGPU_PF] path=CPU fallback reason=%s\n", reason);
    logged = true;
}

static void DiagLogUnsupportedFormatOnce(const PF_EffectWorld* world) {
    static bool logged = false;
    if (!DiagEnabled() || logged || !world) return;
    const int width = static_cast<int>(world->width);
    const int rb = static_cast<int>(world->rowbytes);
    const int bpp = (width > 0) ? (rb / width) : 0;
    std::fprintf(stderr,
                 "[VTC_PrGPU_PF] path=CPU fallback reason=unsupported format (rowBytes=%d width=%d bpp=%d deep=%d)\n",
                 rb,
                 width,
                 bpp,
                 PF_WORLD_IS_DEEP(world) ? 1 : 0);
    logged = true;
}

static PF_Err MapWorldToFrame(const PF_EffectWorld* world, vtc::FrameDesc* out, bool* supported) {
    if (!world || !out) {
        return PF_Err_BAD_CALLBACK_PARAM;
    }

    out->data = world->data;
    out->width = static_cast<int>(world->width);
    out->height = static_cast<int>(world->height);
    out->rowBytes = static_cast<int>(world->rowbytes);
    out->format = vtc::FrameFormat::kRGBA_8u;

    bool ok = false;
    if (PF_WORLD_IS_DEEP(world)) {
        out->format = vtc::FrameFormat::kRGBA_16u;
        ok = true;
    } else if (out->width > 0 && out->rowBytes / out->width >= 16) {
        out->format = vtc::FrameFormat::kRGBA_32f;
        ok = true;
    } else if (out->width > 0 && out->rowBytes / out->width >= 4) {
        out->format = vtc::FrameFormat::kRGBA_8u;
        ok = true;
    }

    if (supported) *supported = ok;
    return PF_Err_NONE;
}

static vtc::LayerParams ReadLayerFromParams(const PF_ParamDef* const params[],
                                            PrGPUParamID enableId,
                                            PrGPUParamID lookId,
                                            PrGPUParamID intensityId) {
    vtc::LayerParams layer{};
    layer.enabled = params[enableId]->u.bd.value != 0;

    // PF popup values are 1-based, where 1 means "None".
    const int popupValue = params[lookId]->u.pd.value;
    layer.lutIndex = (popupValue > 1) ? (popupValue - 2) : -1;

    layer.intensity = static_cast<float>(params[intensityId]->u.fs_d.value) / 100.0f;
    return layer;
}

static vtc::ParamsSnapshot ReadParamsFromRender(const PF_ParamDef* const params[]) {
    vtc::ParamsSnapshot snap{};
    snap.logConvert = ReadLayerFromParams(params, vtc::prgpu::kParam_LogEnable, vtc::prgpu::kParam_LogLook, vtc::prgpu::kParam_LogIntensity);
    snap.creative = ReadLayerFromParams(params, vtc::prgpu::kParam_CreativeEnable, vtc::prgpu::kParam_CreativeLook, vtc::prgpu::kParam_CreativeIntensity);
    snap.secondary = ReadLayerFromParams(params, vtc::prgpu::kParam_SecondaryEnable, vtc::prgpu::kParam_SecondaryLook, vtc::prgpu::kParam_SecondaryIntensity);
    snap.accent = ReadLayerFromParams(params, vtc::prgpu::kParam_AccentEnable, vtc::prgpu::kParam_AccentLook, vtc::prgpu::kParam_AccentIntensity);
    return snap;
}

static vtc::LayerParams CheckoutLayer(PF_InData* in_data,
                                      PrGPUParamID enableId,
                                      PrGPUParamID lookId,
                                      PrGPUParamID intensityId) {
    vtc::LayerParams layer{};
    PF_ParamDef def;

    AEFX_CLR_STRUCT(def);
    if (PF_CHECKOUT_PARAM(in_data, enableId, in_data->current_time,
                          in_data->time_step, in_data->time_scale, &def) == PF_Err_NONE) {
        layer.enabled = def.u.bd.value != 0;
        PF_CHECKIN_PARAM(in_data, &def);
    }

    AEFX_CLR_STRUCT(def);
    if (PF_CHECKOUT_PARAM(in_data, lookId, in_data->current_time,
                          in_data->time_step, in_data->time_scale, &def) == PF_Err_NONE) {
        const int popupValue = def.u.pd.value;
        layer.lutIndex = (popupValue > 1) ? (popupValue - 2) : -1;
        PF_CHECKIN_PARAM(in_data, &def);
    }

    AEFX_CLR_STRUCT(def);
    if (PF_CHECKOUT_PARAM(in_data, intensityId, in_data->current_time,
                          in_data->time_step, in_data->time_scale, &def) == PF_Err_NONE) {
        layer.intensity = static_cast<float>(def.u.fs_d.value) / 100.0f;
        PF_CHECKIN_PARAM(in_data, &def);
    }

    return layer;
}

static vtc::ParamsSnapshot ReadParamsFromSmartRender(PF_InData* in_data) {
    vtc::ParamsSnapshot snap{};
    snap.logConvert = CheckoutLayer(in_data, vtc::prgpu::kParam_LogEnable, vtc::prgpu::kParam_LogLook, vtc::prgpu::kParam_LogIntensity);
    snap.creative = CheckoutLayer(in_data, vtc::prgpu::kParam_CreativeEnable, vtc::prgpu::kParam_CreativeLook, vtc::prgpu::kParam_CreativeIntensity);
    snap.secondary = CheckoutLayer(in_data, vtc::prgpu::kParam_SecondaryEnable, vtc::prgpu::kParam_SecondaryLook, vtc::prgpu::kParam_SecondaryIntensity);
    snap.accent = CheckoutLayer(in_data, vtc::prgpu::kParam_AccentEnable, vtc::prgpu::kParam_AccentLook, vtc::prgpu::kParam_AccentIntensity);
    return snap;
}

static void ProcessOrCopy(const PF_EffectWorld* srcWorld,
                          PF_EffectWorld* dstWorld,
                          const vtc::ParamsSnapshot& snap,
                          const char* reason) {
    DiagLogPathOnce(reason);

    vtc::FrameDesc src{};
    vtc::FrameDesc dst{};
    bool srcSupported = false;
    bool dstSupported = false;

    if (MapWorldToFrame(srcWorld, &src, &srcSupported) != PF_Err_NONE ||
        MapWorldToFrame(dstWorld, &dst, &dstSupported) != PF_Err_NONE ||
        !srcSupported || !dstSupported ||
        !vtc::IsSupported(src) || !vtc::IsSupported(dst) || !vtc::SameGeometry(src, dst)) {
        DiagLogUnsupportedFormatOnce(srcWorld);
        vtc::CopyFrame(src, dst);
        return;
    }

    vtc::ProcessFrameCPU(snap, src, dst);
}

static PF_Err AddGroup(PF_InData* in_data,
                       const char* groupName,
                       int lutCount,
                       const char* lookPopupStr,
                       const char* selectedPopupStr,
                       int defaultIntensity,
                       bool collapsed,
                       PrGPUParamID topicId,
                       PrGPUParamID enableId,
                       PrGPUParamID lookId,
                       PrGPUParamID nextId,
                       PrGPUParamID prevId,
                       PrGPUParamID selectedId,
                       PrGPUParamID intensityId,
                       PrGPUParamID topicEndId) {
    PF_ParamDef def;

    AEFX_CLR_STRUCT(def);
    if (collapsed) def.flags = PF_ParamFlag_START_COLLAPSED;
    PF_ADD_TOPIC(groupName, topicId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_CHECKBOXX("Enable", TRUE, 0, enableId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_POPUPX("Look", lutCount + 1, 1, lookPopupStr,
                  PF_ParamFlag_SUPERVISE, lookId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_BUTTON("", "Next", 0, PF_ParamFlag_SUPERVISE, nextId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_BUTTON("", "Prev", 0, PF_ParamFlag_SUPERVISE, prevId);

    AEFX_CLR_STRUCT(def);
    def.ui_flags = PF_PUI_DISABLED;
    PF_ADD_POPUP("Selected", lutCount + 1, 1, selectedPopupStr, selectedId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_FLOAT_SLIDER("Intensity", 0, 100, 0, 100,
                        0, defaultIntensity, 1, 1, 0, intensityId);

    AEFX_CLR_STRUCT(def);
    PF_END_TOPIC(topicEndId);

    return PF_Err_NONE;
}

static PF_Err AddParams(PF_InData* in_data, PF_OutData* out_data) {
    (void)in_data;
    PF_Err err = PF_Err_NONE;

    ERR(AddGroup(in_data, "Log Convert",
                 vtc::kLogLUTCount, vtc::kLogPopupStr, vtc::kLogSelectedPopupStr, 100,
                 false,
                 vtc::prgpu::kParam_LogTopic, vtc::prgpu::kParam_LogEnable, vtc::prgpu::kParam_LogLook,
                 vtc::prgpu::kParam_LogNext, vtc::prgpu::kParam_LogPrev, vtc::prgpu::kParam_LogSelected,
                 vtc::prgpu::kParam_LogIntensity, vtc::prgpu::kParam_LogTopicEnd));

    ERR(AddGroup(in_data, "Creative Look",
                 vtc::kRec709LUTCount, vtc::kRec709PopupStr, vtc::kRec709SelectedPopupStr, 80,
                 false,
                 vtc::prgpu::kParam_CreativeTopic, vtc::prgpu::kParam_CreativeEnable, vtc::prgpu::kParam_CreativeLook,
                 vtc::prgpu::kParam_CreativeNext, vtc::prgpu::kParam_CreativePrev, vtc::prgpu::kParam_CreativeSelected,
                 vtc::prgpu::kParam_CreativeIntensity, vtc::prgpu::kParam_CreativeTopicEnd));

    ERR(AddGroup(in_data, "Secondary Look",
                 vtc::kRec709LUTCount, vtc::kRec709PopupStr, vtc::kRec709SelectedPopupStr, 50,
                 true,
                 vtc::prgpu::kParam_SecondaryTopic, vtc::prgpu::kParam_SecondaryEnable, vtc::prgpu::kParam_SecondaryLook,
                 vtc::prgpu::kParam_SecondaryNext, vtc::prgpu::kParam_SecondaryPrev, vtc::prgpu::kParam_SecondarySelected,
                 vtc::prgpu::kParam_SecondaryIntensity, vtc::prgpu::kParam_SecondaryTopicEnd));

    ERR(AddGroup(in_data, "Accent Look",
                 vtc::kRec709LUTCount, vtc::kRec709PopupStr, vtc::kRec709SelectedPopupStr, 20,
                 true,
                 vtc::prgpu::kParam_AccentTopic, vtc::prgpu::kParam_AccentEnable, vtc::prgpu::kParam_AccentLook,
                 vtc::prgpu::kParam_AccentNext, vtc::prgpu::kParam_AccentPrev, vtc::prgpu::kParam_AccentSelected,
                 vtc::prgpu::kParam_AccentIntensity, vtc::prgpu::kParam_AccentTopicEnd));

    out_data->num_params = vtc::prgpu::kParam_Count;
    return err;
}

static PF_Err HandleParamChange(PF_ParamDef* params[], PF_UserChangedParamExtra* ucp) {
    const int changed = ucp->param_index;
    for (const GroupIDs& gid : kGroups) {
        const int maxVal = gid.lutCount + 1;

        if (changed == gid.next) {
            int cur = params[gid.look]->u.pd.value;
            int nxt = (cur < maxVal) ? cur + 1 : 1;
            params[gid.look]->u.pd.value = nxt;
            params[gid.look]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            params[gid.selected]->u.pd.value = nxt;
            params[gid.selected]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            return PF_Err_NONE;
        }
        if (changed == gid.prev) {
            int cur = params[gid.look]->u.pd.value;
            int prv = (cur > 1) ? cur - 1 : maxVal;
            params[gid.look]->u.pd.value = prv;
            params[gid.look]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            params[gid.selected]->u.pd.value = prv;
            params[gid.selected]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            return PF_Err_NONE;
        }
        if (changed == gid.look) {
            params[gid.selected]->u.pd.value = params[gid.look]->u.pd.value;
            params[gid.selected]->uu.change_flags = PF_ChangeFlag_CHANGED_VALUE;
            return PF_Err_NONE;
        }
    }
    return PF_Err_NONE;
}

static PF_Err Render(PF_InData* in_data, PF_OutData* out_data,
                     PF_ParamDef* params[], PF_LayerDef* output) {
    (void)in_data;
    (void)out_data;
    if (!params || !params[0] || !output) return PF_Err_INVALID_CALLBACK;

    const PF_EffectWorld* srcWorld = &params[vtc::prgpu::kParam_Input]->u.ld;
    PF_EffectWorld* dstWorld = output;
    if (srcWorld->width != dstWorld->width || srcWorld->height != dstWorld->height) return PF_Err_INVALID_CALLBACK;

    const vtc::ParamsSnapshot snap = ReadParamsFromRender(const_cast<const PF_ParamDef* const*>(params));
    const char* reason = EnvEnabled("VTC_FALLBACK_FORCE_CPU")
        ? "forced by VTC_FALLBACK_FORCE_CPU=1"
        : "no Metal / PF CPU fallback path";
    ProcessOrCopy(srcWorld, dstWorld, snap, reason);
    return PF_Err_NONE;
}


static void UnionRect(const PF_LRect* src, PF_LRect* dst) {
    dst->left = (src->left < dst->left) ? src->left : dst->left;
    dst->top = (src->top < dst->top) ? src->top : dst->top;
    dst->right = (src->right > dst->right) ? src->right : dst->right;
    dst->bottom = (src->bottom > dst->bottom) ? src->bottom : dst->bottom;
}

static PF_Err SmartPreRender(PF_InData* in_data, PF_PreRenderExtra* extra) {
    PF_RenderRequest req = extra->input->output_request;
    PF_CheckoutResult in_result{};
    PF_Err err = extra->cb->checkout_layer(in_data->effect_ref,
                                           vtc::prgpu::kParam_Input, vtc::prgpu::kParam_Input,
                                           &req, in_data->current_time,
                                           in_data->time_step, in_data->time_scale,
                                           &in_result);
    if (!err) {
        UnionRect(&in_result.result_rect, &extra->output->result_rect);
        UnionRect(&in_result.max_result_rect, &extra->output->max_result_rect);
    }
    return err;
}

static PF_Err SmartRender(PF_InData* in_data, PF_SmartRenderExtra* extra) {
    PF_Err err = PF_Err_NONE;
    PF_EffectWorld* input_world = nullptr;
    PF_EffectWorld* output_world = nullptr;

    err = extra->cb->checkout_layer_pixels(in_data->effect_ref, vtc::prgpu::kParam_Input, &input_world);
    if (!err) err = extra->cb->checkout_output(in_data->effect_ref, &output_world);

    if (!err && input_world && output_world) {
        if (input_world->width != output_world->width || input_world->height != output_world->height) {
            err = PF_Err_INVALID_CALLBACK;
        } else {
            const vtc::ParamsSnapshot snap = ReadParamsFromSmartRender(in_data);
            const char* reason = EnvEnabled("VTC_FALLBACK_FORCE_CPU")
                ? "forced by VTC_FALLBACK_FORCE_CPU=1"
                : "no Metal / PF CPU fallback path";
            ProcessOrCopy(input_world, output_world, snap, reason);
        }
    }

    if (input_world) {
        extra->cb->checkin_layer_pixels(in_data->effect_ref, vtc::prgpu::kParam_Input);
    }
    return err;
}

}  // namespace

extern "C" DllExport PF_Err EffectMain(PF_Cmd cmd, PF_InData* in_data, PF_OutData* out_data,
                                       PF_ParamDef* params[], PF_LayerDef* output, void* extra) {
    PF_Err err = PF_Err_NONE;
    switch (cmd) {
        case PF_Cmd_GLOBAL_SETUP:
            out_data->my_version = PF_VERSION(1, 0, 2, 0, 0);
            out_data->out_flags = PF_OutFlag_DEEP_COLOR_AWARE
                               | PF_OutFlag_SEND_UPDATE_PARAMS_UI;
            out_data->out_flags2 = PF_OutFlag2_FLOAT_COLOR_AWARE
                                | PF_OutFlag2_SUPPORTS_SMART_RENDER
                                | PF_OutFlag2_PARAM_GROUP_START_COLLAPSED_FLAG
                                | PF_OutFlag2_SUPPORTS_THREADED_RENDERING;
            break;
        case PF_Cmd_PARAMS_SETUP:
            err = AddParams(in_data, out_data);
            break;
        case PF_Cmd_USER_CHANGED_PARAM:
            err = HandleParamChange(params, reinterpret_cast<PF_UserChangedParamExtra*>(extra));
            break;
        case PF_Cmd_RENDER:
            err = Render(in_data, out_data, params, output);
            break;
        case PF_Cmd_SMART_PRE_RENDER:
            err = SmartPreRender(in_data, reinterpret_cast<PF_PreRenderExtra*>(extra));
            break;
        case PF_Cmd_SMART_RENDER:
            err = SmartRender(in_data, reinterpret_cast<PF_SmartRenderExtra*>(extra));
            break;
        default:
            break;
    }
    return err;
}
