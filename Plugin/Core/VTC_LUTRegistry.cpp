#include "VTC_LUTRegistry.h"

namespace vtc {

const LUT3D* GetLogLUT(int index) {
    if (index < 0 || index >= kLogLUTCount) {
        return nullptr;
    }
    return &kLogLUTs[index];
}

const LUT3D* GetRec709LUT(int index) {
    if (index < 0 || index >= kRec709LUTCount) {
        return nullptr;
    }
    return &kRec709LUTs[index];
}

}  // namespace vtc
