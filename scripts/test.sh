#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

swift package resolve
CRYPTOLIB_DIR="$REPO_ROOT/.build/checkouts/cryptolib-swift"
PATCH_FILE="$SCRIPT_DIR/patches/cryptolib-swift.patch"
if git -C "$CRYPTOLIB_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$CRYPTOLIB_DIR" apply "$PATCH_FILE"
elif ! git -C "$CRYPTOLIB_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    echo "Cryptomator 依赖补丁不匹配，请检查依赖版本。" >&2
    exit 1
fi
swift run CloudDriveTestsRunner "$@"
