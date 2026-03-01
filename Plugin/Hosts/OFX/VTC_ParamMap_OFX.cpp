#include "VTC_ParamMap_OFX.h"
#include "../../Shared/VTC_LUTData.h"

#include "ofxsImageEffect.h"
#include "ofxsParam.h"

#include <string>

namespace vtc {
namespace ofx {

namespace {

void appendChoiceOptions(OFX::ChoiceParamDescriptor* choice, const char* popupStr) {
    std::string s(popupStr);
    size_t start = 0;
    for (;;) {
        size_t pos = s.find('|', start);
        std::string opt = (pos == std::string::npos) ? s.substr(start) : s.substr(start, pos - start);
        if (!opt.empty()) {
            choice->appendOption(opt);
        }
        if (pos == std::string::npos) {
            break;
        }
        start = pos + 1;
    }
}

void addGroup(OFX::ParamSetDescriptor& desc,
              const char* groupName,
              const char* lookPopup,
              const char* selectedPopup,
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
    appendChoiceOptions(look, lookPopup);
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
    appendChoiceOptions(sel, selectedPopup);
    sel->setParent(*grp);
    sel->setEnabled(false);

    OFX::DoubleParamDescriptor* intensity = desc.defineDoubleParam(p + "Intensity");
    intensity->setLabel("Intensity");
    intensity->setDefault(static_cast<double>(defaultIntensity));
    intensity->setRange(0.0, 100.0);
    intensity->setDisplayRange(0.0, 100.0);
    intensity->setParent(*grp);
}

LayerParams readLayer(const OFX::ParamSet* params, const char* prefix) {
    LayerParams lp{};
    std::string p(prefix);

    if (OFX::BooleanParam* en = params->fetchBooleanParam(p + "Enable")) {
        bool enabled = false;
        en->getValue(enabled);
        lp.enabled = enabled;
    }

    if (OFX::ChoiceParam* look = params->fetchChoiceParam(p + "Look")) {
        int v = 0;
        look->getValue(v);
        lp.lutIndex = (v > 0) ? (v - 1) : -1;
    }

    if (OFX::DoubleParam* intensity = params->fetchDoubleParam(p + "Intensity")) {
        double value = 100.0;
        intensity->getValue(value);
        lp.intensity = static_cast<float>(value) / 100.0f;
    } else {
        lp.intensity = 1.0f;
    }

    return lp;
}

}  // namespace

void AddParams(OFX::ParamSetDescriptor& desc) {
    addGroup(desc, "Log Convert", kLogPopupStr, kLogSelectedPopupStr, 100, false, "log");
    addGroup(desc, "Creative", kRec709PopupStr, kRec709SelectedPopupStr, 80, false, "creative");
    addGroup(desc, "Secondary", kRec709PopupStr, kRec709SelectedPopupStr, 50, true, "secondary");
    addGroup(desc, "Accent", kRec709PopupStr, kRec709SelectedPopupStr, 20, true, "accent");
}

ParamsSnapshot ReadParams(const OFX::ParamSet* params) {
    ParamsSnapshot snap{};
    if (!params) {
        return snap;
    }

    snap.logConvert = readLayer(params, "log");
    snap.creative = readLayer(params, "creative");
    snap.secondary = readLayer(params, "secondary");
    snap.accent = readLayer(params, "accent");
    return snap;
}

}  // namespace ofx
}  // namespace vtc
