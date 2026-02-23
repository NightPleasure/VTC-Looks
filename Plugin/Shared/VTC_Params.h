#pragma once

#include <cstdint>

namespace vtc {

// Parameter IDs are append-only; do not reorder once shipped.
enum ParamID : int32_t {
    kParam_Input = 0,  // PF convention
    kParam_Enable,
    kParam_PrimaryCategory,
    kParam_PrimaryLook,
    kParam_PrimaryIntensity,
    kParam_Count
};

struct ParamsSnapshot {
    bool enabled = true;
    int primaryCategory = 0;   // zero-based index
    int primaryLook = 0;       // zero-based index
    float primaryIntensity = 1.0f;  // 0..1

    // Future fields kept for forward compatibility; leave defaults.
    bool secondaryEnabled = false;
    int secondaryLook = 0;
    float secondaryIntensity = 0.0f;
    bool accentEnabled = false;
    int accentLook = 0;
    float accentIntensity = 0.0f;
};

}  // namespace vtc
