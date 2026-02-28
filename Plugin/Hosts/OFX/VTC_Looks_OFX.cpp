#include "VTC_OFX_Includes.h"
#include "VTC_OFX_ImageMap.h"
#include "VTC_ParamMap_OFX.h"

#include "../../Core/VTC_CopyUtils.h"
#include "../../Core/VTC_LUTSampling.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace OFX {
namespace Private {
void setHost(OfxHost* host);
}  // namespace Private
}  // namespace OFX

namespace vtc {
namespace ofx {

namespace {
constexpr const char* kPluginID = "com.vtclooks.ofx.v2";
constexpr const char* kPluginGroup = "VTC Works";
constexpr const char* kPluginLabel = "VTC Looks";

bool layerActive(const LayerParams& lp, int maxCount) {
    return lp.enabled && lp.lutIndex >= 0 && lp.lutIndex < maxCount && lp.intensity > 0.0001f;
}

bool envEnabled(const char* name) {
    const char* v = std::getenv(name);
    return v && (std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 || std::strcmp(v, "TRUE") == 0);
}

void logParamsOncePerFrame(const ParamsSnapshot& snap) {
    static std::atomic<int> count{0};
    const int n = count.fetch_add(1);
    if (n >= 120) {
        return;
    }
    FILE* f = std::fopen("/tmp/vtc_ofx_diag.log", "a");
    if (!f) {
        return;
    }
    if (n == 0) {
        std::fprintf(f, "[VTC] first render from this plugin build\n");
    }
    std::fprintf(
        f,
        "[VTC][diag] log={en=%d idx=%d int=%.3f} creative={en=%d idx=%d int=%.3f} secondary={en=%d idx=%d int=%.3f} accent={en=%d idx=%d int=%.3f}\n",
        snap.logConvert.enabled ? 1 : 0, snap.logConvert.lutIndex, snap.logConvert.intensity,
        snap.creative.enabled ? 1 : 0, snap.creative.lutIndex, snap.creative.intensity,
        snap.secondary.enabled ? 1 : 0, snap.secondary.lutIndex, snap.secondary.intensity,
        snap.accent.enabled ? 1 : 0, snap.accent.lutIndex, snap.accent.intensity);
    std::fclose(f);
}
}  // namespace

class VTCLooksEffect : public OFX::ImageEffect {
public:
    explicit VTCLooksEffect(OfxImageEffectHandle handle) : OFX::ImageEffect(handle) {}

    void render(const OFX::RenderArguments& args) override {
        OFX::Clip* srcClip = fetchClip(kOfxImageEffectSimpleSourceClipName);
        OFX::Clip* dstClip = fetchClip(kOfxImageEffectOutputClipName);
        if (!srcClip || !dstClip || !srcClip->isConnected()) {
            return;
        }

        OFX::Image* srcImg = srcClip->fetchImage(args.time);
        OFX::Image* dstImg = dstClip->fetchImage(args.time);
        if (!srcImg || !dstImg) {
            delete srcImg;
            delete dstImg;
            return;
        }

        FrameDesc src{};
        FrameDesc dst{};
        if (!MapImageToFrame(srcImg, &src) || !MapImageToFrame(dstImg, &dst) || !SameGeometry(src, dst)) {
            if (MapImageToFrame(srcImg, &src) && MapImageToFrame(dstImg, &dst)) {
                CopyFrame(src, dst);
            }
            delete srcImg;
            delete dstImg;
            return;
        }

        const ParamsSnapshot snap = ReadParams(this);
        logParamsOncePerFrame(snap);
        ProcessFrameCPU(snap, src, dst);

        delete srcImg;
        delete dstImg;
    }

    bool isIdentity(const OFX::IsIdentityArguments& args, OFX::Clip*& identityClip, double& identityTime) override {
        (void)args;
        (void)identityClip;
        (void)identityTime;
        return false;
    }

    void changedParam(const OFX::InstanceChangedArgs& args, const std::string& paramName) override {
        if (args.reason != OFX::eChangeUserEdit) return;

        auto cycleLook = [this](const char* prefix, int optionCount, bool forward) {
            std::string p(prefix);
            OFX::ChoiceParam* look = fetchChoiceParam(p + "Look");
            OFX::ChoiceParam* sel = fetchChoiceParam(p + "Selected");
            if (!look || !sel || optionCount <= 0) return;

            int current = 0;
            look->getValue(current);
            if (current < 0 || current >= optionCount) current = 0;

            int next = forward ? (current + 1) : (current - 1);
            if (next < 0) next = optionCount - 1;
            if (next >= optionCount) next = 0;

            look->setValue(next);
            sel->setValue(next);
        };

        if (paramName == "logNext") cycleLook("log", kLogLUTCount + 1, true);
        else if (paramName == "logPrev") cycleLook("log", kLogLUTCount + 1, false);
        else if (paramName == "creativeNext") cycleLook("creative", kRec709LUTCount + 1, true);
        else if (paramName == "creativePrev") cycleLook("creative", kRec709LUTCount + 1, false);
        else if (paramName == "secondaryNext") cycleLook("secondary", kRec709LUTCount + 1, true);
        else if (paramName == "secondaryPrev") cycleLook("secondary", kRec709LUTCount + 1, false);
        else if (paramName == "accentNext") cycleLook("accent", kRec709LUTCount + 1, true);
        else if (paramName == "accentPrev") cycleLook("accent", kRec709LUTCount + 1, false);
        else if (paramName.find("Look") != std::string::npos && paramName.find("Selected") == std::string::npos) {
            std::string p = paramName.substr(0, paramName.find("Look"));
            OFX::ChoiceParam* look = fetchChoiceParam(paramName);
            OFX::ChoiceParam* sel = fetchChoiceParam(p + "Selected");
            if (look && sel) {
                int value = 0;
                look->getValue(value);
                sel->setValue(value);
            }
        }
    }
};

class VTCLooksFactory : public OFX::PluginFactoryHelper<VTCLooksFactory> {
public:
    VTCLooksFactory() : PluginFactoryHelper<VTCLooksFactory>(kPluginID, 1, 0) {}

    void describe(OFX::ImageEffectDescriptor& desc) override {
        desc.setLabels(kPluginLabel, kPluginLabel, kPluginLabel);
        desc.setPluginGrouping(kPluginGroup);
        desc.addSupportedContext(OFX::eContextFilter);
        desc.addSupportedBitDepth(OFX::eBitDepthUByte);
        desc.addSupportedBitDepth(OFX::eBitDepthUShort);
        desc.addSupportedBitDepth(OFX::eBitDepthFloat);
        desc.setSupportsTiles(false);
        desc.setRenderThreadSafety(OFX::eRenderInstanceSafe);
    }

    void describeInContext(OFX::ImageEffectDescriptor& desc, OFX::ContextEnum context) override {
        if (context != OFX::eContextFilter) {
            return;
        }

        OFX::ClipDescriptor* srcClip = desc.defineClip(kOfxImageEffectSimpleSourceClipName);
        srcClip->addSupportedComponent(OFX::ePixelComponentRGBA);
        srcClip->setTemporalClipAccess(false);

        OFX::ClipDescriptor* dstClip = desc.defineClip(kOfxImageEffectOutputClipName);
        dstClip->addSupportedComponent(OFX::ePixelComponentRGBA);

        AddParams(desc);

        OFX::PageParamDescriptor* page = desc.definePageParam("Controls");
        if (page) {
            page->addChild(*desc.getParamDescriptor("logGroup"));
            page->addChild(*desc.getParamDescriptor("creativeGroup"));
            page->addChild(*desc.getParamDescriptor("secondaryGroup"));
            page->addChild(*desc.getParamDescriptor("accentGroup"));
        }
    }

    OFX::ImageEffect* createInstance(OfxImageEffectHandle handle, OFX::ContextEnum context) override {
        (void)context;
        return new VTCLooksEffect(handle);
    }
};

}  // namespace ofx
}  // namespace vtc

namespace OFX {
namespace Plugin {

void getPluginIDs(OFX::PluginFactoryArray& ids) {
    static vtc::ofx::VTCLooksFactory factory;
    ids.push_back(&factory);
}

}  // namespace Plugin
}  // namespace OFX

extern "C" __attribute__((visibility("default"), used)) OfxStatus OfxSetHost(const OfxHost* host) {
    OFX::Private::setHost(const_cast<OfxHost*>(host));
    return kOfxStatOK;
}
