#!/usr/bin/env python3
"""Exercise the packaged executable's loader without starting capture or the GUI."""

import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


def verify(app: Path) -> None:
    app = app.resolve()
    with (app / "Contents/Info.plist").open("rb") as source:
        executable_name = plistlib.load(source)["CFBundleExecutable"]
    executable = app / "Contents/MacOS" / executable_name
    # Developer library paths can hide missing or unloadable embedded frameworks.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
    with tempfile.TemporaryDirectory(prefix="jottie-launch-check-") as directory:
        completed = subprocess.run(
            [str(executable), "--help"], cwd=directory, env=environment,
            capture_output=True, text=True, timeout=30, check=False,
        )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"packaged executable failed to launch ({completed.returncode}):\n{detail}")
    if "USAGE:" not in completed.stdout:
        raise RuntimeError("packaged executable did not return CLI help")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} APP", file=sys.stderr)
        return 2
    try:
        verify(Path(sys.argv[1]))
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("Packaged executable launches with embedded frameworks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
