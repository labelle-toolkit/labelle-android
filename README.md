# labelle-android

Android platform package for the Labelle toolkit.

## Status

**Phase 1a–1d of the runtime extraction ([bgfx #149](https://github.com/labelle-toolkit/labelle-bgfx/issues/149)) — unreleased (no tag yet).** The package ships one Zig module, `labelle_android`, with five services the bgfx and sokol backends used to carry as per-backend copies:

| Namespace | Service | Origin |
|-----------|---------|--------|
| `launch_intent` / `intent_env` | launch-intent `LABELLE_*` extras → process env (allow-list, debuggable gate, revert on relaunch, failed-restore retry) | bgfx #139 / sokol #25 (the sokol superset) |
| `debuggable` | `isDebuggable(activity)`: is the running apk `android:debuggable`? Process-cached, fail-closed | assembler #737 |
| `relayout` | `forceWindowRelayout(activity)`: re-apply the window attributes so a stuck 1x1 restored window relayouts (UI thread only) | bgfx #127 |
| `aaudio` | the AAudio output device (`ensureStarted` / `stop` / `framesMixed`): the `labelle-audio` `DeviceSink` a backend's PCM mixer drives; PCM_I16 stereo 48 kHz. `ensureStarted` opens the stream and only *requests* the start — it never blocks on the audio server (no `AAudioStream_waitForStateChange`). A device-owned control thread logs `android: AAudio stream started (…)` once per start, on the stream's **first mixer pull** (its first data callback) — which may precede AAudio's own STARTED state flip (the legacy AudioTrack path pre-fills first), and never on `requestStart` alone. A device disconnect (headset / Bluetooth route change) is reported by the error callback and the control thread closes and reopens the stream **itself**, with no further `ensureStarted`, logging `android: AAudio stream disconnected; reopening`; a reopen that fails is retried on the control thread with exponential backoff (100 ms doubling to 5 s, ~60 s in total), then given up (one `giving up` line) until the next `ensureStarted`. Setup failures warn once per failure episode and otherwise retry silently. Pure NDK C API, links `libaaudio` | bgfx #306 |
| `video` | MediaCodec decode: `VideoDecoder` (AMediaExtractor + AMediaCodec → AImageReader YUV_420_888 on a worker thread, a ring of tightened Y/U/V planes for the backend's GPU-YUV upload) and `decodeTrack` (the mp4's audio track → 48 kHz stereo i16 `Pcm`), plus the pure, host-tested `yuv` (CPU YUV→RGBA; `Matrix` BT.601/BT.709, limited/full range — the decoder picks it from the stream's `ColorSpace`) and `planes` (row de-pad / NV12 de-interleave) helpers the desktop decoders share; pure NDK C API, links `libmediandk` | bgfx `src/video/{android,android_audio,yuv,planes}.zig` (FP #549) |

Every JNI service takes the running `ANativeActivity*` as an opaque pointer; the JNI walks (`src/jni/*.c`) read `->vm` / `->clazz` through the NDK's own header, so both backends pass what they already hold. `aaudio` declares its `MixCallback` structurally (`*const fn (out: []i16, channels: u8) void`) so the package has no dependency on labelle-audio; the consumer asserts equality at comptime. `build.zig` also exports `addAndroidSysroot` / `resolveNdk` / `nativeAppGlueDir` / `isAndroidTarget` for consumers' build scripts.

Consumers: labelle-bgfx (from the PRs that land #149 phase 1a/1b, 1c and 1d). labelle-sokol adoption is a filed follow-up; until then sokol keeps its own copies. Packaging, asset access and provider commands are still not implemented; runtime acceptance is on-device (SM-T505), not cross-compilation alone.

### Naming

- Zig package `.name = .labelle_android`; the one module is `labelle_android`.
- `plugin.labelle` `.name = "android"`: the assembler derives a plugin's module alias as `labelle_<name>` (`deps_linker.zig`, `build_files/build_zig.zig`), so `android` is the name that yields `labelle_android` with no `b.modules.put` alias. `manifest_version = 1` (the shipping CLI parses nothing higher); no commands or hooks yet — the `android` command namespace (CLI #406) is reserved for this package pending the contract decisions (CLI #411).

### Build and test

```bash
zig build test --summary all                                  # host: intent allow-list / decision, AAudio state machine (against a scripted fake), video yuv/planes/audio_track helpers, NDK-selection tests
zig build test -Dtarget=aarch64-linux-android --summary all   # Android compile-check (needs ANDROID_NDK_HOME or ANDROID_HOME)
```

The Android compile-check compiles and links every AAudio entry point (`ensureStarted`, `stop`, the data and error callbacks) through an Android-only, never-executed harness test in `src/aaudio.zig`; on the host that test is skipped and the same state machine runs against a scripted fake API.

## Planned responsibilities

- Shared Android services: intent extras, data-directory access, immersive mode, display density, and APK asset access.
- Shared lifecycle handling where appropriate, preserving backend-owned GPU/context integration and sokol's app-shell requirements.
- One manifest, asset-staging, native-symbol, and APK packaging implementation, shared by direct builds and Gradle integration.
- Package-provided Android commands and target hooks through the CLI's generic provider contract.

The existing `labelle-android-gamepad` remains a separate package unless its ownership is changed explicitly. Backend renderer code stays in its backend repository.

## Implementation references

- [Shared runtime extraction: bgfx #149](https://github.com/labelle-toolkit/labelle-bgfx/issues/149)
- [Packaging consolidation: CLI #405](https://github.com/labelle-toolkit/labelle-cli/issues/405)
- [Provider architecture: CLI #406](https://github.com/labelle-toolkit/labelle-cli/issues/406)
- [Contract decisions before implementation: CLI #411](https://github.com/labelle-toolkit/labelle-cli/issues/411)
- [APK-loaded assets: assembler #759](https://github.com/labelle-toolkit/labelle-assembler/issues/759)

Migration is breaking: consumers explicitly adopt the package and update configuration. No compatibility shims or implicit provider injection. The package manifest ships now at `manifest_version = 1` with no commands or hooks; its command/hook surface waits for the contract decisions.

Device validation must cover bgfx and sokol cold launch, background/resume, rotation, and asset access; cross-compilation alone is not runtime acceptance.
