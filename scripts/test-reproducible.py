#!/usr/bin/env python3
"""Require two clean builds in different paths to produce the same archive."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from reproducible import APP_NAME, EXECUTABLES, ROOT, digest, run, source_files, verify_app


def sign(app):
    for executable in sorted(EXECUTABLES):
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime", app / executable],
            capture_output=True)
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime", app], capture_output=True)


def must_reject(app, expected):
    try:
        verify_app(app, expected)
    except ValueError:
        return
    raise AssertionError("Modified release incorrectly passed verification")


with tempfile.TemporaryDirectory(prefix="input-selector-repro-test-") as temporary:
    base = Path(temporary)
    archives = []
    for index, name in enumerate(("first", "a different checkout with spaces")):
        checkout = base / name
        for source in source_files():
            target = checkout / source.relative_to(ROOT)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            os.utime(target, (946684800 + index * 86400, 946684800 + index * 86400))
        # Vary environment, source mtimes, output paths and umask; caches start empty.
        env = dict(os.environ, TZ=("Pacific/Honolulu" if index else "Europe/Stockholm"),
                   LC_ALL=("en_US.UTF-8" if index else "C"))
        subprocess.run([sys.executable, checkout / "scripts/reproducible.py", "build"],
                       check=True, cwd=checkout, env=env,
                       preexec_fn=lambda: os.umask(0o077 if index else 0o022))
        archives.append(next((checkout / "dist/reproducible").glob("*.zip")))
    if archives[0].read_bytes() != archives[1].read_bytes():
        raise SystemExit("FAIL: independent builds produced different archives")
    print(f"PASS: both clean builds produced SHA-256 {digest(archives[0])}")

    expected = archives[0].parent / APP_NAME
    candidate = base / "release" / APP_NAME
    shutil.copytree(expected, candidate)
    sign(candidate)
    verify_app(candidate, expected)
    run([candidate / "Contents/MacOS/InputSelector", "--help"], capture_output=True)
    run([candidate / "Contents/Helpers/m1ddc"], capture_output=True)
    run([candidate / "Contents/Helpers/display-discovery", "--help"], capture_output=True)
    print("PASS: signed app and helpers launch successfully without monitor commands")
    # A valid new signature must not hide a changed resource or extra payload.
    license_file = candidate / "Contents/Resources/LICENSE.txt"
    license_file.write_text(license_file.read_text() + "\nModified\n")
    sign(candidate)
    must_reject(candidate, expected)
    shutil.copyfile(expected / "Contents/Resources/LICENSE.txt", license_file)
    (candidate / "Contents/Resources/unexpected.txt").write_text("extra payload")
    sign(candidate)
    must_reject(candidate, expected)
    (candidate / "Contents/Resources/unexpected.txt").unlink()
    helper = candidate / "Contents/Helpers/m1ddc"
    data = bytearray(helper.read_bytes())
    data[4096] ^= 1  # Alter code, then give the modified release a valid signature.
    helper.write_bytes(data)
    sign(candidate)
    must_reject(candidate, expected)
    print("PASS: verification accepts a signed copy and rejects changed code, resources and added files")

    output = ROOT / "dist/reproducible"
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(archives[0].parent, output)
