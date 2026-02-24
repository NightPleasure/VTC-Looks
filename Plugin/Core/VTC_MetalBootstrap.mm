#import <Metal/Metal.h>
#include "VTC_RenderBackend.h"
#include <dispatch/dispatch.h>

namespace vtc {
namespace metal {

namespace {
    id<MTLDevice>       g_device    = nil;
    id<MTLCommandQueue> g_queue     = nil;
    bool                g_available = false;
    dispatch_once_t     g_once;
}

bool InitContext() {
    dispatch_once(&g_once, ^{
        g_device = MTLCreateSystemDefaultDevice();
        if (g_device) {
            g_queue = [g_device newCommandQueue];
            g_available = (g_queue != nil);
        }
    });
    return g_available;
}

bool IsAvailable() {
    InitContext();
    return g_available;
}

bool TryDispatch(const GPUDispatchDesc& desc,
                 const void* srcData, void* dstData,
                 int srcRowBytes, int dstRowBytes) {
    (void)desc; (void)srcData; (void)dstData;
    (void)srcRowBytes; (void)dstRowBytes;
    // Phase 4: Create MTLBuffer from LUT data, encode compute shader,
    // copy src into input buffer, dispatch, read back into dst.
    return false;
}

}  // namespace metal
}  // namespace vtc
