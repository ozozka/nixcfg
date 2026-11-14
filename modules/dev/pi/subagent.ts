/**
 * Subagent tool: delegates tasks to agents, each in its own `pi` process in RPC mode with an
 * isolated context window. Off by default: the --subagents flag registers the tool for the
 * session (`wpi --subagents`). The tool is model-only, so codemode scripts cannot call it.
 *
 * Every run is a background job: `start` returns its ID at once, at most MAX_CONCURRENCY run
 * at a time and the rest wait in a queue, and `wait` waits for them. `send` steers a running
 * child or continues one that ended its turn, in the same session; `stop` aborts children, as
 * does `/subagents stop [id]`. A child reports by ending its turn, asking questions the same
 * way, and can send a note while it keeps working with NOTE_TOOL, which only children get.
 * Each report or note is delivered once: to a `wait` watching that child (a note always ends
 * the wait), otherwise as a steer message that starts a turn when the parent is idle. In print mode the parent waits for its runs before it settles.
 * Runs are aborted when the session shuts down (quit, /new, /resume, /reload).
 *
 * A child gets its task as a prompt on stdin, its events are read from stdout, and closing
 * stdin ends it once its run settles. Budgets: at TURN_LIMIT turns or after TIME_LIMIT_MS it
 * is told to stop and report, and it is aborted after TURN_GRACE more turns or TIME_GRACE_MS;
 * either way its last text is returned as a partial report.
 *
 * Agents are Markdown files in agents/ under Pi's agent directory, loaded at startup: the
 * file name is the agent name, the frontmatter its settings, and the body is appended to its
 * system prompt. Without a model, an agent inherits the session's model and thinking level;
 * without tools, it gets the default tools. Project-local agents are not loaded.
 *
 * Children never get the flag, so delegation stays one level deep, and run without
 * CHILD_EXCLUDED_TOOLS, since they have no user to ask. They inherit the parent's
 * FORWARDED_FLAGS, so a `wpi` child loads the project docs too. Each child keeps its session in
 * subagent-sessions/ under Pi's agent directory; result details record its session ID with
 * only the final output and the last COLLAPSED_ITEM_COUNT items of its transcript. A widget
 * below the editor shows one line per run, until the next user prompt after it ends. Vendored
 * from the Pi subagent example.
 */

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import { type AssistantMessage, StringEnum } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  type ExtensionContext,
  formatReadLineRange,
  getAgentDir,
  getMarkdownTheme,
  parseFrontmatter,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import { Container, Markdown, Spacer, Text, truncateToWidth } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
  assistantText,
  formatDuration,
  formatTokens,
  loadDefinitions,
  optionalList,
  optionalThinking,
  rejectUnknown,
  reply,
  requiredText,
  type ThemeColor,
  type ThinkingLevel,
} from "./lib/shared.ts";

const FLAG = "subagents";
// Tools a child never gets: it has no user to ask.
const CHILD_EXCLUDED_TOOLS = ["question"];
const SESSION_DIR = join(getAgentDir(), "subagent-sessions");
// Flags owned by other extensions that children take from the parent's command line.
const FORWARDED_FLAGS = ["--docs"];
const MAX_CONCURRENCY = 6;
// Parallel runs the guidelines advise; more cost tokens and attention for little gain.
const ADVISED_PARALLEL = "2-3";
const COLLAPSED_ITEM_COUNT = 10;
const PER_TASK_OUTPUT_CAP = 50 * 1024;
const MESSAGE_TYPE = "subagent";
// The child's tool for notes to the parent; registered inactive, turned on for children.
const NOTE_TOOL = "send_message";
// Appended to every child's system prompt, after its agent prompt.
const CHILD_RULES = [
  "You are a subagent: your final message goes to the parent agent that gave you the task.",
  "To ask the parent something, end your turn with the question; its reply continues your session.",
  `Use ${NOTE_TOOL} only for a decision you made on your own that the parent might want to override, for example using a different function than the task names, then keep working; the parent may answer with a message. Never send progress updates.`,
].join(" ");
const parentMessage = (text: string) => `Message from the parent: ${text}`;
const WIDGET = "subagents";
// IDs may be written with a leading #.
const ID_PREFIX = /^#/;
const WHITESPACE = /\s+/;
// Characters of a task shown in the widget.
const TASK_PREVIEW = 40;
// The end of a child's stderr kept for error reports.
const STDERR_CAP = 4096;
// Lines of an assistant text item kept for display.
const TEXT_ITEM_LINES = 3;
// After an abort, a child still running is killed after this delay.
const KILL_DELAY_MS = 5000;
const TURN_LIMIT = 72;
const TURN_GRACE = 24;
const TIME_LIMIT_MS = 30 * 60 * 1000;
// A hung command delays the steer until it ends, so the time grace is short.
const TIME_GRACE_MS = 5 * 60 * 1000;

type Limit = "turn" | "time";

const budgetMessage = (limit: Limit) =>
  `You reached your ${limit} limit. Stop working now and report what you did, what you found, and what remains.`;

interface Agent {
  description: string;
  model?: string;
  thinkingLevel?: ThinkingLevel;
  tools?: string[];
  prompt: string;
}

// A type alias: parseFrontmatter needs the implicit index signature an interface lacks.
type AgentFrontmatter = {
  description?: unknown;
  model?: unknown;
  thinking?: unknown;
  tools?: unknown;
};

function optionalText(value: unknown, key: string): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !value.trim()) throw new Error(`${key} must be a string`);
  return value.trim();
}

// Validates one agent file.
function parseAgent(content: string): Agent {
  const { frontmatter, body } = parseFrontmatter<AgentFrontmatter>(content);
  const { description, model, thinking, tools, ...unknown } = frontmatter;
  rejectUnknown(unknown);
  return {
    description: requiredText(description, "description"),
    model: optionalText(model, "model"),
    thinkingLevel: optionalThinking(thinking),
    tools: optionalList(tools, "tools"),
    prompt: requiredText(body, "the prompt (body)"),
  };
}

// Usage fields summed over a run's messages and over several runs; contextTokens is the
// latest message's.
const TOKEN_KEYS = ["input", "output", "cacheRead", "cacheWrite"] as const;
const SUMMED_KEYS = [...TOKEN_KEYS, "cost", "turns"] as const;
type UsageStats = Record<(typeof SUMMED_KEYS)[number] | "contextTokens", number>;

interface SingleResult {
  agent: string;
  task: string;
  // The child's session in SESSION_DIR.
  sessionId: string;
  // -1 while running.
  exitCode: number;
  // The latest assistant text: the report once the run ends.
  output: string;
  // The last COLLAPSED_ITEM_COUNT display items, out of itemCount.
  items: DisplayItem[];
  itemCount: number;
  stderr: string;
  usage: UsageStats;
  model?: string;
  stopReason?: string;
  errorMessage?: string;
  // The budget limit that stopped the run; its output is then a partial report.
  limit?: Limit;
}

type DisplayItem =
  | { type: "text"; text: string }
  | { type: "toolCall"; name: string; args: Record<string, unknown> };

interface DispatchDefaults {
  model?: string;
  thinkingLevel?: ThinkingLevel;
}

const emptyUsage = (): UsageStats => ({
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  cost: 0,
  contextTokens: 0,
  turns: 0,
});

// A result that has not finished yet.
const newResult = (agent: string, task: string): SingleResult => ({
  agent,
  task,
  sessionId: randomUUID(),
  exitCode: -1,
  output: "",
  items: [],
  itemCount: 0,
  stderr: "",
  usage: emptyUsage(),
});

function formatUsageStats(usage: UsageStats, model?: string): string {
  const parts: string[] = [];
  if (usage.turns) parts.push(`${usage.turns} turn${usage.turns > 1 ? "s" : ""}`);
  if (usage.input) parts.push(`↑${formatTokens(usage.input)}`);
  if (usage.output) parts.push(`↓${formatTokens(usage.output)}`);
  if (usage.cacheRead) parts.push(`R${formatTokens(usage.cacheRead)}`);
  if (usage.cacheWrite) parts.push(`W${formatTokens(usage.cacheWrite)}`);
  if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`);
  if (usage.contextTokens) parts.push(`ctx:${formatTokens(usage.contextTokens)}`);
  if (model) parts.push(model);
  return parts.join(" ");
}

// Mimics the built-in tools' call lines.
function formatToolCall(toolName: string, args: Record<string, unknown>, theme: Theme): string {
  const str = (value: unknown, fallback: string) =>
    typeof value === "string" && value ? value : fallback;
  const home = homedir();
  const shorten = (p: string) => (p.startsWith(home) ? `~${p.slice(home.length)}` : p);
  const preview = (text: string, max: number) =>
    text.length > max ? `${text.slice(0, max)}...` : text;
  const path = shorten(str(args.file_path ?? args.path, toolName === "ls" ? "." : "..."));
  const call = (target: string) =>
    theme.fg("muted", `${toolName} `) + theme.fg("accent", target);

  switch (toolName) {
    case "bash":
      return (
        theme.fg("muted", "$ ") + theme.fg("toolOutput", preview(str(args.command, "..."), 60))
      );
    case "read": {
      const range = formatReadLineRange(args.offset, args.limit);
      return call(path) + (range ? theme.fg("warning", range) : "");
    }
    case "write": {
      const lines = str(args.content, "").split("\n").length;
      return call(path) + (lines > 1 ? theme.fg("dim", ` (${lines} lines)`) : "");
    }
    case "edit":
    case "ls":
      return call(path);
    case "find":
    case "grep": {
      const pattern = str(args.pattern, toolName === "find" ? "*" : "");
      const shown = toolName === "grep" ? `/${pattern}/` : pattern;
      return call(shown) + theme.fg("dim", ` in ${shorten(str(args.path, "."))}`);
    }
    default:
      return (
        theme.fg("accent", toolName) + theme.fg("dim", ` ${preview(JSON.stringify(args), 50)}`)
      );
  }
}

// Records an assistant message: its text as the output, its parts as display items.
function addMessage(result: SingleResult, message: AssistantMessage) {
  const text = assistantText(message);
  if (text) result.output = text;
  for (const part of message.content) {
    if (part.type === "text") {
      const shown = part.text.split("\n").slice(0, TEXT_ITEM_LINES).join("\n");
      result.items.push({ type: "text", text: shown });
    } else if (part.type === "toolCall") {
      result.items.push({ type: "toolCall", name: part.name, args: part.arguments });
    } else continue;
    result.itemCount++;
  }
  result.items = result.items.slice(-COLLAPSED_ITEM_COUNT);
}

// A run stopped by its budget is not a failure: it returns a partial report.
function isFailedResult(result: SingleResult): boolean {
  if (result.limit) return false;
  return (
    result.exitCode > 0 || result.stopReason === "error" || result.stopReason === "aborted"
  );
}

function getResultOutput(result: SingleResult): string {
  const output = result.output;
  if (isFailedResult(result))
    return result.errorMessage || result.stderr || output || "(no output)";
  return output || "(no output)";
}

// The first lines of a failed run's error, for display.
function errorText(result: SingleResult): string {
  return `Error: ${getResultOutput(result).trim().split("\n").slice(0, 5).join("\n")}`;
}

function truncateOutput(output: string): string {
  const byteLength = Buffer.byteLength(output, "utf8");
  if (byteLength <= PER_TASK_OUTPUT_CAP) return output;
  let truncated = output.slice(0, PER_TASK_OUTPUT_CAP);
  while (Buffer.byteLength(truncated, "utf8") > PER_TASK_OUTPUT_CAP) {
    truncated = truncated.slice(0, -1);
  }
  const omitted = byteLength - Buffer.byteLength(truncated, "utf8");
  return `${truncated}\n\n[Output truncated: ${omitted} bytes omitted. Full output preserved in tool details.]`;
}

function piArgs(agent: Agent, defaults: DispatchDefaults, sessionId: string): string[] {
  const args = [
    "--mode",
    "rpc",
    "--session-dir",
    SESSION_DIR,
    "--session-id",
    sessionId,
    "--exclude-tools",
    CHILD_EXCLUDED_TOOLS.join(","),
    ...FORWARDED_FLAGS.filter((flag) => process.argv.includes(flag)),
  ];
  const model = agent.model ?? defaults.model;
  const thinkingLevel =
    agent.thinkingLevel ?? (agent.model ? undefined : defaults.thinkingLevel);
  if (model) args.push("--model", model);
  if (thinkingLevel) args.push("--thinking", thinkingLevel);
  args.push("--tools", agent.tools ? [...agent.tools, NOTE_TOOL].join(",") : `+${NOTE_TOOL}`);
  args.push("--append-system-prompt", `${agent.prompt}\n\n${CHILD_RULES}`);
  return args;
}

interface RunHooks {
  prompt: string;
  signal: AbortSignal;
  // After each assistant message.
  onProgress: () => void;
  // The child's command channel; it returns false once the child no longer takes commands.
  onStart: (send: (command: object) => boolean) => void;
  onNote: (text: string) => void;
}

// Runs one turn of a child, the first or a continuation of its session, filling in its result.
async function runAgent(
  cwd: string,
  defaults: DispatchDefaults,
  agent: Agent,
  result: SingleResult,
  hooks: RunHooks,
) {
  result.model = agent.model ?? defaults.model;
  result.exitCode = -1;
  result.limit = undefined;
  result.stopReason = undefined;
  result.errorMessage = undefined;
  // Budgets count this run's turns only.
  let turns = 0;
  let aborted = false;
  result.exitCode = await new Promise<number>((resolve) => {
    // The same Pi as the parent: its script under the current Node runtime.
    const args = [process.argv[1], ...piArgs(agent, defaults, result.sessionId)];
    const proc = spawn(process.execPath, args, {
      cwd,
      shell: false,
      stdio: ["pipe", "pipe", "pipe"],
    });
    // RPC commands, one JSON object per line.
    const send = (command: object) => {
      if (!proc.stdin.writable) return false;
      proc.stdin.write(`${JSON.stringify(command)}\n`);
      return true;
    };
    hooks.onStart(send);
    // The child shuts down once it is idle.
    const close = () => proc.stdin.end();
    // The child may exit before a write; its exit code reports the failure.
    proc.stdin.on("error", () => undefined);

    // Budget: at a limit the child is told to stop and report, then aborted after the grace.
    const reachLimit = (limit: Limit) => {
      if (result.limit) return;
      result.limit = limit;
      send({ type: "steer", message: budgetMessage(limit) });
    };
    const overLimit = (limit: Limit) => {
      result.limit ??= limit;
      send({ type: "abort" });
    };
    const timers = [
      setTimeout(() => reachLimit("time"), TIME_LIMIT_MS),
      setTimeout(() => overLimit("time"), TIME_LIMIT_MS + TIME_GRACE_MS),
    ];
    for (const timer of timers) timer.unref();
    let buffer = "";

    // Collects assistant messages and usage from the child's events, and closes the child
    // when its run settles or the prompt is rejected.
    const processLine = (line: string) => {
      if (!line.trim()) return;
      let event: {
        type?: string;
        message?: AssistantMessage;
        success?: boolean;
        error?: string;
      };
      try {
        event = JSON.parse(line);
      } catch {
        return;
      }
      if (event.type === "agent_settled") return close();
      if (event.type === "response" && event.success === false) {
        result.errorMessage = event.error;
        result.stopReason = "error";
        return close();
      }
      const msg = event.message;
      if (event.type !== "message_end" || msg?.role !== "assistant") return;
      addMessage(result, msg);
      for (const part of msg.content) {
        if (part.type === "toolCall" && part.name === NOTE_TOOL)
          hooks.onNote(String(part.arguments.text ?? ""));
      }
      turns++;
      result.usage.turns++;
      const usage = msg.usage;
      if (usage) {
        for (const key of TOKEN_KEYS) result.usage[key] += usage[key] || 0;
        result.usage.cost += usage.cost?.total || 0;
        result.usage.contextTokens = usage.totalTokens || 0;
      }
      if (!result.model && msg.model) result.model = msg.model;
      if (msg.stopReason) result.stopReason = msg.stopReason;
      if (msg.errorMessage) result.errorMessage = msg.errorMessage;
      if (turns >= TURN_LIMIT + TURN_GRACE) overLimit("turn");
      else if (turns >= TURN_LIMIT) reachLimit("turn");
      hooks.onProgress();
    };

    // Splits on LF only, as the RPC framing requires.
    proc.stdout.on("data", (data) => {
      buffer += data.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";
      for (const line of lines) processLine(line);
    });
    proc.stderr.on("data", (data) => {
      result.stderr = (result.stderr + data.toString()).slice(-STDERR_CAP);
    });
    proc.on("close", (code) => {
      for (const timer of timers) clearTimeout(timer);
      if (buffer.trim()) processLine(buffer);
      resolve(code ?? 0);
    });
    proc.on("error", () => resolve(1));

    send({ type: "prompt", message: hooks.prompt });

    const kill = () => {
      aborted = true;
      send({ type: "abort" });
      close();
      setTimeout(() => {
        if (proc.exitCode === null) proc.kill("SIGKILL");
      }, KILL_DELAY_MS).unref();
    };
    if (hooks.signal.aborted) kill();
    else hooks.signal.addEventListener("abort", kill, { once: true });
  });
  if (aborted && !result.limit) result.stopReason = "aborted";
}

// Jobs

type JobState = "queued" | "running" | "idle" | "budget" | "failed" | "aborted";

interface Job {
  id: string;
  result: SingleResult;
  started: boolean;
  startedAt?: number;
  endedAt?: number;
  // The result's turn count when the current run started; budgets count from here.
  turnsAtStart: number;
  // Ended jobs leave the widget at the next user prompt.
  hidden: boolean;
  // The prompt of the next run: the task, then the parent's messages.
  prompt: string;
  // Replaced for each run.
  controller: AbortController;
  // The running child's command channel.
  send?: (command: object) => boolean;
  // Starts a run of the child; set when the job is created.
  launch: () => Promise<void>;
}

function jobState(job: Job): JobState {
  const r = job.result;
  if (!job.started) return "queued";
  if (r.exitCode === -1) return "running";
  if (r.limit) return "budget";
  if (r.stopReason === "aborted") return "aborted";
  if (isFailedResult(r)) return "failed";
  return "idle";
}

const isActive = (job: Job) => ["queued", "running"].includes(jobState(job));

// A job as plain data for result details.
type JobView = SingleResult & { id: string; state: JobState };

const view = (job: Job): JobView => ({ ...job.result, id: job.id, state: jobState(job) });

interface SubagentDetails {
  action: "start" | "send" | "wait" | "stop" | "event";
  // `results` keeps the session IDs pi-stats reads.
  results: JobView[];
  // The note of a note event.
  note?: string;
}

const details = (
  action: SubagentDetails["action"],
  jobs: Job[],
  note?: string,
): SubagentDetails => ({ action, results: jobs.map(view), note });

// A child's report (the end of its turn) or note, delivered once to the parent.
interface JobEvent {
  job: Job;
  note?: string;
}

// What the parent reads for an event.
function eventText({ job, note }: JobEvent): string {
  const r = job.result;
  const label = `[subagent #${job.id} ${r.agent}]`;
  if (note !== undefined) return `${label} note, still running:\n\n${note}`;
  const report = truncateOutput(r.output || "(no output)");
  switch (jobState(job)) {
    case "budget":
      return `${label} stopped at the ${r.limit} limit. Partial report:\n\n${report}`;
    case "aborted":
      return `${label} was stopped. Last report:\n\n${report}`;
    case "failed":
      return `${label} failed: ${getResultOutput(r)}`;
    default:
      return `${label} ended its turn:\n\n${report}`;
  }
}

// A one-line summary of a job for wait results.
function jobLine(job: Job): string {
  const state = jobState(job);
  const turns = state === "running" ? `, turn ${job.result.usage.turns}` : "";
  return `#${job.id} ${job.result.agent}: ${state}${turns}`;
}

type Until = "any" | "all";

// A pending `wait`: the jobs it watches and the events delivered to it.
interface Waiter {
  ids: Set<string>;
  until: Until;
  events: JobEvent[];
  done: () => void;
  progress?: () => void;
}

const SubagentParams = Type.Object({
  action: StringEnum(["start", "send", "wait", "stop"] as const),
  agent: Type.Optional(Type.String({ description: "start: the agent to run" })),
  task: Type.Optional(
    Type.String({ description: "start: the task, the only context the subagent gets" }),
  ),
  to: Type.Optional(Type.String({ description: "send: the subagent ID" })),
  text: Type.Optional(Type.String({ description: "send: the message" })),
  ids: Type.Optional(
    Type.Array(Type.String(), {
      description: "wait, stop: subagent IDs (default: all running)",
    }),
  ),
  until: Type.Optional(
    StringEnum(["any", "all"] as const, {
      description: "wait: return at the first ended run (any, default) or when all have ended",
    }),
  ),
});

export default function (pi: ExtensionAPI) {
  pi.registerFlag(FLAG, {
    description: "Enable the subagent tool",
    type: "boolean",
    default: false,
  });

  const { definitions: agents, errors } = loadDefinitions("agents", parseAgent);
  const jobs = new Map<string, Job>();
  const waiters = new Set<Waiter>();
  let nextId = 1;
  let shutDown = false;

  const jobList = () => [...jobs.values()];
  const runningCount = () => jobList().filter((job) => jobState(job) === "running").length;

  // The widget below the editor: one line per shown job, redrawn every second while one runs.
  let ui: ExtensionContext["ui"] | undefined;
  let ticker: ReturnType<typeof setInterval> | undefined;
  function updateWidget() {
    // The session's UI is gone once it shuts down.
    if (shutDown) return;
    const shown = jobList().filter((job) => !job.hidden);
    const running = shown.some(isActive);
    if (running && !ticker) ticker = setInterval(updateWidget, 1000);
    if (!running && ticker) {
      clearInterval(ticker);
      ticker = undefined;
    }
    ui?.setWidget(
      WIDGET,
      shown.length > 0
        ? (_tui, theme) => ({
            render: (width: number) =>
              shown.map((job) => truncateToWidth(widgetLine(job, theme), width)),
            invalidate: () => undefined,
          })
        : undefined,
      { placement: "belowEditor" },
    );
  }

  // Starts queued jobs while slots are free.
  function pump() {
    for (const job of jobList()) {
      if (runningCount() >= MAX_CONCURRENCY) break;
      if (job.started) continue;
      job.started = true;
      job.startedAt = Date.now();
      job.turnsAtStart = job.result.usage.turns;
      job.launch().then(() => finish(job));
    }
    updateWidget();
  }

  function finish(job: Job) {
    job.endedAt = Date.now();
    pump();
    for (const waiter of waiters) waiter.progress?.();
    if (!shutDown) deliver({ job });
  }

  function sendEvent(event: JobEvent, deliverAs: "steer" | "nextTurn") {
    pi.sendMessage(
      {
        customType: MESSAGE_TYPE,
        content: eventText(event),
        display: true,
        details: details("event", [event.job], event.note),
      },
      { deliverAs, triggerTurn: deliverAs === "steer" },
    );
  }

  // An event goes to the wait watching its child, otherwise to the parent as a steer message.
  function deliver(event: JobEvent) {
    const waiter = [...waiters].find((w) => w.ids.has(event.job.id));
    if (!waiter) return sendEvent(event, "steer");
    waiter.events.push(event);
    check(waiter);
  }

  // A note ends any wait, so the parent can still correct the child.
  function check(waiter: Waiter) {
    const watched = [...waiter.ids].flatMap((id) => jobs.get(id) ?? []);
    const allEnded = watched.every((job) => !isActive(job));
    const noted = waiter.events.some((event) => event.note !== undefined);
    const any = waiter.until === "any" && waiter.events.length > 0;
    if (allEnded || noted || any) waiter.done();
  }

  // Waits for events of the given jobs, returned instead of delivered as messages. On abort,
  // the events already delivered to it are queued for the parent's next turn.
  function waitFor(
    ids: string[],
    until: Until,
    signal?: AbortSignal,
    progress?: () => void,
  ): Promise<JobEvent[]> {
    return new Promise((resolve) => {
      const waiter: Waiter = {
        ids: new Set(ids),
        until,
        events: [],
        done: () => end(false),
        progress,
      };
      const end = (aborted: boolean) => {
        waiters.delete(waiter);
        signal?.removeEventListener("abort", onAbort);
        if (aborted) for (const event of waiter.events) sendEvent(event, "nextTurn");
        resolve(aborted ? [] : waiter.events);
      };
      const onAbort = () => end(true);
      waiters.add(waiter);
      signal?.addEventListener("abort", onAbort, { once: true });
      if (signal?.aborted) onAbort();
      else check(waiter);
    });
  }

  // Aborts the given active jobs; a queued one ends without starting.
  function stop(targets: Job[]): Job[] {
    const active = targets.filter(isActive);
    for (const job of active) {
      if (job.started) {
        job.controller.abort();
        continue;
      }
      job.started = true;
      job.result.stopReason = "aborted";
      job.result.exitCode = 0;
      finish(job);
    }
    return active;
  }

  // `/subagents stop [id ...]`: the notification for the user.
  function stopCommand(args: string): [string, "info"] {
    const [verb, ...ids] = args.trim().split(WHITESPACE);
    if (verb !== "stop") return ["Usage: /subagents stop [id ...]", "info"];
    const targets = ids.length
      ? ids.flatMap((id) => jobs.get(id.replace(ID_PREFIX, "")) ?? [])
      : jobList();
    const stopped = stop(targets);
    if (stopped.length === 0) return ["No subagent to stop is running", "info"];
    return [`Stopping ${stopped.map((job) => `#${job.id}`).join(", ")}`, "info"];
  }

  // Children only: notes to the parent, turned on by the parent's tool selection.
  pi.registerTool({
    name: NOTE_TOOL,
    label: "Send message",
    exposure: "model-only",
    defaultActive: false,
    description:
      "Send a note to the parent agent and keep working. Only for a decision you made on your own that the parent might want to override; never for progress updates or questions.",
    parameters: Type.Object({ text: Type.String({ description: "The note" }) }),
    execute: async () =>
      reply("Sent to the parent. Keep working; it may answer with a message.", {}),
  });

  // The flag's value is known only once the session starts; each session gets a new instance.
  pi.on("session_start", (_event, ctx) => {
    if (pi.getFlag(FLAG) !== true) return;
    if (ctx.hasUI) ui = ctx.ui;
    if (errors.length > 0) ctx.ui.notify(`Subagents: ${errors.join("; ")}`, "warning");
    registerTool();
  });

  // Quitting and switching sessions end the runs, so none reports to the wrong session.
  pi.on("session_shutdown", () => {
    shutDown = true;
    if (ticker) clearInterval(ticker);
    for (const job of jobList()) job.controller.abort();
    for (const waiter of waiters) waiter.done();
  });

  // A user prompt clears ended runs from the widget.
  pi.on("input", () => {
    for (const job of jobList()) if (!isActive(job)) job.hidden = true;
    updateWidget();
  });

  // Print mode exits when the parent settles, so it waits for its runs and takes their reports
  // into one more turn.
  pi.on("agent_before_settle", async (event, ctx) => {
    if (ctx.mode === "tui" || ctx.mode === "rpc") return;
    const active = jobList().filter(isActive);
    if (active.length === 0) return;
    const events = await waitFor(
      active.map((job) => job.id),
      "all",
    );
    return {
      entries: [
        ...event.entries,
        ...events.map((jobEvent) => ({
          type: "custom_message" as const,
          customType: MESSAGE_TYPE,
          content: eventText(jobEvent),
          display: true,
        })),
      ],
      continue: true,
    };
  });

  function registerTool() {
    pi.registerTool({
      name: "subagent",
      label: "Subagent",
      exposure: "model-only",
      description: [
        "Delegate tasks to subagents: separate agents with isolated contexts that see only their task, not this conversation. Every subagent runs in the background.",
        `- start { agent, task }: starts one subagent and returns its ID at once. For parallel work, call start several times in one turn; at most ${MAX_CONCURRENCY} run at once and the rest wait in a queue.`,
        "- send { to, text }: messages a subagent. A running one sees it before its next model call; one that ended its turn continues its session with it.",
        '- wait { ids?, until? }: waits for subagents (default: all running) and returns their reports; until "any" (default) returns at the first ended run, "all" when every one has ended. A note from a subagent always ends the wait.',
        "- stop { ids? }: stops subagents (default: all running); each returns its last report.",
        "A subagent ends its turn with a report or a question, and may send a note while it keeps working. What arrives while you are not waiting comes as a message.",
        `Agents:\n${[...agents].map(([name, agent]) => `- ${name}: ${agent.description}`).join("\n")}`,
      ].join("\n"),
      promptGuidelines: [
        `Run ${ADVISED_PARALLEL} subagents at a time, each with a distinct, independent task; split work further only when the parts are truly independent.`,
        "Write each subagent task as a complete brief, since the subagent has not seen this conversation: the goal, the relevant files, the decisions already made, and what to report back.",
        "After subagent start, call subagent wait when your next step needs the result; otherwise continue with independent work or end your turn, since each report arrives by itself. Never redo work you delegated.",
        "Answer a subagent note with subagent send only to override the decision it reports.",
      ],
      parameters: SubagentParams,

      async execute(_toolCallId, params, signal, onUpdate, ctx) {
        if (params.action === "start") {
          const agent = params.agent ? agents.get(params.agent) : undefined;
          if (!(agent && params.agent && params.task)) {
            const text = `start needs an agent and a task. Agents: ${[...agents.keys()].join(", ")}`;
            return reply(text, details("start", []), true);
          }
          const defaults: DispatchDefaults = {
            model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined,
            thinkingLevel: pi.getThinkingLevel(),
          };
          const id = String(nextId++);
          const job: Job = {
            id,
            result: newResult(params.agent, params.task),
            started: false,
            turnsAtStart: 0,
            hidden: false,
            prompt: `Task: ${params.task}`,
            controller: new AbortController(),
            launch: () => {
              job.controller = new AbortController();
              return runAgent(ctx.cwd, defaults, agent, job.result, {
                prompt: job.prompt,
                signal: job.controller.signal,
                onProgress: () => {
                  updateWidget();
                  for (const waiter of waiters) if (waiter.ids.has(id)) waiter.progress?.();
                },
                onStart: (send) => {
                  job.send = send;
                },
                onNote: (note) => deliver({ job, note }),
              }).finally(() => {
                job.send = undefined;
              });
            },
          };
          jobs.set(id, job);
          pump();
          const queued = jobState(job) === "queued" ? ", queued until a slot is free" : "";
          const text = `Started subagent #${id} (${params.agent})${queued}. Its report arrives as a message when it ends its turn, or use wait.`;
          return reply(text, details("start", [job]));
        }

        const ids = params.action === "send" ? [params.to ?? ""] : (params.ids ?? []);
        const unknown = ids
          .map((id) => id.replace(ID_PREFIX, ""))
          .filter((id) => !jobs.has(id));
        if (unknown.length > 0) {
          const text = `Unknown subagent IDs: ${unknown.join(", ")}. Known: ${[...jobs.keys()].join(", ") || "none"}`;
          return reply(text, details(params.action, []), true);
        }

        if (params.action === "send") {
          const job = jobs.get((params.to ?? "").replace(ID_PREFIX, "")) as Job;
          if (!params.text) return reply("send needs a text.", details("send", []), true);
          const state = jobState(job);
          if (state === "queued") {
            const text = `#${job.id} has not started yet; send once it runs.`;
            return reply(text, details("send", [job]), true);
          }
          if (state === "running") {
            if (!job.send?.({ type: "steer", message: parentMessage(params.text) })) {
              const text = `#${job.id} is just ending its turn; send again to continue it.`;
              return reply(text, details("send", [job]), true);
            }
            const text = `Sent to #${job.id}; it sees the message before its next model call.`;
            return reply(text, details("send", [job]));
          }
          job.prompt = parentMessage(params.text);
          job.started = false;
          job.hidden = false;
          job.startedAt = undefined;
          job.endedAt = undefined;
          pump();
          const text = `Continued #${job.id} with the message; its report arrives when it ends its turn.`;
          return reply(text, details("send", [job]));
        }

        if (params.action === "stop") {
          const targets = params.ids?.length
            ? params.ids.flatMap((id) => jobs.get(id.replace(ID_PREFIX, "")) ?? [])
            : jobList();
          const stopped = stop(targets);
          const text =
            stopped.length > 0
              ? `Stopping ${stopped.map((job) => `#${job.id}`).join(", ")}; each returns its last report.`
              : "No subagent to stop is running.";
          return reply(text, details("stop", stopped));
        }

        const watched = params.ids?.length
          ? params.ids.flatMap((id) => jobs.get(id.replace(ID_PREFIX, "")) ?? [])
          : jobList().filter(isActive);
        if (!watched.some(isActive)) {
          const states = watched.map(jobLine).join("\n");
          const text = `No watched subagent is running.${states ? `\n${states}` : ""}`;
          return reply(text, details("wait", watched));
        }
        const progress = () =>
          onUpdate?.(reply(watched.map(jobLine).join("\n"), details("wait", watched)));
        progress();
        const events = await waitFor(
          watched.map((job) => job.id),
          params.until ?? "any",
          signal,
          progress,
        );
        const stillActive = watched.filter(isActive);
        const parts = events.map(eventText);
        if (stillActive.length > 0)
          parts.push(`Still running: ${stillActive.map(jobLine).join("; ")}`);
        const shown = [...new Set([...events.map((event) => event.job), ...stillActive])];
        const notes = events.flatMap((event) => event.note ?? []);
        return reply(
          parts.join("\n\n---\n\n"),
          details("wait", shown, notes.length > 0 ? notes.join("\n") : undefined),
        );
      },

      renderCall(args, theme, _context) {
        const title = theme.fg("toolTitle", theme.bold(`subagent ${args.action ?? ""} `));
        if (args.action === "wait" || args.action === "stop") {
          const ids = args.ids?.length ? args.ids.map((id) => `#${id}`).join(" ") : "all";
          const until = args.action === "wait" ? ` (${args.until ?? "any"})` : "";
          return new Text(title + theme.fg("accent", ids) + theme.fg("dim", until), 0, 0);
        }
        if (args.action === "send") {
          const text = (args.text ?? "...").trim();
          const shown = text.length > 60 ? `${text.slice(0, 60)}...` : text;
          return new Text(
            `${title}${theme.fg("accent", `#${args.to ?? "?"}`)}\n  ${theme.fg("dim", shown)}`,
            0,
            0,
          );
        }
        const task = (args.task ?? "...").trim();
        const shown = task.length > 60 ? `${task.slice(0, 60)}...` : task;
        return new Text(
          `${title}${theme.fg("accent", args.agent || "...")}\n  ${theme.fg("dim", shown)}`,
          0,
          0,
        );
      },

      renderResult(result, { expanded }, theme, _context) {
        const data = result.details as SubagentDetails | undefined;
        if (!data || data.results.length === 0) {
          const text = result.content[0];
          return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
        }
        return renderJobs(data, expanded, theme);
      },
    });

    pi.registerMessageRenderer(MESSAGE_TYPE, (message, { expanded }, theme) => {
      const data = message.details as SubagentDetails | undefined;
      if (!data) return undefined;
      return renderJobs(data, expanded, theme);
    });

    pi.registerCommand("subagents", {
      description: "Stop background subagents: /subagents stop [id ...]",
      handler: async (args, ctx) => ctx.ui.notify(...stopCommand(args)),
    });
  }
}

const WIDGET_MARKS: Record<JobState, [string, ThemeColor]> = {
  queued: ["⧗", "muted"],
  running: ["◆", "accent"],
  idle: ["✔", "success"],
  budget: ["◐", "warning"],
  failed: ["✖", "error"],
  aborted: ["✖", "error"],
};

// A widget line: mark, ID and agent, task, turns over the limit, elapsed time, usage, last call.
function widgetLine(job: Job, theme: Theme): string {
  const r = job.result;
  const state = jobState(job);
  const [mark, color] = WIDGET_MARKS[state];
  const firstLine = r.task.trim().split("\n")[0];
  const task =
    firstLine.length > TASK_PREVIEW ? `${firstLine.slice(0, TASK_PREVIEW - 1)}…` : firstLine;
  const parts = [
    theme.fg(color, `${mark} #${job.id} ${r.agent}`),
    task,
    theme.fg("muted", state === "budget" ? `${r.limit} limit` : state),
  ];
  if (job.startedAt) {
    parts.push(
      theme.fg("muted", `${r.usage.turns - job.turnsAtStart}/${TURN_LIMIT}`),
      theme.fg("muted", formatDuration((job.endedAt ?? Date.now()) - job.startedAt)),
      theme.fg(
        "dim",
        `↑${formatTokens(r.usage.input + r.usage.cacheRead)} ↓${formatTokens(r.usage.output)} $${r.usage.cost.toFixed(2)}`,
      ),
    );
  }
  const last = r.items.findLast((item) => item.type === "toolCall");
  if (state === "running" && last?.type === "toolCall")
    parts.push(formatToolCall(last.name, last.args, theme));
  return parts.join("  ");
}

// One section per job: state, recent items or error, usage; expanded adds the task and report.
function renderJobs(data: SubagentDetails, expanded: boolean, theme: Theme) {
  const mdTheme = getMarkdownTheme();
  const fg = (color: ThemeColor, value: string) => theme.fg(color, value);
  const marks: Record<JobState, string> = {
    queued: fg("muted", "…"),
    running: fg("warning", "⏳"),
    idle: fg("success", "✓"),
    budget: fg("warning", "◐"),
    failed: fg("error", "✗"),
    aborted: fg("error", "✗"),
  };
  const toolLine = (item: DisplayItem & { type: "toolCall" }) =>
    fg("muted", "→ ") + formatToolCall(item.name, item.args, theme);
  const header = (r: JobView) =>
    `${marks[r.state]} ${fg("toolTitle", theme.bold(`#${r.id} ${r.agent}`))} ${fg("muted", r.state === "budget" ? `${r.limit} limit` : r.state)}`;

  const container = new Container();
  for (const [index, r] of data.results.entries()) {
    if (index > 0) container.addChild(new Spacer(1));
    container.addChild(new Text(header(r), 0, 0));
    if (r.state === "failed") container.addChild(new Text(fg("error", errorText(r)), 0, 0));
    if (data.note !== undefined && data.action === "event")
      container.addChild(new Text(fg("accent", `Note: ${data.note}`), 0, 0));
    if (["start", "send", "stop"].includes(data.action) && !expanded) continue;
    if (expanded) container.addChild(new Text(fg("muted", "Task: ") + fg("dim", r.task), 0, 0));
    const items = expanded ? r.items : r.items.slice(-(data.results.length > 1 ? 3 : 5));
    const skipped = r.itemCount - items.length;
    if (skipped > 0)
      container.addChild(new Text(fg("muted", `... ${skipped} earlier items`), 0, 0));
    for (const item of items) {
      const line = item.type === "text" ? fg("toolOutput", item.text) : toolLine(item);
      if (expanded && item.type === "text") continue;
      container.addChild(new Text(line, 0, 0));
    }
    if (expanded && r.output && r.state !== "running") {
      container.addChild(new Spacer(1));
      container.addChild(new Markdown(r.output.trim(), 0, 0, mdTheme));
    }
    const usage = formatUsageStats(r.usage, r.model);
    if (usage) container.addChild(new Text(fg("dim", usage), 0, 0));
  }
  return container;
}
