#pragma once

#include "../Shared/VTC_Params.h"

namespace vtc {
namespace opencl {

// Windows OFX OpenCL native path stub/entrypoint.
// src/dst are host cl_mem handles and cmdQueue is cl_command_queue.
bool TryDispatchNative(const ParamsSnapshot& params,
                       void* srcMem,
                       void* dstMem,
                       void* cmdQueue,
                       int width,
                       int height);

}  // namespace opencl
}  // namespace vtc

