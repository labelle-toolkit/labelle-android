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
| `video` | MediaCodec decode: `VideoDecoder` (AMediaExtractor + AMediaCodec → AImageReader YUV_420_888 on a worker thread, a ring of tightened Y/U/V planes for the backend's GPU-YUV upload) and `decodeTrack` (the mp4's audio track → 48 kHz stereo i16 `Pcm`: multichannel layouts are downmixed ITU-R BS.775-style — L' = L + 0.707·C + 0.707·Ls, R' likewise, LFE dropped, normalised so it cannot clip; mono duplicated, stereo untouched; the layout comes from the output format's `channel-mask`, else the channel count's default — and the PCM is placed on the media timeline from the track's first presentation time: silence prepended when the audio starts late, the head trimmed when it starts early, so PCM frame 0 is media time 0, the player's clock origin), plus the pure, host-tested `yuv` (CPU YUV→RGBA; `Matrix` BT.601/BT.709, limited/full range — the decoder picks it from the stream's `ColorSpace`) and `planes` (row de-pad / NV12 de-interleave) helpers the desktop decoders share; pure NDK C API, links `libmediandk` | bgfx `src/video/{android,android_audio,yuv,planes}.zig` (FP #549) |

Every JNI service takes the running `ANativeActivity*` as an opaque pointer; the JNI walks (`src/jni/*.c`) read `->vm` / `->clazz` through the NDK's own header, so both backends pass what they already hold. `aaudio` declares its `MixCallback` structurally (`*const fn (out: []i16, channels: u8) void`) so the package has no dependency on labelle-audio; the consumer asserts equality at comptime. `build.zig` also exports `addAndroidSysroot` / `resolveNdk` / `nativeAppGlueDir` / `isAndroidTarget` for consumers' build scripts.

Consumers: labelle-bgfx (from the PRs that land #149 phase 1a/1b, 1c and 1d). labelle-sokol adoption is a filed follow-up; until then sokol keeps its own copies. Packaging and asset access are still not implemented (the provider below ships `doctor` only so far); runtime acceptance is on-device (SM-T505), not cross-compilation alone.

### Naming

- Zig package `.name = .labelle_android`; the one module is `labelle_android`.
- `plugin.labelle` `.name = "android"`: the assembler derives a plugin's module alias as `labelle_<name>` (`deps_linker.zig`, `build_files/build_zig.zig`), so `android` is the name that yields `labelle_android` with no `b.modules.put` alias. `manifest_version = 2`: the package is also the `android` CLI provider (see below). The `.plugins` name, the registry package and `.provider_config .package` must all be `android`.

### Build and test

```bash
zig build test --summary all                                  # host: intent allow-list / decision, AAudio state machine (against a scripted fake), video yuv/planes/audio_track helpers, NDK-selection tests
zig build test -Dtarget=aarch64-linux-android --summary all   # Android compile-check (needs ANDROID_NDK_HOME or ANDROID_HOME)
```

**Supported ABIs: 64-bit only** — `arm64-v8a` (`aarch64-linux-android`) and `x86_64` (`x86_64-linux-android`, emulator). 32-bit `armeabi-v7a` (`arm-linux-androideabi`) and `x86` (`i686`) are not supported: the labelle CLI builds and packages only `arm64-v8a` / `x86_64` (`AbiArch`, `--all-abis`), the bgfx/sokol backends accept only `-Dandroid_arch=arm64|x86_64`, and shipped APKs carry only `lib/arm64-v8a`. A 32-bit Android target fails the build with a clear "supports 64-bit Android only" message (`build.zig` for this package's own steps, a `@compileError` in `src/root.zig` for consumers) rather than the 64-bit-atomics errors `aaudio` would otherwise raise ([#10](https://github.com/labelle-toolkit/labelle-android/issues/10)); CI asserts that failure mode.

```bash
zig build test-provider --summary all       # provider host tool: wire decoder + vendored fixtures, settings schema, invocation matrix, doctor against a fake ANDROID_HOME
zig build install-provider                  # zig-out/bin/labelle-android
```

The Android compile-check compiles and links every AAudio entry point (`ensureStarted`, `stop`, the data and error callbacks) through an Android-only, never-executed harness test in `src/aaudio.zig`; on the host that test is skipped and the same state machine runs against a scripted fake API.

## CLI provider

`plugin.labelle` declares the `android` provider for labelle-cli's provider contract ([CLI #405](https://github.com/labelle-toolkit/labelle-cli/issues/405)): namespace `android`, target `android`, `command_contract = ">=1.2.0 <1.3.0"`. Every command and hook runs one host executable, `bin/labelle-android` (`tools/main.zig`, built by `zig build install-provider`), which strictly decodes the context the CLI passes in `LABELLE_CONTEXT` (`tools/contract.zig`, vendored from the CLI with its fixtures) and dispatches on `(kind, id, step, phase)`. Any combination the manifest does not declare is refused. The CLI builds the tool with `zig build --system`, which disables dependency fetching, so `tools/` uses `std` only.

| Command | What it does |
|---|---|
| `labelle android doctor` | Checks the Android SDK (adb, build-tools `aapt`/`zipalign`/`apksigner`, `android.jar` for the configured target SDK), the NDK (sysroot, `llvm-strip`) and the JDK (`jar`, `keytool`). Exits non-zero when a required tool is missing. |

**Run it inside a project** that pins this package: the CLI dispatches provider commands only from a project's `.plugins`, so `labelle android doctor` outside a project no longer works (the CLI's projectless dispatch is a later phase). The packaging hooks (`package` after `build`, `deploy` replacing `run`, `bundle` replacing `bundle`) and the `run`/`deploy` commands arrive in the next release; until then `labelle bundle --platform=android` reports that no provider replaces the bundle step.

Needs a labelle-cli with provider contract 1.2.0 ([CLI #440](https://github.com/labelle-toolkit/labelle-cli/pull/440), on `development`) that no longer reserves the `android` namespace for its legacy built-in `labelle android` subcommand (#405 PR 3). CI drives the real CLI through `tests/provider/e2e.py`; until PR 3 lands it builds the pinned CLI with `tests/provider/unreserve-android.sh`, which makes exactly those two edits.

### Project setup

```zig
// project.labelle
.plugins = .{
    .{ .name = "android", .repo = "github.com/labelle-toolkit/labelle-android", .version = "0.2.0" },
},
.provider_config = .{ .{ .package = "android", .file = "providers/android.json" } },
```

### `providers/android.json` (schema v1)

```json
{
  "schema_version": 1,
  "package_name": "com.labelle.flying_platform",
  "app_name": "Flying Platform",
  "min_sdk_version": 28,
  "target_sdk_version": 34,
  "orientation": "landscape",
  "debuggable": false,
  "version_name": "1.0",
  "abis": ["arm64-v8a"],
  "signing": { "keystore": "keys/release.jks", "store_password": "env:FP_KS_PASS",
               "key_alias": "labelle-release", "key_password": "env:FP_KEY_PASS" },
  "deploy": { "repo": "owner/name", "channel": "stable" }
}
```

| Key | Required | Default | Rule |
|---|---|---|---|
| `schema_version` | yes | | `1` |
| `package_name` | yes | | `[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+` |
| `app_name` | no | project `.title` | non-empty, no control characters |
| `min_sdk_version` | no | `28` | at least 28 (the runtime module uses API 28 MediaCodec entry points) |
| `target_sdk_version` | no | `34` | at least `min_sdk_version` |
| `orientation` | no | `"all"` | `portrait`, `landscape`, `sensor_landscape`, `all` |
| `debuggable` | no | `false` | on-device verification only; never ship it |
| `version_name` | no | `"1.0"` | non-empty; `versionCode` comes from `labelle bundle --build-number` |
| `abis` | no | `["arm64-v8a"]` | exactly `["arm64-v8a"]` in v1 |
| `signing` | no | debug keystore | `store_password`/`key_password` must be `env:VAR` or `file:PATH` (apksigner's forms); a `pass:` literal is rejected so no secret is committed |
| `deploy` | no | | `repo` is `owner/name`; `channel` is `stable`, `staging`, `preview` or `internal` |

The parse is strict: unknown keys, duplicate keys and wrong types are errors, and the file is validated before the provider does anything. `immersive_mode` and `load_assets_from_apk` are rejected here: the assembler reads them at generate time, so they stay in `project.labelle .android`. There is no `studio` block: `labelle android studio` is not part of this release.

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

Migration is breaking: consumers explicitly adopt the package and update configuration. No compatibility shims or implicit provider injection.

Device validation must cover bgfx and sokol cold launch, background/resume, rotation, and asset access; cross-compilation alone is not runtime acceptance.
