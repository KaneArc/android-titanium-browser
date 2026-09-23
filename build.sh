#!/bin/bash
source common.sh
set_keys
export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://chromium.googlesource.com/chromium/src.git # https://github.com/chromium/chromium.git
export DEBIAN_FRONTEND=noninteractive

# Ensure paths are established globally across sequential job updates
mkdir -p chromium/src/out/Default
mkdir -p chromium/src/out/tmp
mkdir -p chromium/src/out/release

sudo apt-get update
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow imagemagick librsvg2-bin ccache
sudo dpkg --add-architecture i386; sudo apt-get update; sudo apt-get install -y libgcc-s1:i386

# --- RESUMABLE GUARD 1: Only setup tools if not present ---
if [ ! -d "depot_tools" ]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$PWD/depot_tools:$PATH"

# --- RESUMABLE GUARD 2: Avoid wiping code tree on checkpoint resumes ---
cd chromium/src
if [ ! -d ".git" ]; then
  git init
  git remote add origin $CHROMIUM_SOURCE
  git fetch --depth 1 $CHROMIUM_SOURCE +refs/tags/$VERSION:chromium_$VERSION
  git checkout $VERSION
  cp $SCRIPT_DIR/.gclient ../.gclient

  # https://grapheneos.org/build#browser-and-webview
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
  source $SCRIPT_DIR/patch.sh
fi

# Make sure base arguments are mapped
cp $SCRIPT_DIR/args.gn out/Default/args.gn

# CRITICAL FIX: Explicitly append ccache execution parameters to Chromium meta-compiler
if ! grep -q "ccache_program" out/Default/args.gn; then
  echo 'ccache_program = "ccache"' >> out/Default/args.gn
fi

# ==================== STEP 1: COMPILING ARM 32-BIT ====================
# Guard skips this entire 3-hour step if it was completed on a previous run
if [ ! -f "out/release/$VERSION-armeabi-v7a.apk" ] && [ ! -f "out/tmp/$VERSION-armeabi-v7a.apk" ]; then
  echo ">>> Commencing/Resuming ARM 32-bit Compilation Target..."
  sed -i 's/target_cpu = "arm64"/target_cpu = "arm"/' out/Default/args.gn
  gn gen out/Default
  
  autoninja -C out/Default chrome_public_apk
  mv $(find out/Default/apks -name 'Chrome*.apk') out/tmp/$VERSION-armeabi-v7a.apk
else
  echo ">>> Target variant ARM 32-bit found. Skipping Compilation."
fi

# ==================== STEP 2: COMPILING ARM64 64-BIT ====================
# Guard skips this step if it was completed on a previous run
if [ ! -f "out/release/$VERSION-arm64-v8a.apk" ] && [ ! -f "out/tmp/$VERSION-arm64-v8a.apk" ]; then
  echo ">>> Commencing/Resuming ARM64 64-bit Compilation Target..."
  sed -i 's/target_cpu = "arm"/target_cpu = "arm64"/' out/Default/args.gn
  gn gen out/Default
  
  autoninja -C out/Default chrome_public_apk chrome_public_bundle
  mv $(find out/Default/apks -name 'Chrome*.apk') out/tmp/$VERSION-arm64-v8a.apk
  mv $(find out/Default/apks -name 'Chrome*.aab') out/tmp/$VERSION-arm64-v8a.aab
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

# Wipe verification assets ONLY if both architecture packages are signed and generated
if [ -f "out/release/$VERSION-armeabi-v7a.apk" ] && [ -f "out/release/$VERSION-arm64-v8a.apk" ]; then
  echo ">>> Release binaries validated successfully. Sweeping local key assets."
  rm -rf $SCRIPT_DIR/keys
fi
