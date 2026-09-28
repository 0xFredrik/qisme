#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/reproducible.py build
APP="$PWD/dist/qisme.app"
# Always start from the unsigned build, never from an earlier signed bundle.
if [[ -d "$APP" ]]; then
    rm -rf "$APP"
fi
ditto "dist/reproducible/qisme.app" "$APP"
SIGNING_ARGS=(--force --sign "${CODE_SIGN_IDENTITY:--}")
if [[ "${CODE_SIGN_IDENTITY:--}" != - ]]; then
    SIGNING_ARGS+=(--options runtime --timestamp)
else
    SIGNING_ARGS+=(--timestamp=none)
fi
codesign "${SIGNING_ARGS[@]}" "$APP/Contents/Helpers/m1ddc"
codesign "${SIGNING_ARGS[@]}" "$APP/Contents/Helpers/display-discovery"
codesign "${SIGNING_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
python3 - "$APP" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'scripts')
from reproducible import run, verify_app
verify_app(Path(sys.argv[1]), Path('dist/reproducible/qisme.app'))
run([Path(sys.argv[1]) / 'Contents/MacOS/qisme', '--help'], capture_output=True)
run([Path(sys.argv[1]) / 'Contents/Helpers/m1ddc'], capture_output=True)
run([Path(sys.argv[1]) / 'Contents/Helpers/display-discovery', '--help'], capture_output=True)
PY
echo "Built: $APP"
