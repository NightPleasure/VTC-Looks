#pragma once

// Tiny baked-in 3D LUTs (2x2x2) for Rec709-ish space.
// Values are normalized RGB in [0,1].

inline constexpr int kLUTDim_Rec709 = 2;

// Identity LUT
inline constexpr float kLUT_Identity_Rec709[] = {
    // r, g, b for each lattice point (r-major, g, then b)
    0.0f, 0.0f, 0.0f,
    0.0f, 0.0f, 1.0f,
    0.0f, 1.0f, 0.0f,
    0.0f, 1.0f, 1.0f,
    1.0f, 0.0f, 0.0f,
    1.0f, 0.0f, 1.0f,
    1.0f, 1.0f, 0.0f,
    1.0f, 1.0f, 1.0f,
};

// Mild warm look: lift reds slightly, reduce blues.
inline constexpr float kLUT_FilmWarm_Rec709[] = {
    0.02f, 0.0f, 0.0f,
    0.05f, 0.0f, 0.90f,
    0.05f, 1.0f, 0.0f,
    0.08f, 1.0f, 0.85f,
    1.05f, 0.0f, 0.0f,
    1.05f, 0.0f, 0.90f,
    1.05f, 1.0f, 0.0f,
    1.05f, 1.0f, 0.90f,
};
