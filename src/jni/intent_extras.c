// Read the launch intent's string extras (labelle-bgfx#139 / labelle-sokol#25,
// shared through labelle-android since labelle-bgfx#149).
//
// `labelle run --platform=android --scene=X` launches the activity with
// `am start ... --es LABELLE_SCENE X` (labelle-cli#397), because an app the
// system starts has no environment the CLI could write into. The backend turns
// the allow-listed extras back into env vars (`intent_env.zig`, driven by
// `launch_intent.zig`) so the engine's `getenv` reads work unchanged. This is
// the JNI half:
//   activity.getIntent().getStringExtra(key)
//
// It lives in C rather than Zig because <jni.h> already declares the
// JNINativeInterface / JNIInvokeInterface vtables; hand-rolling those ordered
// function-pointer slots in Zig would be a silent-wrong-field hazard (same
// rationale as labelle-android-gamepad's `android_gamepad_jni.c`). Off Android
// this is an empty TU; `build.zig` only compiles it for Android anyway.
#ifdef __ANDROID__

#include <android/native_activity.h>
#include <jni.h>
#include <stddef.h>
#include <string.h>

// Resolve a JNIEnv for the calling thread. sokol's `sokol_main()` runs on the
// UI thread, which the VM already has attached; bgfx's `android_main` runs on
// the glue's own thread, which native_app_glue never attaches. Attach if
// needed and report it, so the caller detaches only what WE attached
// (detaching a thread someone else attached would tear down their env).
JNIEnv *labelle_android_acquire_env(JavaVM *vm, int *we_attached) {
    JNIEnv *env = NULL;
    *we_attached = 0;
    jint rc = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
        *we_attached = 1;
    } else if (rc != JNI_OK || env == NULL) {
        return NULL;
    }
    return env;
}

// For each of the `count` keys, copy its string extra (NUL-terminated) into
// `buf` back to back and store its length in `lens[i]`; -1 means the extra is
// absent (or not a string), -2 that it did not fit in what was left of `buf`
// or holds a NUL (which setenv would silently truncate at). `activity_ptr` is
// the running `ANativeActivity*`. Returns 1 when the intent was read, 0 on any
// JNI failure (then `lens` is all -1: nothing to apply). Never leaves a Java
// exception pending and never leaks a local ref.
int labelle_android_read_intent_extras(const void *activity_ptr, const char *const *keys, int count,
                                       char *buf, size_t buf_cap, int *lens) {
    if (lens == NULL || count < 0) return 0;
    for (int i = 0; i < count; i++) lens[i] = -1;
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL || keys == NULL || buf == NULL) return 0;
    JavaVM *vm = na->vm;
    jobject activity = na->clazz;

    int we_attached = 0;
    JNIEnv *env = labelle_android_acquire_env(vm, &we_attached);
    if (env == NULL) return 0;

    int ok = 0;
    // Room for the activity class, intent, its class, the String class, the
    // "UTF-8" charset name and, per key, the key string, the value string and
    // its UTF-8 byte array; the frame hands them all back in one pop.
    if ((*env)->PushLocalFrame(env, 6 + 3 * count) == JNI_OK) {
        jclass activity_cls = (*env)->GetObjectClass(env, activity);
        jmethodID get_intent = activity_cls ? (*env)->GetMethodID(env, activity_cls, "getIntent", "()Landroid/content/Intent;") : NULL;
        // A launcher-icon launch still has an intent, just no extras; null only
        // if something unusual cleared it. Either way "no extras" is the answer.
        jobject intent = (get_intent && !(*env)->ExceptionCheck(env)) ? (*env)->CallObjectMethod(env, activity, get_intent) : NULL;
        // So a null intent (the call itself succeeded) is a successful read
        // with every `lens[i]` still -1, which lets the Zig side revert values
        // an earlier launch set; only a JNI failure reports 0.
        if (get_intent != NULL && intent == NULL && !(*env)->ExceptionCheck(env)) ok = 1;
        if (!(*env)->ExceptionCheck(env) && intent != NULL) {
            jclass intent_cls = (*env)->GetObjectClass(env, intent);
            jmethodID get_extra = intent_cls ? (*env)->GetMethodID(env, intent_cls, "getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;") : NULL;
            // Values are encoded with `String.getBytes("UTF-8")`, NOT
            // `GetStringUTFChars`: the latter yields JNI *modified* UTF-8
            // (supplementary characters as CESU-8 surrogate pairs, U+0000 as
            // C0 80), which would not match a UTF-8 scene name or path.
            jclass string_cls = get_extra ? (*env)->FindClass(env, "java/lang/String") : NULL;
            jmethodID get_bytes = string_cls ? (*env)->GetMethodID(env, string_cls, "getBytes", "(Ljava/lang/String;)[B") : NULL;
            jstring utf8_name = get_bytes ? (*env)->NewStringUTF(env, "UTF-8") : NULL;
            if (get_extra != NULL && utf8_name != NULL && !(*env)->ExceptionCheck(env)) {
                ok = 1;
                size_t used = 0;
                for (int i = 0; i < count && ok; i++) {
                    jstring jkey = (*env)->NewStringUTF(env, keys[i]);
                    if (jkey == NULL || (*env)->ExceptionCheck(env)) {
                        ok = 0;
                        break;
                    }
                    // getStringExtra answers null for a missing key and for an
                    // extra of another type (`--ei`); both read as "absent".
                    jstring jval = (jstring)(*env)->CallObjectMethod(env, intent, get_extra, jkey);
                    if ((*env)->ExceptionCheck(env)) {
                        ok = 0;
                        break;
                    }
                    if (jval != NULL) {
                        jbyteArray bytes = (jbyteArray)(*env)->CallObjectMethod(env, jval, get_bytes, utf8_name);
                        if (bytes == NULL || (*env)->ExceptionCheck(env)) {
                            ok = 0;
                            break;
                        }
                        jsize n = (*env)->GetArrayLength(env, bytes);
                        size_t len = n > 0 ? (size_t)n : 0;
                        if (len + 1 <= buf_cap - used) {
                            (*env)->GetByteArrayRegion(env, bytes, 0, n, (jbyte *)(buf + used));
                            if ((*env)->ExceptionCheck(env)) {
                                ok = 0;
                                break;
                            }
                            buf[used + len] = 0;
                            // An embedded NUL cannot live in an env var:
                            // report it (-2) rather than silently truncating.
                            if (memchr(buf + used, 0, len) != NULL) {
                                lens[i] = -2;
                            } else {
                                lens[i] = (int)len;
                                used += len + 1;
                            }
                        } else {
                            lens[i] = -2;
                        }
                    }
                }
            }
        }
        // Never hand a pending exception back to the caller's thread.
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            ok = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }

    if (!ok) {
        for (int i = 0; i < count; i++) lens[i] = -1;
    }
    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return ok;
}

#endif /* __ANDROID__ */
