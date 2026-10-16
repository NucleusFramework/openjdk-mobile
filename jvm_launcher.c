/*
 * A Java launcher for Android apps: this JVM, its static libraries linked in, running a class's main method.
 *
 *   libjvmlauncher.so <java.home> <class path> <main class> [Java options...]
 *
 * Packaged as a library (lib/<abi>/libjvmlauncher.so) because Android only executes the native code an APK holds; the
 * app starts it as a process (packaging.jniLibs.useLegacyPackaging = true, so it is installed as a file). The JDK's
 * classes and data are where the app put them, given as java.home (JAVA_HOME, read by the patched VM: os_linux.cpp);
 * its natives are linked in. Everything the VM prints goes to standard error: standard output is the program's alone.
 */
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(JNIEnv *env, const char *what) {
    fprintf(stderr, "jvmlauncher: %s\n", what);
    if (env != NULL && (*env)->ExceptionCheck(env)) (*env)->ExceptionDescribe(env);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <java.home> <class path> <main class> [Java options...]\n", argv[0]);
        return 2;
    }
    setenv("JAVA_HOME", argv[1], 1);

    static char *vmOutput[] = {"-XX:+DisplayVMOutputToStderr", "-Xlog:disable", "-Xlog:all=warning:stderr"};
    int fixed = sizeof vmOutput / sizeof vmOutput[0];
    int count = fixed + 1 + argc - 4;
    JavaVMOption *options = calloc(count, sizeof(JavaVMOption));
    for (int i = 0; i < fixed; i++) options[i].optionString = vmOutput[i];
    size_t length = strlen(argv[2]) + sizeof "-Djava.class.path=";
    char *classPath = malloc(length);
    snprintf(classPath, length, "-Djava.class.path=%s", argv[2]);
    options[fixed].optionString = classPath;
    for (int i = 4; i < argc; i++) options[fixed + 1 + i - 4].optionString = argv[i];

    JavaVMInitArgs args = {JNI_VERSION_21, count, options, JNI_TRUE};
    JavaVM *vm;
    JNIEnv *env;
    if (JNI_CreateJavaVM(&vm, (void **) &env, &args) != JNI_OK) return fail(NULL, "JNI_CreateJavaVM failed");

    // FindClass takes the binary name with slashes
    char *className = strdup(argv[3]);
    for (char *c = className; *c; c++) if (*c == '.') *c = '/';
    jclass mainClass = (*env)->FindClass(env, className);
    if (mainClass == NULL) return fail(env, "main class not on the class path");
    jmethodID main = (*env)->GetStaticMethodID(env, mainClass, "main", "([Ljava/lang/String;)V");
    if (main == NULL) return fail(env, "no static main(String[])");
    jobjectArray noArgs = (*env)->NewObjectArray(env, 0, (*env)->FindClass(env, "java/lang/String"), NULL);
    (*env)->CallStaticVoidMethod(env, mainClass, main, noArgs);
    int status = (*env)->ExceptionCheck(env) ? fail(env, "main threw") : 0;
    (*vm)->DestroyJavaVM(vm);
    return status;
}
