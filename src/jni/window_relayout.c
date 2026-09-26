// Force a stuck restored window to relayout (labelle-bgfx#127; shared through
// labelle-android since labelle-bgfx#149).
//
// On resume Android can hand a landscape-locked NativeActivity a restored
// ANativeWindow that is 1x1 and never grows: the window manager already holds
// the full-size frame (dumpsys: mFrame 2000x1200, HAS_DRAWN) but the resize
// never reaches the app's surface, so no APP_CMD_WINDOW_RESIZED arrives and
// the compositor stretches a 1x1 buffer over the screen (a solid frame). Seen
// on an SM-T505 resuming over the portrait launcher; immersive mode makes it
// far more likely (7/15 resumes vs 1/15 without).
//
// Re-applying the window's own attributes marks them changed, so the next
// traversal calls relayoutWindow and the surface is resized to the frame the
// window manager holds, which then arrives as APP_CMD_WINDOW_RESIZED.
//
// In C for the same reason as debuggable.c: <jni.h> already declares the JNI
// vtables. Off Android this is an empty TU.
#ifdef __ANDROID__

#include <android/log.h>
#include <android/native_activity.h>
#include <jni.h>
#include <stddef.h>

// getWindow().setAttributes(getWindow().getAttributes()). MUST run on the UI
// thread (it drives ViewRootImpl), whose JNIEnv is already attached — this
// deliberately does NOT attach: a detached caller is on the wrong thread.
// `activity_ptr` is the running `ANativeActivity*`. Returns 1 on success, 0 on
// any JNI failure.
int labelle_android_force_window_relayout(const void *activity_ptr) {
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL) return 0;
    JavaVM *vm = na->vm;
    jobject activity = na->clazz;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK || env == NULL) return 0; // UI thread is attached
    int ok = 0;
    if ((*env)->PushLocalFrame(env, 8) == JNI_OK) {
        jclass activity_cls = (*env)->GetObjectClass(env, activity);
        jmethodID get_window = activity_cls ? (*env)->GetMethodID(env, activity_cls, "getWindow", "()Landroid/view/Window;") : NULL;
        jobject window = get_window ? (*env)->CallObjectMethod(env, activity, get_window) : NULL;
        if (!(*env)->ExceptionCheck(env) && window != NULL) {
            jclass window_cls = (*env)->GetObjectClass(env, window);
            jmethodID get_attrs = window_cls ? (*env)->GetMethodID(env, window_cls, "getAttributes", "()Landroid/view/WindowManager$LayoutParams;") : NULL;
            jmethodID set_attrs = window_cls ? (*env)->GetMethodID(env, window_cls, "setAttributes", "(Landroid/view/WindowManager$LayoutParams;)V") : NULL;
            jobject attrs = get_attrs ? (*env)->CallObjectMethod(env, window, get_attrs) : NULL;
            if (!(*env)->ExceptionCheck(env) && attrs != NULL && set_attrs != NULL) {
                (*env)->CallVoidMethod(env, window, set_attrs, attrs);
                ok = !(*env)->ExceptionCheck(env);
            }
        }
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            ok = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        // PushLocalFrame failed (OutOfMemoryError pending). This is the UI
        // thread: a pending exception left here would poison its next JNI
        // call, so clear it like every other failure above.
        (*env)->ExceptionClear(env);
        __android_log_print(ANDROID_LOG_WARN, "labelle-android", "window relayout: PushLocalFrame failed; exception cleared, relayout not requested");
    }
    return ok;
}

#endif /* __ANDROID__ */
