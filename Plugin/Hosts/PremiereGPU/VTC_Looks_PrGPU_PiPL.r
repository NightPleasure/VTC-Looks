#ifndef AE_OS_WIN
    #include "AE_General.r"
#endif

resource 'PiPL' (16000) {
    {
        Kind { AEEffect },
        Name { "VTC Looks" },
        Category { "VTC Works" },
        CodeMacARM64 {"EffectMain"},
        AE_PiPL_Version { 2, 0 },
        AE_Effect_Spec_Version { 13, 29 },
        AE_Effect_Version { 524288 },
        AE_Effect_Info_Flags { 0 },
        AE_Effect_Global_OutFlags { 100663296 },
        AE_Effect_Global_OutFlags_2 { 134222856 },
        AE_Effect_Match_Name { "com.vtclooks.cpu" },
        AE_Reserved_Info { 0 },
        AE_Effect_Support_URL { "https://vtclooks.example" }
    }
};
