// Finish the running NativeActivity and end the process once it is destroyed
// (moca-tecnologia/flying-platform-labelle#979). The Zig side, `activity.zig`,
// owns the once-guard and documents the calling contract and why it is safe.
//
// In C for the same reason as the other files here: <android/native_activity.h>
// owns the `ANativeActivity` / `ANativeActivityCallbacks` layout. Off Android
// this is an empty TU.
#ifdef __ANDROID__

#include <android/log.h>
#include <android/native_activity.h>
#include <stddef.h>
#include <unistd.h>

// The glue's own `onDestroy` (android_native_app_glue.c installs it in
// `ANativeActivity_onCreate`), saved when the hook is installed.
static void (*glue_on_destroy)(ANativeActivity *) = NULL;
// The activity whose `onDestroy` is hooked. Callbacks are per activity
// instance, so another instance in the same process (labelle-bgfx#143) keeps
// the glue's callback; the check below is belt and braces.
static ANativeActivity *finishing = NULL;

// Runs on the UI thread. The glue's `onDestroy` posts APP_CMD_DESTROY and
// BLOCKS until `android_main` has returned (the backend's normal destroy
// teardown), so by the time it returns the game loop is gone. Then end the
// process: see `activity.zig` for why, and why `_exit` rather than `exit`.
static void on_destroy_then_exit(ANativeActivity *na) {
    if (glue_on_destroy != NULL) glue_on_destroy(na);
    if (na != finishing) return;
    __android_log_write(ANDROID_LOG_INFO, "labelle", "android: activity finished after a quit request; ending the process");
    _exit(0);
}

// Install the destroy hook, then ask for the finish. The caller (`activity.zig`)
// guarantees this runs at most once per process, on the glue's app thread,
// while the activity still has its window — the contract that orders these
// writes before the UI thread's read of `callbacks->onDestroy` (see
// `activity.zig`). Returns 1 when the finish was requested, 0 when the
// activity has no callbacks table (nothing was touched).
int labelle_android_finish_activity(void *activity_ptr) {
    ANativeActivity *na = (ANativeActivity *)activity_ptr;
    if (na == NULL || na->callbacks == NULL) return 0;
    finishing = na;
    glue_on_destroy = na->callbacks->onDestroy;
    na->callbacks->onDestroy = on_destroy_then_exit;
    __android_log_write(ANDROID_LOG_INFO, "labelle", "android: quit requested; finishing the activity");
    ANativeActivity_finish(na);
    return 1;
}

#endif
