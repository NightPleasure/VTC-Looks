#include "VTC_CudaBootstrap.h"

namespace vtc {
namespace cuda {

bool TryDispatchNative(const ParamsSnapshot&,
                       void*,
                       void*,
                       void*,
                       int,
                       int) {
    // TODO(M8): implement CUDA kernel path on Windows (optional).
    return false;
}

}  // namespace cuda
}  // namespace vtc

