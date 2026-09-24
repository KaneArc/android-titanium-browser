#!/bin/bash
source common.sh
set_keys
export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://chromium.googlesource.com/chromium/src.git # https://github.com/chromium/chromium.git
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow imagemagick librsvg2-bin ccache
sudo dpkg --add-architecture i386; sudo apt-get update; sudo apt-get install -y libgcc-s1:i386

if [ ! -d depot_tools ]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$PWD/depot_tools:$PATH"

mkdir -p chromium/src/out/Default
cd chromium/src

# --- Everything in this block only needs to happen once. On a resumed run
# (chromium/ restored from cache) it's skipped entirely, so we don't redo
# the shallow clone or re-run `git am` against already-applied patches
# (which would fail the second time).
if [ ! -f .titanium_checked_out ]; then
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
  # rm -rf $SCRIPT_DIR/vanadium/patches/*crashpad*.patch
  replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "TITANIUM"
  replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Titanium"
  replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "titanium"
  git am --whitespace=nowarn --keep-non-patch $SCRIPT_DIR/vanadium/patches/*.patch

  touch .titanium_checked_out
fi

gclient sync -D --no-history --nohooks
gclient runhooks
./build/install-build-deps.sh --no-prompt

# --- patch.sh's sed overrides (including your onAuthRequired fix) are also
# only safe to apply once against a clean checkout.
if [ ! -f .titanium_patched ]; then
  source $SCRIPT_DIR/patch.sh
  touch .titanium_patched
fi

cp $SCRIPT_DIR/args.gn out/Default/args.gn
sed -i 's/target_cpu = "arm"/target_cpu = "arm64"/' out/Default/args.gn
echo 'cc_wrapper = "ccache"' >> out/Default/args.gn
gn gen out/Default # gn args out/Default; echo 'treat_warnings_as_errors = false' >> out/Default/args.gn
mkdir -p out/tmp out/release

autoninja -C out/Default chrome_public_apk chrome_public_bundle
mv $(find out/Default/apks -name 'Chrome*.apk') out/tmp/$VERSION-arm64-v8a.apk
mv $(find out/Default/apks -name 'Chrome*.aab') out/tmp/$VERSION-arm64-v8a.aab

export PATH=$PWD/third_party/jdk/current/bin/:$PATH
export ANDROID_HOME=$PWD/third_party/android_sdk/public
sign_apk out/tmp/$VERSION-arm64-v8a.apk out/release/$VERSION-arm64-v8a.apk
sign_aab out/tmp/$VERSION-arm64-v8a.aab out/release/$VERSION-arm64-v8a.aab
rm -rf $SCRIPT_DIR/keys
