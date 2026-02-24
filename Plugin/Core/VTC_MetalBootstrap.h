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

// GPU dispatch stub. Currently returns false (not implemented).
// Phase 4: Will encode and execute Metal compute commands.
// Caller MUST fall back to CPU if this returns false.
bool TryDispatch(const GPUDispatchDesc& desc,
                 const void* srcData, void* dstData,
                 int srcRowBytes, int dstRowBytes);

}  // namespace metal
}  // namespace vtc
