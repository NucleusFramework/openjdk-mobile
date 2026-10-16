# jdk-mobile

OpenJDK's mobile port ([openjdk/mobile](https://github.com/openjdk/mobile)) built as a Java runtime an iOS app embeds:
Zero (the interpreter: iOS forbids generated code), as static libraries the app links. This branch holds the recipe
only; the sources are upstream's.

- `openjdk-mobile.patch`: two fixes for Zero on iOS.
  - `os_bsd_zero.cpp`: the W^X state the shared code needs on Apple aarch64 is only defined for the C1/C2 port: Zero
    gets its own, without page protection switches (it generates no code).
  - `os_bsd.cpp`: the code cache is committed read-write on iOS, which refuses executable pages without the JIT
    entitlement; Zero never executes them.
- `build.sh`: builds a target from an openjdk/mobile checkout and packages it.
- `.github/workflows/build.yml`: every day, builds upstream's head if it (or the recipe) has no release yet, and
  publishes it. It fails, and GitHub says so, when the patch no longer applies.

## Releases

Named like the JBR's: `jdk-mobile-<version>b<build>.<revision>`, for example `jdk-mobile-28b9.1`: JDK 28, upstream at
the JDK's build 9 (`jdk-28+9`), the first release on it (the revision counts the releases on the same JDK build: a newer
upstream commit, a recipe change). Each release's notes give the upstream commit and the recipe it was built from.

| Asset | Contents |
|---|---|
| `jdk-mobile-<version>-ios-simulator-aarch64-b<build>.tar.gz`, `…-ios-device-…` | `static/`: `libjvm.a`, the JDK's native libraries and `libffi.a`; `include/`: `jni.h`, `jni_md.h`; `lib/`: the runtime's `java.home` |

Each comes with its SHA-256 (`.sha256`). `java.home` holds `conf/`, `lib/` and the modules as an exploded image
(`modules/<module>/...`; no jimage: `make images` links a dynamic libjvm): `java.base`, `java.logging`,
`java.management`, `jdk.unsupported` by default (`MODULES`).

## Using it

The app links the static libraries and the system's:

```
-force_load static/libjvm.a -force_load static/lib{java,nio,net,zip,jimage,verify,extnet,fallbackLinker,syslookup}.a
static/libffi.a -export_dynamic -lz -lc++
-framework Foundation -framework CoreFoundation -framework Security -framework SystemConfiguration
```

`-force_load` and `-export_dynamic` are required: the runtime finds its natives by name (`dlsym`). The VM sets its
`java.home` to `<executable dir>/lib` itself (`-Djava.home` is ignored): the bundle holds `lib/` as `App.app/lib`, the
app's jars anywhere (for example `App.app/lib/app`), on the class path given to `JNI_CreateJavaVM`.

## Building

```bash
git clone https://github.com/openjdk/mobile.git jdk
./build.sh ios-simulator jdk   # or ios-device → dist/jdk-mobile-ios-simulator.tar.gz
```

Needs Xcode, autoconf and a boot JDK 26+ (`BOOT_JDK`).
