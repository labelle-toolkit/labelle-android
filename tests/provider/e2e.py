"""Real labelle-cli discovery, build and dispatch of the `android` provider.

A fixture project pins this checkout as `local:` and hands the provider
`providers/android.json` through `.provider_config`. The CLI resolves the
package, builds `bin/labelle-android` with `zig build --system`, writes a
contract context and runs it.

The Android SDK, JDK and NDK are fakes: `tests/provider/stub_tool.zig`,
compiled here and copied under every tool name (aapt, zipalign, the
apksigner `.bat` on Windows, jar, keytool, llvm-strip, adb, and gh on PATH).
Each call appends its argv to a JSON log, marked `via_provider` when the
provider (not the CLI's own legacy packager, still in the pinned CLI until
labelle-cli#405 PR 3) ran it, and the APK stand-ins are real stored zips,
so the assertions read what the provider actually packaged. Generation is a
fake assembler (the CLI suites' pattern) whose target `build.zig` installs a
marker `libgame.so`, so `labelle build|run|bundle --platform=android` run
end to end on Windows, macOS and Linux with no NDK.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

p = argparse.ArgumentParser()
p.add_argument('--cli', required=True)
p.add_argument('--zig', required=True)
a = p.parse_args()
cli, zig = str(Path(a.cli).resolve()), str(Path(a.zig).resolve())
repo = Path(__file__).resolve().parents[2]
version = subprocess.check_output([zig, 'version'], text=True).strip()
windows = os.name == 'nt'
host = 'windows-x86_64' if windows else ('darwin-x86_64' if sys.platform == 'darwin' else 'linux-x86_64')
exe = '.exe' if windows else ''

BUILT = 'BUILT-LIBGAME-WITH-DWARF'

# `generate --platform android` writes `.labelle/<backend>_android/` with a
# build.zig that only installs a marker `libgame.so` (nothing is compiled),
# a `main.zig` that `@embedFile`s two assets (never compiled either: the
# packager only scans it), an `assets/` tree covering every staging rule,
# the assembler's `default_icon.png` and an empty `apk_assets.json`.
FAKE_ASSEMBLER = r'''import os, shutil, struct, sys, zlib
from pathlib import Path
argv = sys.argv[1:]

def png(w, h):
    raw = b''.join(b'\x00' + b''.join(bytes((x * 255 // (w - 1), y * 255 // (h - 1), 128, 255)) for x in range(w)) for y in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

if argv and argv[0] == "--protocol-version":
    print(99)
elif argv and argv[0] == "install":
    print("FIXTURE_INSTALL_DONE", file=sys.stderr, flush=True)
elif argv and argv[0] == "generate":
    root = Path(argv[argv.index("--project-root") + 1])
    backend = argv[argv.index("--backend") + 1]
    platform_name = argv[argv.index("--platform") + 1]
    target = root / ".labelle" / f"{backend}_{platform_name}"
    target.mkdir(parents=True, exist_ok=True)
    (target / "build.zig").write_text(
        'const std = @import("std");\n'
        'pub fn build(b: *std.Build) void {\n'
        '    _ = b.standardOptimizeOption(.{});\n'
        '    b.getInstallStep().dependOn(&b.addInstallFile(b.path("libgame.so"), "lib/libgame.so").step);\n'
        '}\n')
    (target / "libgame.so").write_text(os.environ.get("FAKE_LIBGAME", "BUILT-LIBGAME-WITH-DWARF"))
    (target / "main.zig").write_text(
        '// generated\n'
        'try g.loadAtlasFromMemory("rooms", @embedFile("assets/rooms.json"), @embedFile("assets/rooms.astc"), ".png");\n')
    assets = target / "assets"
    for rel, data in {"rooms.json": "{}", "rooms.astc": "ASTC", "rooms.png": "PNG", "intro.mp4": "VIDEO",
                      "ui/icon_menu.png": "UI", "raw/rooms/r0.png": "RAW", "raw/clip.mp4": "RAWVIDEO"}.items():
        (assets / rel).parent.mkdir(parents=True, exist_ok=True)
        (assets / rel).write_text(data)
    (target / "default_icon.png").write_bytes(png(256, 256))
    (target / "apk_assets.json").write_text(os.environ.get("FAKE_APK_ASSETS", '{"version":1,"compression":"deflate","files":[]}\n'))
    print("FIXTURE_GENERATE", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''


with tempfile.TemporaryDirectory(prefix='labelle-android-provider-') as temp:
    temp = Path(temp).resolve()

    # ── the stub tool and the fake SDK / JDK / NDK ─────────────────────────
    stub = temp / f'stub-tool{exe}'
    subprocess.run([zig, 'build-exe', str(repo / 'tests/provider/stub_tool.zig'), f'-femit-bin={stub}'],
                   cwd=temp, check=True)
    for leftover in temp.glob('stub-tool.*'):
        if leftover.suffix in ('.pdb', '.o', '.obj'):
            leftover.unlink()

    def tool(path: Path, kind='exe'):
        path.parent.mkdir(parents=True, exist_ok=True)
        if windows and kind == 'script':
            real = path.with_name(path.name + '-stub.exe')
            shutil.copy(stub, real)
            path = path.with_name(path.name + '.bat')
            path.write_text(f'@"%~dp0{real.name}" %*\r\n@exit /b %ERRORLEVEL%\r\n')
            return path
        path = path.with_name(path.name + exe)
        shutil.copy(stub, path)
        return path

    sdk, jdk, bin_dir = temp / 'sdk', temp / 'jdk', temp / 'bin'
    tool(sdk / 'platform-tools/adb')
    bt = sdk / 'build-tools/34.0.0'
    for name in ('aapt', 'zipalign'):
        tool(bt / name)
    tool(bt / 'apksigner', 'script')
    for level in (34, 35):
        platform = sdk / f'platforms/android-{level}'
        platform.mkdir(parents=True)
        (platform / 'android.jar').write_text('')
    prebuilt = sdk / 'ndk/27.2.12479018/toolchains/llvm/prebuilt' / host
    (prebuilt / 'sysroot').mkdir(parents=True)
    tool(prebuilt / 'bin/llvm-strip')
    jar = tool(jdk / 'bin/jar')
    tool(jdk / 'bin/keytool')
    tool(bin_dir / 'gh')

    script = temp / 'fake_assembler.py'
    script.write_text(FAKE_ASSEMBLER)
    if windows:
        assembler = temp / 'fake-assembler.cmd'
        assembler.write_text(f'@echo off\r\n"{sys.executable}" "{script}" %*\r\nexit /b %ERRORLEVEL%\r\n')
    else:
        assembler = temp / 'fake-assembler'
        assembler.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n')
        assembler.chmod(0o755)

    # ── the fixture project ────────────────────────────────────────────────
    project = temp / 'game'
    (project / 'providers').mkdir(parents=True)
    dep = f'.{{ .name = "android", .repo = "local:{repo.as_posix()}", .version = "0.2.0" }}'
    (project / 'project.labelle').write_text(
        f'.{{ .name = "game", .title = "Fixture Game", .zig_version = "{version}", .backend = .bgfx, '
        f'.plugins = .{{ {dep} }}, '
        '.provider_config = .{ .{ .package = "android", .file = "providers/android.json" } } }')
    (project / 'labelle.lock').write_text(f'.{{ .plugins = .{{ {dep} }} }}')
    settings = project / 'providers/android.json'
    doctor_settings = '{"schema_version": 1, "package_name": "com.labelle.fixture", "target_sdk_version": 35}'
    good = '{"schema_version": 1, "package_name": "com.labelle.fixture"}'
    settings.write_text(doctor_settings)

    home = temp / 'home'
    log = temp / 'tools.log'
    env = {k: v for k, v in os.environ.items() if not k.startswith(('ANDROID_', 'JAVA_HOME', 'STUB_', 'FAKE_'))}
    env.update(LABELLE_HOME=str(home), LABELLE_ZIG=zig, ANDROID_HOME=str(sdk), JAVA_HOME=str(jdk),
               LABELLE_ASSEMBLER=str(assembler), LABELLE_NO_PREBUILD='1', STUB_LOG=str(log),
               PATH=os.pathsep.join([str(jdk / 'bin'), str(bin_dir), env.get('PATH', '')]))

    def run(*args, cwd=project, ok=True, extra_env=None):
        merged = dict(env, **(extra_env or {}))
        result = subprocess.run([cli, *args], cwd=cwd, env=merged, text=True, capture_output=True, timeout=900)
        out = result.stdout + result.stderr
        if ok:
            assert result.returncode == 0, (args, result.returncode, out)
        else:
            assert result.returncode != 0, (args, out)
        assert 'leaked' not in out, out
        return out

    def calls(provider=True):
        """The logged tool calls since the last `reset_log`."""
        if not log.exists():
            return []
        entries = [json.loads(line) for line in log.read_text().splitlines() if line.strip()]
        return [e for e in entries if provider is None or e['via_provider'] == provider]

    def reset_log():
        if log.exists():
            log.unlink()

    def norm(path):
        return os.path.normcase(os.path.normpath(str(path)))

    def same(got, want):
        """Equal argv lists, paths compared host-normalised (Windows)."""
        def n(v):
            return [n(x) for x in v] if isinstance(v, list) else norm(v)
        assert n(got) == n(want), (got, want)

    def argv_of(tool_name, entries=None):
        found = [e['argv'] for e in (calls() if entries is None else entries) if e['tool'] == tool_name]
        assert len(found) == 1, (tool_name, found)
        return found[0]

    def manifests(entries=None):
        return [e['manifest'] for e in (calls() if entries is None else entries) if e['tool'] == 'aapt']

    # ── discovery and doctor (PR 1) ────────────────────────────────────────
    out = run('help')
    assert 'labelle android doctor — Check the Android SDK/NDK/JDK' in out, out
    assert 'labelle android run — Install and launch the built APK' in out, out
    assert 'labelle android deploy — Publish the bundled APK' in out, out
    assert 'studio' not in out.split('labelle android doctor')[1].split('\n\n')[0], out
    assert 'ReservedNamespace' not in out, out

    # The provider ran: its own checks, the settings' target SDK, the
    # project's title as the default label, and paths inside the fake tree.
    out = run('android', 'doctor')
    assert 'target SDK: 35' in out, out
    assert 'package: com.labelle.fixture  label: "Fixture Game"  min SDK: 28' in out, out
    for name in ('adb', 'build-tools', 'aapt', 'zipalign', 'apksigner', 'android.jar (platform)',
                 'NDK sysroot', 'llvm-strip (NDK)', 'jar (JDK)', 'keytool (JDK)'):
        assert f'[  OK  ] {name}\n' in out, (name, out)
    assert str(jar) in out, out
    assert '27.2.12479018' in out and 'All required Android tools are present.' in out, out

    platform35 = sdk / 'platforms/android-35'
    shutil.rmtree(platform35)
    out = run('android', 'doctor', ok=False)
    assert '[ FAIL ] android.jar (platform)' in out and 'platforms;android-35' in out, out
    platform35.mkdir(parents=True)
    (platform35 / 'android.jar').write_text('')

    # Settings are validated before anything runs; secrets never echo.
    for body, reason in (
        ('{"schema_version": 1, "package_name": "com.a.b", "signing": {"keystore": "k.jks", "store_password": "pass:hunter2"}}',
         "'pass:' puts a secret in the repository"),
        ('{"schema_version": 1, "package_name": "com.a.b", "immersive_mode": true}',
         'set this in project.labelle `.android`'),
        ('{"schema_version": 1, "package_name": "com.a.b", "abis": ["x86_64"]}', 'abis must be ["arm64-v8a"]'),
        ('{"schema_version": 1, "package_name": "com.a.b", "studio": {}}', "unknown key 'studio'"),
        ('{"schema_version": 1, "package_name": "Game"}', "package_name 'Game'"),
    ):
        settings.write_text(body)
        out = run('android', 'doctor', ok=False)
        assert reason in out, (reason, out)
        assert 'hunter2' not in out, out
        assert 'labelle android doctor\n=====' not in out, out
    settings.write_text(doctor_settings)

    out = run('android', 'doctor', '--bogus', ok=False)
    assert "unknown argument '--bogus'" in out, out
    run('android', 'nonexistent', ok=False)
    run('android', 'studio', ok=False)

    # Projectless dispatch is labelle-cli phase 5 (README).
    outside = temp / 'outside'
    outside.mkdir()
    out = run('android', 'doctor', cwd=outside, ok=False)
    assert 'labelle android doctor\n=====' not in out, out

    # ── labelle build --platform=android: the `package` hook ──────────────
    settings.write_text(good)
    target = project / '.labelle' / 'bgfx_android'
    apk_dir = target / 'zig-out' / 'apk'
    apk = apk_dir / 'game.apk'
    so = target / 'zig-out' / 'lib' / 'libgame.so'
    keystore = home / 'android-debug.keystore'

    def inventory(path):
        with zipfile.ZipFile(path) as z:
            return {i.filename: (i.compress_type, z.read(i.filename)) for i in z.infolist()}

    def check_layout(path):
        files = inventory(path)
        # Stored lib/ (the jar --no-compress pass), resources.arsc from -S.
        assert files['lib/arm64-v8a/libgame.so'][0] == zipfile.ZIP_STORED, files.keys()
        assert 'resources.arsc' in files, files.keys()
        for density in ('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'):
            assert files[f'res/mipmap-{density}/ic_launcher.png'][1].startswith(b'\x89PNG'), density
        # Staged: videos (even under raw/) and unreferenced files. Left out:
        # raw/ sources, embedded files and the PNG of an embedded ASTC.
        for kept in ('assets/intro.mp4', 'assets/ui/icon_menu.png', 'assets/raw/clip.mp4'):
            assert kept in files, (kept, sorted(files))
        for dropped in ('assets/rooms.json', 'assets/rooms.astc', 'assets/rooms.png', 'assets/raw/rooms/r0.png'):
            assert dropped not in files, (dropped, sorted(files))
        return files

    reset_log()
    out = run('build', '--platform=android')
    assert apk.is_file(), out
    assert 'labelle-android: APK ready:' in out and 'labelle-android: APK size' in out, out
    # The pinned CLI (pre-PR 3) still packages its own <target>/game.apk on
    # `build`; the provider's calls are the ones marked via_provider.
    assert [e['tool'] for e in calls()] == ['aapt', 'jar', 'zipalign', 'apksigner'], calls()
    assert not list(apk_dir.glob('.staging-*')), list(apk_dir.iterdir())
    staging = Path(argv_of('jar')[argv_of('jar').index('-C') + 1])
    assert staging.parent == apk_dir and staging.name.startswith('.staging-'), staging
    same(argv_of('aapt')[:8], ['package', '-f', '-M', str(staging / 'AndroidManifest.xml'),
                                   '-I', str(sdk / 'platforms/android-34/android.jar'), '-F',
                                   str(staging / 'game.apk.unsigned')])
    same(argv_of('aapt')[8:], ['-A', str(staging / 'assets'), '-S', str(staging / 'res'), '-0', 'arsc'])
    same(argv_of('jar'), ['--update', '--no-compress', '--file', str(staging / 'game.apk.unsigned'),
                              '-C', str(staging), 'lib'])
    same(argv_of('zipalign'), ['-f', '4', str(staging / 'game.apk.unsigned'), str(staging / 'game.apk.aligned')])
    same(argv_of('apksigner'), ['sign', '--ks', str(keystore), '--ks-pass', 'pass:android',
                                        '--ks-key-alias', 'androiddebugkey', '--key-pass', 'pass:android',
                                        '--out', str(staging / 'game.apk.signed'), str(staging / 'game.apk.aligned')])
    # Debug: copied as built, never stripped, no symbols.
    files = check_layout(apk)
    assert files['lib/arm64-v8a/libgame.so'][1] == BUILT.encode(), files['lib/arm64-v8a/libgame.so']
    assert not (apk_dir / 'symbols').exists()
    manifest = manifests()[0]
    assert 'package="com.labelle.fixture"' in manifest and 'android:versionCode="1"' in manifest, manifest
    assert 'android:versionName="1.0"' in manifest and 'android:label="Fixture Game"' in manifest, manifest
    assert 'android:icon="@mipmap/ic_launcher"' in manifest and 'debuggable' not in manifest, manifest
    record = json.loads((apk_dir / 'package.json').read_text())
    assert record['optimize'] == 'Debug' and record['version_code'] == 1, record
    assert record['package_name'] == 'com.labelle.fixture', record

    # Release: the NDK's llvm-strip writes the staged library; the built one
    # is kept under symbols/.
    reset_log()
    run('build', '--platform=android', '--optimize=ReleaseFast')
    strip = argv_of('llvm-strip')
    staging = Path(argv_of('jar')[argv_of('jar').index('-C') + 1])
    same(strip, ['--strip-unneeded', '-o', str(staging / 'lib/arm64-v8a/libgame.so'), str(so)])
    assert inventory(apk)['lib/arm64-v8a/libgame.so'][1] == b'STRIPPED'
    assert (apk_dir / 'symbols/arm64-v8a/libgame.so').read_text() == BUILT
    assert json.loads((apk_dir / 'package.json').read_text())['optimize'] == 'ReleaseFast'

    # A failing apksigner leaves no APK: not the new one, not the old one.
    reset_log()
    out = run('build', '--platform=android', ok=False, extra_env={'STUB_FAIL': 'apksigner'})
    assert "hook 'android/package' failed" in out, out
    assert not apk.exists() and not (apk_dir / 'package.json').exists(), list(apk_dir.iterdir())
    assert not list(apk_dir.glob('.staging-*')), list(apk_dir.iterdir())

    # A non-empty apk_assets.json (load_assets_from_apk) is refused before
    # anything is staged: the packager cannot place those files yet.
    reset_log()
    out = run('build', '--platform=android', ok=False,
              extra_env={'FAKE_APK_ASSETS': '{"version":1,"compression":"deflate","files":["assets/rooms.json"]}'})
    assert 'labelle-assembler#759' in out and calls() == [], out

    # ── labelle run --platform=android: the `deploy` hook ─────────────────
    keystore.unlink()
    reset_log()
    out = run('run', '--platform=android', '--scene=intro', '--screenshot=shot', '--after=4s', '--', 'extra')
    # `run` does not package on the CLI side: every tool call is the provider's.
    assert calls(provider=False) == [], calls(provider=False)
    keytool = argv_of('keytool')
    same(keytool, ['-genkey', '-v', '-keystore', str(keystore), '-alias', 'androiddebugkey', '-keyalg', 'RSA',
                           '-keysize', '2048', '-validity', '10000', '-storepass', 'android', '-keypass', 'android',
                           '-dname', 'CN=Debug,O=Labelle,C=US'])
    adb = [e['argv'] for e in calls() if e['tool'] == 'adb']
    same(adb, [
        ['install', '-r', str(apk)],
        ['shell', 'am', 'start', '-S', '-n', 'com.labelle.fixture/android.app.NativeActivity',
         '--es', 'LABELLE_SCENE', "'intro'", '--es', 'LABELLE_SCREENSHOT_PATH', "'shot'",
         '--es', 'LABELLE_SCREENSHOT_AFTER_SEC', "'4.000'"],
    ])
    assert 'argument(s) after `--` ignored' in out and 'app launched on device' in out, out

    # `labelle android run` installs what was built, on the named device.
    reset_log()
    run('android', 'run', '--device', 'SERIAL-1')
    same([e['argv'] for e in calls() if e['tool'] == 'adb'], [
        ['-s', 'SERIAL-1', 'install', '-r', str(apk)],
        ['-s', 'SERIAL-1', 'shell', 'am', 'start', '-S', '-n', 'com.labelle.fixture/android.app.NativeActivity'],
    ])
    # An APK packaged from another libgame.so is never installed.
    so.write_text('REBUILT-ELSEWHERE')
    reset_log()
    out = run('android', 'run', ok=False)
    assert 'packaged from an older libgame.so' in out and calls() == [], out
    run('android', 'run', '--release', ok=False)

    # ── labelle bundle --platform=android: the `bundle` hook ──────────────
    reset_log()
    out = run('bundle', '--platform=android', '--optimize=ReleaseFast', '--build-number=7')
    bundle_dir = target / 'zig-out' / 'bundle' / 'android'
    bundled = bundle_dir / 'com.labelle.fixture-1.0.apk'
    assert bundled.is_file(), (out, list(bundle_dir.iterdir()) if bundle_dir.exists() else None)
    codes = [m.split('android:versionCode="')[1].split('"')[0] for m in manifests()]
    assert codes == ['1', '7'], codes  # the build's game.apk, then the bundle
    assert inventory(bundled)['lib/arm64-v8a/libgame.so'][1] == b'STRIPPED'
    check_layout(bundled)
    assert (bundle_dir / 'com.labelle.fixture-1.0.size.txt').read_text().startswith('labelle-android: APK size')
    assert (bundle_dir / 'com.labelle.fixture-1.0-symbols/arm64-v8a/libgame.so').read_text() == BUILT
    elsewhere = temp / 'release-out'
    run('bundle', '--platform=android', f'--output={elsewhere}')
    assert (elsewhere / 'com.labelle.fixture-1.0.apk').is_file(), list(elsewhere.iterdir())
    assert not list(elsewhere.glob('.*staging*')), list(elsewhere.iterdir())

    # ── configured signing: env:/file: sources, never the secret ──────────
    (project / 'keys').mkdir()
    (project / 'keys/release.jks').write_text('RELEASE-KEYSTORE')
    (project / 'keys/key.pass').write_text('s3cret-key-value\n')
    settings.write_text(json.dumps({'schema_version': 1, 'package_name': 'com.labelle.fixture',
                                    'signing': {'keystore': 'keys/release.jks', 'store_password': 'env:FIXTURE_KS_PASS',
                                                'key_alias': 'release', 'key_password': 'file:keys/key.pass'}}))
    reset_log()
    out = run('build', '--platform=android', extra_env={'FIXTURE_KS_PASS': 's3cret-store-value'})
    signer = argv_of('apksigner')
    same(signer[:8], ['sign', '--ks', str(project / 'keys/release.jks'), '--ks-pass', 'env:FIXTURE_KS_PASS',
                           '--ks-key-alias', 'release', '--key-pass'])
    assert norm(signer[8][len('file:'):]) == norm(project / 'keys/key.pass'), signer
    assert apk.is_file()
    for secret in ('s3cret-store-value', 's3cret-key-value'):
        assert secret not in out and secret not in log.read_text(), secret
    out = run('build', '--platform=android', ok=False)
    assert 'FIXTURE_KS_PASS, which is not set' in out, out
    settings.write_text(good)

    # ── labelle android deploy: the bundled APK to GitHub Releases ─────────
    reset_log()
    run('android', 'deploy', '--tag', 'v1.0.0', '--channel=staging')
    gh = [e['argv'] for e in calls() if e['tool'] == 'gh']
    same(gh, [['auth', 'status'],
                  ['release', 'create', 'v1.0.0', str(bundled), '--title', 'Fixture Game v1.0.0', '--prerelease',
                   '--generate-notes']])
    out = run('android', 'deploy', ok=False)
    assert 'deploy needs --tag' in out, out

print('labelle-android provider e2e: ok')
