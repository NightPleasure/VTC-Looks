#pragma once

#include <cstddef>
#include "VTC_Params.h"

namespace vtc {

enum LUTId : int {
    kLUT_Identity = 0,
    kLUT_FilmWarm,
    kLUT_CoolFade,
    kLUT_Count
};

struct LookEntry {
    int lutId;
    const char* name;
    int categoryIndex;  // zero-based
};

struct CategoryEntry {
    const char* name;
};

constexpr CategoryEntry kLookCategories[] = {
    {"Base"},
};
constexpr int kLookCategoryCount = static_cast<int>(sizeof(kLookCategories) / sizeof(kLookCategories[0]));

constexpr LookEntry kLookEntries[] = {
    {kLUT_Identity, "Identity", 0},
    {kLUT_FilmWarm, "Film Warm", 0},
    {kLUT_CoolFade, "Cool Fade", 0},
};
constexpr int kLookEntryCount = static_cast<int>(sizeof(kLookEntries) / sizeof(kLookEntries[0]));

inline const CategoryEntry& GetCategory(int idx) {
    static const CategoryEntry kFallback{"Base"};
    return (idx >= 0 && idx < kLookCategoryCount) ? kLookCategories[idx] : kFallback;
}

inline const LookEntry& GetLook(int categoryIndex, int lookIndex) {
    // Return the Nth look within the chosen category; fallback to identity.
    int count = 0;
    for (int i = 0; i < kLookEntryCount; ++i) {
        if (kLookEntries[i].categoryIndex == categoryIndex) {
            if (count == lookIndex) {
                return kLookEntries[i];
            }
            ++count;
        }
    }
    // Fallback to first look of category or identity.
    for (int i = 0; i < kLookEntryCount; ++i) {
        if (kLookEntries[i].categoryIndex == categoryIndex) {
            return kLookEntries[i];
        }
    }
    return kLookEntries[0];
}

inline int LookCountForCategory(int categoryIndex) {
    int count = 0;
    for (int i = 0; i < kLookEntryCount; ++i) {
        if (kLookEntries[i].categoryIndex == categoryIndex) {
            ++count;
        }
    }
    return count;
}

}  // namespace vtc
