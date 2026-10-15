#!/bin/bash
# Builds a Java runtime an app embeds on a mobile platform, and packages it as dist/jdk-<target>.tar.gz (see README.md):
#
#   mobile-runtime/build.sh ios-simulator | ios-device   Zero (the interpreter, as iOS forbids generated code), static
#                                                       libraries the app links
#   mobile-runtime/build.sh android                     the server VM (JIT), linked into a launcher (jvm_launcher.c),
#                                                       Android 10+
#
# Needs a boot JDK 26+ (BOOT_JDK, else java_home -v 26) and autoconf; Xcode for iOS; for Android the NDK
# (ANDROID_NDK_HOME, else the latest of $ANDROID_HOME/ndk) and fontconfig's headers (java.desktop needs them to build;
# FONTCONFIG_INCLUDE, else brew's).
set -euo pipefail

TARGET=${1:?ios-simulator, ios-device or android}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/build/mobile-runtime
BOOT_JDK=${BOOT_JDK:-$(/usr/libexec/java_home -v 26)}
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

mkdir -p "$WORK"
if [ ! -d "$WORK/support" ]; then
    curl -sSfL -o "$WORK/support.zip" $SUPPORT_ZIP
    unzip -q -o "$WORK/support.zip" -d "$WORK/support"
fi
CUPS=$WORK/support/support/cups-2.3.6

# The runtime's classes and data, symlinks dereferenced: <dest>/{conf,lib,modules/<module>}
copy_java_home() {
    local jdk=$1 dest=$2
    mkdir -p "$dest/modules"
    cp -RL "$jdk/conf" "$jdk/lib" "$dest/"
    for module in $MODULES; do cp -RL "$jdk/modules/$module" "$dest/modules/"; done
    for required in lib/tzdb.dat modules/java.base/java/lang/Object.class modules/jdk.unsupported/sun/misc/Unsafe.class; do
        [ -f "$dest/$required" ] || { echo "Missing $required" >&2; exit 1; }
    done
}

package() {
    local stage=$1
    mkdir -p "$ROOT/dist"
    tar -czf "$ROOT/dist/jdk-$TARGET.tar.gz" -C "$stage" .
    (cd "$ROOT/dist" && shasum -a 256 "jdk-$TARGET.tar.gz" > "jdk-$TARGET.tar.gz.sha256")
    ls -la "$ROOT/dist"
}

build_ios() {
    local kind=${TARGET#ios-} sdk clang_target
    case "$kind" in
        simulator) sdk=iphonesimulator; clang_target=arm64-apple-ios$MIN_IOS-simulator ;;
        device) sdk=iphoneos; clang_target=arm64-apple-ios$MIN_IOS ;;
        *) echo "Unknown target $TARGET" >&2; exit 1 ;;
    esac
    local sysroot libffi=$WORK/libffi-$kind conf=ios-$kind-aarch64-zero-release
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

    cd "$ROOT"
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

    local build=$ROOT/build/$conf stage=$WORK/stage-$TARGET
    rm -rf "$stage" && mkdir -p "$stage/static"
    cp "$build/images/static-libs/lib/zero/libjvm.a" "$stage/static/"
    for lib in java nio net zip jimage verify extnet fallbackLinker syslookup; do
        cp "$build/images/static-libs/lib/lib$lib.a" "$stage/static/"
    done
    cp "$libffi/lib/libffi.a" "$stage/static/"
    copy_java_home "$build/jdk" "$stage/lib"
    package "$stage"
}

build_android() {
    local ndk tc conf=android-aarch64-server-release fontconfig
    ndk=${ANDROID_NDK_HOME:-$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/ndk/* | sort | tail -1)}
    tc=$ndk/toolchains/llvm/prebuilt/$(ls "$ndk/toolchains/llvm/prebuilt" | head -1)
    fontconfig=${FONTCONFIG_INCLUDE:-$(brew --prefix fontconfig)/include}

    cd "$ROOT"
    # The host compilers build the tools the build runs; the NDK's wrappers carry the target and its API level
    BUILD_CC=/usr/bin/clang BUILD_CXX=/usr/bin/clang++ \
    CC=$tc/bin/aarch64-linux-android$ANDROID_API-clang CXX=$tc/bin/aarch64-linux-android$ANDROID_API-clang++ \
    sh configure \
        --disable-warnings-as-errors \
        --openjdk-target=aarch64-linux-android \
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
    local build=$ROOT/build/$conf stage=$WORK/stage-$TARGET libs=$ROOT/build/$conf/images/static-libs/lib
    rm -rf "$stage" && mkdir -p "$stage/jniLibs/arm64-v8a"
    local launcher=$stage/jniLibs/arm64-v8a/libjvmlauncher.so
    "$tc/bin/aarch64-linux-android$ANDROID_API-clang++" -x c -O2 -fPIE -pie \
        -I"$build/jdk/include" -I"$build/jdk/include/android" \
        "$ROOT/mobile-runtime/jvm_launcher.c" \
        -x none -o "$launcher" \
        -Wl,--whole-archive "$libs/server/libjvm.a" "$libs/libjava.a" "$libs/libnio.a" "$libs/libnet.a" "$libs/libzip.a" \
        "$libs/libjimage.a" "$libs/libverify.a" "$libs/libextnet.a" "$libs/libsyslookup.a" -Wl,--no-whole-archive \
        -Wl,--export-dynamic -static-libstdc++ -lz -ldl -llog -lm
    "$tc/bin/llvm-strip" --strip-debug "$launcher"
    copy_java_home "$build/jdk" "$stage/jdk"
    package "$stage"
}

case "$TARGET" in
    ios-*) build_ios ;;
    android) build_android ;;
    *) echo "Unknown target $TARGET (ios-simulator, ios-device or android)" >&2; exit 1 ;;
esac
