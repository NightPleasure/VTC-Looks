#pragma once

// Full parity with AdobePF params layout.
// Param 0 = input.
namespace vtc {
namespace prgpu {

enum PrGPUParamID : int {
    kParam_Input = 0,

    kParam_LogTopic,
    kParam_LogEnable,
    kParam_LogLook,
    kParam_LogNext,
    kParam_LogPrev,
    kParam_LogSelected,
    kParam_LogIntensity,
    kParam_LogTopicEnd,

    kParam_CreativeTopic,
    kParam_CreativeEnable,
    kParam_CreativeLook,
    kParam_CreativeNext,
    kParam_CreativePrev,
    kParam_CreativeSelected,
    kParam_CreativeIntensity,
    kParam_CreativeTopicEnd,

    kParam_SecondaryTopic,
    kParam_SecondaryEnable,
    kParam_SecondaryLook,
    kParam_SecondaryNext,
    kParam_SecondaryPrev,
    kParam_SecondarySelected,
    kParam_SecondaryIntensity,
    kParam_SecondaryTopicEnd,

    kParam_AccentTopic,
    kParam_AccentEnable,
    kParam_AccentLook,
    kParam_AccentNext,
    kParam_AccentPrev,
    kParam_AccentSelected,
    kParam_AccentIntensity,
    kParam_AccentTopicEnd,

    kParam_Count
};

struct LayerParams {
    bool enabled = false;
    int lutIndex = -1;
    float intensity = 1.0f;
};

struct PrGPUParamsSnapshot {
    LayerParams logConvert;
    LayerParams creative;
    LayerParams secondary;
    LayerParams accent;
};

}  // namespace prgpu
}  // namespace vtc
