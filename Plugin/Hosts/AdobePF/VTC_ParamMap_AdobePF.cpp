#include "VTC_ParamMap_AdobePF.h"
#include "../../Shared/VTC_LUTData.h"

namespace vtc {
namespace pf {

static PF_Err AddGroup(PF_InData* in_data, PF_OutData* out_data,
                        const char* group_name,
                        int lut_count,
                        const char* look_popup_str,
                        const char* selected_popup_str,
                        int default_intensity,
                        bool collapsed,
                        ParamID topicId, ParamID enableId, ParamID lookId,
                        ParamID nextId, ParamID prevId, ParamID selectedId,
                        ParamID intensityId, ParamID topicEndId) {
    PF_Err err = PF_Err_NONE;
    PF_ParamDef def;

    AEFX_CLR_STRUCT(def);
    if (collapsed) def.flags = PF_ParamFlag_START_COLLAPSED;
    PF_ADD_TOPIC(group_name, topicId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_CHECKBOXX("Enable", TRUE, 0, enableId);

    PF_ADD_POPUPX("Look", lut_count + 1, 1, look_popup_str,
                  PF_ParamFlag_SUPERVISE, lookId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_BUTTON("", "Next", 0, PF_ParamFlag_SUPERVISE, nextId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_BUTTON("", "Prev", 0, PF_ParamFlag_SUPERVISE, prevId);

    AEFX_CLR_STRUCT(def);
    def.ui_flags = PF_PUI_DISABLED;
    PF_ADD_POPUP("Selected", lut_count + 1, 1, selected_popup_str, selectedId);

    AEFX_CLR_STRUCT(def);
    PF_ADD_FLOAT_SLIDER("Intensity", 0, 100, 0, 100,
                        0, default_intensity, 1, 1, 0, intensityId);

    AEFX_CLR_STRUCT(def);
    PF_END_TOPIC(topicEndId);

    (void)out_data;
    return err;
}

PF_Err AddParams(PF_InData* in_data, PF_OutData* out_data) {
    PF_Err err = PF_Err_NONE;

    ERR(AddGroup(in_data, out_data, "Log Convert",
                 kLogLUTCount, kLogPopupStr, kLogSelectedPopupStr, 100,
                 false,
                 kParam_LogTopic, kParam_LogEnable, kParam_LogLook,
                 kParam_LogNext, kParam_LogPrev, kParam_LogSelected,
                 kParam_LogIntensity, kParam_LogTopicEnd));

    ERR(AddGroup(in_data, out_data, "Creative Look",
                 kRec709LUTCount, kRec709PopupStr, kRec709SelectedPopupStr, 80,
                 false,
                 kParam_CreativeTopic, kParam_CreativeEnable, kParam_CreativeLook,
                 kParam_CreativeNext, kParam_CreativePrev, kParam_CreativeSelected,
                 kParam_CreativeIntensity, kParam_CreativeTopicEnd));

    ERR(AddGroup(in_data, out_data, "Secondary Look",
                 kRec709LUTCount, kRec709PopupStr, kRec709SelectedPopupStr, 50,
                 true,
                 kParam_SecondaryTopic, kParam_SecondaryEnable, kParam_SecondaryLook,
                 kParam_SecondaryNext, kParam_SecondaryPrev, kParam_SecondarySelected,
                 kParam_SecondaryIntensity, kParam_SecondaryTopicEnd));

    ERR(AddGroup(in_data, out_data, "Accent Look",
                 kRec709LUTCount, kRec709PopupStr, kRec709SelectedPopupStr, 20,
                 true,
                 kParam_AccentTopic, kParam_AccentEnable, kParam_AccentLook,
                 kParam_AccentNext, kParam_AccentPrev, kParam_AccentSelected,
                 kParam_AccentIntensity, kParam_AccentTopicEnd));

    out_data->num_params = kParam_Count;
    return err;
}

static LayerParams ReadLayer(const PF_ParamDef* const params[],
                             ParamID enableId, ParamID lookId, ParamID intensityId) {
    LayerParams lp;
    lp.enabled   = params[enableId]->u.bd.value != 0;
    const int pv = params[lookId]->u.pd.value;
    lp.lutIndex  = (pv > 1) ? (pv - 2) : -1;
    lp.intensity = static_cast<float>(params[intensityId]->u.fs_d.value) / 100.0f;
    return lp;
}

ParamsSnapshot ReadParams(const PF_ParamDef* const params[]) {
    ParamsSnapshot snap{};
    snap.logConvert = ReadLayer(params, kParam_LogEnable,      kParam_LogLook,       kParam_LogIntensity);
    snap.creative   = ReadLayer(params, kParam_CreativeEnable,  kParam_CreativeLook,  kParam_CreativeIntensity);
    snap.secondary  = ReadLayer(params, kParam_SecondaryEnable, kParam_SecondaryLook, kParam_SecondaryIntensity);
    snap.accent     = ReadLayer(params, kParam_AccentEnable,    kParam_AccentLook,    kParam_AccentIntensity);
    return snap;
}

}  // namespace pf
}  // namespace vtc
