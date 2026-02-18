import { execFile } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
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
const HELPER_POLL_INTERVAL_MS = 100;
const HELPER_MAX_BUFFER_BYTES = 20 * 1024 * 1024;

const DEFAULT_HELPER_APP_PATH = path.resolve(
  thisDir,
  "../XcodePreviewMCPHelperApp/build/Build/Products/Release/XcodePreviewMCPHelperApp.app",
);

const helperAppPath = process.env.XCODE_PREVIEW_APP_PATH ?? DEFAULT_HELPER_APP_PATH;
const helperExecutablePath = path.join(
  helperAppPath,
  "Contents",
  "MacOS",
  "XcodePreviewMCPHelperApp",
);

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

function describeUnknownError(error: unknown): string {
  if (error instanceof Error && error.message) {
    return error.message;
  }
  return String(error);
}

function parseHelperErrorPayload(payload: unknown): string | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const maybeError = (payload as { error?: unknown }).error;
  if (typeof maybeError === "string" && maybeError.trim()) {
    return maybeError.trim();
  }
  return null;
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForHelperResponse(responsePath: string, command: string) {
  const deadline = Date.now() + HELPER_TIMEOUT_MS;
  let lastError: unknown;

  while (Date.now() < deadline) {
    try {
      const raw = await readFile(responsePath, "utf8");
      if (!raw.trim()) {
        await sleep(HELPER_POLL_INTERVAL_MS);
        continue;
      }

      const payload = JSON.parse(raw) as unknown;
      const helperError = parseHelperErrorPayload(payload);
      if (helperError) {
        throw new Error(`Helper command '${command}' failed: ${helperError}`);
      }

      return payload;
    } catch (error) {
      if (
        error &&
        typeof error === "object" &&
        "code" in error &&
        (error as { code?: string }).code === "ENOENT"
      ) {
        // App has not written the response file yet.
      } else if (error instanceof Error && error.message.startsWith("Helper command '")) {
        throw error;
      } else {
        lastError = error;
      }
    }

    await sleep(HELPER_POLL_INTERVAL_MS);
  }

  const suffix = lastError ? `: ${describeUnknownError(lastError)}` : "";
  throw new Error(
    `Helper command '${command}' timed out waiting for app response at ${responsePath}${suffix}`,
  );
}

async function runHelper(command: string, options: Record<string, unknown>) {
  const tempDir = await mkdtemp(path.join(tmpdir(), "xcode-preview-mcp-helper-app-"));
  const responsePath = path.join(tempDir, "response.json");
  const args = [
    "-n",
    "-a",
    helperAppPath,
    "--args",
    command,
    ...toCliOptions(options),
    "--response-path",
    responsePath,
  ];

  try {
    await execFileAsync("open", args, {
      maxBuffer: HELPER_MAX_BUFFER_BYTES,
      timeout: HELPER_TIMEOUT_MS,
    });
    return await waitForHelperResponse(responsePath, command);
  } catch (error) {
    const errorMessage =
      error && typeof error === "object" && "message" in error
        ? String((error as { message?: unknown }).message ?? "")
        : typeof error === "string"
          ? error
          : "";
    if (errorMessage.startsWith(`Helper command '${command}'`)) {
      throw new Error(errorMessage);
    }

    if (error && typeof error === "object" && "stderr" in error) {
      const stderr = String((error as { stderr?: string }).stderr ?? "");
      const timeoutSuffix = "killed" in error && error.killed ? " (timed out)" : "";
      if (stderr) {
        throw new Error(`Failed to launch helper app${timeoutSuffix}: ${stderr.trim()}`);
      }
    }

    throw new Error(
      `Helper command '${command}' failed while launching helper app: ${describeUnknownError(error)}`,
    );
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

async function ensureHelperExists() {
  try {
    await access(helperExecutablePath, fsConstants.R_OK | fsConstants.X_OK);
  } catch {
    throw new Error(
      `Missing helper app executable at ${helperExecutablePath}. Build it first: cd tools/xcode-preview-mcp && npm run build:helper-app`,
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

  log("INFO", "server started", { helperAppPath, helperExecutablePath });
}

main().catch((error) => {
  log("ERROR", "fatal server error", { error: describeUnknownError(error) });
  process.exit(1);
});
