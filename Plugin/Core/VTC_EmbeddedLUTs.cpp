#include "VTC_EmbeddedLUTs.h"

#include "../Shared/VTC_LUTData_Log.h"
#include "../Shared/VTC_LUTData_Rec709.h"

namespace vtc {

static constexpr LUT3D kLUTTable[] = {
    {kLUT_Identity_Rec709, kLUTDim_Rec709},
    {kLUT_FilmWarm_Rec709, kLUTDim_Rec709},
    {kLUT_CoolFade_Log, kLUTDim_Log},
};

const LUT3D* GetLUTById(int lutId) {
    if (lutId >= 0 && lutId < static_cast<int>(sizeof(kLUTTable) / sizeof(kLUTTable[0]))) {
        return &kLUTTable[lutId];
    }
    return nullptr;
}

}  // namespace vtc
