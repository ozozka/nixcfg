/**
 * Subagent tool: delegates tasks to agents, each in its own `pi` process in RPC mode with an
 * isolated context window: the task is sent as a prompt on stdin, the child's events are read
 * from stdout, and closing stdin ends the child once its run settles. Modes: single ({ agent, task }) and parallel ({ tasks }). Off by default:
 * the --subagents flag registers the tool for the session (`wpi --subagents`).
 *
 * Agents are Markdown files in agents/ under Pi's agent directory, loaded at startup: the
 * file name is the agent name, the frontmatter its settings, and the body is appended to its
 * system prompt. Without a model, an agent inherits the session's model and thinking level;
 * without tools, it gets the default tools. Project-local agents are not loaded.
 *
 * Children never get the flag, so delegation stays one level deep, and run without
 * CHILD_EXCLUDED_TOOLS, since they have no user to ask. The tool is model-only: codemode scripts
 * cannot call it. Each child keeps its session in subagent-sessions/ under Pi's agent directory;
 * the result details record its session ID, linking it to the parent's tool call, with only
 * the final output and the last COLLAPSED_ITEM_COUNT items of the transcript. Children
 * inherit the parent's FORWARDED_FLAGS, so a `wpi` child loads the project docs too.
 * While children run, their count is shown in the status line (status.ts). Vendored from the
 * Pi subagent example.
 */

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import {
  type ExtensionAPI,
  formatReadLineRange,
  getAgentDir,
  getMarkdownTheme,
  parseFrontmatter,
  type Theme,
} from "@earendil-works/pi-coding-agent";
import { Container, Markdown, Spacer, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
  assistantText,
  formatTokens,
  loadDefinitions,
  optionalList,
  optionalThinking,
  rejectUnknown,
  reply,
  requiredText,
  sendStatus,
  type ThemeColor,
  type ThinkingLevel,
} from "./lib/shared.ts";

const FLAG = "subagents";
// Tools a child never gets: it has no user to ask.
const CHILD_EXCLUDED_TOOLS = ["question"];
const SESSION_DIR = join(getAgentDir(), "subagent-sessions");
// Flags owned by other extensions that children take from the parent's command line.
const FORWARDED_FLAGS = ["--docs"];
const MAX_PARALLEL_TASKS = 8;
const MAX_CONCURRENCY = 4;
const COLLAPSED_ITEM_COUNT = 10;
const PER_TASK_OUTPUT_CAP = 50 * 1024;
// The end of a child's stderr kept for error reports.
const STDERR_CAP = 4096;
// Lines of an assistant text item kept for display.
const TEXT_ITEM_LINES = 3;
// After an abort, a child still running is killed after this delay.
const KILL_DELAY_MS = 5000;

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
}

type Mode = "single" | "parallel";

interface SubagentDetails {
  mode: Mode;
  results: SingleResult[];
}

type DisplayItem =
  | { type: "text"; text: string }
  | { type: "toolCall"; name: string; args: Record<string, unknown> };

interface DispatchDefaults {
  model?: string;
  thinkingLevel?: ThinkingLevel;
}

// One child run; onProgress gets the result again after each message.
interface Run {
  agent: string;
  task: string;
  onProgress?: (result: SingleResult) => void;
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

const details = (mode: Mode, results: SingleResult[]): SubagentDetails => ({ mode, results });

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

function aggregateUsage(results: SingleResult[]): UsageStats {
  const total = emptyUsage();
  for (const result of results) {
    for (const key of SUMMED_KEYS) total[key] += result.usage[key];
  }
  return total;
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

function isFailedResult(result: SingleResult): boolean {
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

async function mapWithConcurrencyLimit<TIn, TOut>(
  items: TIn[],
  concurrency: number,
  fn: (item: TIn, index: number) => Promise<TOut>,
): Promise<TOut[]> {
  const results: TOut[] = new Array(items.length);
  let nextIndex = 0;
  const limit = Math.max(1, Math.min(concurrency, items.length));
  const workers = Array.from({ length: limit }, async () => {
    while (nextIndex < items.length) {
      const current = nextIndex++;
      // biome-ignore lint/performance/noAwaitInLoops: each worker runs its share in sequence.
      results[current] = await fn(items[current], current);
    }
  });
  await Promise.all(workers);
  return results;
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
  if (agent.tools) args.push("--tools", agent.tools.join(","));
  args.push("--append-system-prompt", agent.prompt);
  return args;
}

async function runAgent(
  cwd: string,
  defaults: DispatchDefaults,
  agents: Map<string, Agent>,
  run: Run,
  signal: AbortSignal | undefined,
): Promise<SingleResult> {
  const result = newResult(run.agent, run.task);
  const agent = agents.get(run.agent);
  if (!agent) {
    result.exitCode = 1;
    result.stderr = `Unknown agent "${run.agent}". Available: ${[...agents.keys()].join(", ")}.`;
    return result;
  }
  result.model = agent.model ?? defaults.model;

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
      if (proc.stdin.writable) proc.stdin.write(`${JSON.stringify(command)}\n`);
    };
    // The child shuts down once it is idle.
    const close = () => proc.stdin.end();
    // The child may exit before a write; its exit code reports the failure.
    proc.stdin.on("error", () => undefined);
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
      run.onProgress?.(result);
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
      if (buffer.trim()) processLine(buffer);
      resolve(code ?? 0);
    });
    proc.on("error", () => resolve(1));

    send({ type: "prompt", message: `Task: ${run.task}` });

    if (signal) {
      const kill = () => {
        aborted = true;
        send({ type: "abort" });
        close();
        setTimeout(() => {
          if (proc.exitCode === null) proc.kill("SIGKILL");
        }, KILL_DELAY_MS).unref();
      };
      if (signal.aborted) kill();
      else signal.addEventListener("abort", kill, { once: true });
    }
  });

  if (aborted) throw new Error("Subagent was aborted");
  return result;
}

const TaskItem = Type.Object({
  agent: Type.String({ description: "Name of the agent to invoke" }),
  task: Type.String({ description: "Task to delegate to the agent" }),
});

const SubagentParams = Type.Object({
  agent: Type.Optional(Type.String({ description: "Agent to invoke (single mode)" })),
  task: Type.Optional(Type.String({ description: "Task to delegate (single mode)" })),
  tasks: Type.Optional(
    Type.Array(TaskItem, {
      description: `Tasks to run in parallel (at most ${MAX_PARALLEL_TASKS})`,
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
  // Children running now, across parallel tasks and concurrent tool calls.
  let runningChildren = 0;
  function sendRunning() {
    const count = runningChildren;
    sendStatus(pi, {
      key: "subagents",
      render:
        count > 0
          ? (theme: Theme) => theme.fg("accent", `${count} ${count === 1 ? "agent" : "agents"}`)
          : undefined,
    });
  }
  // The flag's value is known only once the session starts; each session gets a new instance.
  pi.on("session_start", (_event, ctx) => {
    if (pi.getFlag(FLAG) !== true) return;
    if (errors.length > 0) ctx.ui.notify(`Subagents: ${errors.join("; ")}`, "warning");
    registerTool();
  });

  function registerTool() {
    pi.registerTool({
      name: "subagent",
      label: "Subagent",
      exposure: "model-only",
      description: [
        "Run tasks in subagents with isolated contexts. Each subagent receives its task, not the parent conversation.",
        "Modes: single (agent + task) or parallel (tasks array).",
        `Agents:\n${[...agents].map(([name, agent]) => `- ${name}: ${agent.description}`).join("\n")}`,
      ].join("\n\n"),
      parameters: SubagentParams,

      async execute(_toolCallId, params, signal, onUpdate, ctx) {
        const defaults: DispatchDefaults = {
          model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined,
          thinkingLevel: pi.getThinkingLevel(),
        };
        const run = async (job: Run) => {
          runningChildren++;
          sendRunning();
          try {
            return await runAgent(ctx.cwd, defaults, agents, job, signal);
          } finally {
            runningChildren--;
            sendRunning();
          }
        };
        const update = (mode: Mode, results: SingleResult[], text: string) =>
          onUpdate?.(reply(text, details(mode, results)));
        const runningText = (current: SingleResult) => current.output || "(running...)";

        const modes = [params.tasks?.length, params.agent && params.task];
        if (modes.filter(Boolean).length !== 1) {
          const text = `Invalid parameters: provide exactly one mode.\nAgents: ${[...agents.keys()].join(", ")}`;
          return reply(text, details("single", []), true);
        }

        if (params.tasks?.length) {
          const { tasks } = params;
          if (tasks.length > MAX_PARALLEL_TASKS) {
            const text = `Too many parallel tasks (${tasks.length}). Max is ${MAX_PARALLEL_TASKS}.`;
            return reply(text, details("parallel", []), true);
          }
          const all = tasks.map((t) => newResult(t.agent, t.task));
          const progress = () => {
            const done = all.filter((r) => r.exitCode !== -1).length;
            const text = `Parallel: ${done}/${all.length} done, ${all.length - done} running...`;
            update("parallel", [...all], text);
          };
          const results = await mapWithConcurrencyLimit(
            tasks,
            MAX_CONCURRENCY,
            async (t, i) => {
              all[i] = await run({
                agent: t.agent,
                task: t.task,
                onProgress: (current) => {
                  all[i] = current;
                  progress();
                },
              });
              progress();
              return all[i];
            },
          );

          const succeeded = results.filter((r) => !isFailedResult(r)).length;
          const summaries = results.map((r) => {
            const status = isFailedResult(r)
              ? `failed${r.stopReason && r.stopReason !== "stop" ? ` (${r.stopReason})` : ""}`
              : "completed";
            return `### [${r.agent}] ${status}\n\n${truncateOutput(getResultOutput(r))}`;
          });
          const text = `Parallel: ${succeeded}/${results.length} succeeded\n\n${summaries.join("\n\n---\n\n")}`;
          return reply(text, details("parallel", results));
        }

        const result = await run({
          agent: params.agent ?? "",
          task: params.task ?? "",
          onProgress: (current) => update("single", [current], runningText(current)),
        });
        if (isFailedResult(result)) {
          const text = `Agent ${result.stopReason || "failed"}: ${getResultOutput(result)}`;
          return reply(text, details("single", [result]), true);
        }
        return reply(result.output || "(no output)", details("single", [result]));
      },

      renderCall(args, theme, _context) {
        const title = theme.fg("toolTitle", theme.bold("subagent "));
        const preview = (task: string, max: number) => {
          const clean = task.trim();
          return clean.length > max ? `${clean.slice(0, max)}...` : clean;
        };
        if (args.tasks && args.tasks.length > 0) {
          const { tasks } = args;
          let text = theme.fg("accent", `parallel (${tasks.length} tasks)`);
          for (const t of tasks.slice(0, 3))
            text += `\n  ${theme.fg("accent", t.agent)}${theme.fg("dim", ` ${preview(t.task, 40)}`)}`;
          if (tasks.length > 3)
            text += `\n  ${theme.fg("muted", `... +${tasks.length - 3} more`)}`;
          return new Text(title + text, 0, 0);
        }
        const shown = args.task ? preview(args.task, 60) : "...";
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

        const mdTheme = getMarkdownTheme();
        const fg = (color: ThemeColor, value: string) => theme.fg(color, value);
        const icon = (busy: boolean, failed: boolean) =>
          busy ? fg("warning", "⏳") : failed ? fg("error", "✗") : fg("success", "✓");
        const statusIcon = (r: SingleResult) => icon(r.exitCode === -1, isFailedResult(r));
        const toolLine = (item: DisplayItem & { type: "toolCall" }) =>
          fg("muted", "→ ") + formatToolCall(item.name, item.args, theme);

        // Collapsed: the error, or the last `limit` items, or a placeholder.
        const body = (r: SingleResult, limit: number) => {
          if (isFailedResult(r)) return fg("error", errorText(r));
          const items = r.items.slice(-limit);
          if (items.length === 0)
            return fg("muted", r.exitCode === -1 ? "(running...)" : "(no output)");
          const skipped = r.itemCount - items.length;
          const lines = skipped > 0 ? [fg("muted", `... ${skipped} earlier items`)] : [];
          for (const item of items) {
            lines.push(item.type === "text" ? fg("toolOutput", item.text) : toolLine(item));
          }
          return lines.join("\n");
        };

        // Expanded: the task, the kept tool calls, and the final output as Markdown.
        const addExpanded = (container: Container, r: SingleResult, title: string) => {
          container.addChild(new Text(title, 0, 0));
          if (isFailedResult(r)) container.addChild(new Text(fg("error", errorText(r)), 0, 0));
          container.addChild(new Text(fg("muted", "Task: ") + fg("dim", r.task), 0, 0));
          const skipped = r.itemCount - r.items.length;
          if (skipped > 0)
            container.addChild(new Text(fg("muted", `... ${skipped} earlier items`), 0, 0));
          for (const item of r.items) {
            if (item.type === "toolCall") container.addChild(new Text(toolLine(item), 0, 0));
          }
          if (r.output) {
            container.addChild(new Spacer(1));
            container.addChild(new Markdown(r.output.trim(), 0, 0, mdTheme));
          }
          const usage = formatUsageStats(r.usage, r.model);
          if (usage) container.addChild(new Text(fg("dim", usage), 0, 0));
        };

        if (data.mode === "single") {
          const r = data.results[0];
          const header = `${statusIcon(r)} ${fg("toolTitle", theme.bold(r.agent))}${
            isFailedResult(r) && r.stopReason ? ` ${fg("error", `[${r.stopReason}]`)}` : ""
          }`;
          if (expanded) {
            const container = new Container();
            addExpanded(container, r, header);
            return container;
          }
          let text = `${header}\n${body(r, COLLAPSED_ITEM_COUNT)}`;
          if (!isFailedResult(r) && r.itemCount > COLLAPSED_ITEM_COUNT)
            text += `\n${fg("muted", "(Ctrl+O to expand)")}`;
          const usage = formatUsageStats(r.usage, r.model);
          if (usage) text += `\n${fg("dim", usage)}`;
          return new Text(text, 0, 0);
        }

        // Parallel: one section per task.
        const running = data.results.filter((r) => r.exitCode === -1).length;
        const succeeded = data.results.filter(
          (r) => r.exitCode !== -1 && !isFailedResult(r),
        ).length;
        const total = data.results.length;
        const status =
          running > 0
            ? `${total - running}/${total} done, ${running} running`
            : `${succeeded}/${total} tasks`;
        const header = `${icon(running > 0, succeeded < total)} ${fg("toolTitle", theme.bold(`${data.mode} `))}${fg("accent", status)}`;
        const label = (r: SingleResult) =>
          `${fg("muted", "─── ")}${fg("accent", r.agent)} ${statusIcon(r)}`;
        const totalUsage = running > 0 ? "" : formatUsageStats(aggregateUsage(data.results));

        if (expanded && running === 0) {
          const container = new Container();
          container.addChild(new Text(header, 0, 0));
          for (const r of data.results) {
            container.addChild(new Spacer(1));
            addExpanded(container, r, label(r));
          }
          if (totalUsage) {
            container.addChild(new Spacer(1));
            container.addChild(new Text(fg("dim", `Total: ${totalUsage}`), 0, 0));
          }
          return container;
        }

        let text = header;
        for (const r of data.results) text += `\n\n${label(r)}\n${body(r, 5)}`;
        if (totalUsage) text += `\n\n${fg("dim", `Total: ${totalUsage}`)}`;
        if (!expanded) text += `\n${fg("muted", "(Ctrl+O to expand)")}`;
        return new Text(text, 0, 0);
      },
    });
  }
}
