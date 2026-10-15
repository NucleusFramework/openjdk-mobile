# Mobile runtime

OpenJDK's mobile port built as a Java runtime an app embeds, for iOS and Android, from a macOS host. This branch is
`openjdk/mobile` at the tested commit plus the fixes of its first commit (see its message), this directory and its
workflow (`.github/workflows/mobile-runtime.yml`), which publishes the runtimes on each `mobile-runtime-*` tag.

| Asset | VM | Contents |
|---|---|---|
| `jdk-ios-simulator.tar.gz`, `jdk-ios-device.tar.gz` | Zero (interpreter: iOS forbids generated code) | `static/`: `libjvm.a`, the JDK's native libraries and `libffi.a`; `lib/`: the runtime's `java.home` |
| `jdk-android.tar.gz` | server (JIT), Android 10+ (API 29) | `jniLibs/arm64-v8a/libjvmlauncher.so`: the launcher; `jdk/`: the runtime's `java.home` |

Each comes with its SHA-256 (`.sha256`). A `java.home` holds `conf/`, `lib/` and the modules as an exploded image
(`modules/<module>/...`; no jimage: `make images` links a dynamic libjvm): `java.base`, `java.logging`,
`java.management`, `jdk.unsupported` by default (`MODULES`).

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
it is installed as a file it can execute), with `jdk/` delivered into its files:

```
libjvmlauncher.so <java.home> <class path> <main class> [Java options...]
```

Everything the VM prints goes to standard error; standard output is the program's alone.

## Building

```bash
mobile-runtime/build.sh ios-simulator   # or ios-device, android → dist/jdk-<target>.tar.gz
```

Needs a boot JDK 26+ (`BOOT_JDK`), autoconf, Xcode; for Android the NDK (`ANDROID_NDK_HOME`) and fontconfig's headers.
