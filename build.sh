#!/bin/bash
set -euo pipefail

AE_SDK_ROOT="/Users/victorbarbaian/Local Projects/VTC Looks/SDKs/Adobe/AfterEffectsSDK_25.6_61_mac/ae25.6_61.64bit.AfterEffectsSDK"
VTC_ROOT="/Users/victorbarbaian/Local Projects/VTC Looks/Plugin"
VTC_HOST="$VTC_ROOT/Hosts/AdobePF"
VTC_CORE="$VTC_ROOT/Core"
OUT_ROOT="/Users/victorbarbaian/Local Projects/VTC Looks/Build/VTC_Looks_Pro_Manual"
BUNDLE="$OUT_ROOT/VTC_Looks_Pro.plugin"
DEST="$HOME/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore"

echo "── Clean ──"
rm -rf "$OUT_ROOT"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "── Compile ──"
clang++ -arch arm64 -std=c++17 -O2 -bundle \
    -I"$AE_SDK_ROOT/Examples/Headers" \
    -I"$AE_SDK_ROOT/Examples/Headers/SP" \
    -I"$AE_SDK_ROOT/Examples/Util" \
    -I"$VTC_HOST" -I"$VTC_CORE" -I"$VTC_ROOT/Shared" \
    "$VTC_HOST/VTC_Looks_AdobePF.cpp" \
    "$VTC_HOST/VTC_FrameMap_AdobePF.cpp" \
    "$VTC_HOST/VTC_ParamMap_AdobePF.cpp" \
    "$VTC_CORE/VTC_LUTSampling.cpp" \
    "$VTC_CORE/VTC_LUTData_Log_Gen.cpp" \
    "$VTC_CORE/VTC_LUTData_Rec709_Gen.cpp" \
    "$VTC_CORE/VTC_MetalBootstrap.mm" \
    "$AE_SDK_ROOT/Examples/Util/Smart_Utils.cpp" \
    -framework CoreFoundation \
    -framework Foundation \
    -weak_framework Metal \
    -o "$BUNDLE/Contents/MacOS/VTC_Looks_Pro"

echo "── Rez (PiPL) ──"
xcrun Rez -useDF -d MAC_ENV=1 -d AE_OS_MAC=1 \
    -i "$AE_SDK_ROOT/Examples/Resources" -i "$AE_SDK_ROOT/Examples/Headers" \
    -i "$AE_SDK_ROOT/Examples/Util" -i "$VTC_HOST" \
    -o "$BUNDLE/Contents/Resources/VTC_Looks_Pro.rsrc" \
    "$VTC_HOST/VTC_Looks_AdobePF_CleanPiPL.r"

echo "── Bundle metadata ──"
cat > "$BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>English</string>
<key>CFBundleExecutable</key><string>VTC_Looks_Pro</string>
<key>CFBundleIdentifier</key><string>com.vtc.looks.pro</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>VTC_Looks_Pro</string>
<key>CFBundlePackageType</key><string>eFKT</string>
<key>CFBundleSignature</key><string>FXTC</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CSResourcesFileMapped</key><true/>
</dict></plist>
PLIST
echo -n "eFKTFXTC" > "$BUNDLE/Contents/PkgInfo"

echo "── Install to MediaCore ──"
rm -rf "$DEST/VTC_Looks_Pro.plugin"
cp -R "$BUNDLE" "$DEST/"
chmod +x "$DEST/VTC_Looks_Pro.plugin/Contents/MacOS/VTC_Looks_Pro"
xattr -cr "$DEST/VTC_Looks_Pro.plugin"
codesign --force --deep -s - "$DEST/VTC_Looks_Pro.plugin"

echo "══ BUILD + INSTALL OK ══"
