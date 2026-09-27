"""A real APK through the real CLI, the real assembler and the real NDK/SDK.

python tests/provider/ndk_e2e.py --cli <labelle> --bgfx <labelle-bgfx v0.29.1 checkout> [--keep DIR]

Writes a tiny bgfx project (one screen-space rectangle, the assembler's
default launcher icon, an `assets/` tree with a `raw/` packer source) that
pins this checkout as the `android` provider, then:

- `labelle bundle --platform=android --optimize=ReleaseFast --build-number=3`
  (the core build, the `package` hook's `zig-out/apk/game.apk`, and the
  `bundle` hook's release APK);
- `apksigner verify` on both APKs;
- `aapt dump badging`: package, versionCode (1 for the build's APK, 3 for the
  bundle), SDK levels, label, orientation, launchable activity and icon;
- `unzip -Zv`: `lib/arm64-v8a/libgame.so` stored and stripped (smaller than
  the unstripped copy under `symbols/`), `resources.arsc` stored, the five
  launcher mipmaps present, `assets/raw/` left out and the rest of `assets/`
  kept.

Needs ANDROID_HOME (platform 34, build-tools, an NDK) and a JDK on
JAVA_HOME. Network access: the CLI fetches the assembler and the packages.

The backend is a COPY of the given labelle-bgfx checkout whose
`labelle_android` dependency is rewritten to the path where the assembler
stages this `local:` plugin, `<project>/.labelle/deps/labelle-android` (the
assembler re-roots a staged package's relative paths, so they must name the
final directory). Both the generated build and the backend then name ONE
directory, and Zig resolves ONE `labelle_android` package. Released bgfx pins labelle-android
v0.1.1 by hash; next to a `local:` plugin that is a second copy of the same
JNI C, and the `libgame.so` link fails on duplicate
`labelle_android_*` symbols (labelle-cli#405 D11). Drop the rewrite once
bgfx pins the labelle-android release that ships this provider (#405 PR 4b).
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--cli', required=True)
p.add_argument('--bgfx', required=True, help='a labelle-bgfx checkout at v0.29.1')
p.add_argument('--keep', help='build the project in this directory and leave it there')
a = p.parse_args()
cli = str(Path(a.cli).resolve())
repo = Path(__file__).resolve().parents[2]
sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
exe = '.exe' if os.name == 'nt' else ''


def newest_build_tools():
    versions = [d for d in (sdk / 'build-tools').iterdir() if (d / f'aapt{exe}').exists()]
    return max(versions, key=lambda d: [int(x) for x in re.findall(r'\d+', d.name)[:3]])


bt = newest_build_tools()
apksigner = bt / ('apksigner.bat' if os.name == 'nt' else 'apksigner')
aapt = bt / f'aapt{exe}'

# The pins Flying Platform ships with (bgfx on Android is verified there).
PROJECT = '''.{{
    .name = "tiny_android",
    .title = "Tiny Android",
    .width = 800,
    .height = 600,
    .target_fps = 60,
    .backend = .bgfx,
    .backend_package = .{{ .name = "bgfx", .repo = "local:{bgfx}", .version = "0.29.1" }},
    .gamepad = .none,
    .y_axis = .up,
    .ecs = .mock,
    .initial_prefab = "main",
    .states = .{{"playing"}},
    .layers = .{{ .{{ .name = "hud", .order = 0, .space = .screen }} }},
    .core_version = "2.1.0",
    .engine_version = "3.4.1",
    .gfx_version = "2.2.0",
    .assembler_version = "0.115.0",
    .android = .{{ .immersive_mode = true }},
    .plugins = .{{ .{{ .name = "android", .repo = "local:{repo}" }} }},
    .provider_config = .{{ .{{ .package = "android", .file = "providers/android.json" }} }},
}}
'''

SCENE = '''{
    "name": "main",
    "children": [
        {
            "name": "rect",
            "components": {
                "Position": { "x": 400, "y": 300 },
                "Shape": {
                    "shape": { "rectangle": { "width": 160, "height": 160 } },
                    "color": { "r": 230, "g": 30, "b": 200, "a": 255 },
                    "layer": "hud"
                }
            }
        }
    ]
}
'''

SETTINGS = {
    'schema_version': 1,
    'package_name': 'com.labelle.tiny_android',
    'orientation': 'landscape',
    'version_name': '0.3',
}


def run(argv, cwd, **kw):
    print('+', ' '.join(str(x) for x in argv), flush=True)
    result = subprocess.run([str(x) for x in argv], cwd=cwd, capture_output=True, encoding='utf-8',
                            errors='replace', **kw)
    out = result.stdout + result.stderr
    if result.returncode != 0:
        print(out)
        raise SystemExit(f'{argv[0]} exited {result.returncode}')
    return out


def badging(apk):
    return run([aapt, 'dump', 'badging', apk], cwd=apk.parent)


def inventory(apk):
    """`unzip -Zv` → {name: (method, size)}."""
    out = run(['unzip', '-Zv', apk], cwd=apk.parent)
    entries = {}
    for block in out.split('Central directory entry #')[1:]:
        # `#<n>:`, a rule, then the entry's name, after any zipalign
        # padding note ("There are an extra N bytes preceding this file.").
        lines = [line.strip() for line in block.split('\n')[2:]]
        name = next(line for line in lines if line and not line.startswith('There are an extra'))
        method = re.search(r'compression method:\s+(.+)', block).group(1).strip()
        size = int(re.search(r'uncompressed size:\s+(\d+)', block).group(1))
        entries[name] = (method, size)
    return entries


def check_apk(apk, version_code, symbols_so):
    run([apksigner, 'verify', '--verbose', apk], cwd=apk.parent)
    b = badging(apk)
    for needle in (f"package: name='com.labelle.tiny_android' versionCode='{version_code}' versionName='0.3'",
                   "sdkVersion:'28'", "targetSdkVersion:'34'", "application-label:'Tiny Android'",
                   "launchable-activity: name='android.app.NativeActivity'", "icon='res/mipmap-"):
        assert needle in b, (needle, b)
    assert re.search(r"application-icon-640:'res/mipmap-xxxhdpi(-v4)?/ic_launcher.png'", b), b
    files = inventory(apk)
    lib = files['lib/arm64-v8a/libgame.so']
    assert lib[0] == 'none (stored)', lib
    assert lib[1] < symbols_so.stat().st_size, (lib, symbols_so.stat().st_size)
    assert files['resources.arsc'][0] == 'none (stored)', files['resources.arsc']
    for density in ('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi'):
        assert any(n.startswith('res/mipmap-' + density) and n.endswith('/ic_launcher.png') for n in files), density
    assert 'assets/keep.txt' in files, sorted(files)
    assert not any(n.startswith('assets/raw/') for n in files), sorted(files)
    return files


def stage_bgfx(root, project):
    """The bgfx copy whose labelle_android is the staged plugin (see above)."""
    bgfx = root / 'labelle-bgfx'
    shutil.rmtree(bgfx, ignore_errors=True)
    shutil.copytree(Path(a.bgfx), bgfx, ignore=shutil.ignore_patterns('.git', '.zig-cache', 'zig-out', '.labelle'))
    zon = bgfx / 'build.zig.zon'
    text = zon.read_text()
    patched, n = re.subn(r'\.labelle_android = \.\{\s*\.url = "[^"]+",\s*\.hash = "[^"]+",\s*\}',
                         '.labelle_android = .{ .path = "../%s/.labelle/deps/labelle-android" }' % project.name, text)
    assert n == 1, 'labelle_android dependency not found in ' + str(zon)
    zon.write_text(patched)
    return bgfx


def main(root):
    project = root / 'tiny'
    bgfx = stage_bgfx(root, project)
    shutil.rmtree(project, ignore_errors=True)
    (project / 'scenes').mkdir(parents=True)
    (project / 'providers').mkdir()
    (project / 'assets/raw').mkdir(parents=True)
    (project / 'scripts').mkdir()
    (project / 'scripts/.gitkeep').write_text('')
    (project / 'project.labelle').write_text(PROJECT.format(repo=repo.as_posix(), bgfx=bgfx.as_posix()))
    (project / 'scenes/main.jsonc').write_text(SCENE)
    (project / 'providers/android.json').write_text(json.dumps(SETTINGS, indent=2))
    (project / 'assets/keep.txt').write_text('shipped: no rule leaves it out')
    (project / 'assets/raw/source.txt').write_text('packer source: never shipped')

    # The pinned CLI is a `development` build, versioned below the releases
    # the pinned packages expect.
    out = run([cli, 'bundle', '--platform=android', '--optimize=ReleaseFast', '--build-number=3'],
              cwd=project, timeout=3600, env=dict(os.environ, LABELLE_ALLOW_OLDER_CLI='1'))
    print(out[-4000:])
    target = project / '.labelle' / 'bgfx_android'
    apk = target / 'zig-out/apk/game.apk'
    bundled = target / 'zig-out/bundle/android/com.labelle.tiny_android-0.3.apk'
    assert apk.is_file() and bundled.is_file(), out
    check_apk(apk, 1, target / 'zig-out/apk/symbols/arm64-v8a/libgame.so')
    files = check_apk(bundled, 3, target / 'zig-out/bundle/android/com.labelle.tiny_android-0.3-symbols/arm64-v8a/libgame.so')
    print('inventory:')
    for name, (method, size) in sorted(files.items()):
        print(f'  {size:>10}  {method:<16} {name}')
    print('labelle-android NDK e2e: ok')


if a.keep:
    keep = Path(a.keep).resolve()
    keep.mkdir(parents=True, exist_ok=True)
    main(keep)
else:
    with tempfile.TemporaryDirectory(prefix='labelle-android-ndk-') as temp:
        main(Path(temp).resolve())
