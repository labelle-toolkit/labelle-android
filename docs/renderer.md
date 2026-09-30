# Choosing a renderer

On Android, labelle-bgfx can render with **GLES** or **Vulkan**. labelle-android decides which one at launch and passes the choice to bgfx through the `LABELLE_BGFX_RENDERER` environment variable ([labelle-bgfx#172](https://github.com/labelle-toolkit/labelle-bgfx/issues/172), D1–D4 and D11).

Needs the launch-time resolution ([#27](https://github.com/labelle-toolkit/labelle-android/issues/27)), the crash guard ([#28](https://github.com/labelle-toolkit/labelle-android/issues/28)) and a labelle-bgfx that reads `LABELLE_BGFX_RENDERER` on every platform ([labelle-bgfx#176](https://github.com/labelle-toolkit/labelle-bgfx/issues/176)).

## The `renderer` setting

Set it in `providers/android.json`:

```json
{
  "schema_version": 1,
  "package_name": "com.example.game",
  "renderer": "vulkan"
}
```

| Value | Meaning |
|---|---|
| `"gles"` (default) | GLES 3.0. |
| `"vulkan"` | Vulkan. bgfx falls back to GLES if Vulkan init fails. |
| `"auto"` | Vulkan when the device reports Vulkan ≥ 1.1 (the `android.hardware.vulkan.version` system feature ≥ `0x401000`), else GLES. |

Any other value, or a non-string value, fails the build with `renderer must be one of "gles", "vulkan", "auto"`.

The packager stamps the setting into `AndroidManifest.xml`:

- **Always**, `gles` included: `<meta-data android:name="labelle.renderer" android:value="<value>" />` as the first child of `<application>`. This is what the runtime reads.
- **For `vulkan` and `auto` only:** `<uses-feature android:name="android.hardware.vulkan.version" android:version="0x401000" android:required="false" />`. It's optional, so Play still offers the app to devices without Vulkan. The required GLES 3.0 feature stays, as the fallback.

With `gles`, the manifest is otherwise unchanged. To check a packaged APK (from the generated target directory, e.g. `.labelle/bgfx_android/`):

```sh
"$ANDROID_HOME"/build-tools/36.0.0/aapt2 dump xmltree --file AndroidManifest.xml zig-out/apk/game.apk | grep -E -A2 'labelle.renderer|vulkan'
```

## How the renderer is resolved at launch

`launch_intent.apply` runs `renderer.resolve` at the top of the activity's `run`, before the event loop and so before `bgfx.init`. The first rule that matches wins:

| # | Source | Rule |
|---|---|---|
| 1 | `intent` | The `LABELLE_BGFX_RENDERER` launch extra, `vulkan` or `gles` (exact, lower-case). **Debuggable builds only.** In a non-debuggable build it's ignored with an info line. Any other value is warned about and ignored. An empty extra counts as absent. |
| 2 | `crash-guard` | A previous Vulkan start didn't complete, so start on `gles` (see [Crash guard](#crash-guard)). |
| 3 | `setting` | The `labelle.renderer` meta-data: `gles` or `vulkan`. Missing or unreadable → `gles`. An invalid value → `gles`, with a warning. |
| 4 | `auto` | The setting is `auto`: `vulkan` if the device has the Vulkan 1.1 feature, else `gles`. If the query fails, it counts as no Vulkan. |

The result is exported with `setenv("LABELLE_BGFX_RENDERER", "vulkan"|"gles")`. It always replaces any value already in the process environment.

The override, on a debuggable build:

```sh
adb shell am start -S -n <pkg>/android.app.NativeActivity --es LABELLE_BGFX_RENDERER vulkan
```

The extra only applies to that launch. A later launch without it goes back to rules 2–4.

To see what the `auto` rule will see on a device:

```sh
adb shell pm list features | grep vulkan.version
```

## GLES fallback when Vulkan init fails

bgfx keeps its own fallback on (D4). If Vulkan is requested but bgfx can't start it, bgfx starts the next renderer it can, which on Android is GLES, and the game runs. bgfx reads `LABELLE_BGFX_RENDERER` again on every `bgfx.init`, including after each resume, and logs the result each time.

A fallback is **not** a Vulkan pass: always check `actual=`, not just `requested=`.

## Log lines

All of these are logged under the `labelle` logcat tag:

```sh
adb logcat -d -s labelle | grep -E 'renderer: (gles|vulkan)|bgfx: renderer'
```

| Line | Meaning |
|---|---|
| `renderer: vulkan (source: setting)` | labelle-android's choice and the rule that made it: `intent`, `crash-guard`, `setting` or `auto`. Logged once per launch. |
| `renderer: gles (source: crash-guard; previous Vulkan start did not complete)` | The crash guard switched this launch to GLES. |
| `android: ignoring intent extra LABELLE_BGFX_RENDERER: the apk is not debuggable` | The override was sent to a release build. |
| `android: ignoring intent extra LABELLE_BGFX_RENDERER='<v>' (expected 'vulkan' or 'gles')` | Bad override value. The next rule decides. |
| `android: invalid labelle.renderer meta-data '<v>' (expected 'gles', 'vulkan' or 'auto'); using gles` | The APK carries a bad setting. The strict setting parser should make this impossible. |
| `bgfx: renderer requested=Vulkan actual=Vulkan` | bgfx started what was asked for. Logged on every init and resume. |
| `bgfx: renderer fallback: requested Vulkan but bgfx started OpenGLES` | Vulkan init failed and bgfx fell back (warning). |
| `bgfx: renderer requested=<X> came up as Noop (nothing would render); treating as an init failure` | bgfx started with no real renderer. It's shut down and treated as a failed init (error). |
| `bgfx: renderer init failed (requested=<X>)` | `bgfx.init` failed outright (error). |

## Crash guard

If the game crashes, or is killed, while starting on Vulkan, the next launch starts on GLES. That way a bad Vulkan driver can't leave the game unable to start.

The guard keeps two marker files in the app's internal data directory (`ANativeActivity.internalDataPath`, normally `/data/user/0/<pkg>/files`). Each holds `<versionCode> <setting>`, where the setting is the effective `renderer` setting (a missing or invalid one counts as `gles`).

| File | Written | Removed |
|---|---|---|
| `.labelle_vulkan_start` | Whenever the resolved renderer is `vulkan` (intent override included), just before `setenv`. | By a background timer once the process has lived 10 s after that; or at the next launch, which then writes `.labelle_vulkan_disabled`. |
| `.labelle_vulkan_disabled` | At launch, when `.labelle_vulkan_start` is still there with a matching stamp (the last Vulkan start never reached 10 s). | When the stamp no longer matches (see below). |

**Rules:**

- **Disabled:** while `.labelle_vulkan_disabled` exists with a stamp that matches the current `versionCode` and setting, every launch starts on GLES, with source `crash-guard`.
- **Reset:** a new `versionCode` or a changed `renderer` setting deletes both files, so Vulkan is tried again. An unreadable stamp resets too.
- **Override:** the debuggable intent extra (rule 1) is checked before the guard, so `--es LABELLE_BGFX_RENDERER vulkan` still starts on Vulkan.
- **"Stable" is just time.** The guard doesn't wait for a frame or a bgfx signal. Any process death within 10 s of a Vulkan start counts, including a swipe-away or an `am start -S` relaunch. When testing, wait more than 10 s after a Vulkan launch before relaunching, or use the intent override.

To see the guard's state on a debuggable build:

```sh
adb shell run-as <pkg> ls -a files
```

## Vulkan will become the default

The default is `"gles"` for now. Once Vulkan passes the production gate in [labelle-bgfx#172](https://github.com/labelle-toolkit/labelle-bgfx/issues/172) (D8), a minor labelle-android release changes the default to `"vulkan"` (D12). Devices without working Vulkan still start: bgfx's fallback covers a failed init, and the crash guard covers a crashed one. A project that needs GLES should set `"renderer": "gles"` explicitly.

For testing Vulkan on the emulator, see [Android emulator testing](emulator-testing.md).
