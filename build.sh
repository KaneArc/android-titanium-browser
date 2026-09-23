#!/bin/bash
source common.sh
set_keys
export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://chromium.googlesource.com/chromium/src.git
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure output directories exist relative to workspace root
mkdir -p chromium/src/out/Default
mkdir -p chromium/src/out/tmp
mkdir -p chromium/src/out/release

sudo apt-get update
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow imagemagick librsvg2-bin ccache
sudo dpkg --add-architecture i386; sudo apt-get update; sudo apt-get install -y libgcc-s1:i386

# --- RESUMABLE GUARD 1: Setup depot_tools if missing ---
if [ ! -d "depot_tools" ]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$PWD/depot_tools:$PATH"

# --- RESUMABLE GUARD 2: Initialize / Sync code tree ---
cd chromium/src
if [ ! -d ".git" ]; then
  git init
  git remote add origin $CHROMIUM_SOURCE
  git fetch --depth 1 $CHROMIUM_SOURCE +refs/tags/$VERSION:chromium_$VERSION
  git checkout $VERSION
  cp $SCRIPT_DIR/.gclient ../.gclient

  # Clean incompatible Vanadium patches
  rm -rf $SCRIPT_DIR/vanadium/patches/*trichrome-{apk-build-targets,browser-apk-targets}.patch
  rm -rf $SCRIPT_DIR/vanadium/patches/*{detailed,supported}-language*.patch
  rm -rf $SCRIPT_DIR/vanadium/patches/*javascript-optimizer-{site-setting,settings-UI}.patch
  rm -rf $SCRIPT_DIR/vanadium/patches/*component-updates.patch
  rm -rf $SCRIPT_DIR/vanadium/patches/*{pdf,PDF,for-content-public,toolbar-button,configs-from-config-app,new-tab-card,predictive-back*}*.patch
  
  replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "TITANIUM"
  replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Titanium"
  replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "titanium"
  git am --whitespace=nowarn --keep-non-patch $SCRIPT_DIR/vanadium/patches/*.patch

  gclient sync -D --no-history --nohooks
  gclient runhooks
  ./build/install-build-deps.sh --no-prompt
  
  if [ -f "$SCRIPT_DIR/patch.sh" ]; then
    source $SCRIPT_DIR/patch.sh
  fi
fi

# Ensure base args are copied
cp $SCRIPT_DIR/args.gn out/Default/args.gn

# FIX 1: Prepend explicit newline to prevent GN syntax errors
if ! grep -q "ccache_program" out/Default/args.gn; then
  echo -e '\nccache_program = "ccache"' >> out/Default/args.gn
fi

# ==================== STEP 1: COMPILING ARM 32-BIT ====================
if [ ! -f "out/release/$VERSION-armeabi-v7a.apk" ] && [ ! -f "out/tmp/$VERSION-armeabi-v7a.apk" ]; then
  echo ">>> Commencing/Resuming ARM 32-bit Compilation Target..."
  sed -i 's/target_cpu = "arm64"/target_cpu = "arm"/' out/Default/args.gn
  gn gen out/Default
  
  autoninja -C out/Default chrome_public_apk
  
  APK_FILE=$(find out/Default/apks -name 'Chrome*.apk' 2>/dev/null | head -n 1)
  if [ -n "$APK_FILE" ]; then
    mv "$APK_FILE" out/tmp/$VERSION-armeabi-v7a.apk
  else
    echo "Error: ARM 32-bit compilation finished but no output APK was found."
    exit 1
  fi
else
  echo ">>> Target variant ARM 32-bit found. Skipping Compilation."
fi

# ==================== STEP 2: COMPILING ARM64 64-BIT ====================
if [ ! -f "out/release/$VERSION-arm64-v8a.apk" ] && [ ! -f "out/tmp/$VERSION-arm64-v8a.apk" ]; then
  echo ">>> Commencing/Resuming ARM64 64-bit Compilation Target..."
  sed -i 's/target_cpu = "arm"/target_cpu = "arm64"/' out/Default/args.gn
  gn gen out/Default
  
  autoninja -C out/Default chrome_public_apk chrome_public_bundle
  
  APK_FILE64=$(find out/Default/apks -name 'Chrome*.apk' 2>/dev/null | head -n 1)
  AAB_FILE64=$(find out/Default/apks -name 'Chrome*.aab' 2>/dev/null | head -n 1)
  
  if [ -n "$APK_FILE64" ] && [ -n "$AAB_FILE64" ]; then
    mv "$APK_FILE64" out/tmp/$VERSION-arm64-v8a.apk
    mv "$AAB_FILE64" out/tmp/$VERSION-arm64-v8a.aab
  else
    echo "Error: ARM64 compilation finished but output APK/AAB was missing."
    exit 1
  fi
else
  echo ">>> Target variant ARM64 64-bit found. Skipping Compilation."
fi

# ==================== STEP 3: ARTIFACT SIGNING SYSTEM ====================
export PATH=$PWD/third_party/jdk/current/bin/:$PATH
export ANDROID_HOME=$PWD/third_party/android_sdk/public

if [ -f "out/tmp/$VERSION-armeabi-v7a.apk" ] && [ ! -f "out/release/$VERSION-armeabi-v7a.apk" ]; then
  sign_apk out/tmp/$VERSION-armeabi-v7a.apk out/release/$VERSION-armeabi-v7a.apk
fi

if [ -f "out/tmp/$VERSION-arm64-v8a.apk" ] && [ ! -f "out/release/$VERSION-arm64-v8a.apk" ]; then
  sign_apk out/tmp/$VERSION-arm64-v8a.apk out/release/$VERSION-arm64-v8a.apk
fi

if [ -f "out/tmp/$VERSION-arm64-v8a.aab" ] && [ ! -f "out/release/$VERSION-arm64-v8a.aab" ]; then
  sign_aab out/tmp/$VERSION-arm64-v8a.aab out/release/$VERSION-arm64-v8a.aab
fi

if [ -f "out/release/$VERSION-armeabi-v7a.apk" ] && [ -f "out/release/$VERSION-arm64-v8a.apk" ]; then
  echo ">>> Release binaries validated successfully. Sweeping local key assets."
  rm -rf $SCRIPT_DIR/keys
fi
