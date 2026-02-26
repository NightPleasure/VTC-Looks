#pragma once

// M1: minimal param IDs for PrGPU effect (Enable + Intensity)
// Param 0 = input layer, 1 = Enable, 2 = Intensity
namespace vtc {
namespace prgpu {

enum PrGPUParamID : int {
    kParam_Input     = 0,
    kParam_Enable    = 1,
    kParam_Intensity = 2,
    kParam_Count     = 3
};

struct PrGPUParamsSnapshot {
    bool  enable    = true;
    float intensity = 1.0f;
};

}  // namespace prgpu
}  // namespace vtc
