// The two device/package questions the launch-time renderer resolution asks
// (labelle-android#27, labelle-bgfx#172 D1-D3). The pure decision is
// `renderer.zig`; this is the JNI half:
//
//   * the provider setting the packager stamps into the manifest
//     (`<meta-data android:name="labelle.renderer" android:value="..."/>`,
//     labelle-android#26):
//       getPackageManager()
//         .getApplicationInfo(getPackageName(), GET_META_DATA)
//         .metaData.getString("labelle.renderer")
//   * `auto`'s device check:
//       getPackageManager().hasSystemFeature("android.hardware.vulkan.version",
//                                            0x401000)   // Vulkan 1.1
//   * for the crash guard (labelle-android#28): the package's version code
//     and `ANativeActivity.internalDataPath`, plus (not JNI) the runtime
//     `dlsym` of labelle-bgfx's frame counter and a monotonic clock
//
// In C for the same reason as intent_extras.c: <jni.h> already declares the
// JNI vtables. Off Android this is an empty TU.
#ifdef __ANDROID__

#include <android/log.h>
#include <android/native_activity.h>
#include <dlfcn.h>
#include <jni.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

// android.content.pm.PackageManager.GET_META_DATA (API 1).
#define LABELLE_GET_META_DATA 0x00000080

// intent_extras.c: attach-if-detached, reporting what we attached.
JNIEnv *labelle_android_acquire_env(JavaVM *vm, int *we_attached);

// `activity.getPackageManager()`, or NULL (possibly with an exception
// pending; the callers clear it). A local ref inside the caller's frame.
static jobject package_manager(JNIEnv *env, jobject activity) {
    jclass activity_cls = (*env)->GetObjectClass(env, activity);
    if (activity_cls == NULL) return NULL;
    jmethodID get_pm = (*env)->GetMethodID(env, activity_cls, "getPackageManager", "()Landroid/content/pm/PackageManager;");
    if (get_pm == NULL || (*env)->ExceptionCheck(env)) return NULL;
    jobject pm = (*env)->CallObjectMethod(env, activity, get_pm);
    if ((*env)->ExceptionCheck(env)) return NULL;
    return pm;
}

// Copy the `labelle.renderer` meta-data string into `buf` (NUL-terminated).
// Returns its length (>= 0), -1 when the key is absent (or not a string),
// -2 on any JNI failure, -3 when the value does not fit in `buf_cap`.
// -1 (absent) and -2 (failure) MUST stay distinct: `renderer.MetaRead` maps
// -1 to the default `gles` but -2 to "unknown", and the crash guard keeps its
// marks on unknown rather than reading a transient failure as a setting
// change (labelle-android#33 review).
// Never leaves a Java exception pending and never leaks a local ref.
// Callable from any thread (attached or not).
int labelle_android_read_renderer_meta(const void *activity_ptr, char *buf, size_t buf_cap) {
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL || buf == NULL || buf_cap == 0) return -2;
    JavaVM *vm = na->vm;
    jobject activity = na->clazz;

    int we_attached = 0;
    JNIEnv *env = labelle_android_acquire_env(vm, &we_attached);
    if (env == NULL) return -2;

    int result = -2;
    if ((*env)->PushLocalFrame(env, 16) == JNI_OK) {
        jobject pm = package_manager(env, activity);
        jclass activity_cls = (pm != NULL) ? (*env)->GetObjectClass(env, activity) : NULL;
        jmethodID get_pkg = activity_cls ? (*env)->GetMethodID(env, activity_cls, "getPackageName", "()Ljava/lang/String;") : NULL;
        jstring pkg = (get_pkg && !(*env)->ExceptionCheck(env)) ? (jstring)(*env)->CallObjectMethod(env, activity, get_pkg) : NULL;
        jclass pm_cls = (pkg && !(*env)->ExceptionCheck(env)) ? (*env)->GetObjectClass(env, pm) : NULL;
        // The (String, int) overload: deprecated from API 33 in favour of
        // the ApplicationInfoFlags one, but still present and working.
        jmethodID get_app_info = pm_cls ? (*env)->GetMethodID(env, pm_cls, "getApplicationInfo", "(Ljava/lang/String;I)Landroid/content/pm/ApplicationInfo;") : NULL;
        // Throws NameNotFoundException only if our own package vanished.
        jobject app_info = (get_app_info && !(*env)->ExceptionCheck(env)) ? (*env)->CallObjectMethod(env, pm, get_app_info, pkg, (jint)LABELLE_GET_META_DATA) : NULL;
        if (app_info != NULL && !(*env)->ExceptionCheck(env)) {
            jclass app_info_cls = (*env)->GetObjectClass(env, app_info);
            jfieldID meta_fid = app_info_cls ? (*env)->GetFieldID(env, app_info_cls, "metaData", "Landroid/os/Bundle;") : NULL;
            if (meta_fid != NULL && !(*env)->ExceptionCheck(env)) {
                jobject bundle = (*env)->GetObjectField(env, app_info, meta_fid);
                if (bundle == NULL) {
                    // No <meta-data> at all in <application>.
                    result = -1;
                } else {
                    jclass bundle_cls = (*env)->GetObjectClass(env, bundle);
                    jmethodID get_string = bundle_cls ? (*env)->GetMethodID(env, bundle_cls, "getString", "(Ljava/lang/String;)Ljava/lang/String;") : NULL;
                    jstring jkey = (get_string && !(*env)->ExceptionCheck(env)) ? (*env)->NewStringUTF(env, "labelle.renderer") : NULL;
                    jstring jval = (jkey && !(*env)->ExceptionCheck(env)) ? (jstring)(*env)->CallObjectMethod(env, bundle, get_string, jkey) : NULL;
                    if (jkey != NULL && !(*env)->ExceptionCheck(env)) {
                        if (jval == NULL) {
                            // Missing key, or a non-string value.
                            result = -1;
                        } else {
                            // The accepted values are ASCII, so modified
                            // UTF-8 is byte-identical for every valid one.
                            jsize chars = (*env)->GetStringLength(env, jval);
                            jsize bytes = (*env)->GetStringUTFLength(env, jval);
                            if (bytes < 0 || (size_t)bytes + 1 > buf_cap) {
                                result = -3;
                            } else {
                                (*env)->GetStringUTFRegion(env, jval, 0, chars, buf);
                                if (!(*env)->ExceptionCheck(env)) {
                                    buf[bytes] = 0;
                                    result = (int)bytes;
                                }
                            }
                        }
                    }
                }
            }
        }
        // Any JNI call above may have raised; clear before popping so we
        // never hand a pending exception back to the caller's thread.
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            result = -2;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        __android_log_print(ANDROID_LOG_WARN, "labelle-android", "renderer meta-data: PushLocalFrame failed; exception cleared");
    }

    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return result;
}

// `PackageManager.hasSystemFeature(name, version)` (API 24+). Returns 1 when
// the device reports the feature at `version` or above, 0 otherwise — and 0
// on any JNI failure: `auto` then falls back to GLES, the safe choice.
int labelle_android_has_system_feature(const void *activity_ptr, const char *name, int version) {
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL || name == NULL) return 0;
    JavaVM *vm = na->vm;
    jobject activity = na->clazz;

    int we_attached = 0;
    JNIEnv *env = labelle_android_acquire_env(vm, &we_attached);
    if (env == NULL) return 0;

    int has = 0;
    if ((*env)->PushLocalFrame(env, 8) == JNI_OK) {
        jobject pm = package_manager(env, activity);
        jclass pm_cls = (pm && !(*env)->ExceptionCheck(env)) ? (*env)->GetObjectClass(env, pm) : NULL;
        jmethodID has_feature = pm_cls ? (*env)->GetMethodID(env, pm_cls, "hasSystemFeature", "(Ljava/lang/String;I)Z") : NULL;
        jstring jname = (has_feature && !(*env)->ExceptionCheck(env)) ? (*env)->NewStringUTF(env, name) : NULL;
        if (jname != NULL && !(*env)->ExceptionCheck(env)) {
            jboolean r = (*env)->CallBooleanMethod(env, pm, has_feature, jname, (jint)version);
            if (!(*env)->ExceptionCheck(env)) has = r ? 1 : 0;
        }
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            has = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        __android_log_print(ANDROID_LOG_WARN, "labelle-android", "system feature: PushLocalFrame failed; exception cleared");
    }

    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return has;
}

// `ANativeActivity.internalDataPath` (the app's private files dir), or NULL.
// The crash guard (labelle-android#28) keeps its two marker files there.
const char *labelle_android_internal_data_path(const void *activity_ptr) {
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    return na != NULL ? na->internalDataPath : NULL;
}

// The running package's version code (labelle-android#28: a new app version
// resets the crash guard):
//   getPackageManager().getPackageInfo(getPackageName(), 0)
//     .getLongVersionCode()     // API 28+
//     .versionCode              // older: NoSuchMethodError -> the int field
// Writes it to `*out` and returns 0, or returns -1 on any JNI failure
// (`*out` untouched; the Zig side treats it as "unknown", never as a
// version, so a failure cannot reset the crash guard). Never leaves a Java exception pending and never leaks a
// local ref. Callable from any thread (attached or not).
int labelle_android_version_code(const void *activity_ptr, long long *out) {
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL || out == NULL) return -1;
    JavaVM *vm = na->vm;
    jobject activity = na->clazz;

    int we_attached = 0;
    JNIEnv *env = labelle_android_acquire_env(vm, &we_attached);
    if (env == NULL) return -1;

    int result = -1;
    if ((*env)->PushLocalFrame(env, 16) == JNI_OK) {
        jobject pm = package_manager(env, activity);
        jclass activity_cls = (pm != NULL && !(*env)->ExceptionCheck(env)) ? (*env)->GetObjectClass(env, activity) : NULL;
        jmethodID get_pkg = activity_cls ? (*env)->GetMethodID(env, activity_cls, "getPackageName", "()Ljava/lang/String;") : NULL;
        jstring pkg = (get_pkg && !(*env)->ExceptionCheck(env)) ? (jstring)(*env)->CallObjectMethod(env, activity, get_pkg) : NULL;
        jclass pm_cls = (pkg && !(*env)->ExceptionCheck(env)) ? (*env)->GetObjectClass(env, pm) : NULL;
        // The (String, int) overload: deprecated from API 33 in favour of
        // the PackageInfoFlags one, but still present and working.
        jmethodID get_pkg_info = pm_cls ? (*env)->GetMethodID(env, pm_cls, "getPackageInfo", "(Ljava/lang/String;I)Landroid/content/pm/PackageInfo;") : NULL;
        // Throws NameNotFoundException only if our own package vanished.
        jobject pkg_info = (get_pkg_info && !(*env)->ExceptionCheck(env)) ? (*env)->CallObjectMethod(env, pm, get_pkg_info, pkg, (jint)0) : NULL;
        if (pkg_info != NULL && !(*env)->ExceptionCheck(env)) {
            jclass pi_cls = (*env)->GetObjectClass(env, pkg_info);
            if (pi_cls != NULL && !(*env)->ExceptionCheck(env)) {
                jmethodID get_long = (*env)->GetMethodID(env, pi_cls, "getLongVersionCode", "()J");
                if (get_long != NULL && !(*env)->ExceptionCheck(env)) {
                    jlong v = (*env)->CallLongMethod(env, pkg_info, get_long);
                    if (!(*env)->ExceptionCheck(env)) {
                        *out = (long long)v;
                        result = 0;
                    }
                } else {
                    // Below API 28: NoSuchMethodError. Clear it and read the
                    // (deprecated) int field instead.
                    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
                    jfieldID vc_fid = (*env)->GetFieldID(env, pi_cls, "versionCode", "I");
                    if (vc_fid != NULL && !(*env)->ExceptionCheck(env)) {
                        jint v = (*env)->GetIntField(env, pkg_info, vc_fid);
                        if (!(*env)->ExceptionCheck(env)) {
                            *out = (long long)v;
                            result = 0;
                        }
                    }
                }
            }
        }
        // Any JNI call above may have raised; clear before popping so we
        // never hand a pending exception back to the caller's thread.
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            result = -1;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        __android_log_print(ANDROID_LOG_WARN, "labelle-android", "version code: PushLocalFrame failed; exception cleared");
    }

    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return result;
}

// The crash guard's stable rule (labelle-android#28) counts presented frames
// through labelle-bgfx's generic export (labelle-toolkit/labelle-bgfx#182):
//   uint64_t labelle_bgfx_frames_presented(void);
// looked up at RUNTIME, so labelle-android has no build dependency on
// labelle-bgfx and still links for other backends. Writes the count to
// `*out` and returns 1, or returns 0 when the symbol is not exported.
int labelle_android_frames_presented(uint64_t *out) {
    typedef uint64_t (*frames_fn)(void);
    frames_fn fn = (frames_fn)dlsym(RTLD_DEFAULT, "labelle_bgfx_frames_presented");
    if (fn == NULL || out == NULL) return 0;
    *out = fn();
    return 1;
}

// CLOCK_MONOTONIC in nanoseconds (0 if the clock is unavailable).
uint64_t labelle_android_monotonic_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

#endif /* __ANDROID__ */
