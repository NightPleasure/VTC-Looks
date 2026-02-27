// VTC Looks — Premiere Pro GPU filter (M3: 4-layer LUT stack)
// Entry point: xGPUFilterEntry, loaded via MediaCore GPU extensions.

#include "VTC_PrGPU_Includes.h"
#include "VTC_ParamMap_PrGPU.h"
#include "VTC_PrGPU_Params.h"
#include "../../Shared/VTC_LUTData.h"

static size_t DivideRoundUp(size_t v, size_t m) {
    return v ? (v + m - 1) / m : 0;
}

static bool EnvFlagEnabled(const char* name) {
    const char* v = std::getenv(name);
    if (!v) return false;
    return std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 || std::strcmp(v, "TRUE") == 0;
}

static bool ForceCPUTestModeEnabled() {
    static int cached = -1;
    if (cached < 0) {
        cached = EnvFlagEnabled("VTC_FORCE_CPU_TEST") ? 1 : 0;
    }
    return cached != 0;
}

static void LogForceCPUTestOnce(const char* reason) {
    static bool logged = false;
    if (logged) return;
    if (vtc_prgpu::DiagEnabled()) {
        std::fprintf(stderr, "[VTC PrGPU] CPU TEST MODE (forced): %s\n", reason);
    }
    logged = true;
}

enum { kMaxDevices = 12 };
static id<MTLComputePipelineState> sPSO_32f[kMaxDevices] = {};
static id<MTLComputePipelineState> sPSO_16f[kMaxDevices] = {};
static id<MTLComputePipelineState> sPSO_Multi_32f[kMaxDevices] = {};
static id<MTLComputePipelineState> sPSO_Multi_16f[kMaxDevices] = {};

struct CopyParams {
    int pitch;
    int is16f;
    int width;
    int height;
};

// Multi-LUT params for Metal kernel (matches VTC_Passthrough.metal MultiLUTParams)
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

struct ResolvedLayer {
    const float* data;
    int dimension;
    float intensity;
};

struct ActiveLayers {
    ResolvedLayer layers[4];
    int count = 0;

    void tryAdd(const vtc::prgpu::LayerParams& lp, const vtc::LUT3D* table, int tableCount) {
        if (!lp.enabled || lp.lutIndex < 0 || lp.lutIndex >= tableCount || lp.intensity <= 0.0001f)
            return;
        const vtc::LUT3D& lut = table[lp.lutIndex];
        ResolvedLayer& rl = layers[count++];
        rl.data = lut.data;
        rl.dimension = lut.dimension;
        rl.intensity = (lp.intensity < 0.0f) ? 0.0f : (lp.intensity > 1.0f ? 1.0f : lp.intensity);
    }
};

class VTCPassthrough : public PrGPUFilterBase
{
public:
    prSuiteError Initialize(PrGPUFilterInstance* ioInstanceData) override
    {
        if (ForceCPUTestModeEnabled()) {
            LogForceCPUTestOnce("VTC_FORCE_CPU_TEST=1 -> refusing PrGPU init so PF CPU path is used");
            return suiteError_Fail;
        }

        VTC_PRGPU_LOG("Initialize devIdx=%u", ioInstanceData->inDeviceIndex);
        PrGPUFilterBase::Initialize(ioInstanceData);
        if (mDeviceIndex >= kMaxDevices)
            return suiteError_Fail;

        if (mDeviceInfo.outDeviceFramework == PrGPUDeviceFramework_Metal) {
            return InitMetalPipeline();
        }
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
        if (ForceCPUTestModeEnabled()) {
            LogForceCPUTestOnce("VTC_FORCE_CPU_TEST=1 -> forcing CPU fallback for this frame");
            return suiteError_Fail;
        }

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

        PrTime clipTime = inRenderParams->inClipTime;
        PrParam logEn = GetParam(vtc::prgpu::kParam_LogEnable, clipTime);
        PrParam logLook = GetParam(vtc::prgpu::kParam_LogLook, clipTime);
        PrParam logInt = GetParam(vtc::prgpu::kParam_LogIntensity, clipTime);
        PrParam crEn = GetParam(vtc::prgpu::kParam_CreativeEnable, clipTime);
        PrParam crLook = GetParam(vtc::prgpu::kParam_CreativeLook, clipTime);
        PrParam crInt = GetParam(vtc::prgpu::kParam_CreativeIntensity, clipTime);
        PrParam secEn = GetParam(vtc::prgpu::kParam_SecondaryEnable, clipTime);
        PrParam secLook = GetParam(vtc::prgpu::kParam_SecondaryLook, clipTime);
        PrParam secInt = GetParam(vtc::prgpu::kParam_SecondaryIntensity, clipTime);
        PrParam accEn = GetParam(vtc::prgpu::kParam_AccentEnable, clipTime);
        PrParam accLook = GetParam(vtc::prgpu::kParam_AccentLook, clipTime);
        PrParam accInt = GetParam(vtc::prgpu::kParam_AccentIntensity, clipTime);

        vtc::prgpu::PrGPUParamsSnapshot snap = vtc::prgpu::ReadParamsFromPrParam(
            logEn, logLook, logInt,
            crEn, crLook, crInt,
            secEn, secLook, secInt,
            accEn, accLook, accInt);

        ActiveLayers al;
        al.tryAdd(snap.logConvert, vtc::kLogLUTs, vtc::kLogLUTCount);
        al.tryAdd(snap.creative, vtc::kRec709LUTs, vtc::kRec709LUTCount);
        al.tryAdd(snap.secondary, vtc::kRec709LUTs, vtc::kRec709LUTCount);
        al.tryAdd(snap.accent, vtc::kRec709LUTs, vtc::kRec709LUTCount);

        VTC_PRGPU_LOG("Render %dx%d rb=%d pitch=%d 16f=%d layers=%d", width, height, rowBytes, pitch, is16f ? 1 : 0, al.count);

        if (width <= 0 || height <= 0 || !inData || !outData)
            return suiteError_Fail;

        if (mDeviceInfo.outDeviceFramework == PrGPUDeviceFramework_Metal) {
            return RenderMetal(inData, outData, pixFmt, width, height, pitch, is16f, al);
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
                if (sPSO_Multi_32f[inIndex]) { [sPSO_Multi_32f[inIndex] release]; sPSO_Multi_32f[inIndex] = nil; }
                if (sPSO_Multi_16f[inIndex]) { [sPSO_Multi_16f[inIndex] release]; sPSO_Multi_16f[inIndex] = nil; }
            }
        }
        return suiteError_NoError;
    }

private:
    prSuiteError InitMetalPipeline()
    {
        if (sPSO_32f[mDeviceIndex]) return suiteError_NoError;

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
                VTC_PRGPU_LOG("ERROR metallib load: %s", err ? [[err localizedDescription] UTF8String] : "?");
                return suiteError_Fail;
            }
            id<MTLFunction> fn32 = [lib newFunctionWithName:@"VTC_Passthrough_32f"];
            id<MTLFunction> fn16 = [lib newFunctionWithName:@"VTC_Passthrough_16f"];
            id<MTLFunction> fnMulti32 = [lib newFunctionWithName:@"VTC_LUTApplyMulti_32f"];
            id<MTLFunction> fnMulti16 = [lib newFunctionWithName:@"VTC_LUTApplyMulti_16f"];
            if (!fn32 || !fn16 || !fnMulti32 || !fnMulti16) {
                VTC_PRGPU_LOG("ERROR kernel function missing");
                if (fn32) [fn32 release]; if (fn16) [fn16 release]; if (fnMulti32) [fnMulti32 release]; if (fnMulti16) [fnMulti16 release]; [lib release];
                return suiteError_Fail;
            }
            sPSO_32f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fn32 error:&err];
            sPSO_16f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fn16 error:&err];
            sPSO_Multi_32f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fnMulti32 error:&err];
            sPSO_Multi_16f[mDeviceIndex] = [dev newComputePipelineStateWithFunction:fnMulti16 error:&err];
            [fn32 release]; [fn16 release]; [fnMulti32 release]; [fnMulti16 release]; [lib release];
            if (!sPSO_32f[mDeviceIndex] || !sPSO_16f[mDeviceIndex] || !sPSO_Multi_32f[mDeviceIndex] || !sPSO_Multi_16f[mDeviceIndex]) {
                VTC_PRGPU_LOG("ERROR PSO creation");
                return suiteError_Fail;
            }
            VTC_PRGPU_LOG("Pipeline OK idx=%u", mDeviceIndex);
            return suiteError_NoError;
        }
    }

    prSuiteError RenderMetal(void* inData, void* outData, PrPixelFormat pixFmt,
                             int width, int height, int pitch, bool is16f,
                             const ActiveLayers& al)
    {
        @autoreleasepool {
            id<MTLDevice> dev = (id<MTLDevice>)mDeviceInfo.outDeviceHandle;
            id<MTLCommandQueue> queue = (id<MTLCommandQueue>)mDeviceInfo.outCommandQueueHandle;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            id<MTLBuffer> inBuf = (id<MTLBuffer>)inData;
            id<MTLBuffer> outBuf = (id<MTLBuffer>)outData;

            if (al.count == 0) {
                id<MTLComputePipelineState> pso = is16f ? sPSO_16f[mDeviceIndex] : sPSO_32f[mDeviceIndex];
                CopyParams params = { pitch, is16f ? 1 : 0, width, height };
                id<MTLBuffer> paramBuf = [[dev newBufferWithBytes:&params length:sizeof(CopyParams) options:MTLResourceStorageModeShared] autorelease];
                [enc setComputePipelineState:pso];
                [enc setBuffer:inBuf offset:0 atIndex:0];
                [enc setBuffer:outBuf offset:0 atIndex:1];
                [enc setBuffer:paramBuf offset:0 atIndex:2];
                MTLSize tpg = {[pso threadExecutionWidth], 16, 1};
                MTLSize ntg = {DivideRoundUp((size_t)width, tpg.width), DivideRoundUp((size_t)height, tpg.height), 1};
                [enc dispatchThreadgroups:ntg threadsPerThreadgroup:tpg];
            } else {
                size_t lutFloatsPer = (size_t)33 * 33 * 33 * 3;
                size_t totalFloats = lutFloatsPer * (size_t)al.count;
                id<MTLBuffer> lutBuf = [dev newBufferWithLength:totalFloats * sizeof(float) options:MTLResourceStorageModeShared];
                float* dst = (float*)[lutBuf contents];
                size_t offset = 0;
                MultiLUTParams mp = {};
                mp.pitch = pitch;
                mp.width = width;
                mp.height = height;
                mp.layerCount = al.count;
                for (int i = 0; i < al.count && i < 4; ++i) {
                    size_t n = (size_t)al.layers[i].dimension * al.layers[i].dimension * al.layers[i].dimension * 3;
                    memcpy(dst + offset, al.layers[i].data, n * sizeof(float));
                    if (i == 0) { mp.layer0Offset = (int)offset; mp.layer0Dim = al.layers[i].dimension; mp.layer0Intensity = al.layers[i].intensity; }
                    else if (i == 1) { mp.layer1Offset = (int)offset; mp.layer1Dim = al.layers[i].dimension; mp.layer1Intensity = al.layers[i].intensity; }
                    else if (i == 2) { mp.layer2Offset = (int)offset; mp.layer2Dim = al.layers[i].dimension; mp.layer2Intensity = al.layers[i].intensity; }
                    else { mp.layer3Offset = (int)offset; mp.layer3Dim = al.layers[i].dimension; mp.layer3Intensity = al.layers[i].intensity; }
                    offset += n;
                }
                id<MTLBuffer> paramBuf = [[dev newBufferWithBytes:&mp length:sizeof(MultiLUTParams) options:MTLResourceStorageModeShared] autorelease];
                id<MTLComputePipelineState> pso = is16f ? sPSO_Multi_16f[mDeviceIndex] : sPSO_Multi_32f[mDeviceIndex];
                [enc setComputePipelineState:pso];
                [enc setBuffer:inBuf offset:0 atIndex:0];
                [enc setBuffer:outBuf offset:0 atIndex:1];
                [enc setBuffer:lutBuf offset:0 atIndex:2];
                [enc setBuffer:paramBuf offset:0 atIndex:3];
                MTLSize tpg = {[pso threadExecutionWidth], 16, 1};
                MTLSize ntg = {DivideRoundUp((size_t)width, tpg.width), DivideRoundUp((size_t)height, tpg.height), 1};
                [enc dispatchThreadgroups:ntg threadsPerThreadgroup:tpg];
                [lutBuf release];
            }
            [enc endEncoding];
            [cb commit];
            return suiteError_NoError;
        }
    }

    static NSString* MetallibPath()
    {
        Dl_info info{};
        if (dladdr((const void*)&MetallibPath, &info) == 0 || !info.dli_fname)
            return nil;
        NSString* exe = [NSString stringWithUTF8String:info.dli_fname];
        NSString* contents = [[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        return [contents stringByAppendingPathComponent:@"Resources/MetalLib/VTC_Passthrough.metallib"];
    }
};

DECLARE_GPUFILTER_ENTRY(PrGPUFilterModule<VTCPassthrough>)
