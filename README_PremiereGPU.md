# VTC Looks — Premiere Pro GPU (PrGPU) Plugin

## What is this?
A separate GPU-accelerated plugin for Premiere Pro using the PrGPU (GPU Extensions) API.
Currently implements **M0: GPU passthrough** — copies input to output pixel-for-pixel on the GPU via Metal compute shaders.

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

### 2. Enable diagnostic logging
Before launching Premiere Pro, set the environment variable:

```bash
export VTC_PRGPU_DIAG=1
open -a "Adobe Premiere Pro 2025"
```

Or launch from Terminal:

```bash
VTC_PRGPU_DIAG=1 /Applications/Adobe\ Premiere\ Pro\ 2025/Adobe\ Premiere\ Pro\ 2025.app/Contents/MacOS/Adobe\ Premiere\ Pro\ 2025
```

### 3. Apply the effect
- In the Effects panel, search for **VTC Looks GPU** (category: VTC)
- Apply to a clip and play

### 4. Check logs
With `VTC_PRGPU_DIAG=1`, you'll see on stderr:

```
[VTC PrGPU] Initialize devIdx=0
[VTC PrGPU] Pipeline OK idx=0
[VTC PrGPU] Render 3840x2160 rb=61440 pitch=3840 16f=0
[VTC PrGPU] Render 3840x2160 rb=61440 pitch=3840 16f=0
...
```

### 5. Visual check
Output should match input exactly (passthrough copies pixels 1:1).

## Files

| File | Purpose |
|------|---------|
| `Plugin/Hosts/PremiereGPU/VTC_Looks_PrGPU.mm` | GPU filter class + entry point |
| `Plugin/Hosts/PremiereGPU/VTC_PrGPU_Includes.h` | Shared includes + diagnostic logging |
| `Plugin/Hosts/PremiereGPU/VTC_Passthrough.metal` | Metal compute kernels (32f + 16f) |
| `Plugin/Hosts/PremiereGPU/VTC_FrameMap_PrGPU.cpp` | Frame mapping stub (for future LUT) |
| `Plugin/Hosts/PremiereGPU/VTC_ParamMap_PrGPU.cpp` | Parameter mapping stub (for future LUT) |
| `Plugin/Hosts/PremiereGPU/VTC_Looks_PrGPU_PiPL.r` | PiPL resource (Match_Name: com.vtclooks.prgpu) |
| `Plugin/Hosts/PremiereGPU/VTC_Looks_PrGPU_Info.plist` | Bundle Info.plist |
| `Build/VTC_Looks_PrGPU.xcodeproj/` | Xcode project (separate from AE build) |

## Next steps
- M1: Add LUT rendering (replace passthrough with actual color grading)
- M2: Add parameter controls for look selection
