// VTC Looks — Premiere Pro GPU filter (M0: passthrough)
// Entry point: xGPUFilterEntry, loaded via MediaCore GPU extensions.
// Uses PrGPUFilterModule helper from Premiere SDK.

#include "VTC_PrGPU_Includes.h"
#include <OpenCL/cl.h>

static size_t DivideRoundUp(size_t v, size_t m) {
    return v ? (v + m - 1) / m : 0;
}

enum { kMaxDevices = 12 };
static id<MTLComputePipelineState> sPSO_32f[kMaxDevices] = {};
static id<MTLComputePipelineState> sPSO_16f[kMaxDevices] = {};

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

        VTC_PRGPU_LOG("Render %dx%d rb=%d pitch=%d 16f=%d", width, height, rowBytes, pitch, is16f ? 1 : 0);

        if (width <= 0 || height <= 0 || !inData || !outData)
            return suiteError_Fail;

        if (mDeviceInfo.outDeviceFramework == PrGPUDeviceFramework_Metal) {
            return RenderMetal(inData, outData, pixFmt, width, height, pitch, is16f);
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
            if (!fn32 || !fn16) {
                VTC_PRGPU_LOG("ERROR kernel function missing");
                if (fn32) [fn32 release]; if (fn16) [fn16 release]; [lib release];
                return suiteError_Fail;
            }

            sPSO_32f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fn32 error:&err];
            sPSO_16f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fn16 error:&err];
            [fn32 release]; [fn16 release]; [lib release];

            if (!sPSO_32f[mDeviceIndex] || !sPSO_16f[mDeviceIndex]) {
                VTC_PRGPU_LOG("ERROR PSO creation");
                return suiteError_Fail;
            }
            VTC_PRGPU_LOG("Pipeline OK idx=%u", mDeviceIndex);
            return suiteError_NoError;
        }
    }

    prSuiteError RenderMetal(void* inData, void* outData,
                             PrPixelFormat pixFmt,
                             int width, int height, int pitch, bool is16f)
    {
        @autoreleasepool {
            id<MTLDevice> dev = (id<MTLDevice>)mDeviceInfo.outDeviceHandle;
            id<MTLComputePipelineState> pso = is16f ? sPSO_16f[mDeviceIndex]
                                                    : sPSO_32f[mDeviceIndex];
            if (!pso) return suiteError_Fail;

            CopyParams params = { pitch, is16f ? 1 : 0, width, height };
            id<MTLBuffer> paramBuf = [[dev newBufferWithBytes:&params
                                                       length:sizeof(CopyParams)
                                                      options:MTLResourceStorageModeManaged] autorelease];

            id<MTLCommandQueue> queue = (id<MTLCommandQueue>)mDeviceInfo.outCommandQueueHandle;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];

            id<MTLBuffer> inBuf  = (id<MTLBuffer>)inData;
            id<MTLBuffer> outBuf = (id<MTLBuffer>)outData;

            [enc setComputePipelineState:pso];
            [enc setBuffer:inBuf   offset:0 atIndex:0];
            [enc setBuffer:outBuf  offset:0 atIndex:1];
            [enc setBuffer:paramBuf offset:0 atIndex:2];

            MTLSize tpg = {[pso threadExecutionWidth], 16, 1};
            MTLSize ntg = {DivideRoundUp(width, tpg.width),
                           DivideRoundUp(height, tpg.height), 1};
            [enc dispatchThreadgroups:ntg threadsPerThreadgroup:tpg];
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
