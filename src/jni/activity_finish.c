// Finish the running NativeActivity and end the process once it is destroyed
// (moca-tecnologia/flying-platform-labelle#979). The Zig side is
// `activity.zig`; read it for the why.
//
// In C for the same reason as the other files here: <android/native_activity.h>
// owns the `ANativeActivity` / `ANativeActivityCallbacks` layout. Off Android
// this is an empty TU.
#ifdef __ANDROID__

#include <android/log.h>
#include <android/native_activity.h>
#include <stdatomic.h>
#include <stddef.h>
#include <unistd.h>

// The glue's own `onDestroy` (android_native_app_glue.c installs it in
// `ANativeActivity_onCreate`), saved when the hook is installed.
static void (*glue_on_destroy)(ANativeActivity *) = NULL;
// The activity whose `onDestroy` is hooked. A LATER activity instance in the
// same process (labelle-bgfx#143) keeps the glue's callback, so only a
// finished activity's destroy ends the process.
static ANativeActivity *finishing = NULL;
static atomic_flag requested = ATOMIC_FLAG_INIT;

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

// Returns 1 when this call finished the activity, 0 when it did nothing (no
// activity, or a finish was already requested in this process).
int labelle_android_finish_activity(void *activity_ptr) {
    ANativeActivity *na = (ANativeActivity *)activity_ptr;
    if (na == NULL || na->callbacks == NULL) return 0;
    if (atomic_flag_test_and_set(&requested)) return 0;
    // Hook BEFORE asking for the finish: `ANativeActivity_finish` only posts a
    // message to the UI thread, which is where `onDestroy` later runs, and the
    // post orders these stores before it. The glue never rewrites this slot
    // after onCreate, so saving and replacing it here does not race it.
    finishing = na;
    glue_on_destroy = na->callbacks->onDestroy;
    na->callbacks->onDestroy = on_destroy_then_exit;
    __android_log_write(ANDROID_LOG_INFO, "labelle", "android: quit requested; finishing the activity");
    ANativeActivity_finish(na);
    return 1;
}

#endif
