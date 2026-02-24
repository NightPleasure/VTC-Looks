#pragma once

// Umbrella include for Adobe PF host wrapper. Guards against accidental Premiere headers.
#ifdef __has_include
#  if __has_include("PrSDKAESupport.h")
#    warning "Premiere headers detected in AdobePF target; ensure search paths exclude Premiere SDK."
#  endif
#endif

#include "AEConfig.h"
#include "AE_Effect.h"
#include "AE_EffectCB.h"
#include "AE_EffectPixelFormat.h"
#include "Param_Utils.h"
#include "AE_Macros.h"
#include "Smart_Utils.h"

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
