# Choosing a renderer

On Android, labelle-bgfx can render with **GLES** or **Vulkan**. labelle-android decides which one at launch and passes the choice to bgfx through the `LABELLE_BGFX_RENDERER` environment variable ([labelle-bgfx#172](https://github.com/labelle-toolkit/labelle-bgfx/issues/172), D1–D4 and D11).

This page describes labelle-android ≥ the next release after 0.3.1. Earlier releases don't read the setting at launch; at most they stamp it into the manifest.

It also needs a labelle-bgfx that reads `LABELLE_BGFX_RENDERER` on every platform ([labelle-bgfx#176](https://github.com/labelle-toolkit/labelle-bgfx/issues/176)). The crash guard's frame-based stable rule needs `labelle_bgfx_frames_presented` ([labelle-bgfx#182](https://github.com/labelle-toolkit/labelle-bgfx/issues/182)); without it the guard uses a time-only rule.

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
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
AAPT2="$SDK/build-tools/$(ls "$SDK"/build-tools | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)/aapt2"
"$AAPT2" dump xmltree --file AndroidManifest.xml zig-out/apk/game.apk | grep -E -A2 'labelle.renderer|vulkan'
```

This uses the newest installed build-tools revision (a numeric sort, so it works with BSD and GNU `sort`). The SDK is `ANDROID_HOME`, else `ANDROID_SDK_ROOT`, else the macOS default `$HOME/Library/Android/sdk`.

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

All of these are logged under the `labelle` logcat tag. Clear the log before the launch you're checking, so lines from an earlier launch can't pass for this one:

```sh
adb logcat -c
adb shell am start -S -n <pkg>/android.app.NativeActivity
adb logcat -d -s labelle | grep -E 'renderer: (gles|vulkan)|bgfx: renderer|crash guard|LABELLE_BGFX_RENDERER|labelle.renderer'
```

| Line | Meaning |
|---|---|
| `renderer: vulkan (source: setting)` | labelle-android's choice and the rule that made it: `intent`, `crash-guard`, `setting` or `auto`. Logged once per launch. |
| `renderer: gles (source: crash-guard; …)` | The crash guard decided; see [Crash guard log lines](#crash-guard-log-lines). |
| `android: LABELLE_BGFX_RENDERER=vulkan (launch intent extra)` | The override was applied (debuggable build). |
| `android: LABELLE_BGFX_RENDERER cleared (set by a previous launch's intent)` / `… restored to <v> (set by a previous launch's intent)` | A launch without the extra undid the previous launch's override. |
| `android: ignoring intent extra LABELLE_BGFX_RENDERER: the apk is not debuggable` | The override was sent to a release build. |
| `android: ignoring intent extra LABELLE_BGFX_RENDERER='<v>' (expected 'vulkan' or 'gles')` | Bad override value. The next rule decides. |
| `android: invalid labelle.renderer meta-data '<v>' (expected 'gles', 'vulkan' or 'auto'); using gles` | The APK carries a bad setting. The strict setting parser should make this impossible. |
| `android: no labelle.renderer meta-data; using gles` | The APK has no setting (built before the setting existed). |
| `android: labelle.renderer meta-data too long; using gles` | The value doesn't fit the reader's buffer. |
| `android: could not read the labelle.renderer meta-data; using gles (crash-guard marks kept)` | The setting couldn't be read. The launch uses GLES and the guard's markers are left as they are. |
| `android: could not set LABELLE_BGFX_RENDERER=<v>` | `setenv` failed; bgfx uses its platform default. |
| `bgfx: renderer requested=Vulkan actual=Vulkan` | bgfx started what was asked for. Logged on every init and resume. |
| `bgfx: renderer fallback: requested Vulkan but bgfx started OpenGLES` | Vulkan init failed and bgfx fell back (warning). |
| `bgfx: renderer requested=<X> came up as Noop (nothing would render); treating as an init failure` | bgfx started with no real renderer. It's shut down and treated as a failed init (error). |
| `bgfx: renderer init failed (requested=<X>)` | `bgfx.init` failed outright (error). |

## Crash guard

If the game crashes, hangs or is killed while starting on Vulkan, the next launch starts on GLES. That way a bad Vulkan driver can't leave the game unable to start.

### Markers

Two marker files, each holding `<versionCode> <setting>`. The setting is the effective `renderer` setting; an absent or invalid one counts as `gles`.

| File | Written | Removed |
|---|---|---|
| `.labelle_vulkan_start` | Whenever the resolved renderer is `vulkan` (intent override included), before `setenv`. | When this Vulkan start becomes **stable** (below); or at the next launch in a new process, which then writes `.labelle_vulkan_disabled`. |
| `.labelle_vulkan_disabled` | At launch, when a `.labelle_vulkan_start` left by a process that's gone has a matching stamp. | When its stamp is proven to have changed (see Reset). |

**Where they live.** The directory is chosen once per process:

- **Primary:** the app's no-backup directory (`Context.getNoBackupFilesDir()`, normally `/data/user/0/<pkg>/no_backup`), which Auto Backup and device transfer never copy. All writes go here.
- **Fallback:** if that lookup fails, the primary is `ANativeActivity.internalDataPath` (normally `/data/user/0/<pkg>/files`) for the rest of the process, with a warning.
- **The launch check reads both** directories (the primary and the other one), and a marker in either counts. Writes still go only to the primary.

Writes are atomic (`<name>.tmp`, then renamed), so a failed write never leaves a half-written marker.

### Rules

- **Stable** means **both** of these, checked every 500 ms by a background thread:
  - at least **120 frames presented since this Vulkan start**, counted with labelle-bgfx's `labelle_bgfx_frames_presented` (looked up at runtime with `dlsym`), and
  - at least **10 s** since this Vulkan start.

  A Vulkan init that hangs presents no frames, so its mark is never cleared, however long you wait. If the frame counter isn't available (an older labelle-bgfx or another backend), the rule falls back to 10 s alone, with a warning. If deleting the mark fails, the thread keeps the mark as its own and retries on every poll while the process lives.
- **Only the Vulkan start itself can become stable.** Every renderer resolution, whatever it picks, stops this process's earlier stable thread without clearing its mark. So if the same process relaunches its Activity onto GLES before the Vulkan start was stable, the mark stays "incomplete", and GLES frames never clear it.
- **Same process:** an Activity relaunched in the same process doesn't treat its own live mark as a crash. A relaunch onto Vulkan writes a new mark and starts a new stable thread. A mark left by a dead process is a crash.
- **Disabled:** while `.labelle_vulkan_disabled` exists with a stamp that matches the current `versionCode` and setting, every launch starts on GLES, with source `crash-guard`.
- **Reset:** each marker is judged on its own stamp. It's deleted only when a value was **read successfully** and differs: a new `versionCode` or a changed `renderer` setting. Vulkan is then tried again.
- **Fail closed:**
  - If a marker can't be read (a read error, not "absent"), the launch is guarded and nothing is written or deleted.
  - If the `versionCode` or the setting can't be read, no marker is reset and the launch stays guarded.
  - A malformed marker never resets the guard. It counts as a match, and it's rewritten for the current stamp.
  - If the disabled mark can't be written or the stable thread can't start, the start mark is kept, so the next launch is still guarded.
  - If the start mark itself can't be written, this launch runs on GLES (`could not record the Vulkan start`), unless the intent override asked for Vulkan.
- **Override:** the debuggable intent extra (rule 1) is checked before the guard, so `--es LABELLE_BGFX_RENDERER vulkan` still starts on Vulkan. Without the extra, debuggable builds are guarded too.

**What this means while developing.** Anything that ends a Vulkan start before it's stable makes the next launch in a new process use GLES:

- a crash, a swipe-away, or an `am start -S` relaunch before 120 frames and 10 s
- switching from Vulkan to GLES in the same process (for example an `--es LABELLE_BGFX_RENDERER gles` relaunch) before the Vulkan start was stable: the mark stays, so the next launch uses GLES

To bypass the guard, launch a debuggable build with `--es LABELLE_BGFX_RENDERER vulkan`.

To see the guard's state on a debuggable build (the markers can be in either directory):

```sh
adb shell run-as <pkg> ls -a no_backup files
```

### Crash guard log lines

These are logged under the game's `labelle` tag:

| Line | Meaning |
|---|---|
| `renderer: gles (source: crash-guard; previous Vulkan start did not complete)` | A previous Vulkan start never became stable; this launch uses GLES. |
| `renderer: gles (source: crash-guard; could not record the Vulkan start)` | The start mark couldn't be written, so this launch uses GLES. |
| `android: crash guard: Vulkan start not recorded; keeping vulkan for the intent override` | The start mark couldn't be written, but the intent override keeps Vulkan (unguarded). |
| `android: crash guard: versionCode or labelle.renderer unreadable; cannot record this Vulkan start` | No full stamp, so no start mark. |
| `android: crash guard: could not write .labelle_vulkan_start` | The start mark write failed. |
| `android: crash guard: could not start the stable timer (<error>); keeping .labelle_vulkan_start, so the next launch uses gles` | No stable thread; the mark stays. |
| `android: crash guard: could not delete .labelle_vulkan_start; retrying` | The stable unlink failed; retried every poll (logged once). |
| `crash guard: labelle_bgfx_frames_presented not found; using the time-only stable rule` | No frame counter; stable is 10 s alone (logged once per process). |
| `android: crash guard: could not read a marker; keeping the guard (nothing changed)` | A marker read error; guarded, nothing written or deleted. |
| `android: crash guard: malformed .labelle_vulkan_disabled; keeping the guard` | Guarded; the marker is rewritten for the current stamp. |
| `android: crash guard: could not write .labelle_vulkan_disabled; keeping .labelle_vulkan_start` | The disable failed; the start mark stays, so the next launch is still guarded. |
| `android: crash guard: could not read the app's versionCode; keeping the guard's marks as they are` | Unreadable version; nothing reset. |
| `android: crash guard: could not get noBackupFilesDir; using internalDataPath for this process (Auto Backup may copy the crash-guard markers)` | The fallback directory is the primary for this process. |
| `android: crash guard: no usable internalDataPath; guard off` | No usable directory; the guard is off. |

The JNI helpers log under the `labelle-android` tag. When a JNI local frame can't be pushed, they log `renderer meta-data: PushLocalFrame failed; exception cleared`, or the same line with `system feature:`, `no-backup dir:` or `version code:` in front, and the query counts as failed.

## Vulkan will become the default

The default is `"gles"` for now. Once Vulkan passes the production gate in [labelle-bgfx#172](https://github.com/labelle-toolkit/labelle-bgfx/issues/172) (D8), a minor labelle-android release changes the default to `"vulkan"` (D12). Devices without working Vulkan still start: bgfx's fallback covers a failed init, and the crash guard covers a crashed one. A project that needs GLES should set `"renderer": "gles"` explicitly.

For testing Vulkan on the emulator, see [Android emulator testing](emulator-testing.md).
