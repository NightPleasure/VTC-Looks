#include "VTC_ParamMap_OFX.h"
#include "../../Shared/VTC_LUTData.h"

#include "ofxsImageEffect.h"
#include "ofxsParam.h"

#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

namespace vtc {
namespace ofx {

namespace {

static void appendChoiceOptions(OFX::ChoiceParamDescriptor* choice, const char* popupStr) {
    std::string s(popupStr);
    size_t start = 0;
    for (;;) {
        size_t pos = s.find('|', start);
        std::string opt = (pos == std::string::npos) ? s.substr(start) : s.substr(start, pos - start);
        if (!opt.empty())
            choice->appendOption(opt);
        if (pos == std::string::npos) break;
        start = pos + 1;
    }
}

static bool ShowDebugUI() {
    const char* env = std::getenv("VTC_SHOW_DEBUG_UI");
    return env && std::strcmp(env, "1") == 0;
}

static std::string buildSelectedOrderPopup(int lutCount) {
    std::ostringstream oss;
    oss << "0/" << lutCount;
    for (int i = 1; i <= lutCount; ++i) {
        oss << "|" << i << "/" << lutCount;
    }
    return oss.str();
}

static void addGroup(OFX::ParamSetDescriptor& desc,
                    const char* groupName,
                    int lutCount,
                    const char* lookPopupStr,
                    int defaultIntensity,
                    bool collapsed,
                    const char* prefix) {
    std::string p(prefix);
    OFX::GroupParamDescriptor* grp = desc.defineGroupParam(p + "Group");
    grp->setLabel(groupName);
    grp->setOpen(!collapsed);

    OFX::BooleanParamDescriptor* en = desc.defineBooleanParam(p + "Enable");
    en->setLabel("Enable");
    en->setDefault(true);
    en->setParent(*grp);

    OFX::ChoiceParamDescriptor* look = desc.defineChoiceParam(p + "Look");
    look->setLabel("Look");
    look->setDefault(0);
    appendChoiceOptions(look, lookPopupStr);
    look->setParent(*grp);

    OFX::PushButtonParamDescriptor* nextBtn = desc.definePushButtonParam(p + "Next");
    nextBtn->setLabel("Next");
    nextBtn->setParent(*grp);

    OFX::PushButtonParamDescriptor* prevBtn = desc.definePushButtonParam(p + "Prev");
    prevBtn->setLabel("Prev");
    prevBtn->setParent(*grp);

    OFX::ChoiceParamDescriptor* sel = desc.defineChoiceParam(p + "Selected");
    sel->setLabel("Selected");
    sel->setDefault(0);
    const std::string selectedPopup = buildSelectedOrderPopup(lutCount);
    appendChoiceOptions(sel, selectedPopup.c_str());
    sel->setParent(*grp);
    sel->setEnabled(false);

    OFX::DoubleParamDescriptor* intensity = desc.defineDoubleParam(p + "Intensity");
    intensity->setLabel("Intensity");
    intensity->setDefault(static_cast<double>(defaultIntensity));
    intensity->setRange(0, 100);
    intensity->setDisplayRange(0, 100);
    intensity->setParent(*grp);
}

}  // namespace

void AddParams(OFX::ParamSetDescriptor& desc) {
    addGroup(desc, "Log Convert",
             vtc::kLogLUTCount, vtc::kLogPopupStr, 100,
             false, "log");
    addGroup(desc, "Creative Look",
             vtc::kRec709LUTCount, vtc::kRec709PopupStr, 80,
             false, "creative");
    addGroup(desc, "Secondary Look",
             vtc::kRec709LUTCount, vtc::kRec709PopupStr, 50,
             true, "secondary");
    addGroup(desc, "Accent Look",
             vtc::kRec709LUTCount, vtc::kRec709PopupStr, 20,
             true, "accent");

    if (ShowDebugUI()) {
        OFX::GroupParamDescriptor* dbg = desc.defineGroupParam("debugGroup");
        dbg->setLabel("Debug / Testing");
        dbg->setHint("Testing only. Do not enable in normal use.");
        dbg->setOpen(false);

        OFX::BooleanParamDescriptor* forceCPU = desc.defineBooleanParam("DebugForceCPU");
        forceCPU->setLabel("Force CPU (Test)");
        forceCPU->setHint("Run CPU real LUT stack (testing only).");
        forceCPU->setDefault(false);
        forceCPU->setParent(*dbg);

        OFX::BooleanParamDescriptor* disableNative = desc.defineBooleanParam("DebugDisableNative");
        disableNative->setLabel("Disable Native GPU (Test)");
        disableNative->setHint("Disable OFX native GPU path and use CPU real path (testing only).");
        disableNative->setDefault(false);
        disableNative->setParent(*dbg);
    }
}

static LayerParams readLayer(const OFX::ParamSet* params, const char* prefix) {
    LayerParams lp{};
    std::string p(prefix);

    OFX::BooleanParam* en = params->fetchBooleanParam(p + "Enable");
    if (en) {
        bool enabled = false;
        en->getValue(enabled);
        lp.enabled = enabled;
    }

    OFX::ChoiceParam* look = params->fetchChoiceParam(p + "Look");
    if (look) {
        int v = 0;
        look->getValue(v);
        lp.lutIndex = (v > 0) ? (v - 1) : -1;
    }

    OFX::DoubleParam* intensity = params->fetchDoubleParam(p + "Intensity");
    if (intensity) {
        double value = 100.0;
        intensity->getValue(value);
        lp.intensity = static_cast<float>(value) / 100.0f;
    } else {
        lp.intensity = 1.0f;
    }

    return lp;
}

ParamsSnapshot ReadParams(const OFX::ParamSet* params) {
    ParamsSnapshot snap{};
    if (!params) return snap;
    snap.logConvert = readLayer(params, "log");
    snap.creative   = readLayer(params, "creative");
    snap.secondary  = readLayer(params, "secondary");
    snap.accent     = readLayer(params, "accent");

    OFX::BooleanParam* debugForceCPU = params->fetchBooleanParam("DebugForceCPU");
    if (debugForceCPU) {
        bool v = false;
        debugForceCPU->getValue(v);
        snap.debugForceCPU = v;
    }
    OFX::BooleanParam* debugDisableNative = params->fetchBooleanParam("DebugDisableNative");
    if (debugDisableNative) {
        bool v = false;
        debugDisableNative->getValue(v);
        snap.debugDisableNative = v;
    }
    return snap;
}

}  // namespace ofx
}  // namespace vtc
