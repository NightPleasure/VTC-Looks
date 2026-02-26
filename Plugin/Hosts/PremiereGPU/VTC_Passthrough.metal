#include <metal_stdlib>
using namespace metal;

struct CopyParams {
    int pitch;   // rowBytes / bytesPerPixel
    int is16f;   // 1 = half4, 0 = float4
    int width;
    int height;
};

kernel void VTC_Passthrough_32f(
    device const float4* inBuf  [[buffer(0)]],
    device       float4* outBuf [[buffer(1)]],
    constant CopyParams& params [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) return;
    uint idx = gid.y * uint(params.pitch) + gid.x;
    outBuf[idx] = inBuf[idx];
}

kernel void VTC_Passthrough_16f(
    device const half4* inBuf  [[buffer(0)]],
    device       half4* outBuf [[buffer(1)]],
    constant CopyParams& params [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) return;
    uint idx = gid.y * uint(params.pitch) + gid.x;
    outBuf[idx] = inBuf[idx];
}
