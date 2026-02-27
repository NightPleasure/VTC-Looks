#pragma once

#include "../Shared/VTC_Params.h"

namespace vtc {
namespace cuda {

// Windows OFX CUDA native path stub/entrypoint.
// src/dst are host CUDA memory handles and stream is cudaStream_t.
bool TryDispatchNative(const ParamsSnapshot& params,
                       void* srcMem,
                       void* dstMem,
                       void* stream,
                       int width,
                       int height);

}  // namespace cuda
}  // namespace vtc

