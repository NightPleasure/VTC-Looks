#pragma once

namespace vtc {

enum class RenderBackend {
    kCPU,
    kMetalGPU
};

// Phase 3: Will query MTLCopyAllDevices() or similar at plugin load.
// Returns false until Metal integration is implemented.
constexpr bool IsMetalAvailable() { return false; }

// Phase 3: Will check IsMetalAvailable() + internal state.
// Returns kCPU unconditionally until GPU path is proven stable.
constexpr RenderBackend SelectBackend() { return RenderBackend::kCPU; }

// Compact descriptor for future Metal compute dispatch.
// Built from CPU-side resolved layer data. No allocations, no Metal types.
// Phase 3: lutData pointer becomes byte offset into unified MTLBuffer.
struct GPUDispatchDesc {
    static constexpr int kMaxLayers = 4;

    struct Layer {
        const float* lutData;   // Phase 3: MTLBuffer offset
        int   dimension;        // LUT grid size (e.g. 33)
        float scale;            // (float)(dimension - 1)
        float intensity;        // 0..1, pre-clamped
    };

    Layer layers[kMaxLayers];
    int   layerCount  = 0;
    int   frameWidth  = 0;
    int   frameHeight = 0;
};

}  // namespace vtc
