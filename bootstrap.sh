#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pushd "$ROOT_DIR" >/dev/null
npm ci
npm run build
npm run build:helper-app
popd >/dev/null

echo "Bootstrap complete."
echo "Helper app: $ROOT_DIR/XcodePreviewMCPHelperApp/build/Build/Products/Release/XcodePreviewMCPHelperApp.app"
echo "MCP server: $ROOT_DIR/dist/index.js"
