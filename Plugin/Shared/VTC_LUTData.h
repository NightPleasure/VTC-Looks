#pragma once

namespace vtc {

struct LUT3D {
    const float* data;
    int dimension;
};

constexpr int kLUTDim = 33;

extern const LUT3D kLogLUTs[];
extern const int kLogLUTCount;

extern const LUT3D kRec709LUTs[];
extern const int kRec709LUTCount;

inline const char* const kLogLUTNames[] = {
    "Convert Sony",
    "Dark Forest",
    "Amethyst",
    "Low Highlights",
    "Convert Canon",
    "Convert Fujifilm",
    "Convert RED",
};

inline const char* const kRec709LUTNames[] = {
    "VTC Blue Shadows",
    "VTC Brown Tone",
    "VTC Cinematic Contrast",
    "VTC Cinematic Teal",
    "VTC Cinematic Warm",
    "VTC Contrast Teal",
    "VTC Cool Teal",
    "VTC Crimson Contrast",
    "VTC Cyan Shadows",
    "VTC Dark Cinematic",
    "VTC Dark Tone",
    "VTC Flat Cyan",
    "VTC Forest",
    "VTC Gray",
    "VTC Indigo Gloom",
    "VTC Kodak Teal",
    "VTC Magenta Soft Shadows",
    "VTC Matte",
    "VTC Muted Warm",
    "VTC Saturated",
    "VTC Soft Contrast Warm",
    "VTC Soft Shadows",
    "VTC Soft Teal",
    "VTC Soft Tone",
    "VTC Teal & Orange",
    "VTC Teal Matte Shadows",
    "VTC Verdant",
    "VTC Vintage",
    "VTC Vintage Cyan",
    "VTC Vivid",
    "VTC Warm Shadows",
    "VTC Warm Teal",
    "VTC Warm Tones",
};

inline const char kLogPopupStr[] = "None|Convert Sony|Dark Forest|Amethyst|Low Highlights|Convert Canon|Convert Fujifilm|Convert RED";
inline const char kRec709PopupStr[] = "None|VTC Blue Shadows|VTC Brown Tone|VTC Cinematic Contrast|VTC Cinematic Teal|VTC Cinematic Warm|VTC Contrast Teal|VTC Cool Teal|VTC Crimson Contrast|VTC Cyan Shadows|VTC Dark Cinematic|VTC Dark Tone|VTC Flat Cyan|VTC Forest|VTC Gray|VTC Indigo Gloom|VTC Kodak Teal|VTC Magenta Soft Shadows|VTC Matte|VTC Muted Warm|VTC Saturated|VTC Soft Contrast Warm|VTC Soft Shadows|VTC Soft Teal|VTC Soft Tone|VTC Teal & Orange|VTC Teal Matte Shadows|VTC Verdant|VTC Vintage|VTC Vintage Cyan|VTC Vivid|VTC Warm Shadows|VTC Warm Teal|VTC Warm Tones";

inline const char kLogSelectedPopupStr[] = "0/7|1/7|2/7|3/7|4/7|5/7|6/7|7/7";
inline const char kRec709SelectedPopupStr[] = "0/33|1/33|2/33|3/33|4/33|5/33|6/33|7/33|8/33|9/33|10/33|11/33|12/33|13/33|14/33|15/33|16/33|17/33|18/33|19/33|20/33|21/33|22/33|23/33|24/33|25/33|26/33|27/33|28/33|29/33|30/33|31/33|32/33|33/33";

}  // namespace vtc
