"""Real labelle-cli discovery, build and dispatch of the `android` provider.

A fixture project pins this checkout as `local:` and hands the provider
`providers/android.json` through `.provider_config`. The CLI resolves the
package, builds `bin/labelle-android` with `zig build --system`, writes a
contract context and runs it. A fake ANDROID_HOME/JAVA_HOME tree keeps the
doctor report deterministic, and every assertion checks something only this
provider prints (the CLI's legacy doctor probes `aapt2`, never `aapt` or
`jar`), so a run that silently fell back to the CLI's built-in path fails.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--cli', required=True)
p.add_argument('--zig', required=True)
a = p.parse_args()
cli, zig = str(Path(a.cli).resolve()), str(Path(a.zig).resolve())
repo = Path(__file__).resolve().parents[2]
version = subprocess.check_output([zig, 'version'], text=True).strip()
windows = os.name == 'nt'
# `os.uname()` does not exist on Windows, so branch before calling it.
if windows:
    host = 'windows-x86_64'
else:
    host = 'darwin-x86_64' if os.uname().sysname == 'Darwin' else 'linux-x86_64'


def tool(path: Path, kind='exe'):
    suffix = ('.bat' if kind == 'script' else '.exe') if windows else ''
    path = path.with_name(path.name + suffix)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('')
    return path


with tempfile.TemporaryDirectory(prefix='labelle-android-provider-') as temp:
    temp = Path(temp).resolve()
    sdk, jdk = temp / 'sdk', temp / 'jdk'
    tool(sdk / 'platform-tools/adb')
    for name in ('aapt', 'zipalign'):
        tool(sdk / 'build-tools/34.0.0' / name)
    tool(sdk / 'build-tools/34.0.0/apksigner', 'script')
    platform = sdk / 'platforms/android-35'
    platform.mkdir(parents=True)
    (platform / 'android.jar').write_text('')
    prebuilt = sdk / 'ndk/27.2.12479018/toolchains/llvm/prebuilt' / host
    (prebuilt / 'sysroot').mkdir(parents=True)
    tool(prebuilt / 'bin/llvm-strip')
    jar = tool(jdk / 'bin/jar')
    tool(jdk / 'bin/keytool')

    project = temp / 'game'
    (project / 'providers').mkdir(parents=True)
    dep = f'.{{ .name = "android", .repo = "local:{repo.as_posix()}", .version = "0.2.0" }}'
    (project / 'project.labelle').write_text(
        f'.{{ .name = "game", .title = "Fixture Game", .zig_version = "{version}", .plugins = .{{ {dep} }}, '
        '.provider_config = .{ .{ .package = "android", .file = "providers/android.json" } } }')
    (project / 'labelle.lock').write_text(f'.{{ .plugins = .{{ {dep} }} }}')
    settings = project / 'providers/android.json'
    good = '{"schema_version": 1, "package_name": "com.labelle.fixture", "target_sdk_version": 35}'
    settings.write_text(good)

    env = {k: v for k, v in os.environ.items() if not k.startswith(('ANDROID_', 'JAVA_HOME'))}
    env.update(LABELLE_HOME=str(temp / 'home'), LABELLE_ZIG=zig, ANDROID_HOME=str(sdk), JAVA_HOME=str(jdk))

    def run(*args, cwd=project, ok=True):
        result = subprocess.run([cli, *args], cwd=cwd, env=env, text=True, capture_output=True, timeout=600)
        out = result.stdout + result.stderr
        if ok:
            assert result.returncode == 0, (args, result.returncode, out)
        else:
            assert result.returncode != 0, (args, out)
        assert 'leaked' not in out, out
        return out

    # Discovery lists the manifest's one command.
    out = run('help')
    assert 'labelle android doctor — Check the Android SDK/NDK/JDK' in out, out
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

    # A missing platform fails the command through the provider's exit status.
    shutil.rmtree(platform)
    out = run('android', 'doctor', ok=False)
    assert '[ FAIL ] android.jar (platform)' in out and 'platforms;android-35' in out, out
    platform.mkdir(parents=True)
    (platform / 'android.jar').write_text('')

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
    settings.write_text(good)

    # Arguments reach the tool verbatim; doctor takes none.
    out = run('android', 'doctor', '--bogus', ok=False)
    assert "unknown argument '--bogus'" in out, out
    run('android', 'nonexistent', ok=False)

    # Projectless dispatch is labelle-cli phase 5: outside a project the
    # provider cannot be found (documented in the README), and nothing runs.
    outside = temp / 'outside'
    outside.mkdir()
    out = run('android', 'doctor', cwd=outside, ok=False)
    assert 'labelle android doctor\n=====' not in out, out

print('labelle-android provider e2e: ok')
