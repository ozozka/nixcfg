/**
 * Subagent tool: delegates tasks to agents, each in its own `pi` process with an isolated
 * context window. Modes: single ({ agent, task }), parallel ({ tasks }), and chain ({ chain },
 * where {previous} is replaced by the prior step's output). /review asks the main agent for a
 * read-only review by a subagent.
 *
 * Agents are Markdown files in agents/ under Pi's agent directory, loaded at startup: the
 * file name is the agent name, the frontmatter its settings, and the body is appended to its
 * system prompt. Without a model, an agent inherits the session's model and thinking level;
 * without tools, it gets the default tools. Project-local agents are not loaded.
 *
 * Children run with PI_SUBAGENT set and do not get this tool, so delegation stays one level
 * deep. Vendored from the Pi subagent example.
 */

import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import type { AgentToolResult } from "@earendil-works/pi-agent-core";
import type { Message } from "@earendil-works/pi-ai";
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

const CHILD_ENV = "PI_SUBAGENT";
const MAX_PARALLEL_TASKS = 8;
const MAX_CONCURRENCY = 4;
const COLLAPSED_ITEM_COUNT = 10;
const PER_TASK_OUTPUT_CAP = 50 * 1024;
const PREVIOUS = /\{previous\}/g;
const RUNTIME = /^(node|bun)(\.exe)?$/i;

type ThemeColor = Parameters<Theme["fg"]>[0];
type ThinkingLevel = ReturnType<ExtensionAPI["getThinkingLevel"]>;

const THINKING_LEVELS: readonly string[] = [
  "off",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
];

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

// Validates one agent file; unknown keys are errors, so typos do not pass silently.
function parseAgent(content: string): Agent {
  const { frontmatter, body } = parseFrontmatter<AgentFrontmatter>(content);
  const { description, model, thinking, tools, ...unknown } = frontmatter;
  const extra = Object.keys(unknown);
  if (extra.length > 0) throw new Error(`unknown keys: ${extra.join(", ")}`);
  if (typeof description !== "string" || !description.trim())
    throw new Error("description is required");
  if (model !== undefined && typeof model !== "string")
    throw new Error("model must be a string");
  if (thinking !== undefined && !THINKING_LEVELS.includes(String(thinking)))
    throw new Error(`thinking must be one of: ${THINKING_LEVELS.join(", ")}`);
  // Accepts both YAML spellings: `tools: read, bash` and `tools: [read, bash]`.
  const list = typeof tools === "string" ? tools.split(",") : tools;
  if (list !== undefined && !(Array.isArray(list) && list.every((t) => typeof t === "string")))
    throw new Error("tools must be a comma-separated string or a list");
  if (!body.trim()) throw new Error("the prompt (body) is empty");
  return {
    description: description.trim(),
    model,
    thinkingLevel: thinking as ThinkingLevel | undefined,
    tools: list?.map((t) => t.trim()).filter(Boolean),
    prompt: body.trim(),
  };
}

function loadAgents(): { agents: Map<string, Agent>; errors: string[] } {
  const dir = join(getAgentDir(), "agents");
  const agents = new Map<string, Agent>();
  const errors: string[] = [];
  let files: string[] = [];
  try {
    files = readdirSync(dir).filter((file) => file.endsWith(".md"));
  } catch {
    errors.push(`no agents directory at ${dir}`);
  }
  for (const file of files.sort()) {
    try {
      agents.set(basename(file, ".md"), parseAgent(readFileSync(join(dir, file), "utf8")));
    } catch (error) {
      errors.push(`${file}: ${(error as Error).message}`);
    }
  }
  return { agents, errors };
}

interface UsageStats {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  contextTokens: number;
  turns: number;
}

interface SingleResult {
  agent: string;
  task: string;
  // -1 while running.
  exitCode: number;
  messages: Message[];
  stderr: string;
  usage: UsageStats;
  model?: string;
  stopReason?: string;
  errorMessage?: string;
  step?: number;
}

interface SubagentDetails {
  mode: "single" | "parallel" | "chain";
  results: SingleResult[];
}

type DisplayItem =
  | { type: "text"; text: string }
  | { type: "toolCall"; name: string; args: Record<string, unknown> };

type OnUpdate = (partial: AgentToolResult<SubagentDetails>) => void;

interface DispatchDefaults {
  model?: string;
  thinkingLevel?: ThinkingLevel;
}

function emptyUsage(): UsageStats {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cost: 0,
    contextTokens: 0,
    turns: 0,
  };
}

function formatTokens(count: number): string {
  if (count < 1000) return count.toString();
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  return `${(count / 1000000).toFixed(1)}M`;
}

function formatUsageStats(usage: Partial<UsageStats>, model?: string): string {
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

function aggregateUsage(results: SingleResult[]): Partial<UsageStats> {
  const total = emptyUsage();
  for (const r of results) {
    total.input += r.usage.input;
    total.output += r.usage.output;
    total.cacheRead += r.usage.cacheRead;
    total.cacheWrite += r.usage.cacheWrite;
    total.cost += r.usage.cost;
    total.turns += r.usage.turns;
  }
  return { ...total, contextTokens: 0 };
}

// Mimics the built-in tools' call lines.
function formatToolCall(toolName: string, args: Record<string, unknown>, theme: Theme): string {
  const str = (value: unknown, fallback: string) =>
    typeof value === "string" && value ? value : fallback;
  const shorten = (p: string) => {
    const home = homedir();
    return p.startsWith(home) ? `~${p.slice(home.length)}` : p;
  };
  const path = shorten(str(args.file_path ?? args.path, toolName === "ls" ? "." : "..."));

  switch (toolName) {
    case "bash": {
      const command = str(args.command, "...");
      const preview = command.length > 60 ? `${command.slice(0, 60)}...` : command;
      return theme.fg("muted", "$ ") + theme.fg("toolOutput", preview);
    }
    case "read": {
      const range = formatReadLineRange(args.offset, args.limit);
      return (
        theme.fg("muted", "read ") +
        theme.fg("accent", path) +
        (range ? theme.fg("warning", range) : "")
      );
    }
    case "write": {
      const lines = str(args.content, "").split("\n").length;
      return (
        theme.fg("muted", "write ") +
        theme.fg("accent", path) +
        (lines > 1 ? theme.fg("dim", ` (${lines} lines)`) : "")
      );
    }
    case "edit":
    case "ls":
      return theme.fg("muted", `${toolName} `) + theme.fg("accent", path);
    case "find":
    case "grep": {
      const pattern = str(args.pattern, toolName === "find" ? "*" : "");
      const shown = toolName === "grep" ? `/${pattern}/` : pattern;
      const where = shorten(str(args.path, "."));
      return (
        theme.fg("muted", `${toolName} `) +
        theme.fg("accent", shown) +
        theme.fg("dim", ` in ${where}`)
      );
    }
    default: {
      const json = JSON.stringify(args);
      const preview = json.length > 50 ? `${json.slice(0, 50)}...` : json;
      return theme.fg("accent", toolName) + theme.fg("dim", ` ${preview}`);
    }
  }
}

function getFinalOutput(messages: Message[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const msg = messages[i];
    if (msg.role !== "assistant") continue;
    for (const part of msg.content) {
      if (part.type === "text") return part.text;
    }
  }
  return "";
}

function isFailedResult(result: SingleResult): boolean {
  return (
    result.exitCode > 0 || result.stopReason === "error" || result.stopReason === "aborted"
  );
}

function getResultOutput(result: SingleResult): string {
  if (isFailedResult(result)) {
    return (
      result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)"
    );
  }
  return getFinalOutput(result.messages) || "(no output)";
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

function getDisplayItems(messages: Message[]): DisplayItem[] {
  const items: DisplayItem[] = [];
  for (const msg of messages) {
    if (msg.role !== "assistant") continue;
    for (const part of msg.content) {
      if (part.type === "text") items.push({ type: "text", text: part.text });
      else if (part.type === "toolCall")
        items.push({ type: "toolCall", name: part.name, args: part.arguments });
    }
  }
  return items;
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

// Runs the same Pi as the parent: its script under the current runtime, or `pi` as a fallback.
function getPiInvocation(args: string[]): { command: string; args: string[] } {
  const script = process.argv[1];
  if (script && !script.startsWith("/$bunfs/root/") && existsSync(script)) {
    return { command: process.execPath, args: [script, ...args] };
  }
  if (!RUNTIME.test(process.execPath.split("/").pop() ?? "")) {
    return { command: process.execPath, args };
  }
  return { command: "pi", args };
}

function piArgs(agent: Agent, defaults: DispatchDefaults, task: string): string[] {
  const args = ["--mode", "json", "-p", "--no-session"];
  const model = agent.model ?? defaults.model;
  const thinkingLevel =
    agent.thinkingLevel ?? (agent.model ? undefined : defaults.thinkingLevel);
  if (model) args.push("--model", model);
  if (thinkingLevel) args.push("--thinking", thinkingLevel);
  if (agent.tools) args.push("--tools", agent.tools.join(","));
  // The roadmap belongs to the main session; children report back instead of editing it.
  args.push("--exclude-tools", "roadmap");
  args.push("--append-system-prompt", agent.prompt, `Task: ${task}`);
  return args;
}

async function runSingleAgent(
  cwd: string,
  defaults: DispatchDefaults,
  agents: Map<string, Agent>,
  agentName: string,
  task: string,
  step: number | undefined,
  signal: AbortSignal | undefined,
  onUpdate: OnUpdate | undefined,
  makeDetails: (results: SingleResult[]) => SubagentDetails,
): Promise<SingleResult> {
  const result: SingleResult = {
    agent: agentName,
    task,
    exitCode: -1,
    messages: [],
    stderr: "",
    usage: emptyUsage(),
    step,
  };
  const agent = agents.get(agentName);
  if (!agent) {
    result.exitCode = 1;
    result.stderr = `Unknown agent "${agentName}". Available: ${[...agents.keys()].join(", ")}.`;
    return result;
  }
  result.model = agent.model ?? defaults.model;

  const emitUpdate = () =>
    onUpdate?.({
      content: [{ type: "text", text: getFinalOutput(result.messages) || "(running...)" }],
      details: makeDetails([result]),
    });

  let aborted = false;
  result.exitCode = await new Promise<number>((resolve) => {
    const invocation = getPiInvocation(piArgs(agent, defaults, task));
    const proc = spawn(invocation.command, invocation.args, {
      cwd,
      env: { ...process.env, [CHILD_ENV]: "1" },
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let buffer = "";

    // Collects finished messages and usage from the child's JSON event stream.
    const processLine = (line: string) => {
      if (!line.trim()) return;
      let event: { type?: string; message?: Message };
      try {
        event = JSON.parse(line);
      } catch {
        return;
      }
      const msg = event.message;
      if (!msg || (event.type !== "message_end" && event.type !== "tool_result_end")) return;
      result.messages.push(msg);
      if (event.type === "message_end" && msg.role === "assistant") {
        result.usage.turns++;
        const usage = msg.usage;
        if (usage) {
          result.usage.input += usage.input || 0;
          result.usage.output += usage.output || 0;
          result.usage.cacheRead += usage.cacheRead || 0;
          result.usage.cacheWrite += usage.cacheWrite || 0;
          result.usage.cost += usage.cost?.total || 0;
          result.usage.contextTokens = usage.totalTokens || 0;
        }
        if (!result.model && msg.model) result.model = msg.model;
        if (msg.stopReason) result.stopReason = msg.stopReason;
        if (msg.errorMessage) result.errorMessage = msg.errorMessage;
      }
      emitUpdate();
    };

    proc.stdout.on("data", (data) => {
      buffer += data.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";
      for (const line of lines) processLine(line);
    });
    proc.stderr.on("data", (data) => {
      result.stderr += data.toString();
    });
    proc.on("close", (code) => {
      if (buffer.trim()) processLine(buffer);
      resolve(code ?? 0);
    });
    proc.on("error", () => resolve(1));

    if (signal) {
      const kill = () => {
        aborted = true;
        proc.kill("SIGTERM");
        setTimeout(() => {
          if (!proc.killed) proc.kill("SIGKILL");
        }, 5000);
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

const ChainItem = Type.Object({
  agent: Type.String({ description: "Name of the agent to invoke" }),
  task: Type.String({
    description: "Task with an optional {previous} placeholder for the prior step's output",
  }),
});

const SubagentParams = Type.Object({
  agent: Type.Optional(Type.String({ description: "Agent to invoke (single mode)" })),
  task: Type.Optional(Type.String({ description: "Task to delegate (single mode)" })),
  tasks: Type.Optional(
    Type.Array(TaskItem, {
      description: `Tasks to run in parallel (at most ${MAX_PARALLEL_TASKS})`,
    }),
  ),
  chain: Type.Optional(Type.Array(ChainItem, { description: "Steps to run in sequence" })),
});

// The checklist travels with the request, so any read-only agent can review.
const REVIEW_PROMPT = `Use the subagent tool to have the reader agent review the current uncommitted changes (git status and git diff HEAD, including untracked files). Give it this checklist: correctness, security, and maintainability; the changes against the focused roadmap plan, if there is one (missing work, unplanned work, contradicted decisions); and the documentation changes (a fact stated in two places, content in a document that does not own it, implementation details that belong in source comments, outdated text left next to its replacement). Report its findings by severity with file paths and line numbers, and do not fix anything until I ask.`;

export default function (pi: ExtensionAPI) {
  if (process.env[CHILD_ENV]) return;

  const { agents, errors } = loadAgents();
  pi.on("session_start", (_event, ctx) => {
    if (errors.length > 0) ctx.ui.notify(`Subagents: ${errors.join("; ")}`, "warning");
  });

  pi.registerCommand("review", {
    description: "Review the current changes with a read-only subagent: /review [focus]",
    handler: async (args, ctx) => {
      await ctx.waitForIdle();
      const focus = args.trim();
      pi.sendUserMessage(focus ? `${REVIEW_PROMPT}\n\nFocus: ${focus}` : REVIEW_PROMPT);
    },
  });

  pi.registerTool({
    name: "subagent",
    label: "Subagent",
    description: [
      "Delegate tasks to specialized subagents, each with an isolated context. The subagent sees only the task, so include the context it needs.",
      "Modes: single (agent + task), parallel (tasks array), chain (sequential, with {previous} replaced by the prior step's output).",
      "Agents:",
      ...[...agents].map(([name, agent]) => `- ${name}: ${agent.description}`),
    ].join("\n"),
    parameters: SubagentParams,

    async execute(_toolCallId, params, signal, onUpdate, ctx) {
      const defaults: DispatchDefaults = {
        model: ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined,
        thinkingLevel: pi.getThinkingLevel(),
      };
      const makeDetails =
        (mode: SubagentDetails["mode"]) =>
        (results: SingleResult[]): SubagentDetails => ({ mode, results });
      const run = (
        agent: string,
        task: string,
        step: number | undefined,
        update: OnUpdate | undefined,
        mode: SubagentDetails["mode"],
      ) =>
        runSingleAgent(
          ctx.cwd,
          defaults,
          agents,
          agent,
          task,
          step,
          signal,
          update,
          makeDetails(mode),
        );

      const hasChain = (params.chain?.length ?? 0) > 0;
      const hasTasks = (params.tasks?.length ?? 0) > 0;
      const hasSingle = Boolean(params.agent && params.task);
      if (Number(hasChain) + Number(hasTasks) + Number(hasSingle) !== 1) {
        return {
          content: [
            {
              type: "text",
              text: `Invalid parameters: provide exactly one mode.\nAgents: ${[...agents.keys()].join(", ")}`,
            },
          ],
          details: makeDetails("single")([]),
          isError: true,
        };
      }

      if (params.chain && hasChain) {
        const results: SingleResult[] = [];
        let previous = "";
        for (const [i, step] of params.chain.entries()) {
          const update: OnUpdate | undefined = onUpdate
            ? (partial) => {
                const current = partial.details?.results[0];
                if (current)
                  onUpdate({
                    content: partial.content,
                    details: makeDetails("chain")([...results, current]),
                  });
              }
            : undefined;
          // biome-ignore lint/performance/noAwaitInLoops: each step needs the previous output.
          const result = await run(
            step.agent,
            step.task.replace(PREVIOUS, previous),
            i + 1,
            update,
            "chain",
          );
          results.push(result);
          if (isFailedResult(result)) {
            return {
              content: [
                {
                  type: "text",
                  text: `Chain stopped at step ${i + 1} (${step.agent}): ${getResultOutput(result)}`,
                },
              ],
              details: makeDetails("chain")(results),
              isError: true,
            };
          }
          previous = getFinalOutput(result.messages);
        }
        return {
          content: [{ type: "text", text: previous || "(no output)" }],
          details: makeDetails("chain")(results),
        };
      }

      if (params.tasks && hasTasks) {
        const tasks = params.tasks;
        if (tasks.length > MAX_PARALLEL_TASKS) {
          return {
            content: [
              {
                type: "text",
                text: `Too many parallel tasks (${tasks.length}). Max is ${MAX_PARALLEL_TASKS}.`,
              },
            ],
            details: makeDetails("parallel")([]),
            isError: true,
          };
        }

        const all: SingleResult[] = tasks.map((t) => ({
          agent: t.agent,
          task: t.task,
          exitCode: -1,
          messages: [],
          stderr: "",
          usage: emptyUsage(),
        }));
        const emitParallelUpdate = () => {
          const done = all.filter((r) => r.exitCode !== -1).length;
          onUpdate?.({
            content: [
              {
                type: "text",
                text: `Parallel: ${done}/${all.length} done, ${all.length - done} running...`,
              },
            ],
            details: makeDetails("parallel")([...all]),
          });
        };

        const results = await mapWithConcurrencyLimit(tasks, MAX_CONCURRENCY, async (t, i) => {
          const result = await run(
            t.agent,
            t.task,
            undefined,
            (partial) => {
              const current = partial.details?.results[0];
              if (current) {
                all[i] = current;
                emitParallelUpdate();
              }
            },
            "parallel",
          );
          all[i] = result;
          emitParallelUpdate();
          return result;
        });

        const succeeded = results.filter((r) => !isFailedResult(r)).length;
        const summaries = results.map((r) => {
          const status = isFailedResult(r)
            ? `failed${r.stopReason && r.stopReason !== "stop" ? ` (${r.stopReason})` : ""}`
            : "completed";
          return `### [${r.agent}] ${status}\n\n${truncateOutput(getResultOutput(r))}`;
        });
        return {
          content: [
            {
              type: "text",
              text: `Parallel: ${succeeded}/${results.length} succeeded\n\n${summaries.join("\n\n---\n\n")}`,
            },
          ],
          details: makeDetails("parallel")(results),
        };
      }

      const result = await run(
        params.agent ?? "",
        params.task ?? "",
        undefined,
        onUpdate,
        "single",
      );
      if (isFailedResult(result)) {
        return {
          content: [
            {
              type: "text",
              text: `Agent ${result.stopReason || "failed"}: ${getResultOutput(result)}`,
            },
          ],
          details: makeDetails("single")([result]),
          isError: true,
        };
      }
      return {
        content: [{ type: "text", text: getFinalOutput(result.messages) || "(no output)" }],
        details: makeDetails("single")([result]),
      };
    },

    renderCall(args, theme, _context) {
      const title = theme.fg("toolTitle", theme.bold("subagent "));
      const preview = (task: string, max: number) => {
        const clean = task.replace(PREVIOUS, "").trim();
        return clean.length > max ? `${clean.slice(0, max)}...` : clean;
      };
      const list = (steps: { agent: string; task: string }[], numbered: boolean) => {
        let text = "";
        for (const [i, step] of steps.slice(0, 3).entries()) {
          const prefix = numbered ? `${theme.fg("muted", `${i + 1}.`)} ` : "";
          text += `\n  ${prefix}${theme.fg("accent", step.agent)}${theme.fg("dim", ` ${preview(step.task, 40)}`)}`;
        }
        if (steps.length > 3)
          text += `\n  ${theme.fg("muted", `... +${steps.length - 3} more`)}`;
        return text;
      };

      if (args.chain && args.chain.length > 0) {
        const head = theme.fg("accent", `chain (${args.chain.length} steps)`);
        return new Text(title + head + list(args.chain, true), 0, 0);
      }
      if (args.tasks && args.tasks.length > 0) {
        const head = theme.fg("accent", `parallel (${args.tasks.length} tasks)`);
        return new Text(title + head + list(args.tasks, false), 0, 0);
      }
      const shown = args.task ? preview(args.task, 60) : "...";
      return new Text(
        `${title}${theme.fg("accent", args.agent || "...")}\n  ${theme.fg("dim", shown)}`,
        0,
        0,
      );
    },

    renderResult(result, { expanded }, theme, _context) {
      const details = result.details as SubagentDetails | undefined;
      if (!details || details.results.length === 0) {
        const text = result.content[0];
        return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
      }

      const mdTheme = getMarkdownTheme();
      const fg = (color: ThemeColor, value: string) => theme.fg(color, value);
      const statusIcon = (r: SingleResult) =>
        r.exitCode === -1
          ? fg("warning", "⏳")
          : isFailedResult(r)
            ? fg("error", "✗")
            : fg("success", "✓");
      const toolLine = (item: DisplayItem & { type: "toolCall" }) =>
        fg("muted", "→ ") + formatToolCall(item.name, item.args, theme);

      const renderItems = (items: DisplayItem[], limit: number) => {
        const skipped = Math.max(0, items.length - limit);
        const lines = skipped > 0 ? [fg("muted", `... ${skipped} earlier items`)] : [];
        for (const item of items.slice(-limit)) {
          lines.push(
            item.type === "text"
              ? fg("toolOutput", item.text.split("\n").slice(0, 3).join("\n"))
              : toolLine(item),
          );
        }
        return lines.join("\n");
      };

      // Expanded: the task, every tool call, and the final output as Markdown.
      const addExpanded = (container: Container, r: SingleResult, title: string) => {
        container.addChild(new Text(title, 0, 0));
        if (isFailedResult(r)) container.addChild(new Text(fg("error", errorText(r)), 0, 0));
        container.addChild(new Text(fg("muted", "Task: ") + fg("dim", r.task), 0, 0));
        for (const item of getDisplayItems(r.messages)) {
          if (item.type === "toolCall") container.addChild(new Text(toolLine(item), 0, 0));
        }
        const output = getFinalOutput(r.messages);
        if (output) {
          container.addChild(new Spacer(1));
          container.addChild(new Markdown(output.trim(), 0, 0, mdTheme));
        }
        const usage = formatUsageStats(r.usage, r.model);
        if (usage) container.addChild(new Text(fg("dim", usage), 0, 0));
      };

      if (details.mode === "single") {
        const r = details.results[0];
        const header = `${statusIcon(r)} ${fg("toolTitle", theme.bold(r.agent))}${
          isFailedResult(r) && r.stopReason ? ` ${fg("error", `[${r.stopReason}]`)}` : ""
        }`;
        if (expanded) {
          const container = new Container();
          addExpanded(container, r, header);
          return container;
        }
        const items = getDisplayItems(r.messages);
        let text = header;
        if (isFailedResult(r)) text += `\n${fg("error", errorText(r))}`;
        else if (items.length === 0) text += `\n${fg("muted", "(no output)")}`;
        else {
          text += `\n${renderItems(items, COLLAPSED_ITEM_COUNT)}`;
          if (items.length > COLLAPSED_ITEM_COUNT)
            text += `\n${fg("muted", "(Ctrl+O to expand)")}`;
        }
        const usage = formatUsageStats(r.usage, r.model);
        if (usage) text += `\n${fg("dim", usage)}`;
        return new Text(text, 0, 0);
      }

      // Chain and parallel: one section per step or task.
      const running = details.results.filter((r) => r.exitCode === -1).length;
      const succeeded = details.results.filter(
        (r) => r.exitCode !== -1 && !isFailedResult(r),
      ).length;
      const total = details.results.length;
      const icon =
        running > 0
          ? fg("warning", "⏳")
          : succeeded === total
            ? fg("success", "✓")
            : fg("error", "✗");
      const status =
        details.mode === "chain"
          ? `${succeeded}/${total} steps`
          : running > 0
            ? `${total - running}/${total} done, ${running} running`
            : `${succeeded}/${total} tasks`;
      const header = `${icon} ${fg("toolTitle", theme.bold(`${details.mode} `))}${fg("accent", status)}`;
      const label = (r: SingleResult) =>
        `${fg("muted", r.step ? `─── Step ${r.step}: ` : "─── ")}${fg("accent", r.agent)} ${statusIcon(r)}`;
      const totalUsage = running > 0 ? "" : formatUsageStats(aggregateUsage(details.results));

      if (expanded && running === 0) {
        const container = new Container();
        container.addChild(new Text(header, 0, 0));
        for (const r of details.results) {
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
      for (const r of details.results) {
        const items = getDisplayItems(r.messages);
        text += `\n\n${label(r)}\n`;
        if (isFailedResult(r)) text += fg("error", errorText(r));
        else if (items.length > 0) text += renderItems(items, 5);
        else text += fg("muted", r.exitCode === -1 ? "(running...)" : "(no output)");
      }
      if (totalUsage) text += `\n\n${fg("dim", `Total: ${totalUsage}`)}`;
      if (!expanded) text += `\n${fg("muted", "(Ctrl+O to expand)")}`;
      return new Text(text, 0, 0);
    },
  });
}
