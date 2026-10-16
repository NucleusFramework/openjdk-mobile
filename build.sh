#!/bin/bash
# Builds OpenJDK's mobile port as a Java runtime an iOS app embeds (see README.md): Zero (the interpreter, as iOS forbids
# generated code), as static libraries the app links, and its classes, data and JNI headers, packaged as
# <dist>/<asset>.tar.gz with its SHA-256.
#
#   ./build.sh ios-simulator | ios-device <openjdk/mobile checkout> [dist dir] [asset name]
#
# Applies openjdk-mobile.patch to the checkout unless it is already applied. Needs Xcode, autoconf and a boot JDK 26+
# (BOOT_JDK, else java_home -v 26).
set -euo pipefail

TARGET=${1:?ios-simulator or ios-device}
SRC=$(cd "${2:?openjdk/mobile checkout}" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "${3:-$HERE/dist}"
DIST=$(cd "${3:-$HERE/dist}" && pwd)
ASSET=${4:-jdk-mobile-$TARGET}
WORK=$SRC/build/mobile-runtime
BOOT_JDK=${BOOT_JDK:-$(/usr/libexec/java_home -v 26)}
# The cups headers, as openjdk/mobile's README asks (its libffi is built for iOS devices only: built here)
SUPPORT_ZIP=https://download2.gluonhq.com/mobile/mobile-support-20250106.zip
LIBFFI_VERSION=3.5.2
MIN_IOS=17.0
# The modules the runtime carries (a headless minimum; MODULES to choose others)
MODULES=${MODULES:-"java.base java.logging java.management jdk.unsupported"}
# What the exploded image lacks after static-libs-image: jdk.unsupported's classes, java.base's data (tzdb.dat...)
EXTRA_TARGETS="jdk.unsupported-java java.base-copy java.base-gendata"

case "$TARGET" in
    ios-simulator) SDK=iphonesimulator; CLANG_TARGET=arm64-apple-ios$MIN_IOS-simulator ;;
    ios-device) SDK=iphoneos; CLANG_TARGET=arm64-apple-ios$MIN_IOS ;;
    *) echo "Unknown target $TARGET (ios-simulator or ios-device)" >&2; exit 1 ;;
esac
SYSROOT=$(xcrun --sdk $SDK --show-sdk-path)

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

LIBFFI=$WORK/libffi-$TARGET
if [ ! -f "$LIBFFI/lib/libffi.a" ]; then
    (
        cd "$WORK"
        [ -d libffi-$LIBFFI_VERSION ] || curl -sSfL https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz | tar xz
        cd libffi-$LIBFFI_VERSION
        make distclean > /dev/null 2>&1 || true
        CC="xcrun --sdk $SDK clang" CFLAGS="-target $CLANG_TARGET -isysroot $SYSROOT -O2" \
            LDFLAGS="-target $CLANG_TARGET -isysroot $SYSROOT" \
            ./configure --host=aarch64-apple-darwin --prefix="$LIBFFI" --disable-shared --enable-static --disable-docs > /dev/null
        make -j"$(sysctl -n hw.ncpu)" > /dev/null
        make install > /dev/null
    )
fi

CONF=$TARGET-aarch64-zero-release
sh configure \
    --disable-warnings-as-errors \
    --openjdk-target=aarch64-macos-ios \
    --with-conf-name=$CONF \
    --with-boot-jdk="$BOOT_JDK" \
    --with-libffi-include="$LIBFFI/include" \
    --with-libffi-lib="$LIBFFI/lib" \
    --with-cups-include="$WORK/support/support/cups-2.3.6" \
    --with-sysroot="$SYSROOT" \
    --with-extra-cflags="-target $CLANG_TARGET" \
    --with-extra-cxxflags="-target $CLANG_TARGET" \
    --with-extra-ldflags="-target $CLANG_TARGET"
# No images nor jmods: they link a dynamic libjvm, which iOS can't have. The runtime boots from the exploded image
make CONF=$CONF static-libs-image $EXTRA_TARGETS

BUILD=$SRC/build/$CONF
STAGE=$WORK/stage-$TARGET
rm -rf "$STAGE" && mkdir -p "$STAGE/static" "$STAGE/include" "$STAGE/lib/modules"
cp "$BUILD/images/static-libs/lib/zero/libjvm.a" "$STAGE/static/"
for lib in java nio net zip jimage verify extnet fallbackLinker syslookup; do
    cp "$BUILD/images/static-libs/lib/lib$lib.a" "$STAGE/static/"
done
cp "$LIBFFI/lib/libffi.a" "$STAGE/static/"
cp "$BUILD/jdk/include/jni.h" "$BUILD/jdk/include/ios/jni_md.h" "$STAGE/include/"
# java.home: the classes and data, symlinks dereferenced
cp -RL "$BUILD/jdk/conf" "$BUILD/jdk/lib" "$STAGE/lib/"
for module in $MODULES; do cp -RL "$BUILD/jdk/modules/$module" "$STAGE/lib/modules/"; done
for required in lib/lib/tzdb.dat lib/modules/java.base/java/lang/Object.class lib/modules/jdk.unsupported/sun/misc/Unsafe.class; do
    [ -f "$STAGE/$required" ] || { echo "Missing $required" >&2; exit 1; }
done

tar -czf "$DIST/$ASSET.tar.gz" -C "$STAGE" .
(cd "$DIST" && shasum -a 256 "$ASSET.tar.gz" > "$ASSET.tar.gz.sha256")
ls -la "$DIST"
