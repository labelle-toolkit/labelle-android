"""labelle-cli#446: the built tool's output, redirected to a FILE, is appended.

python tests/provider/stdio_e2e.py --tool zig-out/bin/labelle-android[.exe]

Models `labelle doctor > out.txt 2>&1`: one open file that already holds a
"CLI" line is handed to the tool as BOTH stdout and stderr, then the "CLI"
appends another line. Every line must survive, whole and in order. A
positional writer in the tool (Zig 0.16's `File.writer`) pwrite()s from
offset 0 and overwrites the first line.

Python, not a Zig harness, on purpose: Python passes the file to the child
the way a shell redirect does on every OS (POSIX dup2; Windows
DuplicateHandle, so parent and child share ONE file object and its file
pointer). Zig 0.16's `std.process.spawn` with `.stdout = .{ .file = f }`
instead RE-OPENS the file on Windows (`OpenFile` relative to the handle, in
`Io/Threaded.zig` `processSpawnWindows`), which gives the child a fresh file
pointer at 0 and would fail even a correct, streaming tool.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--tool", required=True)
tool = str(Path(parser.parse_args().tool).resolve())

before = b"cli: a line written before the provider ran\n"
after = b"cli: a line written after the provider exited\n"
want = (before + b"labelle-android: run me through labelle (LABELLE_CONTEXT is not set)\n"
        b"labelle-android: MissingContext\n" + after)

# No LABELLE_CONTEXT: the tool prints its two-line refusal and exits 1.
env = {k: v for k, v in os.environ.items() if k != "LABELLE_CONTEXT"}
with tempfile.TemporaryDirectory(prefix="labelle-android-stdio-") as temp:
    path = Path(temp) / "redirected.txt"
    with open(path, "wb", buffering=0) as sink:
        sink.write(before)
        code = subprocess.run([tool], stdin=subprocess.DEVNULL, stdout=sink, stderr=subprocess.STDOUT,
                              env=env, timeout=60).returncode
        sink.write(after)
    got = path.read_bytes().replace(b"\r\n", b"\n")
assert code == 1, f"expected the tool to refuse with exit 1, got {code}"
assert got == want, ("redirected output mismatch (cli#446)", want.decode(), got.decode(errors="replace"))
print("labelle-android redirected stdio: ok")
