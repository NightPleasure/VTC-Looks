#pragma once

// PrGPUFilterModule.h references PF_TransitionSuite but we don't use transitions.
// Provide a minimal stub to satisfy the compiler.
struct PF_TransitionSuite { void* unused; };
#define kPFTransitionSuite    "PF Transition Suite"
#define kPFTransitionSuiteVersion 1

#include "PrSDKGPUFilter.h"
#include "PrSDKGPUDeviceSuite.h"
#include "PrSDKMemoryManagerSuite.h"
#include "PrSDKPixelFormat.h"
#include "PrSDKPPixSuite.h"
#include "PrSDKPPix2Suite.h"
#include "PrSDKVideoSegmentSuite.h"
#include "PrSDKStringSuite.h"
#include "PrGPUFilterModule.h"

#import <Metal/Metal.h>

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <dlfcn.h>

namespace vtc_prgpu {

inline bool DiagEnabled() {
    static int s_cached = -1;
    if (s_cached < 0) {
        const char* v = std::getenv("VTC_PRGPU_DIAG");
        s_cached = (v && v[0] == '1') ? 1 : 0;
    }
    return s_cached != 0;
}

} // namespace vtc_prgpu

#define VTC_PRGPU_LOG(fmt, ...) \
    do { if (vtc_prgpu::DiagEnabled()) std::fprintf(stderr, "[VTC PrGPU] " fmt "\n", ##__VA_ARGS__); } while (0)
