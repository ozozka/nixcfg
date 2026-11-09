import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { generateUnifiedPatch, isToolCallEventType } from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "session-metrics";
const CODEX_PROVIDER = "openai-codex";
const STALE_AFTER_MS = 10 * 60 * 1000;
const AT_PREFIX = /^@/;
const HOME_PREFIX = /^~(?=$|\/)/;

type UsageWindow = {
  usedPercent: number;
  windowMinutes: number;
  resetAt: number;
  observedAt: number;
};

type LineChanges = { added: number; removed: number };

function countPatchLines(patch: string): LineChanges {
  const changes = { added: 0, removed: 0 };
  let inHunk = false;
  for (const line of patch.split("\n")) {
    if (line.startsWith("@@ ")) inHunk = true;
    // Count only hunk bodies, not file headers. Content beginning with ++/--
    // is still a changed line and must not be mistaken for a header.
    else if (inHunk && line.startsWith("+")) changes.added++;
    else if (inHunk && line.startsWith("-")) changes.removed++;
  }
  return changes;
}

function formatDuration(milliseconds: number): string {
  const seconds = Math.floor(Math.max(0, milliseconds) / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  if (hours > 0) return `${hours}h${minutes % 60}m`;
  if (minutes > 0) return `${minutes}m${seconds % 60}s`;
  return `${seconds}s`;
}

function readNumber(value: unknown): number | undefined {
  if (typeof value !== "number" && typeof value !== "string") return;
  if (typeof value === "string" && value.trim() === "") return;
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}

function readWindow(
  used: unknown,
  minutes: unknown,
  reset: unknown,
  observedAt: number,
): UsageWindow | undefined {
  const usedPercent = readNumber(used);
  const windowMinutes = readNumber(minutes);
  const resetAt = readNumber(reset);
  if (
    usedPercent === undefined ||
    usedPercent < 0 ||
    usedPercent > 100 ||
    windowMinutes === undefined ||
    windowMinutes <= 0 ||
    resetAt === undefined ||
    resetAt <= 0
  )
    return;
  return { usedPercent, windowMinutes, resetAt, observedAt };
}

function record(value: unknown): Record<string, unknown> | undefined {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
}

function formatWindowLabel(windowMinutes: number): string {
  if (windowMinutes === 300) return "5h";
  if (windowMinutes === 10_080) return "w";
  return formatDuration(windowMinutes * 60 * 1000);
}

function formatResetIn(resetIn: number): string {
  if (resetIn <= 0) return "due";
  if (resetIn < 60_000) return "<1m";
  if (resetIn >= 86_400_000)
    return `${Math.floor(resetIn / 86_400_000)}d${Math.floor(resetIn / 3_600_000) % 24}h`;
  if (resetIn >= 3_600_000)
    return `${Math.floor(resetIn / 3_600_000)}h${Math.floor(resetIn / 60_000) % 60}m`;
  return `${Math.floor(resetIn / 60_000)}m`;
}

function formatWindow(window: UsageWindow, now: number): string {
  const resetIn = window.resetAt * 1000 - now;
  const stale = now - window.observedAt > STALE_AFTER_MS || resetIn <= 0;
  // A passed reset is not evidence of a fresh quota allocation.
  const remaining = resetIn <= 0 ? "?" : `${Math.round(100 - window.usedPercent)}%`;
  return `${stale ? "~" : ""}${formatWindowLabel(window.windowMinutes)} ${remaining} ${formatResetIn(resetIn)}`;
}

export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setInterval> | undefined;
  let context: ExtensionContext | undefined;
  let activeMilliseconds = 0;
  let activeStartedAt: number | undefined;
  let responseStartedAt: number | undefined;
  let lastPromptMilliseconds = 0;
  let promptOutputTokens = 0;
  let promptModelMilliseconds = 0;
  let lastTps: number | undefined;
  let selectedProvider: string | undefined;
  let requestProvider: string | undefined;
  let lastStatus: string | undefined;
  const usage = new Map<number, UsageWindow>();
  let toolCalls = 0;
  let addedLines = 0;
  let removedLines = 0;

  function addChanges(changes: LineChanges) {
    addedLines += changes.added;
    removedLines += changes.removed;
    updateStatus();
  }

  // The built-in write tool reports no patch, so snapshot the file before it
  // runs and diff once it succeeds. Pi checks a batch's calls before running
  // any of them, so another same-file mutation in one batch can skew counts.
  const writes = new Map<string, { path: string; previous: string; content: string }>();

  function updateStatus() {
    if (!context) return;
    const elapsed = formatDuration(
      activeMilliseconds +
        (activeStartedAt === undefined ? 0 : performance.now() - activeStartedAt),
    );
    const promptElapsed = formatDuration(
      activeStartedAt === undefined
        ? lastPromptMilliseconds
        : performance.now() - activeStartedAt,
    );
    const parts = [`${elapsed}-${promptElapsed}`];
    if (lastTps !== undefined) parts.push(`${lastTps.toFixed(1)} tps`);
    if (selectedProvider === CODEX_PROVIDER && usage.size > 0) {
      parts.push(
        [...usage.values()]
          .sort((a, b) => a.windowMinutes - b.windowMinutes)
          .map((window) => formatWindow(window, Date.now()))
          .join(" - "),
      );
    }
    const theme = context.ui.theme;
    if (toolCalls > 0) parts.push(`${toolCalls} ${toolCalls === 1 ? "call" : "calls"}`);
    if (addedLines > 0 || removedLines > 0) {
      parts.push(
        `${theme.fg("toolDiffAdded", `+${addedLines}`)} ${theme.fg("toolDiffRemoved", `-${removedLines}`)}`,
      );
    }
    // Rebuild themed strings on every update so theme changes refresh colors.
    const status = parts.join(theme.fg("muted", " * "));
    if (status !== lastStatus) {
      context.ui.setStatus(STATUS_KEY, status);
      lastStatus = status;
    }
  }

  function saveWindows(windows: Array<UsageWindow | undefined>) {
    for (const window of windows) {
      if (window) usage.set(window.windowMinutes, window);
    }
    updateStatus();
  }

  function stop() {
    if (timer !== undefined) clearInterval(timer);
    timer = undefined;
    context?.ui.setStatus(STATUS_KEY, undefined);
    context = undefined;
    activeMilliseconds = 0;
    activeStartedAt = undefined;
    responseStartedAt = undefined;
    lastPromptMilliseconds = 0;
    promptOutputTokens = 0;
    promptModelMilliseconds = 0;
    lastTps = undefined;
    selectedProvider = undefined;
    requestProvider = undefined;
    lastStatus = undefined;
    usage.clear();
    writes.clear();
    toolCalls = 0;
    addedLines = 0;
    removedLines = 0;
  }

  pi.on("tool_execution_start", () => {
    if (!context) return;
    toolCalls++;
    updateStatus();
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!context || !isToolCallEventType("write", event)) return;
    const { path, content } = event.input;
    // Same resolution as the write tool: optional @ prefix, ~, then cwd.
    const file = path.replace(AT_PREFIX, "").replace(HOME_PREFIX, homedir());
    let previous: string | undefined;
    try {
      previous = await readFile(resolve(ctx.cwd, file), "utf8");
    } catch (error) {
      // Unreadable files are skipped; the write itself must still run.
      if (record(error)?.code === "ENOENT") previous = "";
    }
    if (previous !== undefined) writes.set(event.toolCallId, { path, previous, content });
  });

  pi.on("tool_execution_end", (event) => {
    const write = writes.get(event.toolCallId);
    writes.delete(event.toolCallId);
    if (!context || event.isError) return;
    if (event.toolName === "write" && write) {
      addChanges(
        countPatchLines(generateUnifiedPatch(write.path, write.previous, write.content, 0)),
      );
    } else if (event.toolName === "edit") {
      const details = record(record(event.result)?.details);
      if (typeof details?.patch === "string") addChanges(countPatchLines(details.patch));
    }
  });

  pi.on("session_start", (_event, ctx) => {
    stop();
    if (ctx.mode !== "tui") return;
    context = ctx;
    selectedProvider = ctx.model?.provider;
    updateStatus();
    // Local display updates only: no quota queries or other network requests.
    // While idle the work clock stays frozen; reset countdowns can still change.
    timer = setInterval(updateStatus, 1000);
    timer.unref();
  });

  pi.on("agent_start", () => {
    if (!context || activeStartedAt !== undefined) return;
    // Accumulate working time across prompts, including tools and retries.
    activeStartedAt = performance.now();
    promptOutputTokens = 0;
    promptModelMilliseconds = 0;
    lastTps = undefined;
    updateStatus();
  });

  pi.on("agent_settled", () => {
    if (!context || activeStartedAt === undefined) return;
    lastPromptMilliseconds = performance.now() - activeStartedAt;
    activeMilliseconds += lastPromptMilliseconds;
    activeStartedAt = undefined;
    updateStatus();
  });

  pi.on("context", (_event, ctx) => {
    // Includes request latency and thinking, but excludes tool execution.
    if (!context) return;
    responseStartedAt = performance.now();
    requestProvider = ctx.model?.provider;
    updateStatus();
  });

  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant" || responseStartedAt === undefined) return;
    const responseMilliseconds = performance.now() - responseStartedAt;
    responseStartedAt = undefined;
    const message = event.message;
    if (
      message.stopReason !== "error" &&
      message.stopReason !== "aborted" &&
      responseMilliseconds > 0 &&
      Number.isFinite(message.usage.output) &&
      message.usage.output > 0
    ) {
      // Aggregate the prompt's measured model calls, excluding time in tools.
      promptOutputTokens += message.usage.output;
      promptModelMilliseconds += responseMilliseconds;
      lastTps = promptOutputTokens / (promptModelMilliseconds / 1000);
    }
    updateStatus();
  });

  pi.on("after_provider_response", (event) => {
    if (!context || requestProvider !== CODEX_PROVIDER || selectedProvider !== CODEX_PROVIDER)
      return;
    const headers = Object.fromEntries(
      Object.entries(event.headers).map(([key, value]) => [key.toLowerCase(), value]),
    );
    const now = Date.now();
    saveWindows(
      ["primary", "secondary"].map((name) => {
        const prefix = `x-codex-${name}-`;
        const resetAt = readNumber(headers[`${prefix}reset-at`]);
        const resetAfter = readNumber(headers[`${prefix}reset-after-seconds`]);
        return readWindow(
          headers[`${prefix}used-percent`],
          headers[`${prefix}window-minutes`],
          resetAt ??
            (resetAfter !== undefined && resetAfter >= 0 ? now / 1000 + resetAfter : undefined),
          now,
        );
      }),
    );
  });

  pi.on("provider_stream_event", (event) => {
    if (!context || event.provider !== CODEX_PROVIDER || selectedProvider !== CODEX_PROVIDER)
      return;
    const data = record(event.data);
    if (data?.type !== "codex.rate_limits") return;
    const limits = record(data.rate_limits);
    if (!limits) return;
    const now = Date.now();
    // Only accept explicit quota snapshots, never infer quotas from token usage.
    saveWindows(
      ["primary", "secondary"].map((name) => {
        const window = record(limits[name]);
        if (!window) return undefined;
        return readWindow(
          window.used_percent,
          window.window_minutes ?? window.limit_window_minutes,
          window.reset_at,
          now,
        );
      }),
    );
  });

  pi.on("model_select", (event) => {
    if (!context) return;
    if (selectedProvider !== event.model.provider) {
      usage.clear();
      requestProvider = undefined;
    }
    selectedProvider = event.model.provider;
    updateStatus();
  });

  pi.on("agent_end", () => {
    responseStartedAt = undefined;
    requestProvider = undefined;
  });

  pi.on("session_shutdown", stop);
}
