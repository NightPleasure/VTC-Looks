#pragma once

// Umbrella include for Adobe PF host wrapper. Guards against accidental Premiere headers.
#if defined(PrSDKAESupport_H) || defined(PRSDKAESUPPORT_H) || defined(PRSDKAESUPPORT_HEADER)
#  error "Premiere headers must not be included in the AdobePF CPU target."
#endif

#include "AEConfig.h"
#include "AE_Effect.h"
#include "AE_EffectCB.h"
#include "AE_EffectCBSuites.h"
#include "AE_EffectPixelFormat.h"
#include "SP/SPBasic.h"
#include "Param_Utils.h"

#ifndef DllExport
#  ifdef _WIN32
#    define DllExport __declspec(dllexport)
#  else
#    define DllExport __attribute__((visibility("default")))
#  endif
#endif

// Minimal logging macro (compile-time guarded).
#ifndef VTC_DEBUG_LOG
#  define VTC_DEBUG_LOG 0
#endif

#if VTC_DEBUG_LOG
#  include <cstdio>
#  define VTC_LOG(fmt, ...) std::fprintf(stderr, "[VTC] " fmt "\n", ##__VA_ARGS__)
#else
#  define VTC_LOG(fmt, ...)
#endif
