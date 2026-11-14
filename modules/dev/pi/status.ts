/**
 * The status line, drawn on the left of the editor's bottom border (Pi draws its working status
 * in the top border): segments other extensions send on the "status" event bus channel as
 * { key, render?, spinner? } (render: (theme) => string, none removes the segment; spinner: a
 * theme color for the working spinner, accent when no segment sets one), ordered by key, then
 * the session's work clock and Codex quota.
 * Context use and the model with its thinking level are on the right of the same border, and
 * the folder, git branch, and session name on the right of the top border, after Pi's working
 * status; Pi's footer, which showed these, is replaced with an empty one.
 *
 * The border needs Pi's editor replaced with a subclass (StatusEditor), set for each session;
 * another extension that replaces the editor takes the line with it.
 */

import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import {
  CustomEditor,
  type ExtensionAPI,
  type ExtensionContext,
  getAgentDir,
  type ReadonlyFooterDataProvider,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import { stripTerminalSequences, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { formatDuration, formatTokens, onStatus, type ThemeColor } from "./lib/shared.ts";

// Without a segment's color, the working spinner uses this one.
const SPINNER_COLOR = "accent";
const CODEX_PROVIDER = "openai-codex";
const STALE_AFTER_MS = 10 * 60 * 1000;
// Context use above these percentages turns warning, then error, like Pi's footer.
const CONTEXT_WARNING = 70;
const CONTEXT_ERROR = 90;
// Codex quotas belong to the account, not the session, so the latest snapshot is kept here for
// the next session; the stale rule above marks it until a response refreshes it.
const USAGE_FILE = join(getAgentDir(), "codex-usage.json");

type UsageWindow = {
  usedPercent: number;
  windowMinutes: number;
  resetAt: number;
  observedAt: number;
};

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

// The editor borders' line character.
const LINE = "━";

// A border line `━━ left ━━━━ marker ━━ right ━━`, any part optional. The scroll marker always
// fits; the left text keeps its room before the right one, and both are cut to fit.
function borderLine(
  width: number,
  border: (text: string) => string,
  left: string,
  marker: string,
  right: string,
): string {
  const markerText = marker ? ` ${marker} ${LINE}${LINE}` : "";
  // At least one line character of fill, the closing two, and the spaces around each text.
  let room = width - 1 - 2 - visibleWidth(markerText) - (left ? 4 : 0) - (right ? 2 : 0);
  const leftText = left && room > 0 ? truncateToWidth(left, room) : "";
  room -= visibleWidth(leftText);
  const rightText = right && room > 0 ? truncateToWidth(right, room) : "";
  const start = leftText ? `${border(`${LINE}${LINE} `)}${leftText}${border(" ")}` : "";
  const end = rightText
    ? `${border(" ")}${rightText}${border(` ${LINE}${LINE}`)}`
    : border(LINE + LINE);
  const fill = width - visibleWidth(start) - visibleWidth(markerText) - visibleWidth(end);
  return start + border(LINE.repeat(Math.max(1, fill)) + markerText) + end;
}

type WorkingIndicator = Parameters<CustomEditor["setWorkingStatusIndicator"]>[0];

// Pi's editor with the session's place (folder, branch, name) on the right of its top border,
// after Pi's working status, and with the status line on the left of its bottom border and the
// session's details (context use, model) on the right, each around its scroll marker.
class StatusEditor extends CustomEditor {
  status = "";
  details = "";
  place = "";
  // Pi's working status, which the base class keeps private.
  working: WorkingIndicator;
  // Colors the working spinner; Pi would draw it in the border color.
  spinnerColor = (text: string) => text;

  override setWorkingStatusIndicator(indicator: WorkingIndicator) {
    this.working = indicator;
    super.setWorkingStatusIndicator(indicator);
  }

  protected override renderTopBorder(width: number, hiddenLineCount: number): string {
    const marker = hiddenLineCount > 0 ? `↑ ${hiddenLineCount} more` : "";
    if (width < 8) return this.borderColor(LINE.repeat(width));
    // While working, only the spinner shows; retry and compaction keep their text and colors.
    const working =
      this.working?.kind === "working"
        ? this.spinnerColor(stripTerminalSequences(this.working.renderSpinnerInBorder(width)))
        : (this.working?.renderInBorder(width) ?? "");
    return borderLine(width, this.borderColor, working, marker, this.place);
  }

  protected override renderBottomBorder(width: number, hiddenLineCount: number): string {
    const marker = hiddenLineCount > 0 ? `↓ ${hiddenLineCount} more` : "";
    if (width < 8) return this.borderColor(LINE.repeat(width));
    return borderLine(width, this.borderColor, this.status, marker, this.details);
  }

  setStatus(status: string, details: string, place: string) {
    if (status === this.status && details === this.details && place === this.place) return;
    this.status = status;
    this.details = details;
    this.place = place;
    this.tui.requestRender();
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
  let editor: StatusEditor | undefined;
  // Pi gives the git branch only to footers; see session_start.
  let footerData: ReadonlyFooterDataProvider | undefined;
  // Per-session state; stop() starts over with a fresh one.
  const fresh = () => ({
    activeMilliseconds: 0,
    activeStartedAt: undefined as number | undefined,
    lastPromptMilliseconds: 0,
    selectedProvider: undefined as string | undefined,
    // The provider of the request in flight, so quota headers are attributed correctly.
    requestProvider: undefined as string | undefined,
    usage: new Map<number, UsageWindow>(),
  });
  let session = fresh();
  // Segments from other extensions by key; kept across sessions, since they resend on change.
  const segments = new Map<string, (theme: Theme) => string>();
  // Spinner colors segments ask for, by key; the first by key wins.
  const spinnerColors = new Map<string, ThemeColor>();

  function updateStatus() {
    if (!context) return;
    const { activeMilliseconds, activeStartedAt, lastPromptMilliseconds, usage } = session;
    const running = activeStartedAt === undefined ? 0 : performance.now() - activeStartedAt;
    const elapsed = formatDuration(activeMilliseconds + running);
    const promptElapsed = formatDuration(
      activeStartedAt === undefined ? lastPromptMilliseconds : running,
    );
    const parts = [`${elapsed}-${promptElapsed}`];
    const theme = context.ui.theme;
    if (session.selectedProvider === CODEX_PROVIDER && usage.size > 0) {
      parts.push(
        [...usage.values()]
          .sort((a, b) => a.windowMinutes - b.windowMinutes)
          .map((window) => formatWindow(window, Date.now(), theme))
          .join(" - "),
      );
    }
    // Rebuild themed strings on every update so theme changes refresh colors.
    const status = [
      ...[...segments.entries()]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([, render]) => render(theme)),
      ...parts,
    ].join(theme.fg("muted", " * "));
    editor?.setStatus(status, details(context, theme), place(context, theme));
  }

  // Context use and the model with its thinking level, for the right of the bottom border.
  function details(ctx: ExtensionContext, theme: Theme): string {
    const parts: string[] = [];
    const contextUsage = ctx.getContextUsage();
    if (contextUsage) {
      const { percent, contextWindow } = contextUsage;
      const text = `${percent === null ? "?" : percent.toFixed(1)}%/${formatTokens(contextWindow)}`;
      if (percent !== null && percent > CONTEXT_ERROR) parts.push(theme.fg("error", text));
      else if (percent !== null && percent > CONTEXT_WARNING)
        parts.push(theme.fg("warning", text));
      else parts.push(text);
    }
    const model = ctx.model;
    if (model) {
      parts.push(model.reasoning ? `${model.id} • ${pi.getThinkingLevel()}` : model.id);
    }
    return parts.join(theme.fg("muted", " * "));
  }

  // The folder, git branch, and session name, muted, for the right of the top border.
  function place(ctx: ExtensionContext, theme: Theme): string {
    const branch = footerData?.getGitBranch();
    const name = pi.getSessionName();
    return theme.fg(
      "muted",
      `${basename(ctx.cwd) || ctx.cwd}${branch ? ` (${branch})` : ""}${name ? ` • ${name}` : ""}`,
    );
  }

  // Codex reports the requests' quota as a primary and a secondary window, from response
  // headers or stream events; `read` gets each by name.
  function saveWindows(read: (name: string) => UsageWindow | undefined) {
    const { usage } = session;
    const received = ["primary", "secondary"]
      .map(read)
      .filter((window) => window !== undefined);
    for (const window of received) usage.set(window.windowMinutes, window);
    if (received.length > 0) saveUsage([...usage.values()]);
    updateStatus();
  }

  // Quota applies only while the session uses Codex and the event comes from it.
  const fromCodex = (provider: string | undefined) =>
    context !== undefined &&
    provider === CODEX_PROVIDER &&
    session.selectedProvider === CODEX_PROVIDER;

  function stop() {
    if (timer !== undefined) clearInterval(timer);
    timer = undefined;
    context = undefined;
    editor?.setStatus("", "", "");
    editor = undefined;
    footerData = undefined;
    session = fresh();
  }

  // Rebuilds the work clock from the session's messages, so a resumed, reloaded, or forked
  // session continues its time and a new one starts at zero. A run lasts from its
  // user message to the last message before the next one, which approximates the live clock.
  function restoreClock(ctx: ExtensionContext) {
    let runStart: number | undefined;
    let runEnd = 0;
    const finishRun = () => {
      if (runStart === undefined) return;
      session.lastPromptMilliseconds = runEnd - runStart;
      session.activeMilliseconds += session.lastPromptMilliseconds;
    };
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "message") continue;
      const time = Date.parse(entry.timestamp);
      if (!Number.isFinite(time)) continue;
      if (entry.message.role === "user") {
        finishRun();
        runStart = time;
      }
      runEnd = time;
    }
    finishRun();
  }

  onStatus(pi, ({ key, render, spinner }) => {
    if (render) segments.set(key, render);
    else segments.delete(key);
    if (render && spinner) spinnerColors.set(key, spinner);
    else spinnerColors.delete(key);
    updateStatus();
  });

  pi.on("session_start", (_event, ctx) => {
    stop();
    if (ctx.mode !== "tui") return;
    context = ctx;
    session.selectedProvider = ctx.model?.provider;
    for (const window of loadUsage()) session.usage.set(window.windowMinutes, window);
    // Pi restores its own editor between sessions, so each session sets this one again.
    ctx.ui.setEditorComponent((tui, theme, keybindings) => {
      editor = new StatusEditor(tui, theme, keybindings, { embedWorkingStatus: true });
      editor.spinnerColor = (text) => {
        const [first] = [...spinnerColors.entries()].sort(([a], [b]) => a.localeCompare(b));
        return ctx.ui.theme.fg(first?.[1] ?? SPINNER_COLOR, text);
      };
      return editor;
    });
    // The borders show what Pi's footer did, so the footer draws nothing; it stays to receive
    // the git branch and its changes.
    ctx.ui.setFooter((_tui, _theme, data) => {
      footerData = data;
      const unsubscribe = data.onBranchChange(() => updateStatus());
      return {
        render: () => [],
        invalidate() {
          // Nothing is cached.
        },
        dispose: unsubscribe,
      };
    });
    restoreClock(ctx);
    updateStatus();
    // Local display updates only: no quota queries or other network requests.
    // While idle the work clock stays frozen; reset countdowns can still change.
    timer = setInterval(updateStatus, 1000);
    timer.unref();
  });

  pi.on("agent_start", () => {
    if (!context || session.activeStartedAt !== undefined) return;
    // Accumulate working time across prompts, including tools and retries.
    session.activeStartedAt = performance.now();
    updateStatus();
  });

  pi.on("agent_settled", () => {
    if (!context || session.activeStartedAt === undefined) return;
    session.lastPromptMilliseconds = performance.now() - session.activeStartedAt;
    session.activeMilliseconds += session.lastPromptMilliseconds;
    session.activeStartedAt = undefined;
    updateStatus();
  });

  pi.on("context", (_event, ctx) => {
    if (context) session.requestProvider = ctx.model?.provider;
  });

  pi.on("after_provider_response", (event) => {
    if (!fromCodex(session.requestProvider)) return;
    const headers = Object.fromEntries(
      Object.entries(event.headers).map(([key, value]) => [key.toLowerCase(), value]),
    );
    const now = Date.now();
    saveWindows((name) => {
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
    });
  });

  pi.on("provider_stream_event", (event) => {
    if (!fromCodex(event.provider)) return;
    const data = record(event.data);
    if (data?.type !== "codex.rate_limits") return;
    const limits = record(data.rate_limits);
    if (!limits) return;
    const now = Date.now();
    // Only accept explicit quota snapshots, never infer quotas from token usage.
    saveWindows((name) => {
      const window = record(limits[name]);
      return (
        window &&
        readWindow(
          window.used_percent,
          window.window_minutes ?? window.limit_window_minutes,
          window.reset_at,
          now,
        )
      );
    });
  });

  pi.on("model_select", (event) => {
    if (!context) return;
    if (session.selectedProvider !== event.model.provider) {
      session.usage.clear();
      session.requestProvider = undefined;
    }
    session.selectedProvider = event.model.provider;
    updateStatus();
  });

  // Context use changes with each message and compaction, the thinking level by command.
  pi.on("message_end", () => updateStatus());
  pi.on("session_compact", () => updateStatus());
  pi.on("thinking_level_select", () => updateStatus());
  pi.on("session_info_changed", () => updateStatus());

  pi.on("agent_end", () => {
    session.requestProvider = undefined;
  });

  pi.on("session_shutdown", stop);
}
