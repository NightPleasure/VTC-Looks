#include "VTC_OpenCLBootstrap.h"

namespace vtc {
namespace opencl {

bool TryDispatchNative(const ParamsSnapshot&,
                       void*,
                       void*,
                       void*,
                       int,
                       int) {
    // TODO(M8): implement OpenCL kernel path on Windows.
    return false;
}

}  // namespace opencl
}  // namespace vtc

