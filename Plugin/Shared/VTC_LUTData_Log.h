#pragma once

// Tiny baked-in 3D LUT for a cool/soft fade look in log-ish space (still used as normalized RGB).

inline constexpr int kLUTDim_Log = 2;

inline constexpr float kLUT_CoolFade_Log[] = {
    0.0f, 0.0f, 0.02f,
    0.0f, 0.0f, 0.90f,
    0.0f, 1.0f, 0.15f,
    0.0f, 1.0f, 0.95f,
    0.9f, 0.95f, 1.05f,
    0.9f, 0.95f, 1.05f,
    0.9f, 1.0f, 1.05f,
    0.9f, 1.0f, 1.05f,
};
