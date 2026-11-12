import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  type ExtensionAPI,
  type ExtensionContext,
  getAgentDir,
  type Theme,
} from "@earendil-works/pi-coding-agent";

const STATUS_KEY = "session-metrics";
const CODEX_PROVIDER = "openai-codex";
const STALE_AFTER_MS = 10 * 60 * 1000;
// Codex quotas belong to the account, not the session, so the latest snapshot is kept here for
// the next session; the stale rule above marks it until a response refreshes it.
const USAGE_FILE = join(getAgentDir(), "codex-usage.json");

type UsageWindow = {
  usedPercent: number;
  windowMinutes: number;
  resetAt: number;
  observedAt: number;
};

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

function loadUsage(): UsageWindow[] {
  try {
    const windows: unknown = JSON.parse(readFileSync(USAGE_FILE, "utf8"));
    if (!Array.isArray(windows)) return [];
    return windows.flatMap((value) => {
      const window = record(value);
      const observedAt = readNumber(window?.observedAt);
      if (!window || observedAt === undefined) return [];
      const valid = readWindow(
        window.usedPercent,
        window.windowMinutes,
        window.resetAt,
        observedAt,
      );
      return valid ? [valid] : [];
    });
  } catch {
    // A missing or unreadable file only means no snapshot yet.
    return [];
  }
}

function saveUsage(windows: UsageWindow[]) {
  try {
    // Write then rename, so concurrent sessions never read a partial file.
    const temporary = `${USAGE_FILE}.${process.pid}`;
    writeFileSync(temporary, JSON.stringify(windows));
    renameSync(temporary, USAGE_FILE);
  } catch {
    // The snapshot is a convenience; the status line works without it.
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

function formatWindow(window: UsageWindow, now: number, theme: Theme): string {
  const resetIn = window.resetAt * 1000 - now;
  const stale = now - window.observedAt > STALE_AFTER_MS || resetIn <= 0;
  const remaining = Math.round(100 - window.usedPercent);
  // A passed reset is not evidence of a fresh quota allocation.
  const text = `${stale ? "~" : ""}${formatWindowLabel(window.windowMinutes)} ${resetIn <= 0 ? "?" : `${remaining}%`} ${formatResetIn(resetIn)}`;
  if (stale) return theme.fg("muted", text);
  // Bold separates the levels in themes that share warning and error colors.
  if (remaining <= 10) return theme.bold(theme.fg("error", text));
  if (remaining <= 30) return theme.fg("warning", text);
  return text;
}

export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setInterval> | undefined;
  let context: ExtensionContext | undefined;
  let activeMilliseconds = 0;
  let activeStartedAt: number | undefined;
  let lastPromptMilliseconds = 0;
  let selectedProvider: string | undefined;
  let requestProvider: string | undefined;
  let lastStatus: string | undefined;
  const usage = new Map<number, UsageWindow>();
  let toolCalls = 0;

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
    const theme = context.ui.theme;
    if (selectedProvider === CODEX_PROVIDER && usage.size > 0) {
      parts.push(
        [...usage.values()]
          .sort((a, b) => a.windowMinutes - b.windowMinutes)
          .map((window) => formatWindow(window, Date.now(), theme))
          .join(" - "),
      );
    }
    if (toolCalls > 0) parts.push(`${toolCalls} ${toolCalls === 1 ? "call" : "calls"}`);
    // Rebuild themed strings on every update so theme changes refresh colors.
    const status = parts.join(theme.fg("muted", " * "));
    if (status !== lastStatus) {
      context.ui.setStatus(STATUS_KEY, status);
      lastStatus = status;
    }
  }

  function saveWindows(windows: Array<UsageWindow | undefined>) {
    const received = windows.filter((window) => window !== undefined);
    for (const window of received) usage.set(window.windowMinutes, window);
    if (received.length > 0) saveUsage([...usage.values()]);
    updateStatus();
  }

  function stop() {
    if (timer !== undefined) clearInterval(timer);
    timer = undefined;
    context?.ui.setStatus(STATUS_KEY, undefined);
    context = undefined;
    activeMilliseconds = 0;
    activeStartedAt = undefined;
    lastPromptMilliseconds = 0;
    selectedProvider = undefined;
    requestProvider = undefined;
    lastStatus = undefined;
    usage.clear();
    toolCalls = 0;
  }

  // Rebuilds the work clock and tool calls from the session's messages, so a resumed, reloaded,
  // or forked session continues its counts and a new one starts at zero. A run lasts from its
  // user message to the last message before the next one, which approximates the live clock.
  function restoreMetrics(ctx: ExtensionContext) {
    let runStart: number | undefined;
    let runEnd = 0;
    const finishRun = () => {
      if (runStart === undefined) return;
      lastPromptMilliseconds = runEnd - runStart;
      activeMilliseconds += lastPromptMilliseconds;
    };
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "message") continue;
      const time = Date.parse(entry.timestamp);
      if (!Number.isFinite(time)) continue;
      if (entry.message.role === "user") {
        finishRun();
        runStart = time;
      } else if (entry.message.role === "toolResult") {
        toolCalls++;
      }
      runEnd = time;
    }
    finishRun();
  }

  pi.on("tool_execution_start", () => {
    if (!context) return;
    toolCalls++;
    updateStatus();
  });

  pi.on("session_start", (_event, ctx) => {
    stop();
    if (ctx.mode !== "tui") return;
    context = ctx;
    selectedProvider = ctx.model?.provider;
    for (const window of loadUsage()) usage.set(window.windowMinutes, window);
    restoreMetrics(ctx);
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
    // Remember the request's provider so quota headers are attributed correctly.
    if (!context) return;
    requestProvider = ctx.model?.provider;
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
    requestProvider = undefined;
  });

  pi.on("session_shutdown", stop);
}
