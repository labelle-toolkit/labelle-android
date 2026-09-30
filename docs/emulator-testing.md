# Android emulator testing

A recipe for running a labelle game on the Android emulator, including on Vulkan with the Khronos validation layer. It was worked out on a macOS (Apple Silicon) host during [labelle-bgfx#172](https://github.com/labelle-toolkit/labelle-bgfx/issues/172)'s P0 and checked independently on Windows.

Placeholders: `<avd>` is your AVD's name and `<pkg>` is the app's `package_name` from `providers/android.json`.

## 1. Use a rootable `google_apis` image

Use a **`google_apis`** system image, **not** `google_apis_playstore`:

- On the Play Store image, bgfx's Vulkan renderer crashed during `bgfx.init` (emulator 35.6.11) or hung there (37.1.11).
- The Play Store image is a `user` build and can't be rooted, so `debuggerd`, tombstones and `simpleperf` are unavailable.

On the `google_apis` image, the same unmodified build runs on Vulkan end to end.

Check that the image is available, then install it:

```sh
sdkmanager --list | grep "system-images;android-36;google_apis;arm64-v8a"
sdkmanager "system-images;android-36;google_apis;arm64-v8a"
```

Use the **`arm64-v8a`** image. The APK this provider packages carries only `lib/arm64-v8a` (`abis` accepts only `["arm64-v8a"]` in schema v1), so it can't start on an `x86_64` guest. On an Apple Silicon host the arm64 image runs natively.

On an Intel or AMD host, an arm64 image needs ARM translation, which isn't supported or tested here. The Windows check in labelle-bgfx#172 used an `x86_64` AVD with a hand-made APK: it **built `libgame.so` for x86_64** (`x86_64-linux-android`), moved that library into `lib/x86_64`, and re-aligned and re-signed the APK by hand. Moving the arm64 `libgame.so` into `lib/x86_64` doesn't work; the library itself has to be built for x86_64. That's a test-only workaround and unsupported.

Create a tablet-sized AVD (1200×2000 at 240 dpi with 4 GB of RAM, which is close to the SM-T505 test tablet):

```sh
avdmanager create avd -n <avd> -k "system-images;android-36;google_apis;arm64-v8a"
```

Then set these keys in `~/.android/avd/<avd>.avd/config.ini`:

```ini
hw.lcd.width = 1200
hw.lcd.height = 2000
hw.lcd.density = 240
hw.ramSize = 4096M
hw.gpu.enabled = yes
hw.gpu.mode = host
```

## 2. Start the emulator

Use emulator **37.1.11 or newer**:

```sh
emulator -version
```

Start it with the host GPU. Also pass `-crash-report-mode never`: without it, a pending crash report from an earlier emulator crash opens a consent dialog that blocks boot.

```sh
emulator -avd <avd> -gpu host -crash-report-mode never
```

## 3. Root, and check the guest

```sh
adb root
adb shell getprop ro.build.type
```

`ro.build.type` should print `userdebug`. Root gives you `debuggerd -b <pid>` (stacks of a hung process), tombstones under `/data/tombstones` and `simpleperf`.

Check the guest's Vulkan driver and version:

```sh
adb shell cmd gpu vkjson | grep -m1 deviceName
adb shell pm list features | grep vulkan.version
```

On an M1 Max host the device is `Apple M1 Max` (gfxstream over MoltenVK) and the feature is `android.hardware.vulkan.version=4206592` (`0x403000`, Vulkan 1.3). The `auto` renderer setting checks that same feature (see [Choosing a renderer](renderer.md)).

## 4. Why ASTC needs Vulkan on the emulator

On a macOS host, the emulator's GLES runs on the host's desktop OpenGL 4.1, which has no ASTC. An ASTC-only Android build can't load its atlases there under GLES.

Under Vulkan, ASTC works natively: bgfx reports every ASTC format as `TEXTURE_2D`, and the atlases sample correctly. **Use the Vulkan renderer for ASTC builds on the emulator.** Set `"renderer": "vulkan"` in a local `providers/android.json`, or use the launch override below.

## 5. Launch with a renderer override

In a **debuggable** build (`"debuggable": true` in `providers/android.json`), a launch extra overrides the renderer. Clear the log first, so the checks below only see this launch:

```sh
adb logcat -c
adb shell am start -S -n <pkg>/android.app.NativeActivity --es LABELLE_BGFX_RENDERER vulkan
```

Use `gles` for GLES. A non-debuggable build ignores the extra. A later launch without the extra goes back to the provider setting. The extra also bypasses the Vulkan crash guard, which otherwise switches the next launch to GLES after an early force-stop (see [Crash guard](renderer.md#crash-guard)). Confirm which renderer started:

```sh
adb logcat -d -s labelle | grep -E 'renderer: (gles|vulkan)|bgfx: renderer|crash guard'
```

See [Choosing a renderer](renderer.md#log-lines) for what those lines mean.

## 6. Vulkan validation layer, without root

This needs a **debuggable** APK.

1. Download `libVkLayer_khronos_validation.so` for your ABI from the [Khronos `Vulkan-ValidationLayers` releases](https://github.com/KhronosGroup/Vulkan-ValidationLayers/releases) (the `android-binaries` archive). P0 used 1.4.363.0.
2. Copy it into the app's data directory with `run-as`:

   ```sh
   adb push libVkLayer_khronos_validation.so /data/local/tmp/
   adb shell run-as <pkg> cp /data/local/tmp/libVkLayer_khronos_validation.so .
   ```

3. Enable the GPU debug layer for the app:

   ```sh
   adb shell settings put global enable_gpu_debug_layers 1
   adb shell settings put global gpu_debug_app <pkg>
   adb shell settings put global gpu_debug_layers VK_LAYER_KHRONOS_validation
   ```

4. **Required on the emulator:** turn off the layer's handle wrapping.

   ```sh
   adb shell setprop debug.vulkan.khronos_validation.unique_handles false
   ```

   With handle wrapping on (the default), the emulator's gfxstream driver crashes in `vkUpdateDescriptorSets` during gameplay (`get_host_u64_VkBuffer` ← `reservedmarshal_VkWriteDescriptorSet`). With it off, validation stays active through gameplay. The property resets when the emulator restarts, so set it again after each boot. Real devices don't need it.

5. Launch the app as in section 5 (which clears the log first), then check that the loader picked up the layer:

   ```sh
   adb logcat -d -s vulkan | grep 'Loaded layer'
   ```

   It should print `Loaded layer VK_LAYER_KHRONOS_validation`. Validation messages appear in logcat.

To turn the layer off again:

```sh
adb shell settings delete global enable_gpu_debug_layers
adb shell settings delete global gpu_debug_app
adb shell settings delete global gpu_debug_layers
```

## 7. Check colours numerically

**Don't trust your eyes for colour.** On the emulator, bgfx's Vulkan output had red and blue swapped ([labelle-bgfx#177](https://github.com/labelle-toolkit/labelle-bgfx/issues/177)), and a warm-toned sky still looks plausible. Sample the same pixel under Vulkan and GLES, on the same build and scene, and compare the numbers.

Take a raw screenshot, then read one pixel (here x=1000, y=667, which is sky on a portrait 1200×2000 AVD):

```sh
adb exec-out screencap > vulkan.raw
python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); w,h,f=struct.unpack_from("<3I",d); x,y=int(sys.argv[2]),int(sys.argv[3]); o=16+(y*w+x)*4; print(sys.argv[1], (x,y), tuple(d[o:o+3]))' vulkan.raw 1000 667
```

The raw format is a 16-byte header (width, height, format, colour space) followed by RGBA8 pixels. Coordinates are in the device's current orientation. Repeat with `--es LABELLE_BGFX_RENDERER gles` into `gles.raw`, and compare the two. The production gate allows ±6 per channel.

For example, P0 sampled the menu sky as `(100, 174, 217)` on GLES and `(213, 193, 139)` under Vulkan on the emulator. That's a red/blue swap, not a match.

## 8. Gotchas

- **Letterboxing.** Android 16 letterboxes landscape-locked apps on large screens. On a portrait AVD, a landscape game draws in a band with black bars above and below it. That's expected. Rotate the emulator if you need the full screen.
- **"Viewing full screen" prompt.** The first launch of an immersive app shows this prompt. The game doesn't start (`gameInit` doesn't run) until you dismiss it, so a first launch can look hung.
- **Crash dialog at boot.** Always pass `-crash-report-mode never` (section 2).
- **Validation crash in `vkUpdateDescriptorSets`.** Set `unique_handles false` again after every emulator boot (section 6).
