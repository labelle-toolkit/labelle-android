// The on-screen keyboard through `labelle.android.LabelleActivity` (java/).
// The Zig side, `text_input.zig`, documents the contract.
//
// In C for the same reason as the other files here: <jni.h> declares the JNI
// vtables. Off Android this is an empty TU.
#ifdef __ANDROID__

#include <android/log.h>
#include <android/native_activity.h>
#include <jni.h>
#include <pthread.h>
#include <stdint.h>

// What the keyboard typed, oldest first: a Unicode code point, or
// LABELLE_TEXT_INPUT_BACKSPACE for one character erased. Written on the UI
// thread (the Java callbacks), drained on the app thread (`poll`). A full
// queue drops new input: the game drains it every frame.
#define LABELLE_TEXT_INPUT_BACKSPACE (-1)
#define QUEUE_CAPACITY 256
static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static int32_t queue[QUEUE_CAPACITY];
static int queue_head = 0;
static int queue_count = 0;

static void push(int32_t entry) {
    pthread_mutex_lock(&queue_lock);
    if (queue_count < QUEUE_CAPACITY) {
        queue[(queue_head + queue_count) % QUEUE_CAPACITY] = entry;
        queue_count += 1;
    }
    pthread_mutex_unlock(&queue_lock);
}

// LabelleActivity.nativeCommitText(String): UTF-16 → code points.
static void JNICALL commit_text(JNIEnv *env, jclass cls, jstring text) {
    (void)cls;
    if (text == NULL) return;
    const jsize length = (*env)->GetStringLength(env, text);
    const jchar *chars = (*env)->GetStringChars(env, text, NULL);
    if (chars == NULL) return;
    for (jsize i = 0; i < length; i++) {
        uint32_t unit = chars[i];
        if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < length && chars[i + 1] >= 0xDC00 && chars[i + 1] <= 0xDFFF) {
            unit = 0x10000 + ((unit - 0xD800) << 10) + (chars[i + 1] - 0xDC00);
            i++;
        }
        push((int32_t)unit);
    }
    (*env)->ReleaseStringChars(env, text, chars);
}

// LabelleActivity.nativeDeleteBackward(int).
static void JNICALL delete_backward(JNIEnv *env, jclass cls, jint count) {
    (void)env;
    (void)cls;
    for (jint i = 0; i < count && i < QUEUE_CAPACITY; i++) push(LABELLE_TEXT_INPUT_BACKSPACE);
}

// Copy up to `max` queued entries into `out`, oldest first; returns how many.
int labelle_android_text_input_poll(int32_t *out, int max) {
    pthread_mutex_lock(&queue_lock);
    int n = queue_count < max ? queue_count : max;
    for (int i = 0; i < n; i++) out[i] = queue[(queue_head + i) % QUEUE_CAPACITY];
    queue_head = (queue_head + n) % QUEUE_CAPACITY;
    queue_count -= n;
    pthread_mutex_unlock(&queue_lock);
    return n;
}

// 0: not tried yet, 1: the natives are registered, -1: the activity is not a
// LabelleActivity (an APK packaged before it), so there is nothing to call.
static int natives = 0;

// Show (show != 0) or hide the keyboard: `LabelleActivity.setTextInput`,
// which posts to the UI thread itself. Registers the natives on first use.
// Any thread; attaches to the VM for the call when it is not attached.
// Returns 1 when the request reached a LabelleActivity, 0 otherwise.
int labelle_android_set_text_input(const void *activity_ptr, int show) {
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL || natives < 0) return 0;
    JavaVM *vm = na->vm;
    JNIEnv *env = NULL;
    int attached = 0;
    jint got = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (got == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return 0;
        attached = 1;
    } else if (got != JNI_OK || env == NULL) {
        return 0;
    }

    int ok = 0;
    if ((*env)->PushLocalFrame(env, 4) == JNI_OK) {
        jclass cls = (*env)->GetObjectClass(env, na->clazz);
        if (cls != NULL && natives == 0) {
            const JNINativeMethod methods[] = {
                {"nativeCommitText", "(Ljava/lang/String;)V", (void *)commit_text},
                {"nativeDeleteBackward", "(I)V", (void *)delete_backward},
            };
            if ((*env)->RegisterNatives(env, cls, methods, 2) == JNI_OK) {
                natives = 1;
            } else {
                (*env)->ExceptionClear(env);
                natives = -1;
                __android_log_write(ANDROID_LOG_WARN, "labelle-android", "text input: the activity is not labelle.android.LabelleActivity; no on-screen keyboard");
            }
        }
        if (cls != NULL && natives == 1) {
            jmethodID set = (*env)->GetMethodID(env, cls, "setTextInput", "(Z)V");
            if (set != NULL) {
                (*env)->CallVoidMethod(env, na->clazz, set, (jboolean)(show != 0));
                ok = !(*env)->ExceptionCheck(env);
            }
        }
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            ok = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }
    if (attached) (*vm)->DetachCurrentThread(vm);
    return ok;
}

#endif /* __ANDROID__ */
