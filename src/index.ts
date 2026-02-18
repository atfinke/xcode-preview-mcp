import { execFile } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const execFileAsync = promisify(execFile);
const thisFile = fileURLToPath(import.meta.url);
const thisDir = path.dirname(thisFile);
const LOG_COMPONENT = "xcode-preview-mcp";
const HELPER_TIMEOUT_MS = 30_000;
const HELPER_MAX_BUFFER_BYTES = 20 * 1024 * 1024;

const DEFAULT_HELPER_PATH = path.resolve(
  thisDir,
  "../helper/.build/release/xcode-preview-helper",
);

const helperPath = process.env.XCODE_PREVIEW_HELPER_PATH ?? DEFAULT_HELPER_PATH;

function log(
  level: "INFO" | "ERROR",
  message: string,
  metadata: Record<string, unknown> = {},
) {
  const payload = {
    timestamp: new Date().toISOString(),
    level,
    component: LOG_COMPONENT,
    message,
    ...metadata,
  };
  console.error(JSON.stringify(payload));
}

function defaultCapturePath() {
  const timestamp = new Date().toISOString().replaceAll(":", "-");
  return `/tmp/xcode-simulator-captures/xcode-active-sim-${timestamp}.png`;
}

function toCliOptions(raw: Record<string, unknown>): string[] {
  const args: string[] = [];
  for (const [key, value] of Object.entries(raw)) {
    if (value === undefined || value === null) {
      continue;
    }

    args.push(`--${key}`, String(value));
  }
  return args;
}

function parseHelperStderr(stderr: string): string {
  const trimmed = stderr.trim();
  if (!trimmed) {
    return "Helper returned no stderr";
  }

  try {
    const parsed = JSON.parse(trimmed) as { error?: unknown };
    if (parsed && typeof parsed.error === "string" && parsed.error.trim()) {
      return parsed.error.trim();
    }
  } catch {
    // Non-JSON stderr is still useful as-is.
  }

  return trimmed;
}

function describeUnknownError(error: unknown): string {
  if (error instanceof Error && error.message) {
    return error.message;
  }
  return String(error);
}

async function runHelper(command: string, options: Record<string, unknown>) {
  const args = [command, ...toCliOptions(options)];

  try {
    const result = await execFileAsync(helperPath, args, {
      maxBuffer: HELPER_MAX_BUFFER_BYTES,
      timeout: HELPER_TIMEOUT_MS,
    });

    const stdout = result.stdout.trim();
    if (!stdout) {
      throw new Error(`Helper command '${command}' returned no stdout`);
    }

    try {
      return JSON.parse(stdout) as unknown;
    } catch (error) {
      throw new Error(
        `Helper command '${command}' returned invalid JSON: ${describeUnknownError(error)}`,
      );
    }
  } catch (error) {
    if (error && typeof error === "object" && "stderr" in error) {
      const stderr = String((error as { stderr?: string }).stderr ?? "");
      const timeoutSuffix = "killed" in error && error.killed ? " (timed out)" : "";
      if (stderr) {
        throw new Error(
          `Helper command '${command}' failed${timeoutSuffix}: ${parseHelperStderr(stderr)}`,
        );
      }
    }

    throw new Error(`Helper command '${command}' failed: ${describeUnknownError(error)}`);
  }
}

async function ensureHelperExists() {
  try {
    await access(helperPath, fsConstants.R_OK | fsConstants.X_OK);
  } catch {
    throw new Error(
      `Missing helper binary at ${helperPath}. Build it first: cd tools/xcode-preview-mcp && npm run build:helper`,
    );
  }
}

async function main() {
  const server = new McpServer({
    name: "xcode-preview-mcp",
    version: "0.1.0",
  });

  server.registerTool(
    "xcode_preview_permissions",
    {
      title: "Xcode Preview Permissions",
      description:
        "Check and optionally prompt macOS screen recording and accessibility permissions needed for Xcode preview capture.",
      inputSchema: {
        promptScreen: z.boolean().optional(),
        promptAccessibility: z.boolean().optional(),
      },
    },
    async ({ promptScreen, promptAccessibility }) => {
      await ensureHelperExists();
      const result = await runHelper("permissions", {
        "prompt-screen": promptScreen ?? false,
        "prompt-accessibility": promptAccessibility ?? false,
      });

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2),
          },
        ],
      };
    },
  );

  server.registerTool(
    "xcode_preview_list_windows",
    {
      title: "List Xcode Windows",
      description: "List visible Xcode windows discovered by ScreenCaptureKit.",
      annotations: {
        readOnlyHint: true,
      },
      inputSchema: {
        bundleId: z.string().optional(),
        titleContains: z.string().optional(),
        onScreenOnly: z.boolean().optional(),
      },
    },
    async ({ bundleId, titleContains, onScreenOnly }) => {
      await ensureHelperExists();
      const result = await runHelper("list-windows", {
        "bundle-id": bundleId ?? "com.apple.dt.Xcode",
        "title-contains": titleContains,
        "on-screen-only": onScreenOnly ?? true,
      });

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2),
          },
        ],
      };
    },
  );

  server.registerTool(
    "xcode_preview_capture",
    {
      title: "Capture Active Xcode Simulator",
      description:
        "Capture only the active simulator from Xcode preview, with optional max-longest-edge downscale, and return active editor file hints. Fails if Xcode is not open or no simulator preview is active.",
      inputSchema: {
        bundleId: z.string().optional(),
        titleContains: z.string().optional(),
        onScreenOnly: z.boolean().optional(),
        windowIndex: z.number().int().min(0).optional(),
        outputPath: z.string().optional(),
        maxLongEdge: z.number().int().min(1).optional(),
        promptScreen: z.boolean().optional(),
        promptAccessibility: z.boolean().optional(),
      },
    },
    async ({
      bundleId,
      titleContains,
      onScreenOnly,
      windowIndex,
      outputPath,
      maxLongEdge,
      promptScreen,
      promptAccessibility,
    }) => {
      await ensureHelperExists();

      const finalOutputPath = outputPath ?? defaultCapturePath();
      const result = await runHelper("capture", {
        "bundle-id": bundleId ?? "com.apple.dt.Xcode",
        "title-contains": titleContains,
        "on-screen-only": onScreenOnly ?? true,
        "window-index": windowIndex ?? 0,
        "output-path": finalOutputPath,
        "max-long-edge": maxLongEdge,
        "prompt-screen": promptScreen ?? false,
        "prompt-accessibility": promptAccessibility ?? false,
      });

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(result, null, 2),
          },
        ],
      };
    },
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);

  log("INFO", "server started", { helperPath });
}

main().catch((error) => {
  log("ERROR", "fatal server error", { error: describeUnknownError(error) });
  process.exit(1);
});
