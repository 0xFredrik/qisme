#!/usr/bin/env python3
"""Copy unmodified m1ddc sources into an isolated build directory."""

from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = ROOT / 'vendor/m1ddc'


def upstream_files():
    required = [UPSTREAM / name for name in ('LICENSE', 'sources/m1ddc.m', 'headers/ioregistry.h')]
    if not all(path.is_file() for path in required):
        raise ValueError('m1ddc is missing. Run: git submodule update --init --recursive')
    return sorted([UPSTREAM / 'LICENSE', *UPSTREAM.glob('sources/*.m'), *UPSTREAM.glob('headers/*.h')])


def prepare(destination):
    files = upstream_files()
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise ValueError(f'Expected an empty build directory: {destination}')
    for source in files:
        target = destination / source.relative_to(UPSTREAM)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    return destination


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: prepare_m1ddc.py EMPTY_BUILD_DIRECTORY')
    try:
        prepare(Path(sys.argv[1]))
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
