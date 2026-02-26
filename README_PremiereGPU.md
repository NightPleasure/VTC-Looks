# VTC Looks — Premiere Pro GPU (PrGPU) Plugin

## What is this?
A separate GPU-accelerated plugin for Premiere Pro using the PrGPU (GPU Extensions) API.
- **M0**: GPU passthrough (32f + 16f)
- **M1**: Params (Enable, Intensity) + gating
- **M2**: Single-layer LUT (32f + 16f) — kRec709LUTs[0], trilinear sample, intensity blend

The existing AE/PF plugin (`VTC_Looks_AdobePF_Clean`) is completely untouched.

## Build

```bash
cd "/Users/victorbarbaian/Local Projects/VTC Looks"
xcodebuild -project Build/VTC_Looks_PrGPU.xcodeproj \
           -scheme VTC_Looks_PrGPU \
           -configuration Debug build
```

The build automatically:
1. Compiles the PiPL resource
2. Compiles the Metal shader into a `.metallib`
3. Compiles the Objective-C++ source
4. Deploys to `~/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/VTC/VTC_Looks_PrGPU.plugin`

## Verify GPU is being used

### 1. Set Premiere Pro renderer
- **File → Project Settings → General**
- **Video Rendering and Playback → Renderer**: choose **Mercury Playback Engine GPU Acceleration (Metal)**

### 2. Environment variables
| Var | Purpose |
|-----|---------|
| `VTC_PRGPU_DIAG=1` | Diagnostic logs (Initialize, Render, params) |
| `VTC_PRGPU_DEBUG=1` | LUT cache logs (id, size) |
| `VTC_PRGPU_PERF=1` | (M4) Per-frame ms |

### 3. Enable diagnostic logging
Before launching Premiere Pro:

```bash
export VTC_PRGPU_DIAG=1
open -a "Adobe Premiere Pro 2025"
```

Or launch from Terminal:

```bash
VTC_PRGPU_DIAG=1 /Applications/Adobe\ Premiere\ Pro\ 2025/Adobe\ Premiere\ Pro\ 2025.app/Contents/MacOS/Adobe\ Premiere\ Pro\ 2025
```

### 4. Apply the effect
- In the Effects panel, search for **VTC Looks GPU** (category: VTC)
- Apply to a clip and play

### 5. Check logs
With `VTC_PRGPU_DIAG=1`, you'll see on stderr:

```
[VTC PrGPU] Initialize devIdx=0
[VTC PrGPU] Pipeline OK idx=0
[VTC PrGPU] Render 3840x2160 rb=61440 pitch=3840 16f=0
[VTC PrGPU] Render 3840x2160 rb=61440 pitch=3840 16f=0
...
```

### 6. Visual check
**32f timeline**: With Enable ON and Intensity > 0, output has LUT applied (VTC Blue Shadows). **16f or bypass**: passthrough.

## Files

| File | Purpose |
|------|---------|
| `Plugin/Hosts/PremiereGPU/VTC_Looks_PrGPU.mm` | GPU filter class + entry point |
| `Plugin/Hosts/PremiereGPU/VTC_PrGPU_Includes.h` | Shared includes + diagnostic logging |
| `Plugin/Hosts/PremiereGPU/VTC_Passthrough.metal` | Metal kernels: passthrough 32f/16f + LUT apply 32f |
| `Plugin/Core/VTC_LUTData_Rec709_Gen.cpp` | LUT data (kRec709LUTs) |
| `Plugin/Hosts/PremiereGPU/VTC_ParamMap_PrGPU.cpp` | Param mapping (Enable, Intensity) |
| `Plugin/Hosts/PremiereGPU/VTC_Looks_PrGPU_PiPL.r` | PiPL resource (Match_Name: com.vtclooks.prgpu) |
| `Plugin/Hosts/PremiereGPU/VTC_Looks_PrGPU_Info.plist` | Bundle Info.plist |
| `Build/VTC_Looks_PrGPU.xcodeproj/` | Xcode project (separate from AE build) |

## Next steps
- M2b: LUT 16f path
- M3: Full stack (4 layers)
- M4: Optimizations + stability


## CPU fallback test mode (macOS Metal locked)

Premiere on macOS may lock renderer to Metal. To test PF CPU fallback anyway:

### Force CPU test mode

Launch Premiere from Terminal with:

```bash
VTC_FORCE_CPU_TEST=1 VTC_PRGPU_DIAG=1 /Applications/Adobe\ Premiere\ Pro\ 2025/Adobe\ Premiere\ Pro\ 2025.app/Contents/MacOS/Adobe\ Premiere\ Pro\ 2025
```

Behavior when `VTC_FORCE_CPU_TEST=1`:
- PrGPU/Metal path refuses initialization so host falls back to PF CPU rendering.
- CPU path still applies full LUT stack (Log -> Creative -> Secondary -> Accent).
- With `VTC_PRGPU_DIAG=1`, logs include: `CPU TEST MODE (forced)`.
- With `VTC_PRGPU_DIAG=1`, a small 2x2 corner marker is added for visual confirmation.
- Exports follow the same forced CPU behavior.

### Re-enable normal GPU behavior

Unset (or set to `0`) before launching Premiere:

```bash
unset VTC_FORCE_CPU_TEST
# or
VTC_FORCE_CPU_TEST=0 /Applications/Adobe\ Premiere\ Pro\ 2025/Adobe\ Premiere\ Pro\ 2025.app/Contents/MacOS/Adobe\ Premiere\ Pro\ 2025
```

Default (unset/0) behavior remains unchanged: GPU path is used when Metal is available; PF CPU fallback is used only when GPU path is unavailable.


## Clear Premiere plugin cache (after install changes)

If Premiere still shows duplicate effects after deploy, clear plugin cache and relaunch.

1. Quit Premiere completely.
2. Run:

```bash
rm -rf "$HOME/Library/Caches/Adobe/Premiere Pro"/*/PluginCache 2>/dev/null || true
rm -rf "$HOME/Library/Preferences/Adobe/Premiere Pro"/*/PluginCache 2>/dev/null || true
```

3. Launch Premiere again and re-check the Effects panel.

Expected result after deploy script cleanup: only one VTC effect entry from `VTC_Looks_PrGPU.plugin`.
