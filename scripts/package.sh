#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/build"
PACKAGE_ROOT="$BUILD_ROOT/package"
ZIP_PATH="$BUILD_ROOT/lambda_function.zip"

command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required" >&2; exit 1; }
rm -rf "$PACKAGE_ROOT" "$ZIP_PATH"
mkdir -p "$PACKAGE_ROOT"
python3 -m pip install --disable-pip-version-check --no-compile --target "$PACKAGE_ROOT" -r "$REPO_ROOT/src/requirements.txt"
cp "$REPO_ROOT/src/lambda_function.py" "$PACKAGE_ROOT/"
(cd "$PACKAGE_ROOT" && zip -qr "$ZIP_PATH" .)
echo "Lambda deployment package created: $ZIP_PATH"
