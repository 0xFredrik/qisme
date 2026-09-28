#!/usr/bin/env python3
"""Build a deterministic unsigned app, or compare a release against that build."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import zipfile

from prepare_m1ddc import prepare, upstream_files

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Input Selector.app"
EXECUTABLES = {"Contents/MacOS/InputSelector", "Contents/Helpers/m1ddc", "Contents/Helpers/display-discovery"}
LOCK = ROOT / "macos/toolchain.json"


def environment():
    # Ignore ambient compiler flags, include paths, locale and module caches.
    result = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "TZ": "UTC",
              "ZERO_AR_DATE": "1", "HOME": os.environ["HOME"],
              "TMPDIR": tempfile.gettempdir(),
              "DEVELOPER_DIR": os.environ.get("DEVELOPER_DIR", "/Library/Developer/CommandLineTools")}
    return result


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, env=environment(), **kwargs)


def output(*args):
    return run(args, capture_output=True, text=True).stdout.strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def toolchain():
    sdk = Path(output("xcrun", "--sdk", "macosx", "--show-sdk-path"))
    return {
        "architecture": output("uname", "-m"),
        "macos_build": output("sw_vers", "-buildVersion"),
        "swift": output("xcrun", "swiftc", "--version").splitlines()[0],
        "clang": output("xcrun", "clang", "--version").splitlines()[0],
        "linker": json.loads(output("xcrun", "ld", "-version_details")),
        "sdk_version": output("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_build": output("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
        "sdk_settings_sha256": digest(sdk / "SDKSettings.json"),
        "tools_sha256": {name: digest(Path(output("xcrun", "--find", name)))
                         for name in ("clang", "swift-frontend", "swiftc", "ld")},
    }


def check_toolchain():
    expected, actual = json.loads(LOCK.read_text()), toolchain()
    if actual != expected:
        differences = [key for key in expected.keys() | actual.keys() if expected.get(key) != actual.get(key)]
        raise ValueError("Toolchain differs from macos/toolchain.json: " + ", ".join(sorted(differences))
                         + ". See README.md#build for the required tools.")
    return actual


def source_files():
    paths = [ROOT / "LICENSE", ROOT / "macos/Info.plist", LOCK,
             ROOT / ".gitmodules"]
    for directory, suffixes in (("macos/Sources", {".swift"}),
                                ("macos/DisplayDiscovery", {".m", ".h"}),
                                ("macos/Resources", {".icns", ".png"}),
                                ("scripts", {".py", ".sh", ".swift", ".txt"})):
        paths.extend(p for p in (ROOT / directory).iterdir() if p.suffix in suffixes)
    paths.extend(upstream_files())
    return sorted(paths)


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def contents(app):
    result = {}
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Unexpected symlink: {path}")
        if path.is_file():
            result[path.relative_to(app).as_posix()] = {
                "sha256": digest(path), "mode": stat.S_IMODE(path.stat().st_mode)
            }
        elif not path.is_dir():
            raise ValueError(f"Unexpected file type: {path}")
    return result


def archive(app, info, destination):
    # ZIP_STORED avoids compression differences between Python/zlib versions.
    entries = {f"{APP_NAME}/{name}": (app / name).read_bytes() for name in contents(app)}
    entries["build-info.json"] = json_bytes(info)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_STORED) as zipped:
        for name, data in sorted(entries.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            mode = 0o755 if name.removeprefix(APP_NAME + "/") in EXECUTABLES else 0o644
            entry.external_attr = (stat.S_IFREG | mode) << 16
            zipped.writestr(entry, data)


def build(destination):
    tools = check_toolchain()
    destination.mkdir(parents=True, exist_ok=True)
    source_hashes = {p.relative_to(ROOT).as_posix(): digest(p) for p in source_files()}
    sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
    with tempfile.TemporaryDirectory(prefix="qisme-build-") as temporary:
        working = Path(temporary)
        app = working / APP_NAME
        for folder in ("MacOS", "Helpers", "Resources"):
            (app / "Contents" / folder).mkdir(parents=True)
        cache = working / "cache"
        helper = prepare(working / "m1ddc")
        # Stable module name and source paths; keep the linker's content-derived UUID.
        run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror", "-fmodules",
             "-target", "arm64-apple-macosx13.0", "-isysroot", sdk,
             f"-fmodules-cache-path={cache}", f"-ffile-prefix-map={helper}=/src/vendor/m1ddc",
             "-Wl,-no_adhoc_codesign", "-DMAX_DISPLAYS=32",
             "-I", "headers",
             *[p.relative_to(helper) for p in sorted((helper / "sources").glob("*.m"))],
             "-framework", "Foundation", "-framework", "IOKit", "-framework", "CoreGraphics",
             "-framework", "CoreDisplay", "-o", app / "Contents/Helpers/m1ddc"], cwd=helper)
        run(["xcrun", "clang", "-O2", "-Wall", "-Wextra", "-Werror", "-fmodules",
             "-target", "arm64-apple-macosx13.0", "-isysroot", sdk,
             f"-fmodules-cache-path={cache}", f"-ffile-prefix-map={ROOT}=/src",
             f"-ffile-prefix-map={helper}=/src/vendor/m1ddc",
             "-Wl,-no_adhoc_codesign", "-DMAX_DISPLAYS=32", "-I", helper / "headers",
             "macos/DisplayDiscovery/main.m", "macos/DisplayDiscovery/capabilities.m",
             helper / "sources/ioregistry.m",
             "-framework", "Foundation", "-framework", "IOKit", "-framework", "CoreGraphics",
             "-framework", "CoreDisplay", "-o", app / "Contents/Helpers/display-discovery"], cwd=ROOT)
        run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macosx13.0",
             "-sdk", sdk, "-module-cache-path", cache, "-file-prefix-map", f"{ROOT}=/src",
             "-module-name", "InputSelector", "-Xlinker", "-no_adhoc_codesign",
             *[p.relative_to(ROOT) for p in sorted((ROOT / "macos/Sources").glob("*.swift"))],
             "-o", app / "Contents/MacOS/InputSelector"], cwd=ROOT)
        for source, target in (("macos/Info.plist", "Contents/Info.plist"),
                               ("macos/Resources/AppIcon.icns", "Contents/Resources/AppIcon.icns"),
                               ("LICENSE", "Contents/Resources/LICENSE.txt"),
                               ("vendor/m1ddc/LICENSE", "Contents/Resources/m1ddc-LICENSE.txt")):
            shutil.copyfile(ROOT / source, app / target)
        for path in app.rglob("*"):
            path.chmod(0o755 if path.is_dir() or path.relative_to(app).as_posix() in EXECUTABLES else 0o644)
        app.chmod(0o755)
        if source_hashes != {p.relative_to(ROOT).as_posix(): digest(p) for p in source_files()}:
            raise ValueError("Source files changed during the build; run it again.")
        info = {"format": 1, "toolchain": tools, "sources": source_hashes, "files": contents(app)}
        version = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
        name = f"qisme-{version}-arm64-reproducible.zip"
        archive(app, info, destination / name)
        (destination / (name + ".sha256")).write_text(f"{digest(destination / name)}  {name}\n")
        (destination / "build-info.json").write_bytes(json_bytes(info))
        installed = destination / APP_NAME
        if installed.exists():
            shutil.rmtree(installed)
        shutil.copytree(app, installed)
        print(f"Reproducible archive: {destination / name}")
        print(f"SHA-256: {digest(destination / name)}")
        return installed, destination / name


def verify_app(release, expected):
    if release.is_symlink():
        raise ValueError("The app must not be a symlink.")
    contents(release)  # Reject symlinks and special files before copying.
    run(["codesign", "--verify", "--deep", "--strict", release])
    with tempfile.TemporaryDirectory(prefix="qisme-verify-") as temporary:
        copied = Path(temporary) / APP_NAME
        shutil.copytree(release, copied)
        for binary in sorted(EXECUTABLES):
            entitlements = run(["codesign", "-d", "--entitlements", ":-", copied / binary],
                               capture_output=True).stdout
            if entitlements.strip() and plistlib.loads(entitlements):
                raise ValueError(f"Unexpected signing entitlements: {binary}")
            run(["codesign", "--remove-signature", copied / binary])
        # This is the only bundle file that distribution signing is allowed to add.
        resources = copied / "Contents/_CodeSignature/CodeResources"
        if resources.exists():
            resources.unlink()
        actual_files, expected_files = contents(copied), contents(expected)
        differences = sorted(name for name in actual_files.keys() | expected_files.keys()
                             if actual_files.get(name) != expected_files.get(name))
        if differences:
            raise ValueError("Release differs from the local build: " + ", ".join(differences))
    print("VERIFIED: every app file matches the local build after removing distribution signatures.")


def verify(release, expected):
    if release.suffix.lower() != ".dmg":
        verify_app(release, expected)
        return
    with tempfile.TemporaryDirectory(prefix="qisme-mount-") as temporary:
        mount = Path(temporary) / "volume"
        mount.mkdir()
        run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, release],
            capture_output=True)
        try:
            verify_app(mount / APP_NAME, expected)
        finally:
            run(["hdiutil", "detach", mount], capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "verify", "toolchain"))
    parser.add_argument("release", nargs="?", type=Path, help="Downloaded .dmg or .app to verify")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/reproducible")
    args = parser.parse_args()
    if args.command == "toolchain":
        print(json_bytes(toolchain()).decode(), end="")
        return
    if args.command == "verify" and args.release is None:
        parser.error("verify requires a .dmg or .app path")
    app, _ = build(args.output.resolve())
    if args.command == "verify":
        verify(args.release.resolve(), app)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
