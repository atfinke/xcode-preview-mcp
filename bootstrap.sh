#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pushd "$ROOT_DIR/helper" >/dev/null
swift build -c release
popd >/dev/null

pushd "$ROOT_DIR" >/dev/null
npm ci
npm run build
popd >/dev/null

echo "Bootstrap complete."
echo "Helper: $ROOT_DIR/helper/.build/release/xcode-preview-helper"
echo "MCP server: $ROOT_DIR/dist/index.js"
