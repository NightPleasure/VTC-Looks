#pragma once

namespace vtc {

struct GPUDispatchDesc;

namespace metal {

// One-shot Metal device + command queue initialization.
// Thread-safe (dispatch_once). No-op after first call.
bool InitContext();

// Returns true if Metal device and queue were created successfully.
// Triggers InitContext() on first call.
bool IsAvailable();

// GPU compute dispatch.
// Supported: 8bpc 1..4 layers, 16bpc 1..4 layers, 32bpc 1..4 layers.
// Returns true only if GPU successfully rendered the frame.
// Returns false on any failure -- caller MUST fall back to CPU.
bool TryDispatch(const GPUDispatchDesc& desc,
                 const void* srcData, void* dstData,
                 int srcRowBytes, int dstRowBytes);

}  // namespace metal
}  // namespace vtc
