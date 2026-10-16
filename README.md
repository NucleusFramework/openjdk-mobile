# jdk-mobile

OpenJDK's mobile port ([openjdk/mobile](https://github.com/openjdk/mobile)) built as a Java runtime an app embeds, for
iOS (Zero, the interpreter: iOS forbids generated code) and Android (the server VM, with its JIT). This branch holds
the recipe only; the sources are upstream's.

- `openjdk-mobile.patch`, the fixes:
  - iOS: `os_bsd_zero.cpp` (the W^X state the shared code needs on Apple aarch64 is only defined for the C1/C2 port: Zero
    gets its own, without page protection switches), `os_bsd.cpp` (the code cache is committed read-write: iOS refuses
    executable pages without the JIT entitlement, and Zero never executes them);
  - Android, built from a macOS host: `basic.m4`, `flags-cflags.m4` (the NDK's sysroot, no `android32` target nor Linux
    defines forced on, `_GNU_SOURCE`), bionic's C library (`compilerWarnings.hpp`: no `noexcept`; `jni_util_md.c`: its
    XSI `strerror_r`), `java.home` from `JAVA_HOME` (`os_linux.cpp`: the natives are linked into the launcher), Linux
    as the Java code's OS (`GensrcMisc.gmk`), no serviceability agent (`jdk-options.m4`).
- `build.sh`: builds a target from an openjdk/mobile checkout and packages it; `jvm_launcher.c`: Android's launcher.
- `.github/workflows/build.yml`: every day, and on each change to the recipe, builds upstream's head if it and the
  recipe have no release yet, and publishes it in the same run. It fails, and GitHub says so, when the patch no longer
  applies.

## Releases

Named like the JBR's: `jdk-mobile-<version>b<build>.<revision>`, for example `jdk-mobile-28b9.1`: JDK 28, upstream at
the JDK's build 9 (`jdk-28+9`), the first release on it (the revision counts the releases on the same JDK build: a newer
upstream commit, a recipe change). Each release's notes give the upstream commit and the recipe it was built from.

| Asset | Contents |
|---|---|
| `jdk-mobile-<version>-ios-simulator-aarch64-b<build>.tar.gz`, `…-ios-device-…` | `static/`: `libjvm.a`, the JDK's native libraries and `libffi.a` |
| `jdk-mobile-<version>-android-aarch64-b<build>.tar.gz` | `jniLibs/arm64-v8a/libjvmlauncher.so`: the launcher, the VM linked in |

All of them hold `include/` (`jni.h`, `jni_md.h`) and `lib/`, the runtime's `java.home`: `conf/`, `lib/` and the
modules as an exploded image (`modules/<module>/...`; no jimage: `make images` links a dynamic libjvm), `java.base`,
`java.logging`, `java.management`, `jdk.unsupported` by default (`MODULES`). Each comes with its SHA-256 (`.sha256`).

## iOS

The app links the static libraries and the system's:

```
-force_load static/libjvm.a -force_load static/lib{java,nio,net,zip,jimage,verify,extnet,fallbackLinker,syslookup}.a
static/libffi.a -export_dynamic -lz -lc++
-framework Foundation -framework CoreFoundation -framework Security -framework SystemConfiguration
```

`-force_load` and `-export_dynamic` are required: the runtime finds its natives by name (`dlsym`). The VM sets its
`java.home` to `<executable dir>/lib` itself (`-Djava.home` is ignored): the bundle holds `lib/` as `App.app/lib`, the
app's jars anywhere (for example `App.app/lib/app`), on the class path given to `JNI_CreateJavaVM`.

## Android

ART and HotSpot can't share a process (both define `JNI_CreateJavaVM`, both handle `SIGSEGV`): the app runs Java in a
process of its own, the launcher, packaged among its native libraries (`packaging.jniLibs.useLegacyPackaging = true`, so
it is installed as a file it can execute), with `lib/` delivered into its files:

```
libjvmlauncher.so <java.home> <class path> <main class> [Java options...]
```

Everything the VM prints goes to standard error; standard output is the program's alone.

## Building

```bash
git clone https://github.com/openjdk/mobile.git jdk
./build.sh ios-simulator jdk   # or ios-device, android → dist/jdk-mobile-<target>.tar.gz
```

Needs autoconf and a boot JDK 26+ (`BOOT_JDK`); Xcode for iOS; the NDK (`ANDROID_NDK_HOME`) and fontconfig's headers for
Android.
