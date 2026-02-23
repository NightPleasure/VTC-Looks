#include "VTC_ParamMap_AdobePF.h"
#include "../../Shared/VTC_LookRegistry.h"

namespace vtc {
namespace pf {

static const char* BuildPopupList(const char* const* names, int count) {
    // Build a 'Name|Name|...' string at compile time isn't feasible; for this small list we hardcode.
    // Category list is fixed, so we return a literal.
    (void)names;
    (void)count;
    return "Base";
}

static const char* BuildLookPopup() {
    // Fixed order matching kLookEntries.
    return "Identity|Film Warm|Cool Fade";
}

PF_Err AddParams(PF_InData* in_data, PF_OutData* out_data) {
    PF_Err err = PF_Err_NONE;
    PF_ParamDef def;

    AEFX_CLR_STRUCT(def);
    PF_ADD_CHECKBOX("Enable", "On", TRUE, 0, kParam_Enable);

    AEFX_CLR_STRUCT(def);
    const char* categoryPopup = BuildPopupList(nullptr, kLookCategoryCount);
    PF_ADD_POPUP("Primary Category", kLookCategoryCount, 1, categoryPopup, kParam_PrimaryCategory);

    AEFX_CLR_STRUCT(def);
    const char* lookPopup = BuildLookPopup();
    PF_ADD_POPUP("Primary Look", kLookEntryCount, 1, lookPopup, kParam_PrimaryLook);

    AEFX_CLR_STRUCT(def);
    PF_ADD_FLOAT_SLIDER("Primary Intensity", 0, 100, 0, 100, 100, 100, 1, 0, 0, kParam_PrimaryIntensity);

    out_data->num_params = kParam_Count;
    (void)in_data;
    return err;
}

ParamsSnapshot ReadParams(const PF_ParamDef* const params[]) {
    ParamsSnapshot snap{};
    snap.enabled = params[kParam_Enable]->u.bd.value != 0;

    const int catValue = params[kParam_PrimaryCategory]->u.pd.value - 1;  // popup is 1-based
    snap.primaryCategory = (catValue >= 0 && catValue < kLookCategoryCount) ? catValue : 0;

    const int lookValue = params[kParam_PrimaryLook]->u.pd.value - 1;
    snap.primaryLook = (lookValue >= 0) ? lookValue : 0;

    snap.primaryIntensity = static_cast<float>(params[kParam_PrimaryIntensity]->u.fs_d.value) / 100.0f;
    return snap;
}

}  // namespace pf
}  // namespace vtc
