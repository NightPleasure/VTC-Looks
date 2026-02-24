#pragma once
#include "VTC_MetalBootstrap.h"

namespace vtc {

// Master gate: set to true to enable Metal backend selection at runtime.
// When false, SelectBackend() returns kCPU unconditionally and the compiler
// eliminates all Metal code paths via if-constexpr dead-code removal.
constexpr bool kEnableExperimentalMetal = false;

enum class RenderBackend {
    kCPU,
    kMetalGPU
};

inline RenderBackend SelectBackend() {
    if constexpr (kEnableExperimentalMetal) {
        if (metal::IsAvailable()) return RenderBackend::kMetalGPU;
    }
    return RenderBackend::kCPU;
}

// Compact descriptor for Metal compute dispatch.
// Built from CPU-side resolved layer data.
struct GPUDispatchDesc {
    static constexpr int kMaxLayers = 4;

    struct Layer {
        const float* lutData;
        int   dimension;        // LUT grid size (e.g. 33)
        float scale;            // (float)(dimension - 1)
        float intensity;        // 0..1, pre-clamped
    };

    Layer layers[kMaxLayers];
    int   layerCount     = 0;
    int   frameWidth     = 0;
    int   frameHeight    = 0;
    int   bytesPerPixel  = 0;   // 4=8bpc, 8=16bpc, 16=32bpc
};

}  // namespace vtc
