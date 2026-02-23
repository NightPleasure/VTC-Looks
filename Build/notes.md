# VTC Looks AdobePF build/install (macOS)

## Prereqs
- Xcode 14+ on macOS (arm64).
- After Effects SDK headers and libs; set `AE_SDK_ROOT` env or project setting to the SDK root (contains `Examples/Headers` and `Libraries/Mac/`).

## Build (Xcode)
1) Open `Build/VTC_Looks_AdobePF_Clean.xcodeproj` in Xcode.
2) Scheme/target: **VTC_Looks_AdobePF_Clean**.
3) Architecture: arm64 (set in project).
4) Deployment target: macOS 11.0.
5) Build (⌘B). The Run Script phase copies the plugin to:
   `/Users/victorbarbaian/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/VTC Looks/`

## Verify install
Run in Terminal:
```
ls "/Users/victorbarbaian/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/VTC Looks/"
file "/Users/victorbarbaian/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/VTC Looks/VTC_Looks_AdobePF.plugin/Contents/MacOS/VTC_Looks_AdobePF"
codesign -dv --verbose=2 "/Users/victorbarbaian/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/VTC Looks/VTC_Looks_AdobePF_Clean.plugin" || true
```

## Host refresh
- Restart After Effects and Premiere Pro after install so they rescan the plugin.

## Notes
- Built as a Mach-O bundle (`.plugin`) with `-bundle`.
- No GPU; CPU-only PF effect.  
- If you need x86_64, add it to ARCHS/universal and rebuild.***

## Runtime smoke checklist (AE)
- Launch AE, let it rescan plug-ins.
- Effect shows as **VTC Looks** in the Effects list.
- Disabled: output matches input (copy-through).
- Enabled + Identity look: visually unchanged.
- Enabled + Film Warm / Cool Fade: visible color change.
- Test 8/16/32f layers if available; expect valid output.
- Alpha preserved (no fringe or transparency corruption).
