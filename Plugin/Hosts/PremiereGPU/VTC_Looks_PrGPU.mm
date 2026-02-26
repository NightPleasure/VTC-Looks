// VTC Looks — Premiere Pro GPU filter (M0: passthrough)
// Entry point: xGPUFilterEntry, loaded via MediaCore GPU extensions.
// Uses PrGPUFilterModule helper from Premiere SDK.

#include "VTC_PrGPU_Includes.h"
#include "VTC_ParamMap_PrGPU.h"
#include "VTC_PrGPU_Params.h"
#include "../../Shared/VTC_LUTData.h"
#include <OpenCL/cl.h>

static size_t DivideRoundUp(size_t v, size_t m) {
    return v ? (v + m - 1) / m : 0;
}

enum { kMaxDevices = 12 };
static id<MTLComputePipelineState> sPSO_32f[kMaxDevices] = {};
static id<MTLComputePipelineState> sPSO_16f[kMaxDevices] = {};
static id<MTLComputePipelineState> sPSO_LUT_32f[kMaxDevices] = {};
static id<MTLComputePipelineState> sPSO_LUT_16f[kMaxDevices] = {};
static id<MTLBuffer> sLUTBuffer[kMaxDevices] = {};

struct CopyParams {
    int pitch;
    int is16f;
    int width;
    int height;
};

// GPU filter class following SDK ProcAmp pattern
class VTCPassthrough : public PrGPUFilterBase
{
public:
    prSuiteError Initialize(PrGPUFilterInstance* ioInstanceData) override
    {
        VTC_PRGPU_LOG("Initialize devIdx=%u", ioInstanceData->inDeviceIndex);
        PrGPUFilterBase::Initialize(ioInstanceData);
        if (mDeviceIndex >= kMaxDevices)
            return suiteError_Fail;

        if (mDeviceInfo.outDeviceFramework == PrGPUDeviceFramework_Metal) {
            return InitMetalPipeline();
        }
        // No OpenCL/DX support for now
        return suiteError_Fail;
    }

    prSuiteError GetFrameDependencies(
        const PrGPUFilterRenderParams* inRenderParams,
        csSDK_int32* ioQueryIndex,
        PrGPUFilterFrameDependency* outDeps) override
    {
        if (*ioQueryIndex > 0)
            return suiteError_NoError;
        outDeps->outDependencyType = PrGPUDependency_InputFrame;
        outDeps->outTrackID = 0;
        outDeps->outSequenceTime = inRenderParams->inSequenceTime;
        outDeps->outNeedsFieldSeparation = kPrFalse;
        ++(*ioQueryIndex);
        return suiteError_NoError;
    }

    prSuiteError Render(
        const PrGPUFilterRenderParams* inRenderParams,
        const PPixHand* inFrames,
        csSDK_size_t inFrameCount,
        PPixHand* outFrame) override
    {
        if (!inFrames || inFrameCount < 1 || !outFrame)
            return suiteError_Fail;

        void* outData = nullptr;
        mGPUDeviceSuite->GetGPUPPixData(*outFrame, &outData);

        void* inData = nullptr;
        mGPUDeviceSuite->GetGPUPPixData(inFrames[0], &inData);

        PrPixelFormat pixFmt = PrPixelFormat_Invalid;
        mPPixSuite->GetPixelFormat(*outFrame, &pixFmt);

        prRect bounds{};
        mPPixSuite->GetBounds(*outFrame, &bounds);
        int width  = bounds.right - bounds.left;
        int height = bounds.bottom - bounds.top;

        csSDK_int32 rowBytes = 0;
        mPPixSuite->GetRowBytes(*outFrame, &rowBytes);
        int bpp = GetGPUBytesPerPixel(pixFmt);
        int pitch = rowBytes / bpp;
        bool is16f = (pixFmt == PrPixelFormat_GPU_BGRA_4444_16f);

        // M1: read params, gate passthrough
        PrTime seqTime = inRenderParams->inSequenceTime;
        PrParam enableP = GetParam(vtc::prgpu::kParam_Enable, seqTime);
        PrParam intenP = GetParam(vtc::prgpu::kParam_Intensity, seqTime);
        vtc::prgpu::PrGPUParamsSnapshot snap = vtc::prgpu::ReadParamsFromPrParam(enableP, intenP);
        if (!snap.enable || snap.intensity <= 0.0f) {
            VTC_PRGPU_LOG("Render: bypass (Enable=%d Intensity=%.2f)", snap.enable ? 1 : 0, snap.intensity);
        } else {
            VTC_PRGPU_LOG("Render: Apply Enable=%d Intensity=%.2f (LUT 32f or passthrough)", snap.enable ? 1 : 0, snap.intensity);
        }

        VTC_PRGPU_LOG("Render %dx%d rb=%d pitch=%d 16f=%d", width, height, rowBytes, pitch, is16f ? 1 : 0);

        if (width <= 0 || height <= 0 || !inData || !outData)
            return suiteError_Fail;

        if (mDeviceInfo.outDeviceFramework == PrGPUDeviceFramework_Metal) {
            return RenderMetal(inData, outData, pixFmt, width, height, pitch, is16f, snap);
        }
        return suiteError_Fail;
    }

    static prSuiteError Shutdown(piSuitesPtr, csSDK_int32 inIndex)
    {
        VTC_PRGPU_LOG("Shutdown idx=%d", inIndex);
        @autoreleasepool {
            if (inIndex < kMaxDevices) {
                if (sPSO_32f[inIndex]) { [sPSO_32f[inIndex] release]; sPSO_32f[inIndex] = nil; }
                if (sPSO_16f[inIndex]) { [sPSO_16f[inIndex] release]; sPSO_16f[inIndex] = nil; }
                if (sPSO_LUT_32f[inIndex]) { [sPSO_LUT_32f[inIndex] release]; sPSO_LUT_32f[inIndex] = nil; }
                if (sPSO_LUT_16f[inIndex]) { [sPSO_LUT_16f[inIndex] release]; sPSO_LUT_16f[inIndex] = nil; }
                if (sLUTBuffer[inIndex]) { [sLUTBuffer[inIndex] release]; sLUTBuffer[inIndex] = nil; }
            }
        }
        return suiteError_NoError;
    }

private:
    prSuiteError InitMetalPipeline()
    {
        if (sPSO_32f[mDeviceIndex]) return suiteError_NoError; // already built

        @autoreleasepool {
            id<MTLDevice> dev = (id<MTLDevice>)mDeviceInfo.outDeviceHandle;
            NSString* path = MetallibPath();
            if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                VTC_PRGPU_LOG("ERROR metallib not found");
                return suiteError_Fail;
            }

            NSError* err = nil;
            id<MTLLibrary> lib = [dev newLibraryWithFile:path error:&err];
            if (!lib) {
                VTC_PRGPU_LOG("ERROR metallib load: %s",
                              err ? [[err localizedDescription] UTF8String] : "?");
                return suiteError_Fail;
            }

            id<MTLFunction> fn32 = [lib newFunctionWithName:@"VTC_Passthrough_32f"];
            id<MTLFunction> fn16 = [lib newFunctionWithName:@"VTC_Passthrough_16f"];
            id<MTLFunction> fnLUT = [lib newFunctionWithName:@"VTC_LUTApply_32f"];
            id<MTLFunction> fnLUT16 = [lib newFunctionWithName:@"VTC_LUTApply_16f"];
            if (!fn32 || !fn16 || !fnLUT || !fnLUT16) {
                VTC_PRGPU_LOG("ERROR kernel function missing");
                if (fn32) [fn32 release]; if (fn16) [fn16 release]; if (fnLUT) [fnLUT release]; if (fnLUT16) [fnLUT16 release]; [lib release];
                return suiteError_Fail;
            }

            sPSO_32f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fn32 error:&err];
            sPSO_16f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fn16 error:&err];
            sPSO_LUT_32f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fnLUT error:&err];
            sPSO_LUT_16f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fnLUT16 error:&err];
            [fn32 release]; [fn16 release]; [fnLUT release]; [fnLUT16 release]; [lib release];

            if (!sPSO_32f[mDeviceIndex] || !sPSO_16f[mDeviceIndex] || !sPSO_LUT_32f[mDeviceIndex] || !sPSO_LUT_16f[mDeviceIndex]) {
                VTC_PRGPU_LOG("ERROR PSO creation");
                return suiteError_Fail;
            }
            const vtc::LUT3D& lut = vtc::kRec709LUTs[0];
            size_t lutBytes = (size_t)lut.dimension * lut.dimension * lut.dimension * 3 * sizeof(float);
            sLUTBuffer[mDeviceIndex] = [dev newBufferWithBytes:lut.data length:lutBytes options:MTLResourceStorageModeShared];
            if (!sLUTBuffer[mDeviceIndex]) { VTC_PRGPU_LOG("ERROR LUT buffer"); return suiteError_Fail; }
            if (vtc_prgpu::DebugEnabled()) VTC_PRGPU_LOG("LUT cache: id=0 size=%zu kRec709LUTs[0]", lutBytes);
            VTC_PRGPU_LOG("Pipeline OK idx=%u", mDeviceIndex);
            return suiteError_NoError;
        }
    }

    prSuiteError RenderMetal(void* inData, void* outData,
                             PrPixelFormat pixFmt,
                             int width, int height, int pitch, bool is16f,
                             const vtc::prgpu::PrGPUParamsSnapshot& snap)
    {
        @autoreleasepool {
            id<MTLDevice> dev = (id<MTLDevice>)mDeviceInfo.outDeviceHandle;
            id<MTLCommandQueue> queue = (id<MTLCommandQueue>)mDeviceInfo.outCommandQueueHandle;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            id<MTLBuffer> inBuf = (id<MTLBuffer>)inData;
            id<MTLBuffer> outBuf = (id<MTLBuffer>)outData;

            bool useLUT32 = snap.enable && snap.intensity > 0.0f && !is16f && sPSO_LUT_32f[mDeviceIndex] && sLUTBuffer[mDeviceIndex];
            bool useLUT16 = snap.enable && snap.intensity > 0.0f && is16f && sPSO_LUT_16f[mDeviceIndex] && sLUTBuffer[mDeviceIndex];
            if (useLUT32) {
                struct { int pitch; int width; int height; float intensity; } lutParams = { pitch, width, height, snap.intensity };
                id<MTLBuffer> lutParamBuf = [[dev newBufferWithBytes:&lutParams length:sizeof(lutParams) options:MTLResourceStorageModeShared] autorelease];
                [enc setComputePipelineState:sPSO_LUT_32f[mDeviceIndex]];
                [enc setBuffer:inBuf offset:0 atIndex:0];
                [enc setBuffer:outBuf offset:0 atIndex:1];
                [enc setBuffer:sLUTBuffer[mDeviceIndex] offset:0 atIndex:2];
                [enc setBuffer:lutParamBuf offset:0 atIndex:3];
                MTLSize tpg = {[sPSO_LUT_32f[mDeviceIndex] threadExecutionWidth], 16, 1};
                MTLSize ntg = {DivideRoundUp((size_t)width, tpg.width), DivideRoundUp((size_t)height, tpg.height), 1};
                [enc dispatchThreadgroups:ntg threadsPerThreadgroup:tpg];
            } else if (useLUT16) {
                struct { int pitch; int width; int height; float intensity; } lutParams = { pitch, width, height, snap.intensity };
                id<MTLBuffer> lutParamBuf = [[dev newBufferWithBytes:&lutParams length:sizeof(lutParams) options:MTLResourceStorageModeShared] autorelease];
                [enc setComputePipelineState:sPSO_LUT_16f[mDeviceIndex]];
                [enc setBuffer:inBuf offset:0 atIndex:0];
                [enc setBuffer:outBuf offset:0 atIndex:1];
                [enc setBuffer:sLUTBuffer[mDeviceIndex] offset:0 atIndex:2];
                [enc setBuffer:lutParamBuf offset:0 atIndex:3];
                MTLSize tpg = {[sPSO_LUT_16f[mDeviceIndex] threadExecutionWidth], 16, 1};
                MTLSize ntg = {DivideRoundUp((size_t)width, tpg.width), DivideRoundUp((size_t)height, tpg.height), 1};
                [enc dispatchThreadgroups:ntg threadsPerThreadgroup:tpg];
            } else {
                id<MTLComputePipelineState> pso = is16f ? sPSO_16f[mDeviceIndex] : sPSO_32f[mDeviceIndex];
                if (!pso) return suiteError_Fail;
                CopyParams params = { pitch, is16f ? 1 : 0, width, height };
                id<MTLBuffer> paramBuf = [[dev newBufferWithBytes:&params length:sizeof(CopyParams) options:MTLResourceStorageModeManaged] autorelease];
                [enc setComputePipelineState:pso];
                [enc setBuffer:inBuf offset:0 atIndex:0];
                [enc setBuffer:outBuf offset:0 atIndex:1];
                [enc setBuffer:paramBuf offset:0 atIndex:2];
                MTLSize tpg = {[pso threadExecutionWidth], 16, 1};
                MTLSize ntg = {DivideRoundUp((size_t)width, tpg.width), DivideRoundUp((size_t)height, tpg.height), 1};
                [enc dispatchThreadgroups:ntg threadsPerThreadgroup:tpg];
            }
            [enc endEncoding];
            [cb commit];
            return suiteError_NoError;
        }
    }

    static NSString* MetallibPath()
    {
        // metallib lives next to the Mach-O binary in Resources/MetalLib/
        Dl_info info{};
        if (dladdr((const void*)&MetallibPath, &info) == 0 || !info.dli_fname)
            return nil;
        NSString* exe = [NSString stringWithUTF8String:info.dli_fname];
        NSString* contents = [[exe stringByDeletingLastPathComponent]
                              stringByDeletingLastPathComponent];
        return [contents stringByAppendingPathComponent:
                @"Resources/MetalLib/VTC_Passthrough.metallib"];
    }
};


DECLARE_GPUFILTER_ENTRY(PrGPUFilterModule<VTCPassthrough>)
