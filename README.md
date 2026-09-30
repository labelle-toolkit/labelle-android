# labelle-android

Android platform package for the Labelle toolkit.

## Status

**v0.2.x: the `android` CLI provider** (v0.2.0 shipped it; v0.2.1 streams the tool's stdout/stderr so output redirected to a file stays whole, cli#446). What it carries:

- **Provider shipped:** `labelle android doctor`, `labelle android run`, `labelle android deploy`, and the `package` / `deploy` / `bundle` target hooks behind `labelle build|run|bundle --platform=android` ([CLI provider](#cli-provider)).
- **Not included:** `labelle android studio` (the Android Studio / Gradle project export).
- **bgfx only:** the packager is verified end to end on labelle-bgfx; sokol is tracked in [#14](https://github.com/labelle-toolkit/labelle-android/issues/14).
- **Projectless `doctor` needs a project:** the CLI dispatches provider commands only from a project's `.plugins`, so run `labelle android doctor` inside a project that pins this package.
- **Requires labelle-cli ≥ v2.0.0**, the release that removes the CLI's built-in Android support ([CLI #405](https://github.com/labelle-toolkit/labelle-cli/issues/405) PR 3, [#441](https://github.com/labelle-toolkit/labelle-cli/pull/441)). Older CLIs reserve the `android` namespace and reject this provider.
- **Requires labelle-bgfx ≥ 0.30.0** (released), whose build hook links one copy of this package's JNI C next to the plugin. Older bgfx fails the `libgame.so` link; see [Duplicate `labelle_android_*` symbols](#duplicate-labelle_android_-symbols-older-bgfx).

v0.1.x shipped the runtime services only. The runtime extraction, phase 1a–1d ([bgfx #149](https://github.com/labelle-toolkit/labelle-bgfx/issues/149)): the package ships one Zig module, `labelle_android`, with five services (v0.3.0 adds a sixth, `immersive`) the bgfx and sokol backends used to carry as per-backend copies:

| Namespace | Service | Origin |
|-----------|---------|--------|
| `launch_intent` / `intent_env` | launch-intent `LABELLE_*` extras → process env (allow-list, debuggable gate, revert on relaunch, failed-restore retry) | bgfx #139 / sokol #25 (the sokol superset) |
| `debuggable` | `isDebuggable(activity)`: is the running apk `android:debuggable`? Process-cached, fail-closed | assembler #737 |
| `relayout` | `forceWindowRelayout(activity)`: re-apply the window attributes so a stuck 1x1 restored window relayouts (UI thread only) | bgfx #127 |
| `aaudio` | the AAudio output device (`ensureStarted` / `stop` / `framesMixed`): the `labelle-audio` `DeviceSink` a backend's PCM mixer drives; PCM_I16 stereo 48 kHz. `ensureStarted` opens the stream and only *requests* the start — it never blocks on the audio server (no `AAudioStream_waitForStateChange`). A device-owned control thread logs `android: AAudio stream started (…)` once per start, on the stream's **first mixer pull** (its first data callback) — which may precede AAudio's own STARTED state flip (the legacy AudioTrack path pre-fills first), and never on `requestStart` alone. A device disconnect (headset / Bluetooth route change) is reported by the error callback and the control thread closes and reopens the stream **itself**, with no further `ensureStarted`, logging `android: AAudio stream disconnected; reopening`; a reopen that fails is retried on the control thread with exponential backoff (100 ms doubling to 5 s, ~60 s in total), then given up (one `giving up` line) until the next `ensureStarted`. Setup failures warn once per failure episode and otherwise retry silently. Pure NDK C API, links `libaaudio` | bgfx #306 |
| `immersive` | `enable(activity)` / `applyUiThread(activity)`: hide the status and navigation bars in immersive-sticky mode (`WindowInsetsController` on API 30+, `setSystemUiVisibility` on API 28/29). `enable` chains `onContentRectChanged`/`onWindowFocusChanged` for sokol; `applyUiThread` is the UI-thread entry the bgfx shell calls on each focus gain. The generated `main.zig` passes the activity from labelle-core's backend seam | labelle-engine `src/android.zig` (engine#902) |
| `activity` | `finish(activity)`: the game quit (`game.quit()`), so finish the activity (`ANativeActivity_finish`; call from the glue app thread while the activity holds its window — see `activity.zig`) and, once the backend's normal destroy teardown has run, end the process (`_exit(0)`) so the next launch is a cold start rather than a restore of a quit game. First call per process only | FP #979 |
| `video` | MediaCodec decode: `VideoDecoder` (AMediaExtractor + AMediaCodec → AImageReader YUV_420_888 on a worker thread, a ring of tightened Y/U/V planes for the backend's GPU-YUV upload) and `decodeTrack` (the mp4's audio track → 48 kHz stereo i16 `Pcm`: multichannel layouts are downmixed ITU-R BS.775-style — L' = L + 0.707·C + 0.707·Ls, R' likewise, LFE dropped, normalised so it cannot clip; mono duplicated, stereo untouched; the layout comes from the output format's `channel-mask`, else the channel count's default — and the PCM is placed on the media timeline from the track's first presentation time: silence prepended when the audio starts late, the head trimmed when it starts early, so PCM frame 0 is media time 0, the player's clock origin), plus the pure, host-tested `yuv` (CPU YUV→RGBA; `Matrix` BT.601/BT.709, limited/full range — the decoder picks it from the stream's `ColorSpace`) and `planes` (row de-pad / NV12 de-interleave) helpers the desktop decoders share; pure NDK C API, links `libmediandk` | bgfx `src/video/{android,android_audio,yuv,planes}.zig` (FP #549) |

Every JNI service takes the running `ANativeActivity*` as an opaque pointer; the JNI walks (`src/jni/*.c`) read `->vm` / `->clazz` through the NDK's own header, so both backends pass what they already hold. `aaudio` declares its `MixCallback` structurally (`*const fn (out: []i16, channels: u8) void`) so the package has no dependency on labelle-audio; the consumer asserts equality at comptime. `build.zig` also exports `addAndroidSysroot` / `resolveNdk` / `nativeAppGlueDir` / `isAndroidTarget` for consumers' build scripts.

Consumers: labelle-bgfx (from the PRs that land #149 phase 1a/1b, 1c and 1d). labelle-sokol adoption is a filed follow-up; until then sokol keeps its own copies. APK packaging moved here from the CLI (the provider below); APK asset access is still not implemented. Runtime acceptance is on-device (SM-T505), not cross-compilation alone.

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
zig build test-provider --summary all       # provider host tool: wire decoder + fixtures, settings, invocation matrix, doctor, packager (manifest, strip/assets/size report, icon, signing), adb launch args
zig build install-provider                  # zig-out/bin/labelle-android
```

The Android compile-check compiles and links every AAudio entry point (`ensureStarted`, `stop`, the data and error callbacks) through an Android-only, never-executed harness test in `src/aaudio.zig`; on the host that test is skipped and the same state machine runs against a scripted fake API.

## CLI provider

`plugin.labelle` declares the `android` provider for labelle-cli's provider contract ([CLI #405](https://github.com/labelle-toolkit/labelle-cli/issues/405)): namespace `android`, target `android`, `command_contract = ">=1.2.0 <1.4.1"` (the wire versions from 1.2.0 that the vendored decoder accepts). Every command and hook runs one host executable, `bin/labelle-android` (`tools/main.zig`, built by `zig build install-provider`), which strictly decodes the context the CLI passes in `LABELLE_CONTEXT` (`tools/provider_contract.zig`, vendored from the CLI with its tests and fixtures) and dispatches on `(kind, id, step, phase)`. Any combination the manifest does not declare is refused. The CLI builds the tool with `zig build --system`, which disables dependency fetching, so `tools/` uses `std` only.

| Command | What it does |
|---|---|
| `labelle android doctor [--json]` | Checks the Android SDK (adb, build-tools `aapt`/`zipalign`/`apksigner`, `android.jar` for the configured target SDK), the NDK (sysroot, `llvm-strip`) and the JDK (`jar`, `keytool`). Exits non-zero when a required tool is missing. `--json` prints one `android` capability object on stdout instead (one item per check), which `labelle doctor --json` aggregates on labelle-cli ≥ v2.1.1. |
| `labelle android run [--device <serial>] [--apk <path>]` | Installs and launches the APK the last `labelle build --platform=android` packaged (checked against the `libgame.so` it was packaged from), on `--device` or adb's default (`ANDROID_SERIAL`). Builds nothing. |
| `labelle android deploy --tag <tag> [--channel <c>] [--notes-file <f>] [--apk <path>]` | Publishes the APK `labelle bundle --platform=android` produced as a GitHub Release (`gh release create`, `--repo` from `deploy.repo`; a non-`stable` channel is a pre-release). Builds nothing. See [`docs/workflows/android-release.yml`](docs/workflows/android-release.yml). |

| Hook | When | What it does |
|---|---|---|
| `package` | after `build` (target `android`) | Packages `zig-out/apk/game.apk` from the core build's `libgame.so`, so `labelle build --platform=android` yields an installable APK. |
| `deploy` | replaces `run` | Installs that APK (`adb install -r`) and launches it with `am start -S -n <package>/android.app.NativeActivity`, turning the run options (`--scene`, `--profile`, `--screenshot`, `--after`) into `--es LABELLE_*` launch extras. Returns once `am start` does; the arguments after `--` and `--timeout` do not apply on a device. |
| `bundle` | replaces `bundle` | Packages the release APK into the bundle output directory (`zig-out/bundle/android/`, or `--output`): `<package_name>-<version_name>.apk`, with `versionCode` = `--build-number` (default 1), its size report and the unstripped library. |

The packager is the CLI's, moved (labelle-cli#405): the same APK layout and size.

- **Native library.** Release optimize modes stage `libgame.so` through the NDK's `llvm-strip --strip-unneeded` and keep the unstripped library under `symbols/arm64-v8a/` (for `ndk-stack -sym`); Debug stages it as built. A missing or failing `llvm-strip` packages the library unstripped, with a warning.
- **Assets.** `assets/` is staged without the texture packer's `raw/` sources, the files the generated `main.zig` `@embedFile`s, and the PNG of an embedded ASTC. Videos always ship.
- **APK.** `aapt package -f -M -I -F [-A assets] [-S res -0 arsc]`, then `jar --update --no-compress` (so `lib/` is stored), `zipalign -f 4` and `apksigner sign`. The launcher icon (`app_icon`, else the assembler's `default_icon.png`) is downscaled to the five mipmap densities.
- **Signing.** With `signing` in the settings, that keystore signs, its passwords handed to apksigner as `env:`/`file:` sources (never in argv or logs). Without it, the debug keystore at `<LABELLE_HOME or ~/.labelle>/android-debug.keystore` signs (generated with `keytool` on first use), the path the CLI always used, so `adb install -r` keeps updating an installed CLI-built APK. A relative `LABELLE_HOME` is resolved against the project directory; export an absolute one if you run labelle from elsewhere.
- **Failures leave no APK.** Everything is staged under `zig-out/apk/.staging-<pid>/` and the signed APK is renamed into place only after every tool succeeded; the previous `zig-out/apk/` is removed first. `zig-out/apk/package.json` records the `libgame.so` digest the APK was packaged from.
- **Not yet:** `load_assets_from_apk` (a non-empty `apk_assets.json` is refused, [assembler #759](https://github.com/labelle-toolkit/labelle-assembler/issues/759)), fat APKs and the emulator ABI (`abis` is arm64 only), and `labelle android studio`. The manifest is the backend-neutral NativeActivity (`android.app.lib_name = game`); only bgfx is verified through this packager.

Outputs, under the generated target directory `.labelle/<backend>_android/`:

```
zig-out/lib/libgame.so                       core build (input)
zig-out/apk/game.apk                         `package` hook
zig-out/apk/symbols/arm64-v8a/libgame.so     release builds: unstripped
zig-out/apk/package.json                     what game.apk was packaged from
zig-out/bundle/android/<pkg>-<ver>.apk       `bundle` hook (+ .size.txt, -symbols/)
```

**Run it inside a project** that pins this package: the CLI dispatches provider commands only from a project's `.plugins`, so `labelle android doctor` outside a project no longer works (the CLI's projectless dispatch is a later phase).

Needs a labelle-cli with provider contract 1.2.0 ([CLI #440](https://github.com/labelle-toolkit/labelle-cli/pull/440)) and without the built-in Android support ([CLI #441](https://github.com/labelle-toolkit/labelle-cli/pull/441), #405 PR 3): labelle-cli v2.0.0 or newer. Earlier CLIs reserve the `android` namespace for their legacy `labelle android` subcommand, so discovery rejects this provider. A labelle-cli with contract 1.4.0 ([CLI #487](https://github.com/labelle-toolkit/labelle-cli/pull/487)) also tells the `package` hook when it runs under `labelle bundle`, so the APK is packaged once there (by the `bundle` hook); an older CLI still packages it twice. CI drives the real CLI, pinned at `main` d7827eb (the merge of #487, unpatched; it also aggregates provider doctors into `labelle doctor --json`, asserted by the e2e), through `tests/provider/e2e.py` (fake SDK, every host; asserts that only the provider packages) and `tests/provider/ndk_e2e.py` (a real bgfx APK).

### Project setup

Pin the release (v0.2.0 is the first that ships the provider):

```zig
// project.labelle
.plugins = .{
    .{ .name = "android", .repo = "github.com/labelle-toolkit/labelle-android", .version = "0.2.1" },
},
.provider_config = .{ .{ .package = "android", .file = "providers/android.json" } },
```

To develop the provider itself, pin a local checkout instead:

```zig
.{ .name = "android", .repo = "local:../labelle-android" },
```

#### Duplicate `labelle_android_*` symbols (older bgfx)

labelle-bgfx depends on this package for the runtime services, fetched by url+hash into `zig-pkg/labelle_android-<version>-<hash>`. The assembler wires every plugin, this provider included, as a `.path` dependency at `<project>/.labelle/deps/labelle-android`. Zig reuses a dependency only when its build root and options match, and a `.path` root never equals a hash-fetched one, so the Android build graph holds two `labelle_android` modules even when both name the same release. Pinning the same labelle-android version on both sides does not help. Each module compiles the JNI helpers (`src/jni/*.c`), and the `libgame.so` link fails with duplicate `labelle_android_*` symbols (labelle-cli#405 D11).

Use labelle-bgfx ≥ 0.30.0 ([labelle-bgfx#158](https://github.com/labelle-toolkit/labelle-bgfx/pull/158)). On Android its build hook (`post_wire`) checks the import the game root gives this plugin, `android`; when that import exists and is a `labelle_android` instance, it points every `labelle_android` import in the graph at it. bgfx's own copy is then unreachable, and the `.so` carries one copy of the JNI C: the plugin's. Without the plugin nothing changes.

The project's plugin pin therefore decides which labelle-android runs, for bgfx too. Keep it API-compatible with the labelle-android release the bgfx version pins (bgfx 0.30.0 pins v0.2.0). CI's `tests/provider/ndk_e2e.py` builds an unmodified bgfx 0.30.0 next to this checkout as the plugin and checks that the JNI C in `libgame.so` is the plugin's copy.

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
  "deploy": { "repo": "owner/name", "channel": "stable" },
  "renderer": "gles"
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
| `renderer` | no | `"gles"` | `gles`, `vulkan` or `auto` (Vulkan when the device reports Vulkan ≥ 1.1, else GLES). Always stamped into the manifest as `<meta-data android:name="labelle.renderer">` on `<application>`; `vulkan` and `auto` also add the optional `android.hardware.vulkan.version` `0x401000` (Vulkan 1.1) feature. GLES 3.0 stays a required feature as the fallback ([labelle-bgfx#172](https://github.com/labelle-toolkit/labelle-bgfx/issues/172) D2/D7) |

The parse is strict: unknown keys, duplicate keys and wrong types are errors, and the file is validated before the provider does anything. `immersive_mode` and `load_assets_from_apk` are rejected here: the assembler reads them at generate time, so they stay in `project.labelle .android`. There is no `studio` block: `labelle android studio` is not part of this release. `version_name` names the bundle and stamps `android:versionName`; `versionCode` is `labelle bundle --build-number` (1 for `labelle build`).

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
