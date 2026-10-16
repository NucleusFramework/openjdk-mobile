# jdk-mobile

A stable OpenJDK (27, from [openjdk/jdk27u](https://github.com/openjdk/jdk27u)'s GA releases) with
[openjdk/mobile](https://github.com/openjdk/mobile)'s port, built as a Java runtime an app embeds, for iOS (Zero, the
interpreter: iOS forbids generated code; arm64) and Android (the server VM, with its JIT; arm64 and x86_64). openjdk/mobile follows the JDK's
mainline (an early access); this branch holds the recipe that brings its port to the stable line, the sources being
OpenJDK's.

- `openjdk-mobile.patch`: openjdk/mobile's changes over the mainline it merged (the iOS and Android ports), ported to
  27 (its two aarch64-only lines made the target's, for x86_64), and these fixes:
  - iOS: `os_bsd_zero.cpp` (the W^X state the shared code needs on Apple aarch64 is only defined for the C1/C2 port: Zero
    gets its own, without page protection switches), `os_bsd.cpp` (the code cache is committed read-write: iOS refuses
    executable pages without the JIT entitlement, and Zero never executes them);
  - Android, built from a macOS host: `basic.m4`, `flags-cflags.m4` (the NDK's sysroot, no `android32` target nor Linux
    defines forced on, `_GNU_SOURCE`), bionic's C library (`compilerWarnings.hpp`: no `noexcept`; `jni_util_md.c`: its
    XSI `strerror_r`), `java.home` from `JAVA_HOME` (`os_linux.cpp`: the natives are linked into the launcher), Linux
    as the Java code's OS (`GensrcMisc.gmk`), no serviceability agent (`jdk-options.m4`).
- `inprocess.patch`, applied after it: on Android, `os::get_default_process_handle`, `os::lookup_function` and libjava's
  `getProcessHandle` resolve in the shared library holding the VM (`dladdr`, then `dlopen` of its path, else of its
  name when it is loaded from the APK itself, `RTLD_NOLOAD`) rather than in the process: an app's own library, loaded
  `RTLD_LOCAL`, is invisible to the process' handle.
- `build.sh`: builds a target from an OpenJDK 27 checkout and packages it; `jvm_launcher.c`: Android's launcher;
  `smoke/Smoke.java`: the program the CI runs with the x86_64 Android runtime on an emulator before a release (the JIT,
  threads, time zones, files).
- `.github/workflows/build.yml`: every day, and on each change to the recipe, builds the line's latest GA if it and
  the recipe have no release yet, and publishes it in the same run. It fails, and GitHub says so, when the patch no
  longer applies (an update that touches the same code): the port is then redone on it. Moving to the next line (28,
  29...) is porting the patch to it and changing `JDK_LINE`.

## Releases

Named like the JBR's: `jdk-mobile-<version>b<build>.<revision>`, for example `jdk-mobile-27b35.1`: JDK 27, its GA
(`jdk-27-ga`, the JDK's build `jdk-27+35`), the first release on it (the revision counts the releases on the same GA: a
recipe change). Each release's notes give the GA, its commit and the recipe it was built from.

| Asset | Contents |
|---|---|
| `jdk-mobile-<version>-ios-simulator-aarch64-b<build>.tar.gz`, `…-ios-device-…` | `static/`: `libjvm.a`, the JDK's native libraries and `libffi.a` |
| `jdk-mobile-<version>-android-aarch64-b<build>.tar.gz`, `…-android-x64-…` | `jniLibs/<abi>/libjvmlauncher.so` (`arm64-v8a`, `x86_64`): the launcher, the VM linked in; `static/`: `libjvm.a` and the JDK's native libraries, for the VM in the app's process |

All of them hold `include/` (`jni.h`, `jni_md.h`) and `lib/`, the runtime's `java.home` (its own per architecture:
some generated classes, `UnixConstants` among them, depend on it): `conf/`, `lib/` and the
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

Java runs either in a process of its own, the launcher, or in the app's, linked into a library of the app.

### In a process of its own

The launcher is packaged among the app's native libraries (`packaging.jniLibs.useLegacyPackaging = true`, so
it is installed as a file it can execute), with `lib/` delivered into its files:

```
libjvmlauncher.so <java.home> <class path> <main class> [Java options...]
```

Everything the VM prints goes to standard error; standard output is the program's alone.

### In the app's process

The app links the static libraries into a shared library of its own, with a bridge starting the VM. ART and HotSpot
both define `JNI_CreateJavaVM`: linked `-Bsymbolic` and loaded `RTLD_LOCAL` (`System.loadLibrary`), the library binds
to its own. ART's `libsigchain` chains HotSpot's `SIGSEGV` handler behind ART's fault manager; `-Xrs` leaves `SIGQUIT`
and the other signals to ART.

```
-Wl,--whole-archive static/libjvm.a static/lib{java,nio,net,zip,jimage,verify,extnet,syslookup,management}.a
-Wl,--no-whole-archive -Wl,-Bsymbolic -static-libstdc++ -lz -ldl -llog -lm
```

`--whole-archive` is required: the runtime finds its natives by name (`dlsym`, in that library: `inprocess.patch`).
`java.home` comes from `JAVA_HOME`, as for the launcher.

## Building

```bash
git clone --depth 1 --branch jdk-27-ga https://github.com/openjdk/jdk27u.git jdk
./build.sh ios-simulator jdk   # or ios-device, android-aarch64, android-x64 → dist/jdk-mobile-<target>.tar.gz
```

Needs autoconf and a boot JDK 26 or 27 (`BOOT_JDK`); a macOS host with Xcode for iOS; for Android, a Linux (as the CI)
or macOS host with the NDK (`ANDROID_NDK_HOME`), clang and fontconfig's headers.
