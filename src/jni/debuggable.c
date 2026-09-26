// Is the RUNNING apk marked `android:debuggable`? (labelle-assembler#737;
// shared through labelle-android since labelle-bgfx#149.)
//
// The generated Android main reads verification knobs from a `labelle_env`
// file in the app's own internal data dir, and the shell honours the
// `LABELLE_SCREENSHOT_*` launch-intent extras. Both must be gated on the
// process's OWN `ApplicationInfo.FLAG_DEBUGGABLE` (see `debuggable.zig`).
//
// There is no NDK C API for that flag, so this is the JNI walk:
//   activity.getApplicationInfo().flags & FLAG_DEBUGGABLE
//
// In C for the same reason as intent_extras.c: <jni.h> already declares the
// JNI vtables. Off Android this is an empty TU.
#ifdef __ANDROID__

#include <android/log.h>
#include <android/native_activity.h>
#include <jni.h>
#include <stddef.h>

// android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE. A platform constant
// since API 1; spelled out here because the NDK exposes no header for it.
#define LABELLE_FLAG_DEBUGGABLE 0x00000002

// intent_extras.c: attach-if-detached, reporting what we attached.
JNIEnv *labelle_android_acquire_env(JavaVM *vm, int *we_attached);

// `activity_ptr` is the running `ANativeActivity*` (its `vm` and `clazz` are
// read here). Returns 1 (debuggable), 0 (not), or 0 on any JNI failure — fail
// CLOSED: an unanswerable question must not enable a verification channel.
// Callable from any thread (attached or not).
int labelle_android_app_is_debuggable(const void *activity_ptr) {
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL) return 0;
    JavaVM *vm = na->vm;
    jobject activity = na->clazz;

    int we_attached = 0;
    JNIEnv *env = labelle_android_acquire_env(vm, &we_attached);
    if (env == NULL) return 0;

    int debuggable = 0;
    // PushLocalFrame bounds the local refs below: the walk allocates a few and
    // this returns them all in one call, so a repeated query (it is cached on
    // the Zig side, but cheap insurance) cannot leak the local-ref table.
    if ((*env)->PushLocalFrame(env, 8) == JNI_OK) {
        jclass activity_cls = (*env)->GetObjectClass(env, activity);
        // android.content.Context.getApplicationInfo()
        jmethodID get_app_info = activity_cls ? (*env)->GetMethodID(env, activity_cls, "getApplicationInfo", "()Landroid/content/pm/ApplicationInfo;") : NULL;
        jobject app_info = (get_app_info && !(*env)->ExceptionCheck(env)) ? (*env)->CallObjectMethod(env, activity, get_app_info) : NULL;
        if (!(*env)->ExceptionCheck(env) && app_info != NULL) {
            jclass app_info_cls = (*env)->GetObjectClass(env, app_info);
            jfieldID flags_fid = app_info_cls ? (*env)->GetFieldID(env, app_info_cls, "flags", "I") : NULL;
            if (flags_fid != NULL && !(*env)->ExceptionCheck(env)) {
                jint flags = (*env)->GetIntField(env, app_info, flags_fid);
                debuggable = (flags & LABELLE_FLAG_DEBUGGABLE) ? 1 : 0;
            }
        }
        // Any JNI lookup above may have raised; clear before popping so we
        // never hand a pending exception back to the caller's thread.
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            debuggable = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        // PushLocalFrame failed (OutOfMemoryError pending): clear it so the
        // caller's thread is not poisoned; fail closed (`debuggable` stays 0).
        (*env)->ExceptionClear(env);
        __android_log_print(ANDROID_LOG_WARN, "labelle-android", "debuggable: PushLocalFrame failed; exception cleared, answering not-debuggable");
    }

    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return debuggable;
}

#endif /* __ANDROID__ */
