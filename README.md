# xcode-preview-mcp

Install this to let Codex (or any MCP client) capture your **open Xcode preview simulator**.

## Install

```bash
cd tools/xcode-preview-mcp
./bootstrap.sh
```

## Run

```bash
cd tools/xcode-preview-mcp
npm run start
```

## Permissions

Call `xcode_preview_permissions` with prompts enabled once:

- `promptScreen: true`
- `promptAccessibility: true`

After you approve both, capture works.

## MCP config

```json
{
  "mcpServers": {
    "xcodePreview": {
      "command": "node",
      "args": ["/Users/andrewfinke/projects/Attractions Collection/tools/xcode-preview-mcp/dist/index.js"],
      "env": {
        "XCODE_PREVIEW_HELPER_PATH": "/Users/andrewfinke/projects/Attractions Collection/tools/xcode-preview-mcp/helper/.build/release/xcode-preview-helper"
      }
    }
  }
}
```

## Main tool

Use `xcode_preview_capture`. It returns the simulator image path + metadata and fails fast if Xcode/preview/permissions are not ready.
