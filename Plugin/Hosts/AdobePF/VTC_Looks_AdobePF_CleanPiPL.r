#include "AEConfig.h"
#include "AE_EffectVers.h"
#ifndef AE_OS_WIN
    #include "AE_General.r"
#endif

#define VTC_OUTFLAGS   33555522 /* DEEP_COLOR_AWARE | PIX_INDEPENDENT | USE_OUTPUT_EXTENT | WIDE_TIME_INPUT */
#define VTC_OUTFLAGS_2 4096     /* FLOAT_COLOR_AWARE */

resource 'PiPL' (16000) {
    {
        Kind { AEEffect },
        Name { "VTC Looks" },
        Category { "VTC" },
#ifdef AE_OS_WIN
    #if defined(AE_PROC_INTELx64)
        CodeWin64X86 {"EffectMain"},
    #elif defined(AE_PROC_ARM64)
        CodeWinARM64 {"EffectMain"},
    #endif
#elif defined(AE_OS_MAC)
        CodeMacIntel64 {"EffectMain"},
        CodeMacARM64 {"EffectMain"},
#endif
        AE_PiPL_Version { 2, 0 },
        AE_Effect_Spec_Version { PF_PLUG_IN_VERSION, PF_PLUG_IN_SUBVERS },
        AE_Effect_Version { 1 },
        AE_Effect_Info_Flags { 0 },
        AE_Effect_Global_OutFlags { VTC_OUTFLAGS },
        AE_Effect_Global_OutFlags_2 { VTC_OUTFLAGS_2 },
        AE_Effect_Match_Name { "com.vtclooks.cpu" },
        AE_Reserved_Info { 0 },
        AE_Effect_Support_URL { "https://vtclooks.example" }
    }
};
