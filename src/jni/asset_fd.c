// Open a bundled APK asset as a file descriptor (labelle-bgfx#168). The Zig
// side, `assets.zig`, owns the name checks and documents the contract.
//
// In C for the same reason as the other files here: <android/native_activity.h>
// owns the `ANativeActivity` layout, so `assetManager` is read by name rather
// than by a hand-counted field index. Off Android this is an empty TU.
#ifdef __ANDROID__

#include <android/asset_manager.h>
#include <android/native_activity.h>
#include <stddef.h>
#include <stdint.h>

// Returns a descriptor of the APK with the asset's byte range in `*start` /
// `*len`, or -1. The descriptor is independent of the AAsset (the NDK dup's
// it), so the AAsset is closed here and the caller owns only the fd.
int labelle_android_open_asset_fd(void *activity_ptr, const char *name, int64_t *start, int64_t *len) {
    ANativeActivity *na = (ANativeActivity *)activity_ptr;
    if (na == NULL || na->assetManager == NULL || name == NULL) return -1;
    AAsset *asset = AAssetManager_open(na->assetManager, name, AASSET_MODE_STREAMING);
    if (asset == NULL) return -1;
    off64_t s = 0;
    off64_t l = 0;
    // -1 for a compressed entry: the APK must store the asset uncompressed.
    int fd = AAsset_openFileDescriptor64(asset, &s, &l);
    AAsset_close(asset);
    if (fd < 0) return -1;
    *start = s;
    *len = l;
    return fd;
}

#endif
