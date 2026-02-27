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


// M2: LUT apply (32f only). Input/output BGRA. Trilinear sample + intensity blend.
struct LUTParams {
    int pitch;
    int width;
    int height;
    float intensity;
};

inline float3 sampleLUT3D(device const float* lut, int dim, float r, float g, float b) {
    float scale = float(dim - 1);
    r = clamp(r, 0.0f, 1.0f) * scale;
    g = clamp(g, 0.0f, 1.0f) * scale;
    b = clamp(b, 0.0f, 1.0f) * scale;
    int x0 = int(r), y0 = int(g), z0 = int(b);
    int x1 = min(x0 + 1, dim - 1), y1 = min(y0 + 1, dim - 1), z1 = min(z0 + 1, dim - 1);
    float fx = r - x0, fy = g - y0, fz = b - z0;
    int dim2 = dim * dim;
    int i000 = (z0*dim2 + y0*dim + x0) * 3, i100 = (z0*dim2 + y0*dim + x1) * 3;
    int i010 = (z0*dim2 + y1*dim + x0) * 3, i110 = (z0*dim2 + y1*dim + x1) * 3;
    int i001 = (z1*dim2 + y0*dim + x0) * 3, i101 = (z1*dim2 + y0*dim + x1) * 3;
    int i011 = (z1*dim2 + y1*dim + x0) * 3, i111 = (z1*dim2 + y1*dim + x1) * 3;
    float3 c000 = float3(lut[i000], lut[i000+1], lut[i000+2]);
    float3 c100 = float3(lut[i100], lut[i100+1], lut[i100+2]);
    float3 c010 = float3(lut[i010], lut[i010+1], lut[i010+2]);
    float3 c110 = float3(lut[i110], lut[i110+1], lut[i110+2]);
    float3 c001 = float3(lut[i001], lut[i001+1], lut[i001+2]);
    float3 c101 = float3(lut[i101], lut[i101+1], lut[i101+2]);
    float3 c011 = float3(lut[i011], lut[i011+1], lut[i011+2]);
    float3 c111 = float3(lut[i111], lut[i111+1], lut[i111+2]);
    float3 c00 = mix(c000, c100, fx), c10 = mix(c010, c110, fx);
    float3 c01 = mix(c001, c101, fx), c11 = mix(c011, c111, fx);
    float3 c0 = mix(c00, c10, fy), c1 = mix(c01, c11, fy);
    return mix(c0, c1, fz);
}

kernel void VTC_LUTApply_32f(
    device const float4* inBuf  [[buffer(0)]],
    device       float4* outBuf [[buffer(1)]],
    device const float*  lutBuf [[buffer(2)]],
    constant LUTParams&  params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) return;
    uint idx = gid.y * uint(params.pitch) + gid.x;
    float4 inColor = inBuf[idx];
    float r = inColor.z, g = inColor.y, b = inColor.x;
    float3 lutRGB = sampleLUT3D(lutBuf, 33, r, g, b);
    float3 outRGB = mix(float3(r,g,b), lutRGB, params.intensity);
    outBuf[idx] = float4(outRGB.z, outRGB.y, outRGB.x, inColor.w);
}

// M2b: LUT apply (16f). Input/output half4 BGRA. Same logic as 32f with half<->float conversion.
kernel void VTC_LUTApply_16f(
    device const half4*  inBuf  [[buffer(0)]],
    device       half4*  outBuf [[buffer(1)]],
    device const float*  lutBuf [[buffer(2)]],
    constant LUTParams&  params [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(params.width) || gid.y >= uint(params.height)) return;
    uint idx = gid.y * uint(params.pitch) + gid.x;
    half4 inColor = inBuf[idx];
    float r = float(inColor.z), g = float(inColor.y), b = float(inColor.x);
    float3 lutRGB = sampleLUT3D(lutBuf, 33, r, g, b);
    float3 outRGB = mix(float3(r,g,b), lutRGB, params.intensity);
    outBuf[idx] = half4(half(outRGB.z), half(outRGB.y), half(outRGB.x), inColor.w);
}
// M3: 4-layer cascade. LUT buffer has layers concatenated (each 33^3*3 floats).
// Params: pitch, width, height, layerCount, then per-layer: offset (in floats), dimension, intensity (pad).
struct MultiLUTParams {
    int pitch;
    int width;
    int height;
    int layerCount;
    int layer0Offset;
    int layer0Dim;
    float layer0Intensity;
    int layer1Offset;
    int layer1Dim;
    float layer1Intensity;
    int layer2Offset;
    int layer2Dim;
    float layer2Intensity;
    int layer3Offset;
    int layer3Dim;
    float layer3Intensity;
};

kernel void VTC_LUTApplyMulti_32f(
    device const float4* inBuf   [[buffer(0)]],
    device       float4* outBuf  [[buffer(1)]],
    device const float*  lutBuf  [[buffer(2)]],
    constant MultiLUTParams& p   [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.width) || gid.y >= uint(p.height)) return;
    uint idx = gid.y * uint(p.pitch) + gid.x;
    float4 c = inBuf[idx];
    float r = c.z, g = c.y, b = c.x;
    if (p.layerCount >= 1 && p.layer0Dim > 0) {
        float3 lutRGB = sampleLUT3D(lutBuf + p.layer0Offset, p.layer0Dim, r, g, b);
        r = mix(r, lutRGB.x, p.layer0Intensity); g = mix(g, lutRGB.y, p.layer0Intensity); b = mix(b, lutRGB.z, p.layer0Intensity);
    }
    if (p.layerCount >= 2 && p.layer1Dim > 0) {
        float3 lutRGB = sampleLUT3D(lutBuf + p.layer1Offset, p.layer1Dim, r, g, b);
        r = mix(r, lutRGB.x, p.layer1Intensity); g = mix(g, lutRGB.y, p.layer1Intensity); b = mix(b, lutRGB.z, p.layer1Intensity);
    }
    if (p.layerCount >= 3 && p.layer2Dim > 0) {
        float3 lutRGB = sampleLUT3D(lutBuf + p.layer2Offset, p.layer2Dim, r, g, b);
        r = mix(r, lutRGB.x, p.layer2Intensity); g = mix(g, lutRGB.y, p.layer2Intensity); b = mix(b, lutRGB.z, p.layer2Intensity);
    }
    if (p.layerCount >= 4 && p.layer3Dim > 0) {
        float3 lutRGB = sampleLUT3D(lutBuf + p.layer3Offset, p.layer3Dim, r, g, b);
        r = mix(r, lutRGB.x, p.layer3Intensity); g = mix(g, lutRGB.y, p.layer3Intensity); b = mix(b, lutRGB.z, p.layer3Intensity);
    }
    outBuf[idx] = float4(b, g, r, c.w);
}

kernel void VTC_LUTApplyMulti_16f(
    device const half4*  inBuf   [[buffer(0)]],
    device       half4*  outBuf  [[buffer(1)]],
    device const float*  lutBuf  [[buffer(2)]],
    constant MultiLUTParams& p   [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.width) || gid.y >= uint(p.height)) return;
    uint idx = gid.y * uint(p.pitch) + gid.x;
    half4 inC = inBuf[idx];
    float r = float(inC.z), g = float(inC.y), b = float(inC.x);
    if (p.layerCount >= 1 && p.layer0Dim > 0) {
        float3 lutRGB = sampleLUT3D(lutBuf + p.layer0Offset, p.layer0Dim, r, g, b);
        r = mix(r, lutRGB.x, p.layer0Intensity); g = mix(g, lutRGB.y, p.layer0Intensity); b = mix(b, lutRGB.z, p.layer0Intensity);
    }
    if (p.layerCount >= 2 && p.layer1Dim > 0) {
        float3 lutRGB = sampleLUT3D(lutBuf + p.layer1Offset, p.layer1Dim, r, g, b);
        r = mix(r, lutRGB.x, p.layer1Intensity); g = mix(g, lutRGB.y, p.layer1Intensity); b = mix(b, lutRGB.z, p.layer1Intensity);
    }
    if (p.layerCount >= 3 && p.layer2Dim > 0) {
        float3 lutRGB = sampleLUT3D(lutBuf + p.layer2Offset, p.layer2Dim, r, g, b);
        r = mix(r, lutRGB.x, p.layer2Intensity); g = mix(g, lutRGB.y, p.layer2Intensity); b = mix(b, lutRGB.z, p.layer2Intensity);
    }
    if (p.layerCount >= 4 && p.layer3Dim > 0) {
        float3 lutRGB = sampleLUT3D(lutBuf + p.layer3Offset, p.layer3Dim, r, g, b);
        r = mix(r, lutRGB.x, p.layer3Intensity); g = mix(g, lutRGB.y, p.layer3Intensity); b = mix(b, lutRGB.z, p.layer3Intensity);
    }
    outBuf[idx] = half4(half(b), half(g), half(r), inC.w);
}

