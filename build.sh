#!/bin/bash
# Builds OpenJDK's mobile port as a Java runtime an app embeds (see README.md), packaged as <dist>/<asset>.tar.gz with its
# SHA-256:
#
#   ./build.sh ios-simulator | ios-device | android-aarch64 | android-x64 <OpenJDK 27 checkout> [dist dir] [asset name]
#
#   ios-*       Zero (the interpreter, as iOS forbids generated code), as static libraries the app links (arm64)
#   android-*   the server VM (JIT), linked into a launcher the app runs as a process (jvm_launcher.c), Android 10+
#
# Applies openjdk-mobile.patch to the checkout unless it is already applied. Needs autoconf and a boot JDK 26 or 27
# (BOOT_JDK, else java_home -v 26 on macOS); iOS needs a macOS host with Xcode; Android builds from a Linux or macOS
# host, with the NDK (ANDROID_NDK_HOME, else the latest of $ANDROID_HOME/ndk), a host clang (BUILD_CC/BUILD_CXX, else
# the PATH's) and fontconfig's headers (java.desktop needs them to build; FONTCONFIG_INCLUDE, else brew's or
# /usr/include: libfontconfig1-dev).
set -euo pipefail

TARGET=${1:?ios-simulator, ios-device, android-aarch64 or android-x64}
SRC=$(cd "${2:?OpenJDK 27 checkout}" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "${3:-$HERE/dist}"
DIST=$(cd "${3:-$HERE/dist}" && pwd)
ASSET=${4:-jdk-mobile-$TARGET}
WORK=$SRC/build/mobile-runtime
BOOT_JDK=${BOOT_JDK:-$(/usr/libexec/java_home -v 26 2> /dev/null)}
[ -n "$BOOT_JDK" ] || { echo "No boot JDK: set BOOT_JDK" >&2; exit 1; }
# The cups headers, as openjdk/mobile's README asks (its libffi is built for iOS devices only: built here)
SUPPORT_ZIP=https://download2.gluonhq.com/mobile/mobile-support-20250106.zip
LIBFFI_VERSION=3.5.2
MIN_IOS=17.0
# Android 10: the first with native ELF TLS, which HotSpot's aarch64 code needs (posix_spawn needs 28)
ANDROID_API=29
# The modules the runtime carries (a headless minimum; MODULES to choose others)
MODULES=${MODULES:-"java.base java.logging java.management jdk.unsupported"}
# What the exploded image lacks after static-libs-image: jdk.unsupported's classes, java.base's data (tzdb.dat...)
EXTRA_TARGETS="jdk.unsupported-java java.base-copy java.base-gendata"
STAGE=$WORK/stage-$TARGET

cd "$SRC"
if git apply --check "$HERE/openjdk-mobile.patch" 2> /dev/null; then
    git apply "$HERE/openjdk-mobile.patch"
elif ! git apply --reverse --check "$HERE/openjdk-mobile.patch" 2> /dev/null; then
    echo "openjdk-mobile.patch doesn't apply to this checkout" >&2
    exit 1
fi

mkdir -p "$WORK"
if [ ! -d "$WORK/support" ]; then
    curl -sSfL -o "$WORK/support.zip" $SUPPORT_ZIP
    unzip -q -o "$WORK/support.zip" -d "$WORK/support"
fi
CUPS=$WORK/support/support/cups-2.3.6

# The JNI headers and java.home (the classes and data, symlinks dereferenced) of the exploded image <jdk>
stage_jdk() {
    local jdk=$1 platform=$2
    mkdir -p "$STAGE/include" "$STAGE/lib/modules"
    cp "$jdk/include/jni.h" "$jdk/include/$platform/jni_md.h" "$STAGE/include/"
    cp -RL "$jdk/conf" "$jdk/lib" "$STAGE/lib/"
    for module in $MODULES; do cp -RL "$jdk/modules/$module" "$STAGE/lib/modules/"; done
    # The build's own files left in the exploded image (_the.java.base.vardeps...)
    find "$STAGE/lib/modules" -name '_the.*' -delete
    for required in lib/lib/tzdb.dat lib/modules/java.base/java/lang/Object.class lib/modules/jdk.unsupported/sun/misc/Unsafe.class; do
        [ -f "$STAGE/$required" ] || { echo "Missing $required" >&2; exit 1; }
    done
}

package() {
    tar -czf "$DIST/$ASSET.tar.gz" -C "$STAGE" .
    (cd "$DIST" && shasum -a 256 "$ASSET.tar.gz" > "$ASSET.tar.gz.sha256")
    ls -la "$DIST"
}

build_ios() {
    local sdk clang_target sysroot libffi=$WORK/libffi-$TARGET conf=$TARGET-aarch64-zero-release
    case "$TARGET" in
        ios-simulator) sdk=iphonesimulator; clang_target=arm64-apple-ios$MIN_IOS-simulator ;;
        ios-device) sdk=iphoneos; clang_target=arm64-apple-ios$MIN_IOS ;;
    esac
    sysroot=$(xcrun --sdk $sdk --show-sdk-path)

    if [ ! -f "$libffi/lib/libffi.a" ]; then
        (
            cd "$WORK"
            [ -d libffi-$LIBFFI_VERSION ] || curl -sSfL https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz | tar xz
            cd libffi-$LIBFFI_VERSION
            make distclean > /dev/null 2>&1 || true
            CC="xcrun --sdk $sdk clang" CFLAGS="-target $clang_target -isysroot $sysroot -O2" \
                LDFLAGS="-target $clang_target -isysroot $sysroot" \
                ./configure --host=aarch64-apple-darwin --prefix="$libffi" --disable-shared --enable-static --disable-docs > /dev/null
            make -j"$(sysctl -n hw.ncpu)" > /dev/null
            make install > /dev/null
        )
    fi

    sh configure \
        --disable-warnings-as-errors \
        --openjdk-target=aarch64-macos-ios \
        --with-conf-name=$conf \
        --with-boot-jdk="$BOOT_JDK" \
        --with-libffi-include="$libffi/include" \
        --with-libffi-lib="$libffi/lib" \
        --with-cups-include="$CUPS" \
        --with-sysroot="$sysroot" \
        --with-extra-cflags="-target $clang_target" \
        --with-extra-cxxflags="-target $clang_target" \
        --with-extra-ldflags="-target $clang_target"
    # No images nor jmods: they link a dynamic libjvm, which iOS can't have. The runtime boots from the exploded image
    make CONF=$conf static-libs-image $EXTRA_TARGETS

    local build=$SRC/build/$conf
    rm -rf "$STAGE" && mkdir -p "$STAGE/static"
    cp "$build/images/static-libs/lib/zero/libjvm.a" "$STAGE/static/"
    for lib in java nio net zip jimage verify extnet fallbackLinker syslookup; do
        cp "$build/images/static-libs/lib/lib$lib.a" "$STAGE/static/"
    done
    cp "$libffi/lib/libffi.a" "$STAGE/static/"
    stage_jdk "$build/jdk" ios
}

build_android() {
    local ndk tc fontconfig triple abi conf=$TARGET-server-release
    case "$TARGET" in
        android-aarch64) triple=aarch64-linux-android; abi=arm64-v8a ;;
        android-x64) triple=x86_64-linux-android; abi=x86_64 ;;
    esac
    ndk=${ANDROID_NDK_HOME:-$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/ndk/* | sort | tail -1)}
    tc=$ndk/toolchains/llvm/prebuilt/$(ls "$ndk/toolchains/llvm/prebuilt" | head -1)
    if [ -n "${FONTCONFIG_INCLUDE:-}" ]; then
        fontconfig=$FONTCONFIG_INCLUDE
    elif command -v brew > /dev/null; then
        fontconfig=$(brew --prefix fontconfig)/include
    else
        fontconfig=/usr/include
    fi

    # The host compilers build the tools the build runs; the NDK's wrappers carry the target and its API level.
    # config.guess identifies the host with CC_FOR_BUILD, else CC: the NDK's, which would make a Linux host Android
    local build_cc=${BUILD_CC:-$(command -v clang)} build_cxx=${BUILD_CXX:-$(command -v clang++)}
    BUILD_CC=$build_cc BUILD_CXX=$build_cxx CC_FOR_BUILD=$build_cc \
    CC=$tc/bin/$triple$ANDROID_API-clang CXX=$tc/bin/$triple$ANDROID_API-clang++ \
    sh configure \
        --disable-warnings-as-errors \
        --openjdk-target=$triple \
        --with-conf-name=$conf \
        --with-jvm-variants=server \
        --with-boot-jdk="$BOOT_JDK" \
        --with-toolchain-type=clang \
        --with-toolchain-path="$tc/bin" \
        --with-sysroot="$tc/sysroot" \
        --with-cups-include="$CUPS" \
        --with-fontconfig-include="$fontconfig" \
        --enable-headless-only
    # The archives need llvm-ar (Xcode's ar takes no @file); no images nor jmods (they need a build JDK for macOS)
    make CONF=$conf static-libs-image $EXTRA_TARGETS AR="$tc/bin/llvm-ar"

    # The launcher: an executable with the VM and the JDK's natives in, packaged as a library (Android only executes the
    # native code an APK holds)
    local build=$SRC/build/$conf libs=$SRC/build/$conf/images/static-libs/lib
    rm -rf "$STAGE" && mkdir -p "$STAGE/jniLibs/$abi"
    local launcher=$STAGE/jniLibs/$abi/libjvmlauncher.so
    "$tc/bin/$triple$ANDROID_API-clang++" -x c -O2 -fPIE -pie \
        -I"$build/jdk/include" -I"$build/jdk/include/android" \
        "$HERE/jvm_launcher.c" \
        -x none -o "$launcher" \
        -Wl,--whole-archive "$libs/server/libjvm.a" "$libs/libjava.a" "$libs/libnio.a" "$libs/libnet.a" "$libs/libzip.a" \
        "$libs/libjimage.a" "$libs/libverify.a" "$libs/libextnet.a" "$libs/libsyslookup.a" -Wl,--no-whole-archive \
        -Wl,--export-dynamic -static-libstdc++ -lz -ldl -llog -lm
    "$tc/bin/llvm-strip" --strip-debug "$launcher"
    stage_jdk "$build/jdk" android
}

case "$TARGET" in
    ios-simulator | ios-device) build_ios ;;
    android-aarch64 | android-x64) build_android ;;
    *) echo "Unknown target $TARGET (ios-simulator, ios-device, android-aarch64 or android-x64)" >&2; exit 1 ;;
esac
package
